# Strata backend: provisioning and runtime detail

The README ([Opt-in Strata backend](../README.md#opt-in-strata-backend-strix-halo)) has the setup and options. This page holds the longer provisioning, sampling, memory and limits notes. Measurements and the build are in [`bench-logs/qwen38-flash-next-strata-2026-10-06`](../bench-logs/qwen38-flash-next-strata-2026-10-06/README.md), quality in [`bench-logs/qwen38-flash-next-strata-quality-2026-10-07`](../bench-logs/qwen38-flash-next-strata-quality-2026-10-07/README.md) and the soak in [`bench-logs/qwen38-flash-next-strata-soak-2026-10-08`](../bench-logs/qwen38-flash-next-strata-soak-2026-10-08/README.md).

## Model and provisioning

`model` defaults to the Flash-Next GGUF pinned in `pkgs/strata/sources.nix` (`unsloth/Qwen3.8-Flash-Next-GGUF`, quant chosen by `strata.quant`; `UD-IQ4_XS` is the only one packed and benched so far), read from lemond's Hugging Face cache under `lemonade.cacheDir`. It is the same checkpoint a llamacpp `customModels` entry pulls, so the shards are shared rather than downloaded twice. The default is pinned to one snapshot, though, and `lemonade pull` fetches the repository's current one; if the pinned snapshot is missing, `strata-prepare` fails and prints the `hf download --revision …` command that fills it in. Without `cacheDir`, or for a GGUF kept elsewhere, set `model` to the first shard's path.

With only `enable` and a model, the module provisions the rest. `strata.prepare` renders a oneshot `strata-prepare` unit that builds `pack` and the MTP runtime in `/var/lib/strata` with the pinned Strata's own tools, and `vision.mmproj` defaults to a pinned `mmproj-Qwen3.8-Flash-Next-BF16.gguf` fixed-output fetch. Each derived output has a stamp recording the pinned Strata package (its tools and gguf-py) and its Strata/ggml revisions, the model path and the sibling shard sizes: an unchanged run is a no-op, a changed model path rebuilds the pack, and a Strata/ggml revision bump or a different `strata.package` rebuilds both (the pin bump leaves the literal `version` alone, so the stamps key on the pins, not the version). The pack tool is CPU-only and reads the shards in place. The shim refuses a load until both stamps exist, and the unit removes a stamp before rebuilding, so a load that races a rebuild gets a clear message instead of an engine that cannot open its pack.

Setting `pack`, `mtp` and `vision.mmproj` explicitly keeps your own artifacts; the module then renders no unit and passes those paths through as before. `strata.prepare.enable` is `null` (the default: run the unit only when `pack` and `mtp` are at their defaults), `true` (force it on; then `pack`/`mtp` must stay at defaults) or `false` (disable it; then set both paths explicitly). `strata.prepare.user` defaults to `lemonade.user`, so the engine can read the outputs.

## Sampling defaults

`sampling` sets the decoding defaults for requests that send none: strata-server decodes greedily otherwise. The default is Qwen's recommended thinking set (`temperature` 0.6, `top_p` 0.95, `top_k` 20), because strata-server takes one set rather than one per thinking mode and lemond serves the model with thinking on. A request's own fields win, so `temperature: 0` stays greedy. For a non-thinking deployment set `temperature = 0.7; top_p = 0.8; top_k = 20; presence_penalty = 1.5;`; setting every key to `null` restores greedy. Keys merge individually, so `sampling.top_k = 40;` keeps the other defaults.

## First-run cost

The `strata-prepare` pack step is CPU-only. Measured on a Strix Halo (gfx1151) host on 2026-10-08 over the same UD-IQ4_XS shards: `iq_pack.py --compat-bf16` took 8 s wall and about 1.2 GiB peak RSS for a 1.4 GiB pack, reading the three GGUF shards in place. The MTP step is the slow part of the first run: 4.9 GiB of tensors downloaded (SHA-256-checked against the pinned checkpoint revision while upstream still serves it; a fallback to the repository's current files is not hash-checked), then a 0.8 GiB runtime directory. The raw tensors are removed after packing, so any MTP rebuild — a Strata/ggml revision bump or a different `strata.package` — re-downloads them; a model change rebuilds only the pack.

## Memory and behind-lemond limits

**Memory.** About 67 GiB of GTT at 131072 context on a Strix Halo host (see the Strata bench README). lemond counts loaded models per slot, not memory, so it will load Strata next to another large model if a slot is free: keep one LLM slot (`lemonade.settings.max_loaded_models`) or unload the resident model first. If a load fails, lemond evicts every loaded model, pinned ones included, and retries once.

**Limits behind lemond.** Images must be sent as `data:` URLs; file paths, `file://` URLs and http(s) URLs are refused (a request using one fails with a 400), since lemond forwards client requests as-is. Engine arguments set per model through lemond are limited to tuning flags (`--prefill`, `--spec`, `--spec-min-p`, `--mtp-q4`, `--kv`, `--lookup-chain`, `--vram-reserve-mib`).

**Timeout.** The `strata` backend carries its own fixed 1 h readiness timeout, so enabling Strata leaves lemond's `global_timeout` at 0 (no request cutoff) and `global_timeout` no longer changes the strata startup wait. vLLM still raises `global_timeout` to 3600 for its own startup wait.

Unloading the model or stopping lemond ends the engine's whole process group within lemond's stop window.
