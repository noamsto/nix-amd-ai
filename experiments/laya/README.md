# Laya prototype (throwaway)

Prototype for the typed-decisions exploration (#149). Lives only under
`experiments/laya/` — it is **not a flake output**; nothing under `pkgs/`,
`modules/`, or `flake.nix` references it.

`shell.nix` builds a CPU-only Python (torch, transformers, safetensors,
huggingface-hub, numpy, pyarrow) from the repo's pinned nixpkgs, with Laya
(`NandhaKishorM/laya@v0.3.5`) vendored via `fetchFromGitHub` onto
`PYTHONPATH`. No pip at runtime. Model weights (`convaiinnovations/laya`,
~0.8-1.7 GB per checkpoint) and the `allenai/ai2_arc` parquet files download
into the ambient Hugging Face cache (`$HF_HOME` or `~/.cache/huggingface`) on
first use — nothing large is committed. Results land in
`experiments/laya/results/`, and those *are* committed.

Every printed number is prefixed with a host label —
`<hostname> / <cpu model> / CPU <threads> threads` — read at run time from
`socket.gethostname()`, `/proc/cpuinfo`, and `torch.get_num_threads()`; never
hard-coded.

## Subcommands

```bash
nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py probe"
nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py laya-latency --checkpoint root --n 120"
nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py grade"        # Step 3
nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py baselines"    # Step 3
nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py report"       # Step 3
nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py contention"   # Step 3
```

- `probe` — checks lemonade residency (`GET /api/v1/health`) and whether the
  small candidate (`llama3.2-1b-FLM`) answers a trivial chat request; falls
  back to `Qwen3.5-4B-GGUF` if the FLM probe fails (the NPU may be held by a
  sibling task). Never pulls a model.
- `laya-latency` — loads a Laya checkpoint (`--checkpoint root` or
  `typed-decisions`) and times `agent.predict()` over the first `--n` items
  of the ARC prompt pool (default 120), plus one 10-question batched call.
- `grade`, `baselines`, `report`, `contention` — implemented in Step 3 of
  `docs/superpowers/plans/2026-09-22-typed-decisions-exploration.md`.

All subcommands read/merge/write the same results file,
`experiments/laya/results/halo-2026-09-22.json`.

## Results

Rendered tables: `experiments/laya/results/halo-2026-09-22.md`. Overall
verdict: **KILL** for the I1/I2 arm (Laya AUC 0.5565 < 0.65 floor; warm p50
797.2 ms ≥ 250 ms line, both halo) — see
`docs/research/typed-decisions-local-models.md` §8 for the full breakdown.
