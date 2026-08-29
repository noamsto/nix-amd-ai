# Strix Halo (gfx1151) bring-up checklist

Everything in this repo that is blocked on Halo hardware, ordered so each step
unblocks the next. Written before the box was set up; nothing here has been run.

The point of the ordering is that **#61's decisive long-context A/B is the
expensive one**, and it is worthless if the GTT ceiling or the kernel is wrong.
Phases 0–2 are cheap and make the phase-3 numbers trustworthy.

Open issues this closes: #42 (partly — the NPU half landed in #94), #61, #63,
#68.

## Phase 0 — identify the box before changing anything

```bash
# NPU: which device profile did amdxdna bind?
lspci -nn | grep -i 'signal processing'      # expect 1022:17f0, note the rev
cat /sys/class/accel/accel0/device/fw_version
journalctl -k -b | grep -iE 'amdxdna|amdgpu'

# GPU: does ROCm see gfx1151 natively?
rocminfo | grep -i 'gfx\|Marketing'
cat /sys/class/drm/card*/device/mem_info_vram_total
cat /sys/class/drm/card*/device/mem_info_gtt_total

uname -r
```

Record the rev byte. #79 turned on `rev 0x10` (npu4) vs `rev 0x20` (npu6/Krackan)
mapping to different driver profiles, and README line 123 already carries a
"Krackan is untested" caveat. Halo should be npu5.

