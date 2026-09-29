# `flm serve` releases a connection slot exactly once on disconnect (#194), on halo

Red/green for #194, a counter-level check that a dead streaming session does not
double-release, and a rerun of OFLM-Next's server-api conformance suite using the
same method as
[`oflm-api-conformance-2026-09-28-after-187`](../oflm-api-conformance-2026-09-28-after-187/):
the same `run_spec_tests.py` shim, the same OFLM-Next commit, and the same models
and ports as after-187. Only the `flm` build under test changed.

This is the post-rebase rerun: #196 merged (main @ `ae40eed`) and inserted
`ps-serving-snapshot.patch` ahead of the #194 patch, so
`connection-slot-release.patch` was regenerated against the full series. Its
hunks are byte-identical to the first run — only `@@` line numbers and blob
hashes changed — so the relocation is mechanical.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`; kernel 7.2.8).
**Old build (red):** `origin/main` @ `ae40eed` —
`fastflowlm-1.0.6`.
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/connection-slot-release.patch` after
`ps-serving-snapshot.patch` on top of `ae40eed` —
`fastflowlm-1.0.6`.
**Scratch debug build (counter logs):** green plus temporary `header_print("DBG", …)`
instrumentation, never committed —
`fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` (chat).

`pgrep -a flm` was empty before and after every server run; each `flm serve` was
stopped by its PID. `lemond` had no model loaded (`all_models_loaded: []`), so it
was left running and never touched.

## The fix

`HttpSession` gains an atomic once-per-session flag and a single release:

```cpp
void HttpSession::release_slot() {
    if (!slot_released_.exchange(true)) {
        server_.active_connections_.fetch_sub(1);
    }
}
```

Every decrement site now goes through it. The commented-out decrement in
`send_chunk_data` is replaced by `release_slot()` rather than uncommented, because
after the first failed chunk write every later chunk for that dead session
re-enters the branch (the stream keeps producing, and `ostream.finalize()` sends a
final chunk too) and would decrement once per remaining chunk.

### Answer to #194's "not verified" question

Can a session whose streaming write failed reach `read_request`'s error path or
`write_response` again?

- **`read_request`: no.** It is called only from `start()` and from the
  OPTIONS-preflight write callback. A request that entered the streaming branch
  never returns to it.
- **`write_response`: yes, for a deferred session.** `rest_handler.cpp` calls
  `send_response` on an insert failure or a `generate()` exception and returns
  before `ostream.finalize()`. For a deferred session `send_response` runs
  `write_response_from_callback()` → `write_response` → the release; for a
  **non-deferred** session it does nothing and the handler abandons a stream that
  had already sent chunks, so `handle_request` releases that case explicitly
  (`else if (is_streaming_ && !deferred && !slot_released_.load())`). The atomic
  guard is what makes every re-entry safe rather than a claim it cannot happen.

## Red/green: slot leak

[`disconnect.sh`](disconnect.sh) aborts 12 streaming `/v1/chat/completions`
requests mid-stream (read one chunk, then RST via `SO_LINGER`), then opens a final
connection. On a leaking build the cap fills after ten aborts.

| Run | Build | Aborts | Final connection | `Connection limit reached` lines |
| --- | --- | --- | --- | --- |
| red | `ae40eed` | 12 | **REFUSED** (`Connection reset by peer`) | 3 |
| green | this branch | 12 | **ACCEPTED** (`HTTP/1.1 200 OK`) | 0 |

## No double-decrement / counter never below the real value

[`debug-slots.sh`](debug-slots.sh) ran against the scratch debug build, which
prints `active_connections_` on every accept and every release and prints each
`send_chunk_data` write failure. It ran 12 keep-alive `/api/version` requests,
1 non-streaming `/v1/chat/completions`, then 12 streaming aborts.

| Metric | Value |
| --- | --- |
| accepts | 27 |
| releases | 27 |
| `chunk write failed` lines | 36 |
| distinct accept counter values | `1` only |
| distinct release counter values | `0` only |
| final counter | 0 |

Every accept moved the counter to 1 and every release moved it to 0, so it never
underflowed and was never driven below the real value; the 36 write-failure lines
against 27 releases are the re-entries the guard collapses into one. Raw log:
summary in [`debug-slots.summary`](debug-slots.summary).

One abort's lines, as an example of the re-entry:

```
[DBG]  accept -> 1
[DBG]  chunk write failed
[DBG]  release -> 0
[DBG]  chunk write failed
[DBG]  chunk write failed
```

## Keep-alive and non-streaming unchanged

[`keepalive-nonstream.sh`](keepalive-nonstream.sh) against the green build: 12
keep-alive-shaped `/api/version` requests and 12 non-streaming
`/v1/chat/completions` requests all answered `200`, and a new connection was still
accepted after 12 further streaming aborts. Log:
(the log is not committed; rerun `keepalive-nonstream.sh`).

## Consumer map — every decrement site

| # | site (`src/server/server.cpp`) | before | disposition |
| - | ---- | ------ | ----------- |
| 0 | `do_accept` increment | `fetch_add(1)` | unchanged; one accept = one session |
| 1 | `HttpSession::close_connection` | plain `fetch_sub` | `release_slot()`; no caller in this tree |
| 2 | `read_request` read-error path | plain `fetch_sub` | `release_slot()` |
| 3 | OPTIONS `async_write` error | `return`, no cleanup | `release_slot()` (previously leaked) |
| 4 | `write_response` `async_write` completion | plain `fetch_sub` | `release_slot()` |
| 5 | `write_streaming_response` header-write error | `return`, no cleanup | `release_slot()` (previously leaked) |
| 6 | `send_chunk_data` write-error branch | decrement commented out | `release_slot()` — the #194 bug |
| 7 | `send_chunk_data` `is_final` branch | plain `fetch_sub` | `release_slot()` |
| 8 | `start_client_disconnect_monitor` | cancels token only | no release of its own; generation still reaches `finalize()` (site 7/6) or `send_response`/site 4 |
| 9 | `handle_request`, non-deferred abandoned stream | `else` did nothing | `release_slot()` when `is_streaming_ && !deferred && !slot_released_`; a synchronous handler that throws after chunks were sent leaves no async op to release |

## Conformance rerun

Same method and models as after-187. Each file's sorted `PASS`/`FAIL`/`SKIP` lines
diff **empty** against after-187; no regressions.

| Test file | after-187 | after-194 |
| --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 |
| `test_finish_reason.py` | PASS 7 | PASS 7 |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 |

## Reproduce

```
nix build .#fastflowlm --no-link --print-out-paths   # red on ae40eed, green here
bash bench-logs/oflm-api-conformance-2026-09-28-after-194/disconnect.sh \
  /nix/store/<flm>/bin/flm 58701 12 bench-logs/oflm-api-conformance-2026-09-28-after-194 <label>
bash bench-logs/oflm-api-conformance-2026-09-28-after-194/keepalive-nonstream.sh \
  /nix/store/<flm>/bin/flm 58704 bench-logs/oflm-api-conformance-2026-09-28-after-194
bash bench-logs/oflm-api-conformance-2026-09-28-after-194/conformance.sh \
  /nix/store/<flm>/bin/flm bench-logs/oflm-api-conformance-2026-09-28-after-194 <oflm-next checkout>
```

The debug build is not reproducible from the committed tree: it was built by adding
a temporary patch that printed the three `DBG` lines above, then removing that patch
and rebuilding the green path.