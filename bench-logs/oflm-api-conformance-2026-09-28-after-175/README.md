# `flm serve` error bodies without exception text, on halo (after #175)

Red/green for #175, plus a rerun of OFLM-Next's server-api conformance suite
using the same method as
[`oflm-api-conformance-2026-09-28-after-173`](../oflm-api-conformance-2026-09-28-after-173/):
the same `run_spec_tests.py` shim, the same OFLM-Next commit, and the same
models and ports. Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Old build (red):** the #173 tip (`d38bfd7`), which has no `no-exception-text.patch` —
`/nix/store/zvg05givvmmlmp331fn9imjyfyrr6jyi-fastflowlm-1.0.6`, the same out path
the after-173 run ended on.
**New build (green):** this branch, adding `pkgs/fastflowlm/patches/no-exception-text.patch` —
`/nix/store/1hk1j328srbnqyic0az0m08ffxzf1mms-fastflowlm-1.0.6`.
Later comment-only changes to the patch moved the out path to
`/nix/store/5gga3wag3iqndlk6hnlnvic2idl7vlm4-fastflowlm-1.0.6`. The code it
compiles is the same.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` and `gemma4-it:e4b` (chat), `embed-gemma:300m` (embedding).

`pgrep -a flm` was empty before and after every server run. `lemond` had no
model loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was
left running and never touched. Each `flm serve` was stopped by its PID.

## Red/green: malformed requests

[`probes.sh`](probes.sh) sends three well-formed JSON bodies whose field has
the wrong type. Each passes `require_field` but throws inside a handler.
A fourth, normal request confirms the server still answers. It was run
against `$FLM serve llama3.2:1b --port 58601`, with `LD_LIBRARY_PATH` set as
in the #171 README (#148).

| Probe | Old build ([`before/probes.txt`](before/probes.txt)) | New build ([`probes.txt`](probes.txt)) |
| --- | --- | --- |
| `/v1/chat/completions`, `"stream":"yes"` | 500 `{"message":"[json.exception.type_error.302] type must be boolean, but is string","type":"server_error","code":500}` | 400 `{"message":"Invalid request","type":"invalid_request_error","code":"invalid_value"}` |
| `/api/chat`, `"options":"x"` | 400 `{"error":"[json.exception.type_error.306] cannot use value() with string"}` | 400, same generic body |
| `/api/generate`, `"stream":"yes"` | 400 `{"error":"[json.exception.type_error.302] type must be boolean, but is string"}` | 400, same generic body |
| normal chat request | 200 | 200 |

On the new build the detail goes to the server log only
([`probes-server-log.txt`](probes-server-log.txt)). There is one `[ERROR]` line
per probe, naming the handler and quoting the nlohmann text. The old build
did not log it at all ([`before/probes-server-log.txt`](before/probes-server-log.txt)).

The first probe's status moves from 500 to 400. A `json::exception` means the
request had a field of the wrong shape, so it is a client error. Handlers that
already sent bare-string errors answered 400 before and still do.

Catches around prompt processing (`insert()` and `generate_with_prompt()`)
answer 400 for any exception, as they did before. That is where a chat
template's `raise_exception` rejects a conversation, as a plain
`std::runtime_error`. Other non-JSON exceptions, such as a failure in
`generate()`, now answer 500. This template path was checked in the code
only. None of the conversations tried on `llama3.2:1b` (tools with no user
turn, an image part, a lone `tool` message) made its template raise.

## Source grep

[`what-grep.txt`](what-grep.txt): `rg -n 'what\(\)' src/server` over v1.0.6
with all four patches applied in `default.nix` order. Every hit is a
`header_print` log call or a comment. None of them builds a response body.

## Conformance rerun

| Test file | After #173 | After #175 | Log |
| --- | --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 | [log](test_error_status.log) |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 | [log](test_error_status.gemma4.log) |
| `test_finish_reason.py` | PASS 7 | PASS 7 | [log](test_finish_reason.log) |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 | [log](test_request_validation.log) |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 | [log](test_request_validation.embed.log) |
| `test_embed_task_prompt.py` | FAIL 2, PASS 1, SKIP 8 | FAIL 2, PASS 1, SKIP 8 | [log](test_embed_task_prompt.log) |

Every test has the same outcome as in the after-173 logs; each file's sorted
PASS/FAIL/SKIP lines diff empty. The two `test_embed_task_prompt.py` failures
are #174, which is unchanged.
