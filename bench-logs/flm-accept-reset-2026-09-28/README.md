# `flm serve` keeps accepting after a client resets before accept (#202), on halo

Red/green for #202, a counter-level check that each reset connection gives its
slot back exactly once, a rerun of #198's slot probes, and a rerun of
OFLM-Next's server-api conformance suite using the same method, shim, commit,
models and ports as
[`oflm-api-conformance-2026-09-28-after-194`](../oflm-api-conformance-2026-09-28-after-194/).
Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`; kernel 7.2.8).
**Old build (red):** `origin/main` @ `95ae7a6` —
`/nix/store/1z0mbcmhl9jfrn9pbphvqy7a76jwpjzm-fastflowlm-1.0.6`.
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/accept-loop-rearm.patch` after
`connection-slot-release.patch` —
`/nix/store/c4bf3vxy028mji2cvq4swq316i85f9hc-fastflowlm-1.0.6`.
**Scratch debug build (counter logs):** green plus the same temporary
`header_print("DBG", …)` lines #198 used (accept, release, chunk write failed),
never committed — `/nix/store/zdj5bcg4jqr9nxzq3xg6xgmbarmfyb53-fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` (chat), plus `gemma4-it:e4b` and `embed-gemma:300m`
for the conformance legs, as in after-194.

`pgrep -a flm` was empty before and after every server run; each `flm serve` was
stopped by its PID, after a `SIGCONT` in case it was still stopped.

## The fix

- The `HttpSession` constructor uses the `error_code` overloads of `set_option`
  and `remote_endpoint`, and logs `TCP connection established - Remote endpoint
  unavailable` on error. The session then ends through `read_request`'s error
  path, which releases the slot through `release_slot()` (#198).
- `do_accept` wraps session creation and `start()` in `try`/`catch`. On a throw
  it logs, gives the slot back with a direct `fetch_sub` and falls through to the
  re-arm. No double release is possible: a session releases only from a
  completion handler, and none is queued when construction or `start()` throws.

## Red/green: reset before accept

[`reset-before-accept.sh`](reset-before-accept.sh) runs #202's sequence per
cycle: `SIGSTOP` flm, connect and close with `SO_LINGER {1,0}` (the reset
connection stays in the accept queue), `SIGCONT`, then `GET /api/version` with a
10 s timeout.

| Run | Build | Cycles | `GET /api/version` | `Error in WebServer I/O thread` | Log |
| --- | --- | --- | --- | --- | --- |
| red | `95ae7a6` | stopped at 1 | **timeout** (`000`) | 1 | [`before/server-red.log`](before/server-red.log), [`before/client-red.log`](before/client-red.log) |
| green | this branch | 15 | **200** ×15 | 0 | [`server-green.log`](server-green.log), [`client-green.log`](client-green.log) |

The red server log line:

```
[LOG]  Error in WebServer I/O thread: remote_endpoint: Transport endpoint is not connected [system:107 ...]
```

On green each reset connection logs `TCP connection established - Remote
endpoint unavailable` (15 lines) and the server keeps answering past the
10-connection cap, so every reset connection gave its slot back.

## Counter: one release per reset connection

The same probe against the scratch debug build (15 cycles, all 200):
32 accepts, 32 releases, every accept `-> 1`, every release `-> 0`.
Raw lines: [`reset-debug-slots.log`](reset-debug-slots.log), summary
[`summary-reset-debug.txt`](summary-reset-debug.txt).

## #198's slot probes, unchanged

| Probe | after-194 | this branch | Log |
| --- | --- | --- | --- |
| `disconnect.sh`, 12 streaming aborts | final connection ACCEPTED, 0 limit lines | ACCEPTED, 0 limit lines | [`client-green-disconnect.log`](client-green-disconnect.log), [`server-green-disconnect.log`](server-green-disconnect.log) |
| `debug-slots.sh` (debug build) | accepts 27, releases 27, chunk write failures 36, final 0 | 27, 27, 36, 0 | [`debug-slots.log`](debug-slots.log), [`debug-slots.summary`](debug-slots.summary) |
| `keepalive-nonstream.sh` | all 200, accepted after aborts | all 200, accepted after aborts | [`keepalive-nonstream.log`](keepalive-nonstream.log) |

## Conformance rerun

Each file's sorted `PASS`/`FAIL`/`SKIP` lines diff **empty** against after-194.

| Test file | after-194 | this branch | Log |
| --- | --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 | [log](test_error_status.log) |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 | [log](test_error_status.gemma4.log) |
| `test_finish_reason.py` | PASS 7 | PASS 7 | [log](test_finish_reason.log) |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 | [log](test_request_validation.log) |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 | [log](test_request_validation.embed.log) |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 | [log](test_embed_task_prompt.log) |

## Reproduce

```
nix build .#fastflowlm --no-link --print-out-paths   # red on 95ae7a6, green here
D=bench-logs/flm-accept-reset-2026-09-28 P=bench-logs/oflm-api-conformance-2026-09-28-after-194
bash $D/reset-before-accept.sh /nix/store/<flm>/bin/flm 58712 15 $D green
bash $P/disconnect.sh /nix/store/<flm>/bin/flm 58701 12 $D green-disconnect
bash $P/keepalive-nonstream.sh /nix/store/<flm>/bin/flm 58704 $D
bash $P/conformance.sh /nix/store/<flm>/bin/flm $D <oflm-next checkout>
```

The debug build is not reproducible from the committed tree: it adds a temporary
patch printing the three `DBG` lines, on top of this branch.
