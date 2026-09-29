# `flm serve` malformed `name` / `flm_min_version` fails load as 500 `model_load_failed` (#181 audit), on halo

An audit of #188 (the #181 fix) found a second read on the same load path that
still answers a server-side config fault as a 400. This is its red/green, plus a
rerun of OFLM-Next's server-api conformance suite with the same method as
[`oflm-api-conformance-2026-09-28-after-194`](../oflm-api-conformance-2026-09-28-after-194/):
the same `conformance.sh` and `run_spec_tests.py`, the same OFLM-Next commit, and
the same models and ports. Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build (red):** `main` at 95ae7a6,
`fastflowlm-1.0.6`.
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/model-list-download-check.patch`,
`fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` (the model left loaded) and `gemma4-it:e4b` (the
malformed entry the request names; its files were already on disk, which the
`missing-min-version` case needs).

`pgrep -a flm` was empty before and after every run. `lemond` had no model
loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was left
running and never touched.

## The bug

After #188, `ensure_model_loaded` refuses a malformed `details.family` before
anything is unloaded. The check right after it,

```cpp
if (downloader.is_model_downloaded(ensure_tag) == ModelDownloader::ModelStatus::Incompatible) {
```

(from #173's `model-identity.patch`) is outside any try, and
`is_model_downloaded()` reads the model-list entry too:
`check_model_compatibility()` calls `get_model_path()`, which does
`std::string model_name = model_info["name"];`, and then reads
`std::string flm_min_version = model_info["flm_min_version"];`. A missing
field throws `[json.exception.type_error.302] type must be string, but is
null`, and the handler's outer catch answers any `json::exception` 400
`invalid_request_error` "Invalid request".

A missing `name` reaches the throw whether or not the model is downloaded:
`get_missing_files()` swallows its own exception for the same read and returns an
empty list, so `config.json` looks present. This also means #175's claim that a
malformed model path entry fails the load as 500 never held for `name`: this
check runs before the #175 try.

The fix wraps that one call in a try that logs and returns
`ModelLoad::LoadFailed`, still before `publish_serving_chat_tag("")` and the
engine reset, so the served model and the published `/api/ps` snapshot are left
alone.

## Red/green

[`probes.sh`](probes.sh) `<flm> <outdir> <base|new>` copies the shipped
`model_list.json`, removes one field from the `gemma4-it:e4b` entry, points
`flm serve` at it with `FLM_CONFIG_PATH`, serves `llama3.2:1b` on port 58601, and
sends one `/v1/chat/completions` request naming `gemma4-it:e4b`, checking
`GET /api/ps` before and after. The probe and server logs are not committed; rerun `probes.sh`.

| Case | Expected | Red build | Green build | `llama3.2:1b` listed after |
| --- | --- | --- | --- | --- |
| `name` removed | 500 `model_load_failed` | **400** `Invalid request` | 500 `model_load_failed` | yes, both builds |
| `flm_min_version` removed | 500 `model_load_failed` | **400** `Invalid request` | 500 `model_load_failed` | yes, both builds |
| `details.family` removed (#188 regression) | 500 `model_load_failed` | 500 `model_load_failed` | 500 `model_load_failed` | yes, both builds |

The red build logs `[ERROR]  handle_openai_chat_completion:
[json.exception.type_error.302] type must be string, but is null` for both new
cases. The green build logs `[ERROR]  model 'gemma4-it:e4b' could not be
checked: [json.exception.type_error.302] type must be string, but is null`.

The oracle is sensitive to the bug: `probes.sh` in `new` mode against the red
build fails exactly `missing-name/status` and `missing-min-version/status`
(got HTTP 400), 7 passed, 2 failed.

A corrupt local `config.json` (a `json::parse_error` from the same call) is
caught by the same try but was not measured: probing it would mean corrupting a
real model directory.

## Conformance rerun

[`conformance.sh`](conformance.sh) `<flm> <outdir> <oflm-next>` is unchanged
from after-194. It was run against the new build.

| Test file | After #194 | This build |
| --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 |
| `test_finish_reason.py` | PASS 7 | PASS 7 |
| `test_request_validation.py` (chat server) | PASS 15 | PASS 15 |
| `test_request_validation.py` (embed server) | PASS 14 | PASS 14 |
| `test_embed_task_prompt.py` | PASS 3 | PASS 3 |

For each file, the sorted per-test PASS/FAIL/SKIP lines differ from the
after-194 logs by nothing.
