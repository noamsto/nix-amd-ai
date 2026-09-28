# `flm serve` `GET /api/ps` races model swaps (#184), on halo

Red/green for #184 under ThreadSanitizer, production-build probes for the NPU
lock and for `/api/ps` during a swap, and a rerun of OFLM-Next's server-api
conformance suite using the same method as
[`oflm-api-conformance-2026-09-28-after-187`](../oflm-api-conformance-2026-09-28-after-187/).

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build (red):** the #187 tip, this branch's base,
`/nix/store/fqkyn7jv5mqvzc51fgq4vghv33slqar7-fastflowlm-1.0.6` (the same out
path as the after-187 green build).
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/ps-serving-snapshot.patch`,
`/nix/store/6y3hc05zlx0vy4vzbzyplv3q0w2i90lc-fastflowlm-1.0.6`.
**TSan builds:** [`tsan.nix`](tsan.nix), scratch only, not wired into the flake.
The base patch set is `/nix/store/71kaddldrwvfwkvk380dgz5g0s18781k-fastflowlm-tsan-1.0.6`
(`--arg fixed false`). All 9 patches is `/nix/store/m0598bixf0k7gsx04fp2ylkjzcdk5q7g-fastflowlm-tsan-1.0.6`.
Both builds compile everything with `-fsanitize=thread -g` (followed by the
forced Release `-O3`). `nm -D bin/flm` lists undefined `__tsan_func_entry` and
`__tsan_read8`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b`, `gemma4-it:e4b` (chat) and `embed-gemma:300m`.

`pgrep -a flm` was empty before and after every run. `lemond` had no model
loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was left
running and never touched. Each `flm serve` was stopped by its PID.

## The bug

`requires_npu_access()` (`server.cpp`) serialises only POST `/api/generate`,
`/api/chat`, `/v1/chat/completions`, `/v1/audio/transcriptions` and
`/v1/embeddings`. Every other route runs on any of the 10 I/O threads, so it
runs concurrently with those five.

- `GET /api/ps` read `auto_chat_engine` (a `unique_ptr`) and
  `current_model_tag` (a `std::string`) while an NPU route's
  `ensure_model_loaded` reset and move-assigned the engine and assigned the tag.
- `POST /v1/completions` was not in the list at all. It calls
  `ensure_model_loaded` and runs inference, so it is an unlocked writer.
- `POST /api/embeddings` runs `embed()` on the NPU unlocked. `/v1/embeddings`
  is the same handler, and it is locked.
- The NPU token was released inside `send_response` and the final
  `send_streaming_response`. Handlers then went on calling
  `auto_chat_engine->clear_context()` and `prompt_cache.reset()` after their
  token was released, at which point the next NPU request could already be
  swapping the engine.

## The fix

- **Snapshot for `/api/ps`.** `ensure_model_loaded` publishes the serving chat
  tag under a new `loaded_model_mutex`. The tag is `""` with no chat model, so
  one value carries the whole (engine present, tag) pair. `handle_ps` reads only
  that snapshot and never touches the engine or `current_model_tag`.
  Rejected alternative: holding one mutex for the whole of `ensure_model_loaded`.
  Loads take seconds, and `/api/ps` would stall behind them.
- **Flip point.** The snapshot is cleared right before the outgoing engine is torn
  down (the 500 ms sleep, then `reset()`), and set once `load_model()` has
  returned. During a swap, `/api/ps` therefore answers `[]` and never lists a
  model that is not loaded. The early refusals (same model, unknown, non-chat,
  incompatible) return before the teardown, so the serving model stays listed.
- **Two more routes behind the lock.** `/v1/completions` and `/api/embeddings`
  are added to `requires_npu_access`.
- **Later token release.** The token is released when the handler returns,
  right after `it->second(...)`, rather than when it sends. The catch blocks
  and the guard's destructor still release on every other path. Handlers are
  synchronous (none posts work elsewhere), so the token now covers each whole
  handler.

