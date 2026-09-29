# `flm serve` `GET /api/ps` races model swaps (#184, #192), on halo

Red/green for #184 under ThreadSanitizer, production-build probes for the NPU
lock (including #192's measured disconnect sequence) and for `/api/ps` during
a swap, and a rerun of OFLM-Next's server-api
conformance suite using the same method as
[`oflm-api-conformance-2026-09-28-after-187`](../oflm-api-conformance-2026-09-28-after-187/).

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build (red):** the #187 tip, this branch's base,
`fastflowlm-1.0.6` (the same out
path as the after-187 green build).
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/ps-serving-snapshot.patch`,
`fastflowlm-1.0.6`. The
production probes below ran on
`fastflowlm-1.0.6`, an earlier
revision of the patch. Review changed only a comment in it after that run, so
the compiled code is the same.
**TSan builds:** [`tsan.nix`](tsan.nix), scratch only, not wired into the flake.
The base patch set is `fastflowlm-tsan-1.0.6`
(`--arg fixed false`). All 9 patches is `fastflowlm-tsan-1.0.6`.
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
4. Queue phase: 4 rounds, alternating `/api/chat` and `/v1/chat/completions`
   on `llama3.2:1b`. Each round sends request A, then request B 0.3 s later,
   so B queues behind A on the NPU token. Back-to-back NPU requests on the
   same model, with no 500 ms swap pause between them, can overlap the
   previous handler's post-send tail: both a queued B (B starts once A's
   token is released) and the next round's request, sent as soon as the
   replies arrive without queuing. The sequential swap phases never overlap
   it, because `ensure_model_loaded` sleeps 500 ms before touching the engine.
5. Classifies every TSan report with [`tsan-classify.py`](tsan-classify.py), of
   any warning kind (not only data races).

The classifier works per access stack, and the first bucket that matches wins:
1. `libc-tz`: `tzset`/`localtime`/`gmtime`/`strftime` in either access stack's
   top frames.
2. `ps-pair`: `handle_ps` in one access stack and `ensure_model_loaded` in the
   other.
3. `model-state`: `ensure_model_loaded` or `AutoModel::` in an access stack, or
   a `RestHandler::` access to the RestHandler heap object. Also any other
   warning kind (e.g. heap-use-after-free) whose stacks contain `RestHandler::`
   or `AutoModel::`.
4. `incomplete` (a truncated report), `failed-restore`, then `other`.

A log the classifier cannot read fails the run.
- Red requires `ps-pair ≥ 1` (the `/api/ps` race) and `model-state ≥ 1` (the
  tail race).
- Green requires `ps-pair`, `model-state`, `incomplete` and `other` all 0,
  with every poll and every request answered 200.

| | Red (base patch set) | Green (with the fix) |
| --- | --- | --- |
| `/api/ps` polls | 171699: 171693 × 200, 6 × `000` | 180118, all 200 |
| chat + completions + queue | 17, all 200 | 17, all 200 |
| `ps-pair` | **8** | 0 |
| `model-state` | **35** | 0 |
| `other` | 57 | 0 |
| `incomplete` / `failed-restore` / skipped logs | 1 / 0 / 0 | 0 / 0 / 0 |
| `libc-tz` (not gating) | 83 | 78 |
| verdict | PASS 2/2 (both races reproduced) | PASS 5/5 |

The `other == 0` green gate was added after review; the green run
reported here predates it and reported `other=0` under
the original gate.

The eight red reports
are exactly the race in the issue:

| Write (`ensure_model_loaded`) | Read (`handle_ps`) | Reports |
| --- | --- | --- |
| `rest_handler.cpp:597` `auto_chat_engine.reset()` | `:1343` `unique_ptr::operator bool` | 2 |
| `rest_handler.cpp:604` `auto_chat_engine = std::move(...)` | `:1343` `unique_ptr::operator bool` | 1 |
| `rest_handler.cpp:645` `current_model_tag = ensure_tag` | `:1343` `is_model_supported(current_model_tag)` (2), and the JSON entry's copies of `current_model_tag` (3, which TSan attributes to `:1373` under `-O3` inlining) | 5 |

The writers came from both `handle_chat` and `handle_openai_completion`. Every
racing address is inside the RestHandler object: the 248-byte heap block that
`create_lm_server` allocates. Line numbers are in the base-build source. The
excerpt cuts access stacks at frame #16. `tsan-classify.py` writes the full
classification, one line per report. That summary (0.4 MB red, 0.1 MB green), the
raw TSan logs (3 MB), the
server logs (~65 MB each, one request banner per poll) and the raw per-poll
status files are not committed.

**The tail race** shows up only in the queue phase. All 35 red `model-state`
reports
have `handle_chat`'s post-send `clear_context()` (`rest_handler.cpp:1091`,
right after `send_response`) on one side. 6 of them race the queued request
B's prefill (`AutoModel::_shared_insert` via `rest_handler.cpp:1061`,
dispatched through `server.cpp:930`, the queued-task lambda). The other 29
race the *next* round's
`/v1/chat/completions` request A, which is not queued at all: it is sent as
soon as the previous round's replies arrive, while `/api/chat` B's tail is
still running (A's side is `clear_context()` at `:1517` on a prompt-cache
miss, or `insert()`/`profiler::stop()` at `:1596`).
`/v1/chat/completions` has no post-send tail on its non-streaming success
path — its `prompt_cache.reset()` at `:1656` runs only for a cancelled
generation, before `send_response` — so only `handle_chat`'s tail was
reproduced; `/v1/chat/completions` shows up only as the request that
overlaps it. In all 57 red `other` reports,
both access stacks are under a RestHandler route handler: two NPU handlers
running at once, racing inside the NPU runtime (`npu_app::_setup_kernel`,
`llama_npu_sequence`, and XRT/ELFIO objects destroyed under one handler while
the other uses them). With the release moved to after the handler returns,
all three buckets are 0.

On red, 6 `/api/ps` polls got no reply within curl's 30 s `--max-time`
(`000`). They fall in the middle of the pollers' files, not at teardown, and
red's last queue round took 240 s where green's took 2–4 s. That was not
investigated further. It happened only on the base build.

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

| Check | Base | New |
| --- | --- | --- |
| `/v1/completions` queued | **FAIL**: ran immediately | PASS |
| `/api/embeddings` queued | **FAIL**: ran immediately | PASS |
| chat / completions / embeddings | **500** / 200 / 200 | 200 / 200 / 200 |
| server alive | PASS | PASS |

On the base build, the unlocked `/v1/completions` launched on the NPU while the
chat was decoding. The chat died with
`[ERROR] handle_chat: bad command state, can't launch`, an XRT
fault, and answered 500.

### #192's disconnect sequence

[`disconnect.sh`](disconnect.sh) replays the sequence measured in #192 on
`llama3.2:1b`, with each server log line stamped in wall-clock seconds:
1. A streaming `/v1/completions` (`max_tokens: 512`). The client disconnects
   after 5 chunks, and the server keeps decoding (#191).
2. Immediately after, a non-streaming `/api/chat` (`num_predict: 4`).
3. Then a second streaming `/v1/completions` (`max_tokens: 8`), read to the end.

The base build is the one #192 measured on (`fqkyn7…`, the same as main). It
was run three times, because what the overlap breaks varies from run to run.

| Run | Step 2 `/api/chat` | Step 3 `/v1/completions` | Server afterwards |
| --- | --- | --- | --- |
| base 1 | **500** in 6 ms: `The runlist is submitted for execution and cannot be reset` | 200, but logs `handle_openai_completion: bad command state, can't launch` | alive |
| base 2 | same runlist error logged, then **SIGSEGV**: no reply (`000`) | server gone | **dead** |
| base 3 | **500** in 2 ms, runlist error | **500**, runlist error | alive |
| new | **queued** (`NPU busy, request queued (1/10): POST /api/chat`), 200 after 5.2 s | 200, `[DONE]` | alive, no `ERROR` lines |

On base, the step-1 `/v1/completions` never logs `NPU Locked!`, so the step-2
chat takes the lock at once while the orphaned decode is still using the NPU.
Run 2's core dump (`coredumpctl`) shows where it died:

```
#0 alloc_run(std::shared_ptr<xrt::kernel_impl> const&)   libxrt_coreutil.so.2
#1 xrt::run::run(xrt::kernel const&)                    libxrt_coreutil.so.2
#2 llama_npu::Impl::set_context_length(int)             libllama_npu.so
#3 AutoModel::clear_context()                           flm
#4 RestHandler::handle_chat(...)                        flm
```

`#3` is the chat's error-path `clear_context()`. It rebuilds NPU runs while the
unlocked `/v1/completions` is still submitting its own.

#192's heap corruption (`double free or corruption`) did not recur in these
three runs; the SIGSEGV in run 2 is this build's crash instead. On the new build,
the step-1 `/v1/completions` holds the token, so the chat waits for the
orphaned 512-token decode to finish (about 4.8 s). That wait is #191's missing
cancellation, not a lock problem.

## `/api/ps` during a swap: latency and flip point

[`ps-during-swap.sh`](ps-during-swap.sh) serves `llama3.2:1b` and polls
`/api/ps` every 50 ms. It asks `/api/chat` for `gemma4-it:e4b`, which swaps the
model, and keeps polling for 1 s after the reply. The load window runs from
sending the chat to its reply.

| | Base | New |
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

| Test file | After #187 | After #184 |
| --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 |
| `test_finish_reason.py` | PASS 7 | PASS 7 |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 |

## Not measured

- Streaming responses under TSan. `race.sh` sends only non-streaming requests,
  so the moved release is exercised on `send_response` paths, and on
  `send_streaming_response(final)` only through the conformance suite's
  streaming cases.
- `/v1/audio/transcriptions` (`--asr`). It was already locked, and the release
  change applies to it too.
- A queue-full (503) case for the two newly locked routes. It is the same code
  path as the five routes that were already locked.
- Tails other than non-streaming `/api/chat`'s. Streaming tails,
  `/api/generate`, `/v1/completions`, and `/v1/chat/completions`'s error-path
  tail were not reproduced under TSan; the release change covers them by the
  same code path (the token is released after the handler returns).
