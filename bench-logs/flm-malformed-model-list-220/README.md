# `LM_Config::_load_json()` throws instead of `exit(1)`: `flm pull` and startup ASR/embed (#220), on halo

`LM_Config::_load_json()` (`src/include/lm_config.hpp`) called `exit(1)` when a
model directory had no `config.json`, so the fault was uncatchable on every path
that parsed a model's config. #204/#205 fixed the `flm serve` request path by
validating a chat entry's `files` before the download check; the exit stayed
reachable through `flm pull` and through the optional `whisper-v3` /
`embed-gemma` loads at `flm serve` startup.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`).
**Base build (red):** the pre-change tree, `fastflowlm-1.0.6` (the same
derivation as the installed `flm`).
**New build (green):** this branch, adding
`pkgs/fastflowlm/patches/lm-config-throw.patch`, `fastflowlm-1.0.6`.
**Models:** `llama3.2:1b` (the chat model left serving) symlinked into a scratch
`FLM_MODEL_PATH`; `gemma4-it:e2b`, `whisper-v3:turbo` and `embed-gemma:300m`
deliberately absent there, so a `files` array that omits `config.json` really
has no `config.json` on disk.

`pgrep -x flm` was empty (`lemond`'s `/api/v1/health` returned
`all_models_loaded: []`) before every server start.

## The bug

`get_missing_files()` only checks the files an entry lists, so an entry whose
`files` omits `config.json` is treated as having it:
`is_config_file_missing` is false and the code proceeds to
`check_model_compatibility()` → `from_pretrained()` → `_load_json()`, which
found no file and called `exit(1)`. No C++ `try` can catch that:

- `flm pull gemma4-it:e2b` (`ModelDownloader::pull_model` → `is_model_downloaded`)
  died inside the function that the CLI already wrapped in a catch — the catch
  never ran.
- `flm serve -a 1` / `-e 1` died in the `RestHandler` constructor while loading
  the optional side model, before the chat model was even loaded.

## The fix

`lm-config-throw.patch`:

- `_load_json()` throws `std::runtime_error` instead of exiting.
- `ensure_model_loaded` keeps #219's 500 `model_load_failed` handling
  (`is_model_downloaded` is wrapped in a try, both the pre-evict check and the
  post-`get_auto_model` one).
- `ModelDownloader::pull_model` already catches `std::exception`, so the throw
  becomes a clean CLI error and `flm pull` exits 1.
- `ensure_asr_model_loaded` / `ensure_embed_model_loaded` wrap the whole
  optional load (download check, family lookup, `load_model`) in a try; on a
  throw they log the fault, set `asr`/`embed` false and return, so `flm serve`
  keeps serving chat models. The old `exit(EXIT_FAILURE)` in those two
  `load_model` catches is changed to the same log-and-skip for a coherent
  policy.

## Red/green

[`probes.sh`](probes.sh) `<flm> <outdir> <base|new>` copies the shipped
`model_list.json`, points `FLM_CONFIG_PATH` at it, points `FLM_MODEL_PATH` at a
scratch models dir with only `llama3.2:1b` symlinked in, and runs three cases:
`pull` (`flm pull gemma4-it:e2b`), `serve-asr` (`flm serve llama3.2:1b -a 1`)
and `serve-embed` (`-e 1`), each with the named entry's `files` omitting
`config.json`. `base` expects the raw exit; `new` expects the handled outcome.
Set `XRT_LIB_DIR` to the `xrt-combined` lib dir when running the unwrapped
build (the wrapped `flm` sets the equivalent `LD_LIBRARY_PATH` itself).

| Case | Red build | Green build |
| --- | --- | --- |
| `pull` | exits 1: `Failed to open file: …/Gemma4-E2B-IT-NPU2`, no `Failed to pull model` | exits 1 cleanly: `[ERROR] Exception during download: config.json is missing or unreadable in …` then `[ERROR] Failed to pull model: gemma4-it:e2b` |
| `serve-asr` | server exits before ready: `Failed to open file: …/Whisper-V3-Turbo-NPU2` | server ready, `[ERROR] Failed to load ASR model: …; serving without ASR`, `llama3.2:1b` in `/api/ps`, chat 200 |
| `serve-embed` | server exits before ready: `Failed to open file: …/Embedding-Gemma-300M-NPU2` | server ready, `[ERROR] Failed to load embedding model: …; serving without embeddings`, `llama3.2:1b` in `/api/ps`, chat 200 |

Runs: `base` 3 passed / 0 failed; `new` 3 passed / 0 failed. The probe and server
logs are not committed; rerun `probes.sh`.

### Serve request path (no regression)

`bench-logs/flm-malformed-model-list-204-205/probes.sh` `new` mode against the
green build is **21 passed / 0 failed**: the `files-without-config` case still
answers 500 `model_load_failed` with `llama3.2:1b` left loaded, and its red
behaviour is recorded in that directory's README.

## Consumer map

`_load_json()` is called from the two `from_pretrained` implementations
(`lm_config.hpp:73`, `:209`), reached through `is_model_downloaded` →
`check_model_compatibility`, and directly by `AutoModel::_shared_load_model`,
`AutoEmbeddingModel::_shared_load_model`, `Qwen3_5_Omni::load_model` and
`Whisper::load_model`. Every `is_model_downloaded` call site is either inside a
`try` after this patch (`pull_model`, the two startup loads, both
`ensure_model_loaded` checks) or inside `main`'s outer `try` around the whole
command dispatch (`flm check`, `flm list`, `flm run`). See the PR body for the
full table.

## Repro without hardware

`nix build .#fastflowlm` builds the package; the `flm pull` case needs no NPU,
but the status codes and the "still serving" guarantee need the NPU and the
models above.
