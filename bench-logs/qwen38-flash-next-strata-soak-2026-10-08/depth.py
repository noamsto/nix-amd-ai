"""Long-context and two-session groups for probe.py (#282), loaded like soak.py: `run_*(e, c, P)` where `e` is probe's
engine namespace (port, model, pid, args, gtt0, vram0), `c` the corpus cache and `P` probe's module. Both groups run on
Strata and on llama-server, over /v1/chat/completions with thinking off.

  run_depth       one agent conversation grown stage by stage to the engine's context limit: at each depth the prefill rate
                  of the new tokens, a 1,500-token agent turn on the cached prefix, and the decode rate (MTP acceptance
                  where the server reports it)
  run_twosession  two such conversations at limit-24K tokens each in two slots: does one session's prefill or request
                  evict the other's cache, per-stream and combined decode concurrent and staggered, then a third session

The text is the repo's own tracked files at a pinned commit, never repeated, so neither prompt lookup nor a prefix cache
can answer from earlier text. A request that fails is recorded and ends the group: deeper stages would fail the same way.
A decode rate is reported only for a request that ran to its token limit (`finish` length): one that ended as a tool call or a
short answer says nothing about the sustained rate and carries `short: true` instead.
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
ESSAY = ("Do not call any tool. Write a very long, detailed, multi-section essay in prose about the documents above, "
         "at least 1500 words.")
SESSION_HEADROOM = 24000  # a two-session fill leaves room for ~10 turns of 1,500 tokens and replies of up to 400
FILL_TOLERANCE = 0.03  # a session fill stops within this fraction of its target
HEADROOM = 5000  # the last stage stops this far under the limit: one turn, the essay and the template
HARNESS = 2  # two-session groups written before this (replies often cut short) carry no `harness` key
STAGGER_S = 3  # the second request of a staggered round arrives this long after the first


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


def full_length(r):
    """True for a request that ran to its token limit: only those say anything about the sustained decode rate."""
    return r["finish_reason"] == "length"


def aggregate_tps(timed):
    """Tokens per second over the span in which any of the concurrent requests was generating. `timed` holds
    (result, start_s) with start_s the request's send time on the round's clock, since ttft counts from each own send."""
    lo = min(s + r["ttft_s"] for r, s in timed)
    hi = max(s + r["ttft_s"] + r["gen_s"] for r, s in timed)
    return round(sum(r["completion_tokens"] for r, _ in timed) / (hi - lo), 2) if hi > lo else None


class Convo:
    """One agent session: the replay's system prompt and tools, a nonce user task, then tool turns of unseen text."""

    def __init__(self, c, source, tag, ratio):
        rp = c["replay"]
        self.tools, self.source, self.ratio, self.turns = rp["tools"], source, ratio, 0
        self.msgs = [{"role": "system", "content": rp["system"]},
                     {"role": "user", "content": f"# session {tag} {uuid.uuid4()}\n{rp['user']}"}]
        self.chars = 0

    def add_turn(self, tokens, ask=None):
        """A tool call and its result of unseen text, then `ask` as the user's next message. A reply committed before
        this turn gets a user message in front of the next call, as an agent's transcript would."""
        self.turns += 1
        if self.msgs[-1]["role"] == "assistant":
            self.msgs.append({"role": "user", "content": "Continue with the next file."})
        text = self.source.take(int(tokens * self.ratio))
        self.chars += len(text)
        call = {"id": f"call_{self.turns}", "type": "function",
                "function": {"name": "read_file", "arguments": f'{{"path": "chunk-{self.turns}.md"}}'}}
        self.msgs += [{"role": "assistant", "content": f"I'll read chunk-{self.turns}.md next.", "tool_calls": [call]},
                      {"role": "tool", "tool_call_id": call["id"], "content": text}]
        if ask:
            self.msgs.append({"role": "user", "content": ask})

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
        """`essay` adds a throwaway user message: the next request's prompt will not contain it."""
        msgs = self.msgs + ([{"role": "user", "content": ESSAY}] if essay else [])
        return {"messages": msgs, "tools": self.tools, "max_tokens": max_tokens, "temperature": temperature,
                "seed": 0, "cache_prompt": True, **P.thinking_off(e)}


