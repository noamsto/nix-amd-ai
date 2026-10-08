"""Long-context and two-session groups for probe.py (#282), loaded like soak.py: `run_*(e, c, P)` where `e` is probe's
engine namespace (port, model, pid, args, gtt0, vram0), `c` the corpus cache and `P` probe's module. Both groups run on
Strata and on llama-server, over /v1/chat/completions with thinking off.

  run_depth       one agent conversation grown stage by stage to the engine's context limit: at each depth the prefill rate
                  of the new tokens, a 1,500-token agent turn on the cached prefix, and the decode rate (MTP acceptance
                  where the server reports it)
  run_twosession  two such conversations at ~limit-12K tokens each in two slots: does one session's prefill or request
                  evict the other's cache, per-stream and aggregate decode concurrent and staggered, then a third session

The text is the repo's own tracked files at a pinned commit, never repeated, so neither prompt lookup nor a prefix cache
can answer from earlier text. A request that fails is recorded and ends the group: deeper stages would fail the same way.
"""
import subprocess
import threading
import time
import uuid

CORPUS_REV = "29202b453430ecd630eaf7d8bf573f35fde978c1"
SKIP_SUFFIXES = (".png", ".jpg", ".gif", ".lock", ".bin", ".jsonl", ".json", ".log")
STAGES = (8192, 32768, 65536, 98304, 131072, 163840, 196608, 229376, 262144)
TURN_TOKENS = 1500
FILL_TURN_MAX = 16000
ESSAY = "Write a very long, detailed, multi-section essay about the documents above, at least 1500 words."
SESSION_HEADROOM = 24000  # a two-session fill leaves room for ~10 turns of 1,500 tokens and replies of up to 400
FILL_TOLERANCE = 0.03  # a session fill stops within this fraction of its target
HEADROOM = 5000  # the last stage stops this far under the limit: one turn, the essay and the template


class Source:
    """The corpus as one text, handed out front to back from `start`; a session never sees the same text twice."""

    def __init__(self, text, start=0):
        self.text, self.pos = text, start

    def take(self, chars):
        if self.pos + chars > len(self.text):
            raise RuntimeError(f"corpus exhausted at {self.pos} of {len(self.text)} chars")
        out = self.text[self.pos:self.pos + chars]
        self.pos += chars
        return out


def load_corpus(root, rev=CORPUS_REV):
    def git(*args):
        return subprocess.run(["git", "-C", root, *args], capture_output=True, check=True).stdout

    parts = []
    for path in sorted(git("ls-tree", "-r", "--name-only", "-z", rev).decode().split("\0")):
        if not path or path.endswith(SKIP_SUFFIXES):
            continue
        try:
            body = git("show", f"{rev}:{path}").decode()
        except UnicodeDecodeError:
            continue
        parts.append(f"# {path}\n\n{body}\n\n")
    return "".join(parts)


def stage_targets(limit):
    """Context depths to measure: the fixed ladder under the limit, then the deepest one a turn and an essay still fit."""
    last = limit - HEADROOM
    return [s for s in STAGES if s < last] + [last]


def acceptance(r):
    t = r["timings"] or {}
    return round(t["draft_n_accepted"] / t["draft_n"], 4) if t.get("draft_n") else None


def aggregate_tps(results):
    """Tokens per second over the span in which any of the concurrent requests was generating."""
    lo = min(r["ttft_s"] for r in results)
    hi = max(r["ttft_s"] + r["gen_s"] for r in results)
    return round(sum(r["completion_tokens"] for r in results) / (hi - lo), 2) if hi > lo else None


class Convo:
    """One agent session: the replay's system prompt and tools, a nonce user task, then tool turns of unseen text."""

    def __init__(self, c, source, tag, ratio):
        rp = c["replay"]
        self.tools, self.source, self.ratio, self.turns = rp["tools"], source, ratio, 0
        self.msgs = [{"role": "system", "content": rp["system"]},
                     {"role": "user", "content": f"# session {tag} {uuid.uuid4()}\n{rp['user']}"}]
        self.chars = 0

    def add_turn(self, tokens, ask=None):
        """A tool call and its result of unseen text; `ask` goes after the text, and a reply committed before this turn
        gets a user message in front of the next call, as an agent's transcript would."""
        self.turns += 1
        if self.msgs[-1]["role"] == "assistant":
            self.msgs.append({"role": "user", "content": "Continue with the next file."})
        text = self.source.take(int(tokens * self.ratio))
        self.chars += len(text)
        if ask:
            text += f"\n\n{ask}"
        call = {"id": f"call_{self.turns}", "type": "function",
                "function": {"name": "read_file", "arguments": f'{{"path": "chunk-{self.turns}.md"}}'}}
        self.msgs += [{"role": "assistant", "content": f"I'll read chunk-{self.turns}.md next.", "tool_calls": [call]},
                      {"role": "tool", "tool_call_id": call["id"], "content": text}]

    def commit(self, r):
        """Keep the model's reply in the transcript: the next request's prompt then extends what the server last held."""
        if r["text"].strip():
            self.msgs.append({"role": "assistant", "content": r["text"]})

    def add_tokens(self, tokens):
        while tokens > 0:
            step = min(tokens, FILL_TURN_MAX)
            self.add_turn(step)
            tokens -= step

    def body(self, P, e, max_tokens, essay=False, temperature=0):
        msgs = self.msgs + ([{"role": "user", "content": ESSAY}] if essay else [])
        return {"messages": msgs, "tools": self.tools, "max_tokens": max_tokens, "temperature": temperature,
                "seed": 0, "cache_prompt": True, **P.thinking_off(e)}


