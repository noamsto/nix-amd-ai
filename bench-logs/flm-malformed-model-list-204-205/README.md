# `flm serve` malformed `model_list.json` entry: no size variants and no `files` fail the load 500 (#204, #205), on halo

Two more `ensure_model_loaded` paths broke the #181 contract (a malformed
`model_list.json` entry is a server-side config fault: the load must fail as
HTTP 500 `model_load_failed` and must not evict the serving model). This is
their red/green through `flm serve`.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`).
**Base build (red):** the pre-change tree, `fastflowlm-1.0.6` (the same
derivation as the installed `flm`).
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/model-list-entry-validation.patch`,
`fastflowlm-1.0.6`.
**Models:** `llama3.2:1b` (the model left loaded) and `gemma4-it:e4b` /
`gemma4-it:e2b` (the malformed entries; `e2b` is deliberately not downloaded,
which the #204 mechanism needs).

`pgrep -a flm` was empty before and after every run. `lemond` had no model
loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was left
running and never touched.

## The bugs

- **#205 — a bare tag with no size variants.** `ensure_model_loaded` calls
  `supported_models.rectify_model_tag(ensure_tag)` at the top, outside any try.
  For a bare tag (no `:size`), `rectify_model_tag()` does
  `this->config["models"][model_type].begin().key()`:
  - an empty-object size map dereferences `end()` — undefined behavior, the
    server dies;
  - a non-object size map makes `key()` throw
    `[json.exception.invalid_iterator.207] cannot use key() for non-object
    iterators`, which the handler answers 400 `invalid_request_error`.

- **#204 — an entry with no `files` for a model not on disk.**
  `ModelDownloader::get_missing_files()` reads `model_info["files"]` inside a
  catch-all try and swallows the `json::type_error`, returning an empty list —
  so `config.json` is treated as present. `check_model_compatibility()` then
  calls `LM_Config::from_pretrained()` → `_load_json()`, which finds no
  `config.json` and calls `exit(1)`. No C++ try can catch that; the request
  never gets an answer.

## The fix

`model-list-entry-validation.patch`:

- `rectify_model_tag()` no longer reads `begin().key()` blindly: a missing,
  non-object or empty size map now throws `std::runtime_error`. The
  `ensure_model_loaded` call site wraps it in a try and returns
  `ModelLoad::LoadFailed` (#205).
- The selected chat entry is validated up front, in the existing try that
  reads `details.family` and before anything is unloaded:
  `files` must be a non-empty array of strings that lists `config.json`.
  Otherwise the same catch returns `ModelLoad::LoadFailed` (#204). The
  non-chat families (`whisper-v3`, `embed-gemma`) are refused just below and
  are not validated here.

Both failures now answer 500 `model_load_failed` and leave `llama3.2:1b`
loaded.

## Red/green

[`probes.sh`](probes.sh) `<flm> <outdir> <base|new>` copies the shipped
`model_list.json`, mutates the `gemma4-it` map, points `flm serve` at it with
`FLM_CONFIG_PATH`, serves `llama3.2:1b` on port 58601, sends one
`/v1/chat/completions` request naming the broken entry, and checks `GET
/api/ps` before and after. The probe and server logs are not committed; rerun
`probes.sh`.

`new` mode expects 500 `model_load_failed` and `llama3.2:1b` still listed.

| Case | Request | Expected | Red build | Green build | `llama3.2:1b` listed after |
| --- | --- | --- | --- | --- | --- |
| `empty-size-map` (`models["gemma4-it"] = {}`) | `gemma4-it` | 500 `model_load_failed` | **server died** (HTTP 000) | 500 `model_load_failed` | yes |
| `array-size-map` (size map replaced by a one-element array) | `gemma4-it` | 500 `model_load_failed` | **400** `Invalid request` | 500 `model_load_failed` | yes |
| `missing-files` (`e2b` without `files`) | `gemma4-it:e2b` | 500 `model_load_failed` | **no answer**, 30s timeout (HTTP 000) | 500 `model_load_failed` | yes |
| `nonarray-files` (`e2b` with a string `files`) | `gemma4-it:e2b` | 500 `model_load_failed` | **no answer**, 30s timeout (HTTP 000) | 500 `model_load_failed` | yes |

The red build logs `handle_openai_chat_completion:
[json.exception.invalid_iterator.207] cannot use key() for non-object
iterators` for `array-size-map`, and `Error checking missing files:
[json.exception.type_error.302] type must be array, but is null` followed by
`Failed to open file: …/Gemma4-E2B-IT-NPU2` for `missing-files`. The green
build logs `model 'gemma4-it' has a malformed model-list entry: model
'gemma4-it' has no size variants` and `model 'gemma4-it:e2b' has a malformed
model-list entry: missing or empty 'files' array`.

The oracle is sensitive to the bug: `probes.sh` in `new` mode against the red
build fails exactly the four `*/status` checks plus
`empty-size-map/not-evicted` (7 passed, 5 failed); against the green build it
is 12 passed, 0 failed.

## Consumer regression

The #181 audit probe
([`../oflm-api-conformance-2026-09-28-after-181-audit/probes.sh`](../oflm-api-conformance-2026-09-28-after-181-audit/probes.sh))
exercises the same load path with `name`, `flm_min_version` and
`details.family` removed from a chat entry. Run against the green build
(`new` mode) it is 9 passed, 0 failed — the new validation does not disturb
the existing malformed-entry handling.

## Repro without hardware

`nix build .#fastflowlm` builds the package; the four malformed entries can
also be reasoned about from the diff, but the status codes and the
"still serving" guarantee need the NPU and the two models above.
