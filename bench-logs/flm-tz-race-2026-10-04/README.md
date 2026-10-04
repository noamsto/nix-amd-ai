# `flm serve` localtime/gmtime static-buffer races (#197), on halo

Red/green under ThreadSanitizer for the three served-path time calls, plus a
production probe for the `/api/ps` `expires_at` timezone offset, using the
same method as [`flm-ps-race-2026-09-28`](../flm-ps-race-2026-09-28/).

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`).
**Base build (red):** the current patch set with
`thread-safe-localtime.patch` dropped (`--arg fixed false`).
**Fixed build (green):** every patch applied.
**TSan builds:** [`tsan.nix`](tsan.nix), scratch only, not wired into the
flake, adapted from the #196 recipe. Both builds compile everything with
`-fsanitize=thread -g` and link `libtsan.so.2` (`ldd bin/flm`).
**Production builds:** the flake's `fastflowlm` with and without the patch
([`unpatched.nix`](unpatched.nix) drops only it), for the offset probe.
**Models:** `llama3.2:1b` and `gemma4-it:e4b`.
**Harness:** the #196 [`race.sh`](../flm-ps-race-2026-09-28/race.sh) and
[`tsan-classify.py`](../flm-ps-race-2026-09-28/tsan-classify.py) unchanged,
run with `POLLERS=4 SWAPS=2 COMPLETIONS=1 QUEUE_ROUNDS=1` (a shorter envelope
than #196; the time races fire from the concurrent `/api/ps` pollers, not from
the swap count). `pgrep -x flm` was empty before and after every run; each
`flm serve` was stopped by its PID.

## The bug

`flm serve` runs its request handlers on 10 I/O threads. Three served-path
sites called the non-reentrant libc time functions, which return a pointer to
one process-wide static `struct tm`:

- `RestHandler::handle_ps` (`expires_at` in `rest_handler.cpp`) called
  `localtime()` and then `gmtime()` into that same buffer, so `local_tm` and
  `utc_tm` aliased; the buffer held UTC, and the timezone-offset computation
  was always `+00:00`;
- the request logger's `get_current_time_string()` in `server.cpp`;
- minja's `strftime_now` from `chat_template::apply`.

The patch switches the first and third to `localtime_r` with a caller-owned
`struct tm`, and takes `handle_ps`'s offset directly from `local_tm.tm_gmtoff`
(libc's own UTC offset for that instant), so the offset is correct across DST
and month/year boundaries and no two threads share a time buffer. The
`gmtime_r` call is gone entirely: the offset needs no UTC `struct tm`.

## Red/green: ThreadSanitizer

`race.sh <flm> <outdir> green` was run with label `green` for **both** builds:
both carry the #184 `ps-serving-snapshot.patch`, so its green oracle (no
`ps-pair`, no `model-state`, no `incomplete`, no `other`, every reply 200) is
the right one, and `libc-tz` is the bucket under test.

| | Red (no patch) | Green (patched) |
| --- | --- | --- |
| `/api/ps` polls | 141936, all 200 | 175318, all 200 |
| chat + completions + queue | 7, all 200 | 7, all 200 |
| `libc-tz` | **64** | **0** |
| `ps-pair` / `model-state` / `incomplete` / `other` | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| TSan log files | 1 (64 reports) | **none** |

The green run wrote no TSan log file at all: TSan creates the `log_path` file
only when it reports something, and the same harness on the red build of the
same recipe produced one, so the empty set is zero reports across 175318
`/api/ps` replies and 7 NPU requests. The red reports name exactly the sites
above: `[W]localtime` from `get_current_time_string()` (`server.cpp:30`) and
`[W]gmtime` from `RestHandler::handle_ps`, against `tzset_internal`, `malloc`
and `free`. Raw TSan logs and per-poll status files are not committed.

`libc-tz` does not gate `race.sh`; the counts above are read from
`tsan-green.summary.txt` (red) and the absence of any `tsan-green.*` report
file (green). Both runs exit 0 under the green oracle.

## `/api/ps` `expires_at` offset under `TZ=Asia/Jerusalem`

[`offset.sh`](offset.sh) serves `llama3.2:1b` under `TZ=Asia/Jerusalem`,
fetches `/api/ps`, splits `expires_at` into its wall-clock part and its
`±HH:MM` suffix, and re-derives both with GNU `date` under the same TZ. The
unpatched build printed the UTC wall clock with a `+00:00` suffix — the same
instant as the local one, but the wrong offset and not the local wall clock —
so both comparisons fail; the patched build prints the local wall clock and
the matching `+03:00`. Run against the unpatched production build (red), then
the patched one (green):

| | `expires_at` | suffix vs true | wall clock vs true |
| --- | --- | --- | --- |
| Red (no patch) | `2026-10-04T10:21:46.04826+00:00` | `+00:00` vs `+03:00` **FAIL** | `10:21:46` vs `13:21:46` **FAIL** |
| Green (patched) | `2026-10-04T13:21:42.23229+03:00` | `+03:00` vs `+03:00` PASS | `13:21:42` vs `13:21:42` PASS |

Both runs were on the same host within the same hour, well away from any DST
transition (`Asia/Jerusalem` ends DST in late October). The unpatched build's
constant `+00:00` and UTC wall clock are the alias in the issue. The offset is
taken from `tm_gmtoff`, so it needs no hour/minute/day arithmetic and stays
correct at month and year ends; only the *value* changes — the field's shape
and its only producer (`handle_ps`) are unchanged, so lemond/Ollama-style
clients that parse the ISO-8601 offset are unaffected.

## Not measured

- ThreadSanitizer coverage of the offset probe: the TSan runs above exercise
  `handle_ps` concurrently, but with the machine's TZ; the offset itself is
  checked on the production builds.
- A response computed across a DST transition, or at a month/year end: the
  probe compares a fixed instant on one day. The offset is taken directly from
  `tm_gmtoff`, so it has no day-wrap arithmetic to get wrong, but that path is
  not exercised by a run of its own.
