# `flm serve` malformed `details.family` fails load as 500 `model_load_failed` (#181), on halo

Red/green for #181, plus a rerun of OFLM-Next's server-api conformance suite
using the same method as
[`oflm-api-conformance-2026-09-28-after-180`](../oflm-api-conformance-2026-09-28-after-180/):
the same `run_spec_tests.py` shim, the same OFLM-Next commit, and the same
models and ports. Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build (red):** the #180 tip, this branch's base (`feat/180-...`),
`fastflowlm-1.0.6`.
**New build (green):** this branch, adding the `details.family` guards to
`pkgs/fastflowlm/patches/model-identity.patch`,
`fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` (the model left loaded) and `gemma4-it:e4b` (the
malformed entry the request names).

`pgrep -a flm` was empty before and after every run. `lemond` had no model
loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was left
running and never touched. Each `flm serve` was stopped by its PID.

## The bug

`ensure_model_loaded` read `std::string family = info["details"]["family"];`
outside any try. `info` is a non-const `nlohmann::json`, so a missing
`details.family` reads as `null` and the string conversion throws
`[json.exception.type_error.302] type must be string, but is null`. The
exception reached the handler's outer catch, and since #175 a `json::exception`
there is answered 400 `invalid_request_error` "Invalid request". It is a
server-side config fault. #175 already routed `max_prefill_len` and the
model-path lookups to `ModelLoad::LoadFailed`; this read was missed.

## Red/green: malformed `details.family`

[`probes.sh`](probes.sh) `<flm> <outdir> <base|new>` copies the shipped
`model_list.json`, mutates the `gemma4-it:e4b` entry, points `flm serve` at it
with `FLM_CONFIG_PATH` (the override `utils::find_model_list()` honours), serves
`llama3.2:1b` on port 58601, and sends one `/v1/chat/completions` request naming
`gemma4-it:e4b`. The per-case reply and server logs are not committed; rerun `probes.sh`.

| Case | Probe | Expected | Red build | Green build |
| --- | --- | --- | --- | --- |
| `details.family` key removed | `/v1/chat/completions` for `gemma4-it:e4b` | 500 `model_load_failed` | **400** `Invalid request` | 500 `{"message":"model 'gemma4-it:e4b' is known to this build but could not be loaded; the server log says why","type":"server_error","param":"model","code":"model_load_failed"}` |
| `details.family` = `"bogus-family"` | same | 500 `model_load_failed` | 500 `server_error` "Internal error" | 500 `model_load_failed`, same body |
| removed-family | `GET /api/ps` after the failed request | `llama3.2:1b` still listed | `llama3.2:1b` still listed | `llama3.2:1b` still listed |

The red build's detail is in its server log only,
`[ERROR]  handle_openai_chat_completion: [json.exception.type_error.302] type
must be string, but is null`. On the green build the new guard logs
`[ERROR]  model 'gemma4-it:e4b' has a malformed model-list entry:
[json.exception.type_error.302] type must be string, but is null`, and no body
carries it.

The missing-family read is **before** anything is unloaded, which is what keeps
`llama3.2:1b` resident on both builds — the #173 resolve-before-evict invariant
holds. The second case (`"bogus-family"`) is read again inside
`get_auto_model()` (`modelFamilyMap.at`), after the old engine is released; on
the green build that call is now guarded too and answers `model_load_failed`
instead of the generic `server_error`. A genuine load failure like that one
does release the serving model, as the existing `load_model` catch already does.

## Conformance rerun

[`conformance.sh`](conformance.sh) `<flm> <outdir> <oflm-next>` is unchanged
from after-180. It was run against the new build.

| Test file | After #180 | After #181 |
| --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 |
| `test_finish_reason.py` | PASS 7 | PASS 7 |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 |

For each file, the sorted per-test PASS/FAIL/SKIP lines differ from the
after-180 logs by nothing.
