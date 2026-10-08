"""Markdown tables for the README from a rows.jsonl written by rows.sh: python3 tables.py rows.jsonl [section...]

Sections: rows (one line per row), replay, conc, depth, two, rounds, long. The last row of a label wins, so a re-run replaces.
A group that failed (`{"error": ...}`) or stopped part-way shows as such instead of as numbers."""
import json
import sys

GIB = 1 << 30
TWO_ROWS = ("two128", "two128-nobatch", "two128-mtp", "two128-park", "two256-park", "gsq-two128")
DEPTH_ROWS = ("depth192", "depth256", "nomtp-depth128", "gsq-depth192", "gsq-depth256")


def load(path):
    rows = {}
    for line in open(path, encoding="utf-8"):
        r = json.loads(line)
        rows[r["label"].removeprefix("s282-")] = r
    return rows


def gib(b):
    return "-" if b is None else f"{b / GIB:.1f}"


def kib(kb):
    return "-" if kb is None else f"{kb / (1 << 20):.1f}"


def f(x, nd=1):
    return "-" if x is None else f"{x:.{nd}f}"


def cell(x):
    """A table cell from arbitrary text: errors carry pipes and newlines."""
    return str(x).replace("|", "/").replace("\n", " ")


def table(head, body):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---:" if i else "---" for i in range(len(head))) + "|"]
    return "\n".join(out + ["| " + " | ".join(cell(c) for c in r) + " |" for r in body])


def failed(g, *payload):
    """True for a group that holds only its error: none of the keys its results would have."""
    return not any(k in g for k in payload)


def errors_of(r):
    """Failed requests in a row: the groups count them differently."""
    if r.get("error"):
        return "row failed"
    n = 0
    s = r.get("soak")
    if s:
        n += 1 if failed(s, "replay") else sum(rep["errors"] for rep in s["replay"]) + sum(
            c["errors"] for c in s["concurrency"].values())
    lg = r.get("longsoak")
    if lg:
        n += 1 if failed(lg, "errors") else lg["errors"]
    d = r.get("depth")
    if d:
        n += 1 if failed(d, "stages") else sum("error" in st for st in d["stages"])
    t = r.get("twosession")
    if t:
        n += ("error" in t) + sum(isinstance(x, str) for rd in t.get("rounds", []) for x in rd["streams"])
    return n


def rows_table(rows):
    body = []
    for k, r in rows.items():
        mem = r.get("mem_end") or {}
        body.append([k, "error" if r.get("error") else "ran", gib(r.get("gtt_peak_delta_bytes")), kib(r.get("hwm_kb")),
                     kib(mem.get("rss_anon_kb")), f(r.get("loadavg_start"), 2), f(r.get("loadavg_max"), 1),
                     r.get("ctx"), errors_of(r), r.get("load_s")])
    return table(["row", "result", "peak GTT GiB", "RSS HWM GiB", "anon RSS end GiB", "load start", "load max", "ctx", "errors",
                  "load s"], body)


def replay_table(rows):
    body = []
    for k in ("soak", "soak-batch"):
        s = (rows.get(k) or {}).get("soak")
        if not s or failed(s, "replay"):
            continue
        for i, rep in enumerate(s["replay"], 1):
            body.append([k, i, rep["errors"], f(rep["ttft_total_s"]), f(rep["wall_total_s"]), f(rep["decode_tps_median"])])
    return table(["row", "rep", "errors", "ttft total s", "wall total s", "decode tok/s median"], body)


def conc_table(rows):
    body = []
    for k in ("soak", "soak-batch"):
        s = (rows.get(k) or {}).get("soak")
        if not s or failed(s, "concurrency"):
            continue
        for n, c in s["concurrency"].items():
            dec = [x.get("decode_tps") for x in c["requests"] if x["kind"] == "decode"]
            tc = [x.get("decode_tps") for x in c["requests"] if x["kind"] == "toolcall"]
            ok = sum(1 for x in c["requests"] if x.get("tool_call_ok"))
            body.append([k, n, c["errors"], f(c["wall_s"], 2), f(c["aggregate_tps"]),
                         "/".join(f(x) for x in dec), "/".join(f(x) for x in tc), ok])
    return table(["row", "requests", "errors", "wall s", "aggregate tok/s", "long-context decode tok/s", "tool-call decode tok/s",
                  "tool calls ok"], body)


def valid_decode(es):
    """An essay's decode rate and acceptance, or None for one that ended early (rows written before `short` existed
    are judged by `finish`)."""
    if es.get("short") or es.get("finish") != "length":
        return None, None
    return es.get("decode_tps"), es.get("acceptance")


