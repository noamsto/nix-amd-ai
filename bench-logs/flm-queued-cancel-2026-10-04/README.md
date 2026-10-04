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
never prefills, samples or decodes. `unregister_active_request` erases a slot
only while it still holds that request's token, so a reused `request_id` is not
erased by the cancelled request's completion; `/api/cancel` keeps its own random
id and is not registered; embeddings and audio have no cancellation path and
keep registering when they start; a non-string `request_id` is refused 400
before queueing.

## Red/green (`llama3.2:1b` streaming `/api/generate`, `max_tokens` 768)

A is a long streaming generation holding the NPU; B is a second streaming
generation with a caller-supplied `request_id`, queued behind A. The cancel is
posted while the server log shows B queued. B's stream is the per-request
`.ndjson`; "content lines" counts non-empty `response` lines.

| case | red | green |
|---|---|---|
| `queued-cancel` | FAIL: `/api/cancel` `{"cancelled":false}`; B ran to `done_reason=length`, 768 eval tokens, 769 content lines | PASS: `{"cancelled":true}`; B `done_reason=cancel`, 0 content lines, `prompt_eval_count=0 eval_count=0`; A `done_reason=length` |
| `queued-disconnect` | PASS (guard): B's client left while queued; server logged `Client disconnected; cancelling active request` and B's dequeue logged `Prefill Cancelled!` | PASS: same |
| `queued-normal` | PASS (guard): B completed after A, `done_reason=length`, 769 content lines | PASS: same |
| `registry` (id reuse) | FAIL: first cancel `cancelled:false`, so the sequence never starts | PASS: first cancel for B `cancelled:true`; C re-uses B's id while B is still queued; after B answers cancelled, cancelling the reused id again is `cancelled:true` — B's completion did not erase C's slot |

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

`active_requests_` is keyed by `request_id`. A cancelled request is erased by
`cancel_request()` (the `/api/cancel` hit), and its completion callback then
calls `unregister_active_request(id, token)`, which erases only if the slot still
holds **that request's** token. That is what makes the line safe when a caller
re-uses an id: after B is cancelled, C may register the same id before B's
handler runs; B's unregister sees C's token in the slot and leaves it alone. A
non-cancelled request is erased once by its own completion callback or catch.
`/api/cancel` is never registered and uses its own random id, so it cannot erase
another request's slot; a non-aware NPU route (embeddings, audio) registers when
it starts and unregisters on completion. The `registry` case drives exactly this
id-reuse sequence and fails if the slot is erased early; `queued-cancel`,
`queued-disconnect` and `queued-normal` exercise the cancel-hit, disconnect and
normal-completion paths.

## Limits

- **A cancelled queued request naming a different model still pays the model
  swap.** The four handlers call `ensure_model_loaded()` before their
  cancellation branch, so a request queued behind A that names a model other
  than A's and is then cancelled will swap/load that model before answering
  cancelled. The task's "skip it" is met for the decode and prefill (nothing is
  generated); the load is not avoided, and skipping it would mean answering in
  an endpoint's shape without that endpoint's engine. Stated as a trade-off.
- **Embeddings and audio are not cancellation-aware** (`handle_embeddings` takes
  no token; `handle_openai_audio_transcriptions` ignores it). They keep their
  current behavior: a cancel on a running request answers `cancelled:true`
  without stopping it. This change does not widen that to the queued window
  (they register when they start, not at accept). Pre-existing, orthogonal to
  #222.
- **TSan was not run**: the existing harness
  (`bench-logs/flm-ps-race-2026-09-28/tsan.nix`) is a full instrumented package
  build, which is not cheap on this shared host. The locking is argued below.

## Locking (TSan not run)

No new shared state: registration just moves earlier under the existing
`active_requests_mutex_`; token flags are `std::atomic<bool>`; the queue stays
under `npu_queue_mutex_`. The one new ordering is `npu_queue_mutex_` →
`active_requests_mutex_` (register under the queue lock in the queue branch);
`cancel_request` takes only `active_requests_mutex_`, so there is no lock-order
inversion.

## Reproduce

```
nix build .#fastflowlm --no-link --print-out-paths   # red on main, green on this branch
export XRT_LIB=<xrt-combined out path>/lib
bash bench-logs/flm-queued-cancel-2026-10-04/queued-cancel.sh \
  <fastflowlm out path>/bin/flm <out dir> <red|green>
```

`queued-cancel.sh` exits 0 iff no case FAILs. It waits for any other `flm`
process to exit before starting (never kills one), checks its own server PID,
and `shellcheck`s clean. `nix flake check` passes; `nix build .#fastflowlm`
builds.