def summarize(P, r, long=False):
    """The fields every request of these groups reports. `new_tokens` is what the prefill had to read, None when the
    server does not say what it cached. A decode rate and acceptance are kept only for a request that ran to its token
    limit; `long` marks a request that was meant to, and one that did not carries `short: true`."""
    cached = r["cached_tokens"]
    new = None if cached is None else r["prompt_tokens"] - cached
    tps = P.decode_tps(r) if full_length(r) else None
    out = {"prompt_tokens": r["prompt_tokens"], "cached_tokens": cached, "new_tokens": new,
           "ttft_s": round(r["ttft_s"], 3), "prefill_tps": round(new / r["ttft_s"], 1) if new and new > 0 else None,
           "completion_tokens": r["completion_tokens"], "decode_tps": None if tps is None else round(tps, 2),
           "acceptance": acceptance(r) if full_length(r) else None, "finish": r["finish_reason"],
           "wall_s": round(r["wall_s"], 2)}
    if long and not full_length(r):
        out["short"] = True
    return out


def fill_tokens(e):
    """Output budget of the requests that only exist to prefill: llama-server buffers a tool call until it is complete, so
    a reply cut at 8 tokens streams nothing."""
    return 64 if e.engine == "llama" else 8


def request(P, e, body):
    return P.stream(e, "/v1/chat/completions", body)


def load_text(P):
    return load_corpus(P.os.getcwd())  # run.sh runs probe.py from the repo root


def calibrate(P, e, c, text):
    """Characters per token of this corpus through this engine's tokenizer, from the replay prompt alone."""
    base = request(P, e, Convo(c, Source(""), "calibrate", 1).body(P, e, fill_tokens(e)))["prompt_tokens"]
    probe = Convo(c, Source(text), "calibrate", 3.5)
    probe.add_turn(8000)
    r2 = request(P, e, probe.body(P, e, fill_tokens(e)))
    return base, probe.chars / (r2["prompt_tokens"] - base)


def snap(P, e):
    return {**P.mem_snapshot(e.pid, e.gtt0, e.vram0), "loadavg": round(P.os.getloadavg()[0], 2)}


def limit_of(e):
    """Tokens one session can hold: strata's --max-context, or llama-server's -c split over its slots."""
    return e.args.ctx // (max(1, e.args.slots) if e.engine == "llama" else 1)


def guarded(fn, e, c, P):
    """A group's setup (corpus, calibration) failing is recorded as the group's error, not raised out of the row."""
    try:
        return fn(e, c, P)
    except Exception as exc:  # noqa: BLE001 - a row keeps the groups that did run
        return {"error": f"{type(exc).__name__}: {str(exc)[:300]}"}


# ---- one session to the limit -----------------------------------------------------------------------------------

def run_depth(e, c, P):
    return guarded(depth_group, e, c, P)


def depth_group(e, c, P):
    limit = limit_of(e)
    text = load_text(P)
    base, ratio = calibrate(P, e, c, text)
    convo = Convo(c, Source(text), "depth", ratio)
    out = {"context_limit": limit, "calibrated_chars_per_token": round(ratio, 3), "base_prompt_tokens": base,
           "corpus_rev": CORPUS_REV, "stages": []}
    depth = base
    for target in stage_targets(limit):
        stage = {"target": target}
        try:
            convo.add_tokens(target - depth)
            fill = request(P, e, convo.body(P, e, fill_tokens(e)))
            stage["fill"] = summarize(P, fill)
            convo.ratio = convo.chars / max(1, fill["prompt_tokens"] - base)  # refine on the measured count
            convo.add_turn(TURN_TOKENS)
            turn = request(P, e, convo.body(P, e, P.REPLAY_GEN))
            stage["turn"] = summarize(P, turn)
            essay = request(P, e, convo.body(P, e, 256, essay=True))
            stage["essay"] = summarize(P, essay, long=True)
            depth = turn["prompt_tokens"]
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
    """One agent turn: new tool output, `ask` as the user's message, the reply kept in the transcript."""
    convo.add_turn(TURN_TOKENS, ask)
    r = request(P, e, convo.body(P, e, max_tokens))
    convo.commit(r)
    return r


