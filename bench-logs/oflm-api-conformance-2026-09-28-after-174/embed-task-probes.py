#!/usr/bin/env python3
"""Probe /v1/embeddings task-prompt handling (#174).

Runs against a server started with an embedding model loaded:
  OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_EMBED_MODEL=embed-gemma:300m \
    python3 embed-task-probes.py [--dump vectors.json]

Exit 0 iff every check passes. `gemma` prefixes are known from
src/include/AutoEmbeddingModel/modeling_gemma_embedding.hpp: query ->
"task: search result | query: ", document -> "title: none | text: ".
"""
import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("OFLM_TEST_BASE_URL", "http://127.0.0.1:58602")
MODEL = os.environ.get("OFLM_TEST_EMBED_MODEL", "embed-gemma:300m")
TEXT = "The NPU runs the embedding model on device."

failures = []


def check(name, ok, detail=""):
    detail = str(detail)
    if len(detail) > 200:
        detail = detail[:200] + "..."
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f" -- {detail}" if detail else ""), flush=True)
    if not ok:
        failures.append(name)


def post(payload):
    req = urllib.request.Request(
        f"{BASE}/v1/embeddings", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"_raw": raw}


def embed(**extra):
    p = dict(model=MODEL, input=TEXT)
    p.update(extra)
    return post(p)


def vec(**extra):
    status, body = embed(**extra)
    assert status == 200, (status, body)
    return body["data"][0]["embedding"]


def err(body):
    e = body.get("error")
    return e if isinstance(e, dict) else {}


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", help="write the vectors to this JSON path")
    args = ap.parse_args()

    vectors = {}
    absent = vec()
    vectors["absent"] = absent
    vectors["query"] = vec(prompt_name="query")
    vectors["document"] = vec(prompt_name="document")

    check("no prompt_name -> 200 with a vector", len(absent) > 0)
    check("no prompt_name keeps the default task_query",
          absent == vectors["query"],
          "byte-identical to prompt_name=query")
    check("prompt_name=query and prompt_name=document differ",
          vectors["query"] != vectors["document"],
          f"cosine {cosine(vectors['query'], vectors['document']):.6f}")
    check("query vs document cosine well under 0.9999",
          cosine(vectors["query"], vectors["document"]) < 0.9999)
    check("prompt_name=query reproducible",
          vec(prompt_name="query") == vectors["query"])
    check("prompt_name=document reproducible",
          vec(prompt_name="document") == vectors["document"])
    # Non-default task: comparing against vectors["query"] would pass on a
    # server that ignores task_type, since query is also the default.
    doc_alias = vec(task_type="document")
    check("task_type is an alias for prompt_name",
          doc_alias == vectors["document"] and doc_alias != vectors["query"])
    agree_alias = vec(prompt_name="document", task_type="search_document")
    check("the two spellings may agree (document/search_document)",
          agree_alias == vectors["document"] and agree_alias != vectors["query"])

    st, body = embed(prompt_name="query", task_type="document")
    m = err(body).get("message", "")
    check("disagreeing prompt_name/task_type -> 400 invalid_value",
          st == 400 and err(body).get("code") == "invalid_value", f"{st} {body}")
    check("disagreement message names both fields",
          "prompt_name" in m and "task_type" in m, m)

    st, body = embed(prompt_name="not_a_task")
    m = err(body).get("message", "")
    check("unknown task name -> 400 invalid_value",
          st == 400 and err(body).get("code") == "invalid_value"
          and "data" not in body, f"{st} {body}")
    check("unknown-name message quotes the value and accepted names",
          "not_a_task" in m and "search_query" in m and "search_document" in m, m)

    for field in ("prompt_name", "task_type"):
        st, body = embed(**{field: 7})
        check(f"non-string {field} -> 400 invalid_value",
              st == 400 and err(body).get("code") == "invalid_value"
              and err(body).get("param") == field, f"{st} {body}")

    if args.dump:
        with open(args.dump, "w") as f:
            json.dump(vectors, f)

    print(f"\n=== {'ALL PASS' if not failures else 'FAILURES: ' + ', '.join(failures)} ===")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
