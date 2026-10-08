"""Markdown tables for the README from a rows.jsonl written by rows.sh: python3 tables.py rows.jsonl [section...]

Sections: rows (one line per row), replay, conc, depth, two, long. The last row of a label wins, so a re-run replaces."""
import json
import sys

GIB = 1 << 30


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


def table(head, body):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---:" if i else "---" for i in range(len(head))) + "|"]
    return "\n".join(out + ["| " + " | ".join(str(c) for c in r) + " |" for r in body])


def errors_of(r):
    """Failed requests in a row: the groups count them differently."""
    if r.get("error"):
        return "row failed"
    n = 0
    s = r.get("soak")
    if s:
        n += sum(rep["errors"] for rep in s["replay"]) + sum(c["errors"] for c in s["concurrency"].values())
    if r.get("longsoak"):
        n += r["longsoak"]["errors"]
    d = r.get("depth")
    if d:
        n += sum("error" in st for st in d["stages"])
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
    return table(["row", "result", "peak GTT GiB", "RSS HWM GiB", "anon RSS end GiB", "load start", "load max", "ctx", "errors", "load s"], body)


def replay_table(rows):
    body = []
    for k in ("soak", "soak-batch"):
        s = (rows.get(k) or {}).get("soak")
        if not s:
            continue
        for i, rep in enumerate(s["replay"], 1):
            body.append([k, i, rep["errors"], f(rep["ttft_total_s"]), f(rep["wall_total_s"]), f(rep["decode_tps_median"])])
    return table(["row", "rep", "errors", "ttft total s", "wall total s", "decode tok/s median"], body)


def conc_table(rows):
    body = []
    for k in ("soak", "soak-batch"):
        s = (rows.get(k) or {}).get("soak")
        if not s:
            continue
        for n, c in s["concurrency"].items():
            dec = [x["decode_tps"] for x in c["requests"] if x["kind"] == "decode"]
            tc = [x["decode_tps"] for x in c["requests"] if x["kind"] == "toolcall"]
            ok = sum(1 for x in c["requests"] if x.get("tool_call_ok"))
            body.append([k, n, c["errors"], f(c["wall_s"], 2), f(c["aggregate_tps"]),
                         "/".join(f(x) for x in dec), "/".join(f(x) for x in tc), ok])
    return table(["row", "requests", "errors", "wall s", "aggregate tok/s", "long-context decode tok/s", "tool-call decode tok/s",
                  "tool calls ok"], body)


def depth_table(rows):
    body = []
    for k in ("depth192", "depth256", "nomtp-depth128", "gsq-depth192", "gsq-depth256"):
        r = rows.get(k)
        d = (r or {}).get("depth")
        if not d:
            continue
        for s in d["stages"]:
            if "fill" not in s:
                body.append([k, s["target"], "error: " + s["error"][:60], "", "", "", "", ""])
                continue
            body.append([k, s["fill"]["prompt_tokens"], f(s["fill"]["prefill_tps"], 0), f(s["turn"]["ttft_s"]),
                         f(s["essay"]["decode_tps"]), f(s["essay"]["acceptance"], 2), s["turn"]["cached_tokens"],
                         gib((s.get("mem") or {}).get("gtt_delta_bytes"))])
    return table(["row", "depth (prompt tokens)", "prefill tok/s", "agent-turn ttft s", "decode tok/s", "MTP acceptance",
                  "turn cached tokens", "GTT GiB"], body)


def two_table(rows):
    body = []
    for k in ("two128", "two128-nobatch", "two128-mtp", "two128-park", "two256-park", "gsq-two128"):
        d = (rows.get(k) or {}).get("twosession")
        if not d:
            continue
        hit = lambda s: "-" if not s else f"{s['cached_tokens']}/{s['prompt_tokens']} ({s['ttft_s']:.1f} s)"  # noqa: E731
        body.append([k, hit(d.get("repeat_B")), hit(d.get("repeat_A")), hit(d.get("alone_A")), hit(d.get("alone_B")),
                     hit(d.get("after_third_A")), hit(d.get("after_third_B"))])
    return table(["row", "repeat B (just filled)", "repeat A (B filled after)", "A turn", "B turn", "A after 3rd session",
                  "B after 3rd session"], body)


def two_rounds(rows):
    body = []
    for k in ("two128", "two128-nobatch", "two128-mtp", "two128-park", "two256-park", "gsq-two128"):
        d = (rows.get(k) or {}).get("twosession")
        for x in (d or {}).get("rounds", []):
            ss = x["streams"]
            body.append([k, x["kind"]] + [f"{f(s['decode_tps'])} (ttft {f(s['ttft_s'])} s)"
                                          if isinstance(s, dict) else s for s in ss] + [f(x["aggregate_tps"])])
    return table(["row", "round", "stream A: decode tok/s", "stream B: decode tok/s", "combined tok/s"], body)


def long_table(rows):
    l = (rows.get("longsoak") or {}).get("longsoak")
    if not l:
        return ""
    body = [[w["from_min"], w["requests"], f(w["decode_tps_median"])] for w in l["windows"]]
    kinds = [[k, v["n"], v["errors"], f(v["ttft_median_s"], 2), f(v["decode_tps_median"])] for k, v in l["kinds"].items()]
    can = [[c["t_s"], f(c["decode_tps"]), f(c["prefill_tps"], 0), len(c["errors"])] for c in l["canaries"]]
    return "\n\n".join([table(["minute", "requests", "decode tok/s median"], body),
                        table(["kind", "n", "errors", "ttft median s", "decode tok/s median"], kinds),
                        table(["t s", "canary decode tok/s", "canary prefill tok/s", "errors"], can)])


SECTIONS = {"rows": rows_table, "replay": replay_table, "conc": conc_table, "depth": depth_table, "two": two_table,
            "rounds": two_rounds, "long": long_table}

if __name__ == "__main__":
    data = load(sys.argv[1])
    for name in sys.argv[2:] or SECTIONS:
        print(f"<!-- {name} -->\n{SECTIONS[name](data)}\n")