def concurrent(P, e, jobs):
    """Run each (convo, max_tokens, ask, delay_s) at once. Results in order: (result, start_s) with start_s the send time
    on the round's clock, or the error as a string."""
    results = [None] * len(jobs)
    t_round = time.perf_counter()

    def go(i):
        convo, tokens, ask, delay = jobs[i]
        time.sleep(delay)
        start = time.perf_counter() - t_round
        try:
            results[i] = (turn_request(P, e, convo, tokens, ask), start)
        except Exception as exc:  # noqa: BLE001 - recorded, the round continues
            results[i] = f"{type(exc).__name__}: {str(exc)[:300]}"

    threads = [threading.Thread(target=go, args=(i,)) for i in range(len(jobs))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


def round_row(P, results, longs):
    """Per-stream summaries, and the combined rate only when every stream was meant to run to its limit (`longs`) and did:
    one that ended early would make the span and the token count say different things. A round with a one-line stream, like
    the staggered one, never gets a combined rate."""
    ok = [x for x in results if not isinstance(x, str)]
    streams = [x if isinstance(x, str) else {**summarize(P, x[0], long=lg), "start_s": round(x[1], 2)}
               for x, lg in zip(results, longs)]
    clean = all(longs) and len(ok) == len(results) and all(full_length(r) for r, _ in ok)
    return {"streams": streams, "combined_tps": aggregate_tps(ok) if clean else None}


def run_twosession(e, c, P):
    return guarded(twosession_group, e, c, P)


def twosession_group(e, c, P):
    limit = limit_of(e)
    depth = limit - SESSION_HEADROOM
    text = load_text(P)
    base, ratio = calibrate(P, e, c, text)
    a, b = Convo(c, Source(text, 0), "A", ratio), Convo(c, Source(text, len(text) // 2), "B", ratio)
    out = {"harness": HARNESS, "context_limit": limit, "session_tokens": depth,
           "calibrated_chars_per_token": round(ratio, 3), "corpus_rev": CORPUS_REV}
    try:
        view = P.grid.http(e.port, "/slots", timeout=30)
        out["slots_seen"] = [{k: s.get(k) for k in ("id", "n_ctx")} for s in view]
    except Exception as exc:  # noqa: BLE001 - not every server has it
        out["slots_seen"] = f"{type(exc).__name__}"

    def fill(convo):
        """Grow to `depth` in measured steps: the corpus is denser in tokens further in than where the ratio was taken."""
        steps, cur = [], base
        while depth - cur > depth * FILL_TOLERANCE:
            need = depth - cur
            convo.add_tokens(int(need * 0.9) if need > 20000 else need)
            r = request(P, e, convo.body(P, e, fill_tokens(e)))
            convo.commit(r)
            steps.append(summarize(P, r))
            convo.ratio = convo.chars / max(1, r["prompt_tokens"] - base)
            cur = r["prompt_tokens"]
        return steps

    def seq_turn(convo, tokens, ask=None):
        return summarize(P, turn_request(P, e, convo, tokens, ask), long=ask == ESSAY)

    try:
        out["prefill_A"] = fill(a)
        out["prefill_B"] = fill(b)  # A idle meanwhile
        out["mem_after_prefill"] = snap(P, e)
        # the last fill request again with its reply appended, B's then A's: a hit means the server still holds the session
        for key, convo in (("B", b), ("A", a)):
            r = request(P, e, convo.body(P, e, fill_tokens(e)))
            out[f"repeat_{key}"] = summarize(P, r)
        # one agent turn each in turn: A's cache after B's whole prefill and a repeat, then B's, then A's again
        out["alone_A"] = seq_turn(a, 256, ESSAY)
        out["alone_B"] = seq_turn(b, 256, ESSAY)
        out["alone_A_again"] = seq_turn(a, 256, ESSAY)
        out["rounds"] = []
        for kind in ("concurrent", "concurrent", "staggered"):
            # staggered: A decodes a long essay, B's agent turn arrives STAGGER_S in and wants a one-line answer
            if kind == "concurrent":
                jobs, longs = [(a, 400, ESSAY, 0), (b, 400, ESSAY, 0)], [True, True]
            else:
                jobs, longs = [(a, 400, ESSAY, 0), (b, 64, "Do not call any tool. Answer in one sentence.", STAGGER_S)], [True, False]
            out["rounds"].append({"kind": kind, **round_row(P, concurrent(P, e, jobs), longs)})
        out["mem_after_rounds"] = snap(P, e)
        # a third session: does its prefill take a slot's cache from A or B?
        third = Convo(c, Source(text, len(text) // 4), "C", ratio)
        third.add_tokens(16000)
        out["third_prefill"] = summarize(P, request(P, e, third.body(P, e, fill_tokens(e))))
        out["after_third_A"] = seq_turn(a, 64)
        out["after_third_B"] = seq_turn(b, 64)
        out["mem_end"] = snap(P, e)
    except Exception as exc:  # noqa: BLE001 - what ran is kept
        out["error"] = f"{type(exc).__name__}: {str(exc)[:300]}"
    return out
