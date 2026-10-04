# `flm serve` backs off on a persistent accept error (#207), on halo

Red/green for #207. `WebServer::do_accept` re-armed immediately after its
handler ran, including when `async_accept` had failed. A persistent error such
as `EMFILE`/`ENFILE` — once the process runs out of file descriptors — fails
again the instant the next accept is armed, so the I/O thread spun on it and
never let a descriptor free up.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`; kernel 7.2.8). This probe does not load a model and never touches
the NPU: `flm serve` with no model tag starts the WebServer and answers
`GET /api/version` on its own.
**Old build (red):** `origin/main` @ `dc4cd36`.
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/accept-error-backoff.patch` after
`cancel-keep-early.patch`.

`pgrep -a flm` was empty before and after every server run; the probe waits for
any other `flm` and stops only the PID it started.

## The fix

`do_accept`'s error branch arms a `net::steady_timer` (`ioc`,
100 ms) and re-arms `do_accept()` from its completion handler, only while
`running`. The success path — including the connection-cap reject — is
unchanged. The timer is kept alive by the `shared_ptr` captured in its own
handler; the pending connection stays in the accept backlog, so it is accepted
once the wait ends and a descriptor is available.

## Red/green: CPU under descriptor exhaustion

[`accept-error-backoff.sh`](accept-error-backoff.sh) starts `flm serve -p
<port>` (no model), samples its CPU ticks over 3 s while idle
(`baseline`), lowers the process's `RLIMIT_NOFILE` soft limit to its current
open-fd count with `prlimit` so `accept4` has no fd to allocate and fails
`EMFILE`, holds one pending connection so the listener stays readable, samples
CPU again (`exhausted`), then restores the limit and asks
`GET /api/version` with a 10 s timeout (`recovered`). It fails closed if it
cannot lower the limit, and sets the soft limit to the lowest free fd number —
so no descriptor is allocatable and the `exhausted` figure cannot be near
baseline without the process having actually been out of descriptors.

| Run | Build | baseline CPU | exhausted CPU | recovery |
| --- | --- | --- | --- | --- |
| red | `dc4cd36` | 0.0 % | **296.0 %** | 200 |
| green | this branch | 0.0 % | **0.0 %** | 200 |

The red figure is the busy loop: ~3 cores of I/O threads re-arming immediately
on `EMFILE`. On green the process stays idle through the exhaustion, and both
builds accept a new connection once the limit is restored.

## #202 reset-before-accept probe on green

The new timer sits in the accept loop next to #202's re-arm, so #202's probe
was re-run against the green build:

| `cycles_answered_200` | `io_thread_errors` | `remote_endpoint_unavailable` | `connection_limit_reached` |
| --- | --- | --- | --- |
| 5 / 5 | 0 | 5 | 0 |

The success path is unaffected.

## Reproduce

```
nix build .#fastflowlm --no-link --print-out-paths   # green here; red: build origin/main @ dc4cd36
D=bench-logs/flm-accept-error-2026-10-04
export XRT_LIB_DIR=<xrt-combined lib dir>
bash $D/accept-error-backoff.sh <flm> 58761 $D red
bash $D/accept-error-backoff.sh <flm> 58762 $D green
bash bench-logs/flm-accept-reset-2026-09-28/reset-before-accept.sh \
  <flm> 58763 5 $D green-reset-before-accept
```
