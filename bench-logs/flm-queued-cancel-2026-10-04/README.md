# `flm serve`: `POST /api/cancel` reaches a request queued for the NPU (#222), on halo

Red/green for #222. A request waiting in the NPU queue behind another is now
registered for cancellation at accept time, so `POST /api/cancel` with its
`request_id` finds it, and the dequeued request answers cancelled through the
handler's existing cancellation path instead of running in full. The fix also
keeps #201's disconnect-while-queued cancel and leaves a normal queued request
untouched.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`; kernel 7.2.8).
**Old build (red):** `main`, the 21 patches before this one, no
`cancel-queued-request.patch`.
**New build (green):** this branch, `cancel-queued-request.patch` last in
`pkgs/fastflowlm/default.nix`.
**Model:** `llama3.2:1b` (`max_prefill_len` 4096). `pgrep -x flm` was empty
before and after every run; the host `lemond` was never touched.

Raw per-request logs are not committed; this README carries the decisive numbers
and log lines, and [`queued-cancel.sh`](queued-cancel.sh) reproduces the run.

## The defect

`WebServer::handle_request` pushes `process_task(true)` onto
`npu_request_queue_` when the NPU is busy. The cancellation token was created
and `register_active_request(request_id, token)` called **inside**
`process_task`, so a request waiting in the queue was absent from
`active_requests_`. `POST /api/cancel` answered
`{"cancelled": false, "message": "Request not found or already completed"}` and
the request then ran to completion. The fix parses the body once in
`handle_request`, creates and registers the token there for the routes whose
handler composes it into its generation loop (`/api/generate`, `/api/chat`,
`/v1/chat/completions`, `/v1/completions`), and lets the dequeued request answer
through the handler's existing cancel branch. `AutoModel::_shared_insert` now
checks the predicate before any prefill, so a request cancelled before it starts
never prefills, samples or decodes. `/api/cancel` keeps its own random id and is
not registered (it cannot erase another request's slot), embeddings and audio
have no cancellation path and keep registering when they start, and a
non-string `request_id` is refused 400 before queueing.

## Red/green (`llama3.2:1b` streaming `/api/generate`, `max_tokens` 768)

A is a long streaming generation holding the NPU; B is a second streaming
generation with a caller-supplied `request_id`, queued behind A. The cancel is
posted while the server log shows B queued. B's stream is the per-request
`.ndjson`; "content lines" counts non-empty `response` lines.

| case | red | green |
|---|---|---|
| `queued-cancel` | FAIL: `/api/cancel` `{"cancelled":false}`; B ran to `done_reason=length`, 768 eval tokens, 769 content lines | PASS: `{"cancelled":true}`; B `done_reason=cancel`, 0 content lines, `prompt_eval_count=0 eval_count=0`; A `done_reason=length` |
| `queued-disconnect` | PASS (guard): B's client left while queued; server logged `Client disconnected; cancelling active request`; B did not run | PASS: same |
| `queued-normal` | PASS (guard): B completed after A, `done_reason=length`, 769 content lines | PASS: same |
| `registry` | FAIL: first cancel `cancelled:false`, second `cancelled:false` | PASS: first `cancelled:true`, second `cancelled:false` (B's slot is gone, not lingering) |

The green queued-cancel B response is a single NDJSON line:
`{"model":"llama3.2:1b","response":"","prompt_eval_count":0,"eval_count":0,…,"done_reason":"cancel","done":true}`
— the same shape the streaming handler produces for a client disconnect while
queued, and no decode happened. The red B response ends
`…,"prompt_eval_count":49,"eval_count":768,…,"done_reason":"length","done":true`.

Decisive server-log lines (green, three queued requests):

```
[🕒 ]  NPU busy, request queued (1/10): POST /api/generate
[🟡 ]  Dequeuing NPU request (0 remaining)...
[❌ ]  Prefill Cancelled!
[🔒 ]  Client disconnected; cancelling active request      # queued-disconnect case
```

Red shows `request queued` then `Dequeuing NPU request` with no `Prefill
Cancelled!` for the queued-cancel case: B ran.

## Registry erase-once

`active_requests_` is keyed by `request_id` and every erase is
`unordered_map::erase(key)`, which is idempotent. A cancelled request is erased
by `cancel_request()` (the `/api/cancel` hit) and then unregistered again by the
completion callback or a handler-throw catch — the second erase is a no-op. A
non-cancelled request is erased once by its completion callback or catch.
`/api/cancel` is never registered and uses its own random id, so it cannot erase
another request's slot; a non-aware NPU route (embeddings, audio) registers when
it starts and unregisters on completion. The `registry` case shows the key is
gone after B answers; `queued-cancel`, `queued-disconnect` and `queued-normal`
exercise the cancel-hit, disconnect and normal-completion paths.

## Locking (TSan not run)

No new shared state: registration just moves earlier under the existing
`active_requests_mutex_`; token flags are `std::atomic<bool>`; the queue stays
under `npu_queue_mutex_`. The one new ordering is `npu_queue_mutex_` →
`active_requests_mutex_` (register under the queue lock in the queue branch);
`cancel_request` takes only `active_requests_mutex_`, so there is no lock-order
inversion. The existing TSan harness
(`bench-logs/flm-ps-race-2026-09-28/tsan.nix`) is a full instrumented package
build, which is not cheap on this shared host, so the locking is argued rather
than measured here.

## Reproduce

```
nix build .#fastflowlm --no-link --print-out-paths   # red on main, green on this branch
export XRT_LIB=<xrt-combined out path>/lib
bash bench-logs/flm-queued-cancel-2026-10-04/queued-cancel.sh \
  <fastflowlm out path>/bin/flm <out dir> <red|green>
```

`queued-cancel.sh` exits 0 iff no case FAILs. It waits for any other `flm`
process to exit before starting (never kills one), checks its own server PID,
and `shellcheck`s clean.