def depth_table(rows):
    body = []
    for k in DEPTH_ROWS:
        d = (rows.get(k) or {}).get("depth")
        if not d:
            continue
        if failed(d, "stages"):
            body.append([k, "group failed: " + d.get("error", "?")[:80]] + [""] * 6)
            continue
        for s in d["stages"]:
            fill, turn, es = s.get("fill"), s.get("turn"), s.get("essay")
            if "error" in s or not (fill and turn and es):
                body.append([k, s["target"], "stopped: " + s.get("error", "?")[:80]] + [""] * 5)
                continue
            dec, acc = valid_decode(es)
            body.append([k, fill["prompt_tokens"], f(fill.get("prefill_tps") if fill.get("cached_tokens") is not None else None, 0),
                         f(turn["ttft_s"]), f(dec), f(acc, 2),
                         turn["cached_tokens"], gib((s.get("mem") or {}).get("gtt_delta_bytes"))])
    return table(["row", "depth (prompt tokens)", "prefill tok/s", "agent-turn ttft s", "decode tok/s (essays run to 256 tokens)",
                  "draft acceptance", "turn cached tokens", "GTT GiB"], body)


def rerun(d):
    """True for a two-session group written by the current harness (it carries `harness`); earlier ones ran with replies
    that ended as short tool calls, so their cache cells stand but their decode numbers are not reported."""
    return "harness" in d


def hit(s):
    return "-" if not s else f"{s['cached_tokens']}/{s['prompt_tokens']} ({s['ttft_s']:.1f} s)"


def two_table(rows):
    body = []
    for k in TWO_ROWS:
        d = (rows.get(k) or {}).get("twosession")
        if not d:
            continue
        if failed(d, "prefill_A"):
            body.append([k, "group failed: " + d.get("error", "?")[:80]] + [""] * 6)
            continue
        if "error" in d:
            body.append([k, "stopped: " + d["error"][:80]] + [""] * 6)
            continue
        body.append([k, "re-run" if rerun(d) else "earlier harness (not re-run, owner cut)", hit(d.get("repeat_B")),
                     hit(d.get("repeat_A")), hit(d.get("alone_A")), hit(d.get("alone_B")), hit(d.get("after_third_A")),
                     hit(d.get("after_third_B"))])
    return table(["row", "harness", "repeat B (just filled)", "repeat A (B filled after)", "A turn", "B turn", "A after 3rd session",
                  "B after 3rd session"], body)


def stream_cell(s):
    if not isinstance(s, dict):
        return s
    rate = f(s["decode_tps"]) if s.get("finish") == "length" and s.get("decode_tps") is not None else "short reply"
    return f"{rate} (ttft {f(s['ttft_s'])} s, {s['completion_tokens']} tok, {s['finish']})"


def two_rounds(rows):
    body = []
    for k in TWO_ROWS:
        d = (rows.get(k) or {}).get("twosession")
        if d and d.get("rounds") and not rerun(d):
            body.append([k, "not re-run (owner cut)", "-", "-", "-"])
            continue
        for x in (d or {}).get("rounds", []):
            body.append([k, x["kind"]] + [stream_cell(s) for s in x["streams"]] + [f(x.get("combined_tps"))])
    return table(["row", "round", "stream A: decode tok/s", "stream B: decode tok/s", "combined tok/s"], body)


def long_table(rows):
    lg = (rows.get("longsoak") or {}).get("longsoak")
    if not lg or failed(lg, "windows"):
        return ""
    body = [[w["from_min"], w["requests"], f(w["decode_tps_median"])] for w in lg["windows"]]
    kinds = [[k, v["n"], v["errors"], f(v["ttft_median_s"], 2), f(v["decode_tps_median"])] for k, v in lg["kinds"].items()]
    can = [[c["t_s"], f(c["decode_tps"]), f(c["prefill_tps"], 0), len(c["errors"])] for c in lg["canaries"]]
    return "\n\n".join([table(["minute", "requests", "decode tok/s median"], body),
                        table(["kind", "n", "errors", "ttft median s", "decode tok/s median"], kinds),
                        table(["t s", "canary decode tok/s", "canary prefill tok/s", "errors"], can)])


SECTIONS = {"rows": rows_table, "replay": replay_table, "conc": conc_table, "depth": depth_table, "two": two_table,
            "rounds": two_rounds, "long": long_table}

if __name__ == "__main__":
    data = load(sys.argv[1])
    for name in sys.argv[2:] or SECTIONS:
        print(f"<!-- {name} -->\n{SECTIONS[name](data)}\n")
