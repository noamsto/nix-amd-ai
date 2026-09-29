# `flm serve` streaming `/api/chat` segfaults: double insert, no generate (#187), on halo

Red/green for #187, plus a rerun of OFLM-Next's server-api conformance suite
using the same method as
[`oflm-api-conformance-2026-09-28-after-181`](../oflm-api-conformance-2026-09-28-after-181/).
The `run_spec_tests.py` shim, the OFLM-Next commit, the models and the ports
are the same. Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build (red):** the #181 tip, this branch's base (`feat/181-...`),
`fastflowlm-1.0.6`.
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/stream-chat-generate.patch`,
`fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` (port 58601) and `gemma4-it:e4b` (port 58603).

`pgrep -a flm` was empty before and after every run. `lemond` had no model
loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was left
running and never touched. Each `flm serve` was stopped by its PID. The red
runs' servers died on their own.

## The bug

`handle_chat`'s streaming branch ran the `insert()` try block twice and never
called `generate()` before `ostream.finalize_chat(meta_info)`. That is upstream
v1.0.6 code, and it is unchanged on ROCm/FastFlowLM `main` at `39ff855632`
(2026-09-22), so there was no upstream fix to port.

The source reading predicted two prefills and no tokens. What actually happens
is worse. `AutoModel::_shared_insert` prefix-matches the new tokens against
`token_history`. The first `insert()` wrote the whole prompt there, so the
second one matches all of it, erases every token, prefills an empty vector,
and then calls `sampler->sample()` on an empty logits buffer. **Every
streaming `/api/chat` request segfaults `flm serve`**, on both models. The
client gets no bytes at all (`RemoteDisconnected`), and the server log shows
one `Prefill chunk 1/1` line, because the second insert has nothing to prefill
or log. The core dumps' backtraces:

```
llama3.2:1b                                  gemma4-it:e4b
#0 Sampler::sample_greedy(buffer<bf16>&)     #0 Sampler::sample_greedy(buffer<bf16>&)
#1 AutoModel::_shared_insert(...)            #1 AutoModel::_shared_insert(...)
#2 Llama3::insert(...)                       #2 Gemma4e::insert(...)
#3 RestHandler::handle_chat(...)             #3 RestHandler::handle_chat(...)
```

(`sample_greedy` because the probes pin `top_k: 1`. Unpinned, the first manual
capture crashed in `Sampler::sample` at the same call site.)

The patch replaces the second `insert()` block with the `generate()` block
that streaming `/api/generate` uses. The insert catch keeps the #175
request-fault classification (400 "Invalid request"). The generate catch uses
the default one (500 "Internal error" for anything but a `json::exception`),
the same as streaming `/api/generate` and `/v1/chat/completions`.

## Red/green

[`probes.sh`](probes.sh) `<flm> <outdir>` serves each model and sends four
requests in this order, all with the same prompt and `top_k: 1` (greedy):

1. `nonstream-chat`: non-streaming `/api/chat`
2. `stream-openai`: streaming `/v1/chat/completions`
3. `stream-chat`: streaming `/api/chat`, the #187 path
4. `nonstream-after`: `nonstream-chat` again

The checks are the contract, and they are the same for every build. Red: 4 passed, 8 failed. Green: 12 passed, 0 failed. `probes.sh` also writes each
request's raw reply to `<model>.<case>.{ndjson,sse}`, every line stamped by its
arrival time. Those captures are not committed.

| Check (per model) | Red build | Green build |
| --- | --- | --- |
| `nonstream-chat`: 200, `done:true`, content | PASS | PASS |
| `stream-openai`: 200, delta content, one `finish_reason`, `[DONE]` | PASS | PASS |
| `stream-chat/server-alive` | **FAIL**: segfault | PASS |
| `stream-chat/tokens`: `done:false` content chunks, then one `done:true` chunk with stats | **FAIL**: no reply | PASS |
| `stream-chat/matches-nonstream`: streamed text == non-streamed text | **FAIL**: empty | PASS |
| `nonstream-after`: same answer as `nonstream-chat` | **FAIL**: server gone | PASS |

Green `stream-chat`, from the captured streams:

| Model | Chunks | First chunk | Total | `prompt_eval_count` | `eval_count` | `done_reason` | Prefill log lines |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `llama3.2:1b` | 13 content + 1 final | 0.390 s | 0.599 s | 47 | 13 | `stop` | 1 |
| `gemma4-it:e4b` | 13 content + 1 final | 1.208 s | 2.217 s | 21 | 13 | `stop` | 1 |

Both models stream `1, 2, 3, 4, 5` one token per chunk (about 15 ms per token
on llama, 72 ms on gemma4), byte-identical to the non-streaming reply.

## Other chat paths unchanged

With greedy decoding and the same request sequence, the `nonstream-chat` and
`stream-openai` content files are byte-identical (`cmp`) between `before/` and
this directory, for both models. The timings match too: llama `nonstream-chat`
took 0.604 s before and 0.613 s after, and gemma4 took 2.271 s on both.

## Conformance rerun

[`conformance.sh`](conformance.sh) `<flm> <outdir> <oflm-next>` and
[`run_spec_tests.py`](run_spec_tests.py) are copied unchanged from after-181.
They were run against the new build. OFLM-Next has no streaming `/api/chat`
test, so no result was expected to change.

| Test file | After #181 | After #187 |
| --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 |
| `test_finish_reason.py` | PASS 7 | PASS 7 |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 |

For each file, the sorted per-test PASS/FAIL/SKIP lines are identical to the
after-181 logs.

## Not measured

Streaming `/api/chat` now takes the same `insert()` + `generate()` path as
streaming `/v1/chat/completions`, not the `generate_with_prompt()` path that
non-streaming `/api/chat` uses (#180). For Qwen3.5, Qwen3.6-MoE and GPT-OSS,
those two paths are expected to answer differently. Only `llama3.2:1b` and
`gemma4-it:e4b` were run here.
