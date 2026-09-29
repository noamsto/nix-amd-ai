# `flm serve` keeps decoding after the client disconnects (#191), on halo

Red/green for #191, plus a rerun of OFLM-Next's server-api conformance suite
using the same method as
[`oflm-api-conformance-2026-09-28-after-187`](../oflm-api-conformance-2026-09-28-after-187/).
The `run_spec_tests.py` shim, `conformance.sh`, the OFLM-Next commit, the
models and the ports are the same. Only the `flm` build under test changed;
`disconnect.sh` dropped its `/v1/completions` follow-up exception once #196 put
that route behind the NPU lock.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build (red):** `main` at ae40eed (#196); #193 (cfb936b) above it
only bumps flake.lock/lemonade, so the fastflowlm derivation is unchanged.
`/nix/store/hzqppl44zhfxpk0nl1wv6r8fd69g4w4p-fastflowlm-1.0.6`.
**New build (green):** this branch, rebased onto cfb936b, adding
`pkgs/fastflowlm/patches/cancel-client-disconnect.patch`,
`/nix/store/vrjxsjfalvp7169snygf1slcvph2xyp6-fastflowlm-1.0.6`.
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
limit (default 4096), for a client that was gone. Upstream ROCm/FastFlowLM
`main` at 39ff855632 is the same: in its `rest_handler.cpp`,
`cancellation_token` is only read inside `handle_openai_chat_completion`.

The patch passes the predicate to `insert()` and `generate()` on those
branches. A cancelled prefill finalizes the stream (streaming) or sends `{}`
(non-streaming) to the closed socket, then clears the context. A cancelled
decode logs `Generation Cancelled!` and takes the existing finalize path. The
streaming branches also call `cancellation_token->reset()` first, as
`/v1/chat/completions`' streaming branch does. The non-streaming branches do
not, like `/v1/chat/completions`' non-streaming branch; see
[the queued case](#the-queued-case-and-reset). The catch blocks are
unchanged, so the #175/#180/#187 error classification is too.

Non-streaming `/api/chat` is not changed. It uses `generate_with_prompt()`,
which has no cancellation parameter in any model class, and switching it to
`insert()` + `generate()` changes answers for Qwen3.5, Qwen3.6-MoE and GPT-OSS
(#180).

## Red/green

[`disconnect.sh`](disconnect.sh) `<flm> <outdir>` runs, per model and on a
fresh `flm serve` per endpoint, these cases against six endpoints: streaming
`chat`, `generate`, `openai` (`/v1/chat/completions`, the control) and
`completions` (`/v1/completions`), and non-streaming `generate-ns` and
`completions-ns`. The prompt is an essay request with
`num_predict`/`max_tokens` 512 and, where the endpoint applies it, `top_k: 1`.

- `full` reads the reply to the end.
- `decode` closes the socket (`shutdown(SHUT_RDWR)`) after 5 content chunks,
  or after 2 s on a non-streaming endpoint.
- `prefill` (streaming only) sends a ~12k-token prompt, which is three
  4096-token prefill chunks, and closes 0.3 s later, during chunk 1.
- `queued` (non-streaming endpoints) sends the request while a normal
  `/api/chat` holds the NPU, and closes it 0.3 s later, while it waits in the
  queue.

After each close the probe sends a small non-streaming `/api/chat` at once.
Every probed endpoint holds the NPU lock, `/v1/completions` included now that
#196 lists it in `requires_npu_access()`, so one follow-up is sent on every
route and the hold is always timed by the lock. The server log is stamped per
line with wall-clock time. The hold is the time from the close to the first
line showing the work over: the NPU lock released, handed to the queued
follow-up, or taken by it. For `queued` it is timed from the request's own
dequeue instead. Each endpoint gets its own server because every disconnected
stream leaks one of `flm serve`'s 10 connection slots (#194).

The contract is the same for both builds. Mid-decode and after a dequeue, the
hold must be under 2 s. Mid-prefill, no further prefill chunk may start (the
chunk already on the NPU cannot be interrupted). Red:
[`before/disconnect.txt`](before/disconnect.txt), 28 passed, 20 failed. Green:
[`disconnect.txt`](disconnect.txt), 48 passed, 0 failed.

| Case | llama red | llama green | gemma4 red | gemma4 green |
| --- | --- | --- | --- | --- |
| streaming `/api/chat`, mid-decode | **8.02 s** | 0.35 s | **38.11 s** | 0.44 s |
| streaming `/api/generate`, mid-decode | **8.07 s** | 0.35 s | **38.04 s** | 0.41 s |
| streaming `/v1/completions`, mid-decode | **8.02 s** | 0.35 s | **38.07 s** | 0.44 s |
| non-streaming `/api/generate`, mid-decode | **6.51 s** | 0.34 s | **37.54 s** | 0.39 s |
| non-streaming `/api/generate`, closed while queued | **8.46 s** | 0.34 s | **39.49 s** | 0.36 s |
| non-streaming `/v1/completions`, mid-decode | **6.45 s** | 0.35 s | **37.51 s** | 0.39 s |
| non-streaming `/v1/completions`, closed while queued | **8.45 s** | 0.34 s | **39.48 s** | 0.37 s |
| `/v1/chat/completions` (control), mid-decode | 0.35 s | 0.35 s | 0.41 s | 0.41 s |
| streaming `/api/chat`, mid-prefill | **7.66 s, +2 chunks** | 1.84 s, +0 | **25.17 s, +2 chunks** | 6.11 s, +0 |
| streaming `/api/generate`, mid-prefill | **7.70 s, +2 chunks** | 1.83 s, +0 | **25.14 s, +2 chunks** | 6.12 s, +0 |
| streaming `/v1/completions`, mid-prefill | **7.63 s, +2 chunks** | 1.83 s, +0 | **25.18 s, +2 chunks** | 6.12 s, +0 |
| `/v1/chat/completions` (control), mid-prefill | 1.83 s, +0 | 1.86 s, +0 | 6.12 s, +0 | 6.14 s, +0 |

The server logged the disconnect within 1 ms of the close in every case that
was not queued, on both builds. On red, nothing read the cancelled token. A
queued request's disconnect is logged when it is dequeued, because the monitor
is armed only then.

The mid-prefill hold on green is the rest of the chunk that was already
running: a 4096-token chunk takes about 1.8 s on llama and 8.5 s on gemma4.
It is the same as the control's.

### The queued case and `reset()`

The token is created fresh for every request, so `reset()` can only clear a
real cancel. A client that disconnects while its request is queued has
already closed its socket by the time the request is dequeued. The monitor
then fires as soon as it is armed, before the handler starts work. A
non-streaming reply writes nothing until the end, so nothing else notices the
dead socket. The first version of this patch called `reset()` on the
non-streaming branches too. [`reset-sensitivity/`](reset-sensitivity/) runs
the `generate-ns` cases on that build,
`/nix/store/jfwv0r1sfs1w9g5vlmws3gfzkv66qa5a-fastflowlm-1.0.6`. It decodes a
queued request whose client has gone for 8.46 s on llama and 39.83 s on
gemma4, as red does, while its mid-decode case passes (0.34 s, 0.40 s). The
green build has no non-streaming `reset()` and stops it in 0.33 s.

The streaming branches keep the `reset()` that `/v1/chat/completions` has, so
a streaming client that disconnects before its handler starts (queued, or
during a model load) can still lose the cancel. The first failed chunk write
also cancels the token (`send_chunk_data`), so such a stream ends within a
token or two of decode. It still runs its whole prefill. This is shared with
`/v1/chat/completions` and not measured here.

## Normal replies unchanged

Every `full` case passes on both builds with the same stop reason and token
count: `length` at 512 on all twelve. Eight of the twelve `full` contents are
byte-identical (`cmp`) between `before/` and this directory: every `chat`,
`openai`, `completions` and `completions-ns` case. The four `/api/generate`
ones differ between builds, because `/api/generate` never applies a request's
sampling options. On a fresh server it samples with the default random
sampler, and `top_k` in the request is ignored.
[`greedy-generate.sh`](greedy-generate.sh) `<flm> <outdir>` starts a fresh
server per model and first sends a one-token `/api/chat` with `top_k: 1`,
which leaves the sampler greedy for `/api/generate`. It then records a
streaming and a non-streaming `/api/generate` reply. On both builds all four
end `length` at 512 tokens, and each is byte-identical between
[`greedy-generate/before/`](greedy-generate/before/) and
[`greedy-generate/after/`](greedy-generate/after/).

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

- A streaming disconnect before the handler's `reset()` (see above).
- A disconnect during a model load.
- Non-streaming `/api/chat`, which still ignores a disconnect (see above).
- `POST /api/cancel` cancels the same token. With this patch, a live client
  whose non-streaming `/api/generate` or `/v1/completions` is cancelled that
  way gets a 200. The body is the partial reply with
  `done_reason`/`finish_reason` `"cancel"`, or `{}` if the cancel landed
  during prefill. Not exercised.
- Models other than `llama3.2:1b` and `gemma4-it:e4b`. Every model class's
  `insert()`/`generate()` takes the predicate, but only these two were run.