- [ ] Kernel is in the known-good gfx1151 window (~6.18.6–6.18.14). **Avoid
      6.19.x** — it misidentifies gfx1151 as gfx1100 (#61). If the box ships
      something newer, pin before benchmarking or every number below is suspect.
- [ ] `rocminfo` reports `gfx1151`, not `gfx1100`.

## Phase 1 — GTT ceiling (#42)

@expelledboy measured this on his 128 GB Halo and #96 folds it into the README.
This is the confirmation run on our own box, plus the one question he could not
answer.

```bash
# with hardware.amd-npu.gpuMemory.ttmSizeGiB = 96
cat /sys/class/drm/card1/device/mem_info_gtt_total   # expect 103079215104
```

- [ ] `mem_info_gtt_total` == `ttmSizeGiB × 262144 × 4096` exactly.
- [ ] ROCm agrees (`llama.cpp` HIP backend prints `Total VRAM: 98304 MiB`).
- [ ] **Settle `pagePoolSizeGiB`** — the open question from #42. Drop the line
      entirely, reboot, and re-read `mem_info_gtt_total`. If unchanged, the
      option is decorative and the README should say so instead of hedging on
      three unmeasured sources.
- [ ] Confirm `amdgpu.gttsize` is genuinely unnecessary (it should already be
      unset; just verify nothing else set it).

Do **not** set `amd_iommu=off`. It kills the NPU, and expelledboy showed it
isn't needed for headroom anyway — his host runs `iommu.passthrough=0` and still
loads an 80 GiB model.

## Phase 2 — vLLM gfx1151 has never executed a kernel (#63, #68)

`pkgs/vllm-rocm/sources.nix` says it plainly: packaging is verified, the bundle
unpacks, `vllm-server --help` imports torch — but **no gfx1151 kernel has ever
run**. This is the cheapest high-value result on the list.

```bash
# smallest real model first; Qwen3.5-0.8B-FP16-vLLM exists in the registry
lemonade pull Qwen3.5-0.8B-FP16-vLLM
lemonade run Qwen3.5-0.8B-FP16-vLLM
```

- [ ] One successful completion end-to-end. That alone closes the "never
      executed" caveat and lets the comment in `sources.nix` be rewritten.
- [ ] Then a 9B (`Qwen3.5-9B-FP16-vLLM`) to prove it isn't only toy-sized.

Note the vllm pin is stale and will move once #95 lands and the weekly workflow
picks a tag that actually has gfx1150 **and** gfx1151 builds. Prefer testing
whatever the workflow lands rather than the current pin.

## Phase 3 — the decisive test: ROCm vs Vulkan at long context (#61)

This is the one the issue is actually gated on. The premise to test is **not**
"is ROCm faster" — the gfx1150 answer was no. It is: *does the ordering flip at
long context on gfx1151?* Community data says HIP+rocWMMA+FA holds ~51 t/s at
8K where Vulkan collapses to ~32 t/s.

The repo's harness does the A/B:

```bash
nix run .#benchmark -- -backend rocm   -prompt-tokens 8192 -repeat 5 -no-tui
nix run .#benchmark -- -backend vulkan -prompt-tokens 8192 -repeat 5 -no-tui
```

### ⚠️ Tooling gap to fix first

`-ctx-size` **only reaches `llama-server` in `--mtp-ab` mode.** It is consumed
by `BuildLlamaServerArgs` at `internal/bench/run.go:571`, inside `RunMTPAB`. In
the normal `-backend` path the benchmark drives lemonade's HTTP API and lemond
spawns `llama-server` with whatever the config says — so **you cannot request
8K/16K/32K context on the path this test needs**, and a long `-prompt-tokens`
against a 2048 ctx just truncates.

Two ways out, in preference order:

1. Set it declaratively and leave the harness alone:
   ```nix
   hardware.amd-npu.lemonade.settings.llamacpp.args = "--ctx-size 32768 --flash-attn on";
   ```
2. Or extend `-ctx-size` to apply outside MTP A/B mode.

Either way, **confirm the server actually got the context** (lemond logs the
`llama-server` argv) before trusting a single number. A silently-truncated 8K
run that reports healthy t/s is the failure mode that would make this whole
phase worthless.

### Build the ROCm side properly

The comparison is only fair if ROCm is fully optimized — **rocWMMA ON +
Flash-Attention + hipBLASLt**. Per-arch matters:

| target | rocWMMA |
|---|---|
| gfx1150 | **OFF** — measured net regression, −42% pp4096 |
| gfx1151 | **ON** — this is where the community win comes from |

Do not reuse the gfx1150 rocWMMA conclusion here; different arch, opposite
expected sign.

- [ ] Bench 8K, 16K, 32K — not just pp512/tg128. Short context was already
      answered on gfx1150 and is not the regime that motivates Halo.
- [ ] Capture GPU utilisation evidence alongside, same as the gfx1150 eval did,
      to rule out CPU fallback (`-min-decode-tps` guards the gross case).
- [ ] Log raw output under `bench-logs/` — that's the repo convention.
- [ ] First `sd-cpp` ROCm-vs-Vulkan look on gfx1151 (image-gen), lower priority.

### Decision gate

- **ROCm+rocWMMA clearly wins long context** → vendor a per-arch gfx1151
  optimized-ROCm llama path via TheRock, behind a hand-gated update lane plus a
  hardware smoke test.
- **Vulkan wins or ties even at long context** → Vulkan-first everywhere, keep
  nixpkgs ROCm as fallback/tooling, and **close #61** rather than leaving it
  open indefinitely.

Record whichever it is in `docs/therock-eval-results.md` next to the gfx1150
half so the two arches sit together.

## Phase 4 — NPU cross-check (optional)

#94 has expelledboy's Halo NPU numbers on FLM 0.9.43. The flake is moving to
1.0.3 (#98), which re-quantized Qwen3.5 / Qwen3.6-MoE from Q4_1 to Q4_K.

- [ ] Re-run `flm bench` on 1.0.3 for a Qwen3.5 model and see whether the
      re-quantization moved throughput on Halo. His Llama rows are unaffected.
- [ ] Sanity-check the concurrency result — NPU model + iGPU model at once, the
      claim being the iGPU pays nothing measurable.
- [ ] While here: #79 hypothesised that two NPU models can't co-exist because
      each FLM context requests all 8 columns. Loading two FLM models at once
      on this box would confirm or kill that cheaply, and it's the open question
      on [ROCm/FastFlowLM#655](https://github.com/ROCm/FastFlowLM/issues/655).