**Lock ordering.**
- `loaded_model_mutex` is a leaf lock. Each critical section is one string
  move-assign or copy, and neither calls anything that takes a lock.
- The NPU token cannot join a cycle, because acquiring it never blocks: it is a
  try under `g_npu_access_mutex`, or an enqueue under `npu_queue_mutex_`.
- Those two mutexes are held only inside `NPUAccessManager` and
  `process_next_npu_request()`. Neither runs RestHandler code while holding
  them: the queued task is handed off with `net::post` after the scope closes.
- The writer holds `loaded_model_mutex` only for the assignment, never across
  a load, so `/api/ps` never waits on a load.

## Red/green: ThreadSanitizer

[`race.sh`](race.sh) `<flm> <outdir> <label>` does the following:
1. Serves `llama3.2:1b` under TSan.
2. Starts 4 threads that poll `GET /api/ps` back to back.
3. Sends 6 non-streaming `/api/chat` requests that alternate `gemma4-it:e4b` and
   `llama3.2:1b`, then 3 `/v1/completions` requests the same way. Every one
   swaps the model.
4. Classifies the TSan reports with [`tsan-classify.py`](tsan-classify.py).

The classifier works per access stack, and the first bucket that matches wins:
1. `libc-tz`: `tzset`/`localtime`/`gmtime`/`strftime` in either access stack's
   top frames.
2. `ps-pair`: `handle_ps` in one access stack and `ensure_model_loaded` in the
   other.
3. `model-state`: `ensure_model_loaded` or `AutoModel::` in an access stack, or
   a `RestHandler::` access to the RestHandler heap object.
4. `failed-restore`, then `other`.

Red requires `ps-pair ≥ 1`. Green requires `ps-pair = 0` and `model-state = 0`,
with every poll and every chat reply 200.

| | Red (base patch set) | Green (with the fix) |
| --- | --- | --- |
| `/api/ps` polls | 143067, all 200 | 167268, all 200 |
| chat + completions | 9, all 200 | 9, all 200 |
| `ps-pair` | **8** | 0 |
| `model-state` | 0 | 0 |
| `libc-tz` (not gating) | 76 | 69 |
| verdict | [`before/race-red.txt`](before/race-red.txt): PASS (reproduced) | [`race-green.txt`](race-green.txt): PASS 4/4 |

The eight red reports ([`before/tsan-red.ps-pair.txt`](before/tsan-red.ps-pair.txt))
are exactly the race in the issue:

| Write (`ensure_model_loaded`) | Read (`handle_ps`) | Reports |
| --- | --- | --- |
| `rest_handler.cpp:597` `auto_chat_engine.reset()` | `:1343` `unique_ptr::operator bool` | 3 |
| `rest_handler.cpp:645` `current_model_tag = ensure_tag` | `:1343` `is_model_supported(current_model_tag)` (2), and the JSON entry's copies of `current_model_tag` (3, which TSan attributes to `:1373` under `-O3` inlining) | 5 |

The writers came from both `handle_chat` and `handle_openai_completion`. Every
racing address is inside the RestHandler object: the 248-byte heap block that
`create_lm_server` allocates. Line numbers are in the base-build source. The
excerpt cuts access stacks at frame #16. The full
classification, one line per report, is in
[`before/tsan-red.summary.txt`](before/tsan-red.summary.txt) and
[`tsan-green.summary.txt`](tsan-green.summary.txt). The raw TSan logs (3 MB) and
the server logs (~60 MB each, one request banner per poll) are not committed.

**Not caught by TSan:** the release-before-tail race. `model-state` was 0 on red
too, so these sequential chats found no report of `clear_context()` running
against the next `ensure_model_loaded`. That part of the fix rests on the code
path described above, not on a TSan report.

**`libc-tz`** is present on both builds and unchanged by the fix. The reports are
`localtime()`'s shared static buffer and `tzset_internal`, reached from
`handle_ps`, the request logger's `get_current_time_string()` and minja's
`strftime_now`. None of them is loaded-model state. They are filed as a
follow-up, not fixed here.