def summarize(P, r, prev_prompt=None):
    """The fields every request of these groups reports. `new_tokens` is what the prefill had to read."""
    cached = r["cached_tokens"]
    new = r["prompt_tokens"] - (cached if cached is not None else (prev_prompt or 0))
    tps = P.decode_tps(r)
    return {"prompt_tokens": r["prompt_tokens"], "cached_tokens": cached, "new_tokens": new,
            "ttft_s": round(r["ttft_s"], 3), "prefill_tps": round(new / r["ttft_s"], 1) if new > 0 else None,
            "completion_tokens": r["completion_tokens"], "decode_tps": None if tps is None else round(tps, 2),
            "acceptance": acceptance(r), "finish": r["finish_reason"], "wall_s": round(r["wall_s"], 2)}


def fill_tokens(e):
    """Output budget of the requests that only exist to prefill: llama-server buffers a tool call until it is complete, so
    a reply cut at 8 tokens streams nothing."""
    return 64 if e.engine == "llama" else 8


def request(P, e, body):
    return P.stream(e, "/v1/chat/completions", body)


def calibrate(P, e, c):
    """Characters per token of this corpus through this engine's tokenizer, from the replay prompt alone."""
    convo = Convo(c, Source(""), "calibrate", 1)
    r = request(P, e, convo.body(P, e, fill_tokens(e)))
    base = r["prompt_tokens"]
    probe = Convo(c, Source(load_text(P)), "calibrate", 3.5)
    probe.add_turn(8000)
    r2 = request(P, e, probe.body(P, e, fill_tokens(e)))
    ratio = probe.chars / (r2["prompt_tokens"] - base)
    return base, ratio


def load_text(P):
    return load_corpus(P.os.getcwd())  # run.sh runs probe.py from the repo root


def snap(P, e):
    return {**P.mem_snapshot(e.pid, e.gtt0, e.vram0), "loadavg": round(P.os.getloadavg()[0], 2)}


def limit_of(e):
    """Tokens one session can hold: strata's --max-context, or llama-server's -c split over its slots."""
    return e.args.ctx // max(1, e.args.slots)


# ---- one session to the limit -----------------------------------------------------------------------------------

def run_depth(e, c, P):
    limit = limit_of(e)
    base, ratio = calibrate(P, e, c)
    convo = Convo(c, Source(load_text(P)), "depth", ratio)
    out = {"context_limit": limit, "calibrated_chars_per_token": round(ratio, 3), "base_prompt_tokens": base,
           "corpus_rev": CORPUS_REV, "stages": []}
    prev = base
    depth = base
    for target in stage_targets(limit):
        stage = {"target": target}
        try:
            convo.add_tokens(target - depth)
            fill = request(P, e, convo.body(P, e, fill_tokens(e)))
            stage["fill"] = summarize(P, fill, prev)
            convo.ratio = convo.chars / max(1, fill["prompt_tokens"] - base)  # refine on the measured count
            convo.add_turn(TURN_TOKENS)
            turn = request(P, e, convo.body(P, e, P.REPLAY_GEN))
            stage["turn"] = summarize(P, turn, fill["prompt_tokens"])
            essay = request(P, e, convo.body(P, e, 256, essay=True))
            stage["essay"] = summarize(P, essay, turn["prompt_tokens"])
            prev = turn["prompt_tokens"]
            depth = prev
            stage["mem"] = snap(P, e)
        except Exception as exc:  # noqa: BLE001 - a failed stage is the finding; deeper ones would fail alike
            stage["error"] = f"{type(exc).__name__}: {str(exc)[:300]}"
            out["stages"].append(stage)
            out["stopped_at"] = target
            return out
        out["stages"].append(stage)
    out["reached_tokens"] = depth
    return out


# ---- two sessions ------------------------------------------------------------------------------------------------

def turn_request(P, e, convo, max_tokens, ask=None):
    """One agent turn: new tool output (asking for a long reply when `ask` is set), the reply kept in the transcript."""
    convo.add_turn(TURN_TOKENS, ask)
    r = request(P, e, convo.body(P, e, max_tokens))
    convo.commit(r)
    return r


