# `flm serve` keeps decoding after the client disconnects (#191), on halo

Red/green for #191, plus a rerun of OFLM-Next's server-api conformance suite
using the same method as
[`oflm-api-conformance-2026-09-28-after-187`](../oflm-api-conformance-2026-09-28-after-187/).
The `run_spec_tests.py` shim, `conformance.sh`, the OFLM-Next commit, the
models and the ports are the same. Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build (red):** `main` at 46d7a73 (the #187 tip),
`/nix/store/fqkyn7jv5mqvzc51fgq4vghv33slqar7-fastflowlm-1.0.6`.
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/cancel-client-disconnect.patch`,
`/nix/store/jfwv0r1sfs1w9g5vlmws3gfzkv66qa5a-fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` (port 58601) and `gemma4-it:e4b` (port 58603).

`pgrep -x flm` was empty before every run, and the scripts wait until it is.
`lemond` had no model loaded (`/api/v1/health` returned
`all_models_loaded: []`), so it was left running and never touched. Each
`flm serve` was stopped by its PID.

## The bug

`server.cpp` gives every request a `CancellationToken`. A disconnect monitor
cancels the token when the client's socket reads EOF (the server logs
`Client disconnected; cancelling active request`). Only
`handle_openai_chat_completion` passed `[&] { return cancellation_token->cancelled(); }`
to `insert()` and `generate()`. `/api/generate`, streaming `/api/chat` and
`/v1/completions` called them without a predicate, so the token was cancelled
and nothing read it. Prefill ran every chunk, then decode ran to the token
limit, for a client that was gone. Ollama's default limit here is 4096 tokens.

The patch mirrors `/v1/chat/completions`: it calls `cancellation_token->reset()`
first and passes the predicate to `insert()` and `generate()`. A cancelled
prefill finalizes the stream (streaming) or sends an empty reply (non-streaming)
to the closed socket, then clears the context. A cancelled decode logs
`Generation Cancelled!` and takes the existing finalize path. The catch blocks
are unchanged, so the #175/#180/#187 error classification is too.

Non-streaming `/api/chat` is not changed. It uses `generate_with_prompt()`,
which has no cancellation parameter in any model class, and switching it to
`insert()` + `generate()` changes answers for Qwen3.5, Qwen3.6-MoE and GPT-OSS
(#180).

## Red/green

[`disconnect.sh`](disconnect.sh) `<flm> <outdir>` serves each model and runs
three cases against six endpoints: streaming `chat`, `generate`, `openai`
(`/v1/chat/completions`, the control), `completions` (`/v1/completions`), and
non-streaming `generate-ns` and `completions-ns`. The prompt is an essay
request with `num_predict`/`max_tokens` 512 and `top_k: 1`.

- `full` reads the reply to the end.
- `decode` closes the socket (`shutdown(SHUT_RDWR)`) after 5 content chunks,
  or after 2 s on a non-streaming endpoint.
- `prefill` (streaming only) sends a ~12k-token prompt, which is three
  4096-token prefill chunks, and closes 0.3 s later, during chunk 1.

After each close the probe sends a small non-streaming `/api/chat` at once.
The server log is stamped per line with wall-clock time. The hold is the time
from the close to the first line showing the work over: the NPU lock
released, handed to the queued follow-up, or taken by it. `/v1/completions`
never takes the NPU lock (#192), so the probe sends it no follow-up (one would
run on the NPU concurrently) and times it by `generate()`'s raw-output line or
`Prefill Cancelled!`.

The contract is the same for both builds. Mid-decode, the hold must be under
2 s. Mid-prefill, no further prefill chunk may start (the chunk already on the
NPU cannot be interrupted). Red: [`before/disconnect.txt`](before/disconnect.txt),
28 passed, 16 failed. Green: [`disconnect.txt`](disconnect.txt), 44 passed,
0 failed.

| Case | llama red | llama green | gemma4 red | gemma4 green |
| --- | --- | --- | --- | --- |
| streaming `/api/chat`, mid-decode | **8.05 s** | 0.35 s | **38.71 s** | 0.41 s |
| streaming `/api/generate`, mid-decode | **8.03 s** | 0.35 s | **38.66 s** | 0.41 s |
| streaming `/v1/completions`, mid-decode | **8.09 s** | 0.02 s | **38.41 s** | 0.07 s |
| non-streaming `/api/generate`, mid-decode | **6.81 s** | 0.35 s | **39.08 s** | 0.40 s |
| non-streaming `/v1/completions`, mid-decode | **10.05 s** | 0.00 s | **37.50 s** | 0.07 s |
| `/v1/chat/completions` (control), mid-decode | 0.35 s | 0.35 s | 0.41 s | 0.41 s |
| streaming `/api/chat`, mid-prefill | **7.63 s, +2 chunks** | 1.83 s, +0 | **29.38 s, +2 chunks** | 6.13 s, +0 |
| streaming `/api/generate`, mid-prefill | **7.87 s, +2 chunks** | 1.85 s, +0 | **26.15 s, +2 chunks** | 6.31 s, +0 |
| streaming `/v1/completions`, mid-prefill | **7.31 s, +2 chunks** | 1.57 s, +0 | **25.04 s, +2 chunks** | 5.74 s, +0 |
| `/v1/chat/completions` (control), mid-prefill | 1.82 s, +0 | 1.90 s, +0 | 6.29 s, +0 | 6.37 s, +0 |

The server logged the disconnect within 1 ms of the close in every case, on
both builds. On red, nothing read the cancelled token.

The mid-prefill hold on green is the rest of the chunk that was already
running: a 4096-token chunk takes about 1.8 s on llama and 8.5 s on gemma4.
It is the same as the control's.

## Normal replies unchanged

Every `full` case passes on both builds with the same stop reason and token
count: `length` at 512 on all twelve. Eleven of the twelve `full` contents are
byte-identical (`cmp`) between `before/` and this directory. The exception is
llama `completions-ns`, which diverges at byte 954. That request runs right
after the `generate-ns` disconnect, which the red build decoded to 512 tokens
and the green build cancelled, and non-streaming `/v1/completions` does not
clear its context after answering. So the two builds started it from
different state.
[`recheck-completions-ns.sh`](recheck-completions-ns.sh) removes that state.
It sends the same request twice to a fresh server on each build, and the
builds answer identically each time: `recheck/red.1` = `recheck/green.1` and
`recheck/red.2` = `recheck/green.2`. The first and second answers differ from
each other on both builds, which is that carried-over context.

## Conformance rerun

[`conformance.sh`](conformance.sh) `<flm> <outdir> <oflm-next>` and
[`run_spec_tests.py`](run_spec_tests.py) are copied unchanged from after-187.
They were run against the new build. For each file, the sorted per-test
PASS/FAIL/SKIP lines are identical to the after-187 logs.

| Test file | After #187 | After #191 | Log |
| --- | --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 | [log](test_error_status.log) |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 | [log](test_error_status.gemma4.log) |
| `test_finish_reason.py` | PASS 7 | PASS 7 | [log](test_finish_reason.log) |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 | [log](test_request_validation.log) |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 | [log](test_request_validation.embed.log) |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 | [log](test_embed_task_prompt.log) |

## Not measured

- A disconnect before the handler reaches `cancellation_token->reset()`, for
  example during a model load. The monitor fires once, and `reset()` clears a
  cancel it already made, so such a request still decodes to its limit.
  `/v1/chat/completions` has the same race. The patch copies it as it is.
- Non-streaming `/api/chat`, which still ignores a disconnect (see above).
- Models other than `llama3.2:1b` and `gemma4-it:e4b`. Every model class's
  `insert()`/`generate()` takes the predicate, but only these two were run.