## Red/green: the NPU lock covers `/v1/completions` and `/api/embeddings`

[`npu-lock.sh`](npu-lock.sh) serves `llama3.2:1b --embed 1` and sends a long
greedy non-streaming `/api/chat` (count to 400). 0.3 s later, while that chat
is still decoding, it sends `/v1/completions` (`llama3.2:1b`, `max_tokens: 4`)
and `/api/embeddings` (`embed-gemma:300m`). The oracle is the server log's
`NPU busy, request queued (...): POST <route>` line.

| Check | Base ([`before/npu-lock-base.txt`](before/npu-lock-base.txt)) | New ([`npu-lock-new.txt`](npu-lock-new.txt)) |
| --- | --- | --- |
| `/v1/completions` queued | **FAIL**: ran immediately | PASS |
| `/api/embeddings` queued | **FAIL**: ran immediately | PASS |
| chat / completions / embeddings | **500** / 200 / 200 | 200 / 200 / 200 |
| server alive | PASS | PASS |

On the base build, the unlocked `/v1/completions` launched on the NPU while the
chat was decoding. The chat died with
`[ERROR] handle_chat: bad command state, can't launch`
([`before/server-npu-lock-base.log`](before/server-npu-lock-base.log)), an XRT
fault, and answered 500.

## `/api/ps` during a swap: latency and flip point

[`ps-during-swap.sh`](ps-during-swap.sh) serves `llama3.2:1b` and polls
`/api/ps` every 50 ms. It asks `/api/chat` for `gemma4-it:e4b`, which swaps the
model, and keeps polling for 1 s after the reply. The load window runs from
sending the chat to its reply.

| | Base ([`before/ps-swap-base.txt`](before/ps-swap-base.txt)) | New ([`ps-swap-new.txt`](ps-swap-new.txt)) |
| --- | --- | --- |
| polls, all 200 | 131 | 127 |
| load window | 7.70 s, 103 polls | 7.00 s, 97 polls |
| `/api/ps` latency in the load window, max / p50 | 0.6 ms / 0.4 ms | **0.8 ms / 0.4 ms** |
| names seen, in order | `llama3.2:1b` ×21 → `[]` ×6 → **`llama3.2:1b` ×68** → `gemma4-it:e4b` ×36 | `llama3.2:1b` ×15 → `[]` ×77 → `gemma4-it:e4b` ×35 |
| no stale model after the swap started | **FAIL** | PASS |

`/api/ps` does not wait on the load: its worst case during the 7 s load is under
1 ms. On the base build, the brief `[]` is the gap between
`auto_chat_engine.reset()` and the new engine's assignment. After that it lists
`llama3.2:1b` for the rest of the gemma4 load, because the new engine is set
but the tag is not. With the fix, `[]` runs from the teardown until gemma4 is
serving. Raw polls are in `ps-swap-*.tsv` (`epoch_ms`, code, `time_total`, names).

## Conformance rerun

[`conformance.sh`](conformance.sh) and [`run_spec_tests.py`](run_spec_tests.py)
are copied unchanged from after-187 and were run against the new build. For each
file, the sorted per-test PASS/FAIL/SKIP lines are identical to the after-187
logs.

| Test file | After #187 | After #184 | Log |
| --- | --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 | [log](test_error_status.log) |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 | [log](test_error_status.gemma4.log) |
| `test_finish_reason.py` | PASS 7 | PASS 7 | [log](test_finish_reason.log) |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 | [log](test_request_validation.log) |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 | [log](test_request_validation.embed.log) |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 | [log](test_embed_task_prompt.log) |

## Not measured

- Streaming responses under TSan. `race.sh` sends only non-streaming requests,
  so the moved release is exercised on `send_response` paths, and on
  `send_streaming_response(final)` only through the conformance suite's
  streaming cases.
- `/v1/audio/transcriptions` (`--asr`). It was already locked, and the release
  change applies to it too.
- A queue-full (503) case for the two newly locked routes. It is the same code
  path as the five routes that were already locked.