def concurrent(P, e, jobs):
    """Run each (convo, max_tokens, ask, delay_s) at once; raw results in order, errors kept as strings."""
    results = [None] * len(jobs)

    def go(i):
        convo, tokens, ask, delay = jobs[i]
        time.sleep(delay)
        try:
            results[i] = turn_request(P, e, convo, tokens, ask)
        except Exception as exc:  # noqa: BLE001 - recorded, the round continues
            results[i] = f"{type(exc).__name__}: {str(exc)[:300]}"

    threads = [threading.Thread(target=go, args=(i,)) for i in range(len(jobs))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


def round_row(P, results, prevs):
    ok = [r for r in results if not isinstance(r, str)]
    return {"streams": [r if isinstance(r, str) else summarize(P, r, p) for r, p in zip(results, prevs)],
            "aggregate_tps": aggregate_tps(ok) if len(ok) == len(results) else None}


def run_twosession(e, c, P):
    limit = limit_of(e)
    depth = limit - SESSION_HEADROOM
    base, ratio = calibrate(P, e, c)
    text = load_text(P)
    a, b = Convo(c, Source(text, 0), "A", ratio), Convo(c, Source(text, len(text) // 2), "B", ratio)
    out = {"context_limit": limit, "session_tokens": depth, "slots": e.args.slots, "calibrated_chars_per_token": round(ratio, 3),
           "corpus_rev": CORPUS_REV}
    try:
        out["slots_view"] = P.grid.http(e.port, "/slots", timeout=30)
    except Exception as exc:  # noqa: BLE001 - not every server has it
        out["slots_view"] = f"{type(exc).__name__}"
    prompt = {}

    def fill(convo, key):
        """Grow to `depth` in measured steps: the corpus is denser in tokens further in than where the ratio was taken."""
        steps, cur = [], base
        while depth - cur > depth * FILL_TOLERANCE:
            need = depth - cur
            convo.add_tokens(int(need * 0.9) if need > 20000 else need)
            r = request(P, e, convo.body(P, e, fill_tokens(e)))
            convo.commit(r)
            steps.append(summarize(P, r, cur))
            convo.ratio = convo.chars / max(1, r["prompt_tokens"] - base)
            cur = r["prompt_tokens"]
        prompt[key] = cur
        return steps

    def seq_turn(convo, key, tokens, ask=None):
        r = turn_request(P, e, convo, tokens, ask)
        s = summarize(P, r, prompt[key])
        prompt[key] = r["prompt_tokens"]
        return s

    try:
        out["prefill_A"] = fill(a, "A")
        out["prefill_B"] = fill(b, "B")  # A idle in its slot
        out["mem_after_prefill"] = snap(P, e)
        # the identical request again, B's then A's: a hit means the server still holds that session's tokens
        for key, convo in (("B", b), ("A", a)):
            r = request(P, e, convo.body(P, e, fill_tokens(e)))
            out[f"repeat_{key}"] = summarize(P, r, prompt[key])
        # A's cache after B's whole prefill, then B's cache after A's turn: sequential turns, one stream each
        out["alone_A"] = seq_turn(a, "A", 256, ESSAY)
        out["alone_B"] = seq_turn(b, "B", 256, ESSAY)
        # the same again, now that each has just run: is a session's second turn a hit
        out["alone_A_again"] = seq_turn(a, "A", 256, ESSAY)
        out["rounds"] = []
        for kind in ("concurrent", "concurrent", "staggered"):
            before = [prompt["A"], prompt["B"]]
            # staggered: A decodes a long essay, B's agent turn arrives 3 s in and wants a short answer
            jobs = [(a, 400, ESSAY, 0), (b, 400, ESSAY, 0)] if kind == "concurrent" else [(a, 400, ESSAY, 0), (b, 64, None, 3)]
            res = concurrent(P, e, jobs)
            out["rounds"].append({"kind": kind, **round_row(P, res, before)})
            for key, r in zip("AB", res):
                if not isinstance(r, str):
                    prompt[key] = r["prompt_tokens"]
        out["mem_after_rounds"] = snap(P, e)
        # a third session: does its prefill take a slot's cache from A or B?
        third = Convo(c, Source(text, len(text) // 4), "C", ratio)
        third.add_tokens(16000)
        r = request(P, e, third.body(P, e, fill_tokens(e)))
        out["third_prefill"] = summarize(P, r, base)
        out["after_third_A"] = seq_turn(a, "A", 64)
        out["after_third_B"] = seq_turn(b, "B", 64)
        out["mem_end"] = snap(P, e)
    except Exception as exc:  # noqa: BLE001 - what ran is kept
        out["error"] = f"{type(exc).__name__}: {str(exc)[:300]}"
    return out
