# Strix Halo (gfx1151) bring-up checklist

Everything in this repo that is blocked on Halo hardware, ordered so each step
unblocks the next.

**Status (2026-09-06): the box exists, Phases 0-2 are done, and #105 is
diagnosed — Phase 3 is unblocked for Vulkan and CPU, not for ROCm.** The
misbehaviour reported in #105 is not the kernel/firmware pair corrupting
everything: on this host `llamacpp:rocm` returns garbage (perplexity 1334) while
Vulkan (6.8067) and CPU (6.8056) are correct on that same kernel 7.2.2 and
linux-firmware 20260810. See [rocm-gfx1151-numerics.md](rocm-gfx1151-numerics.md).

So a Vulkan or CPU number measured today is trustworthy and need not be thrown
away. **Any ROCm number is not** — which lands directly on #61, whose whole point
is a ROCm-vs-Vulkan A/B. Establish ROCm's *correctness* first (nixpkgs ROCm is
broken here; TheRock may not be) or #61 measures the speed of a wrong answer.

The point of the ordering is that **#61's decisive long-context A/B is the
expensive one**, and it is worthless if the GTT ceiling or the kernel is wrong.
Phases 0-2 are cheap and make the phase-3 numbers trustworthy.

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

- [x] `rocminfo` reports `gfx1151`, not `gfx1100`. Confirmed: `gfx1151` and
      `amdgcn-amd-amdhsa--gfx1151`. NPU is `rev 0x11` (npu5, as predicted), fw
      `1.1.2.65`. IOMMU on, group 34.
- [ ] Kernel window. The original entry named ~6.18.6-6.18.14 and said to avoid
      6.19.x, which misidentifies gfx1151 as gfx1100. **This host runs 7.2.2**,
      far outside that window, and `rocminfo` identifies the arch correctly — so
      the 6.19.x misidentification bug is not present here and that window is
      stale rather than violated. The live kernel question is #105, not this one.

## Phase 1 — GTT ceiling (#42)

@expelledboy measured this on his 128 GB Halo and #96 folds it into the README.
This is the confirmation run on our own box, plus the one question he could not
answer.

```bash
# with hardware.amd-npu.gpuMemory.ttmSizeGiB = 96
cat /sys/class/drm/card1/device/mem_info_gtt_total   # expect 103079215104
```

- [x] `mem_info_gtt_total` == `ttmSizeGiB × 262144 × 4096` exactly. Measured:
      `ttmSizeGiB = 104` gives `111669149696`, which is `104 × 262144 × 4096`.
      Reproduces @expelledboy's result on our own box.
- [x] ROCm agrees. `llama-bench` on the HIP backend reports `Total VRAM: 106496
      MiB`, and a vLLM run profiled **35.8 GiB** of KV cache out of that pool,
      so the headroom is usable and not just advertised.
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

- [x] One successful completion end-to-end. Done 2026-09-05, though not by the
      route above: `enableVllm` is off on this host, so the bundle was built
      directly for `gpuTarget = "gfx1151"` and `vllm-server` run against
      `facebook/opt-125m`. `Application startup complete`, coherent completion
      returned. torch reports `gfx1151` / ROCm 7.15.0a and executed an fp16
      2048x2048 matmul whose mean matches the analytic value, so the kernel
      computed rather than merely not crashing.
      **It did not work as packaged** — `torch/lib/libaotriton_v2.so` needs a
      plain `liblzma.so.5` that the bundle only ships renamed, so `import torch`
      died. Fixed in #114; without that the caveat below could not have been
      closed at all.
- [ ] Then a 9B (`Qwen3.5-9B-FP16-vLLM`) to prove it isn't only toy-sized.
      ~18 GB pull, not yet done.

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

**This does not need TheRock.** The earlier assumption was that an optimized
gfx1151 ROCm build required vendoring TheRock, because nixpkgs 7.2.3 was
believed to fault on gfx1151. It does not — measured 2026-09-05, see the
Correction in `docs/therock-eval-results.md`. `rocmPackages.rocwmma` is in
nixpkgs at the same 7.2.3, so the rocWMMA + FA build is reachable as an override
on the existing `llama-cpp-rocm`. Try that before reopening vendoring: the
gfx1150 A/B already showed newer ROCm losing, and nixpkgs-unstable is also at
7.2.3, so vendoring is the only route to anything newer and costs a 16 GB fetch
at ~350 KB/s plus four undocumented NixOS build fixes.

**Second candidate that could flip the gate.** A community ROCm fork
(`halo-box/strix-llama.cpp`) claims large MoE prefill gains on gfx1151. Treat as
unreplicated: it has no releases, its own README documents a gfx1151 HIP
async-execution correctness bug (perplexity ~88 vs ~9.4 on batched inference,
worked around with `HIP_LAUNCH_BLOCKING=1` at a performance cost) and names
Vulkan the default recommendation, and a sibling project in the same community
retracted a 25% pp claim that turned out to be a work-skipping bug on q4_K/q5_K
MoE. Its numbers are also on ROCm 7.14, which nixpkgs does not have. The bar for
it to matter here: beat Vulkan on **decode at >=32K depth with perplexity
checked**, not beat ROCm master on prefill.

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
### Settled: NPU contexts are not column-exclusive

#79 hypothesised that two NPU models can't co-exist because each FLM context
requests all 8 columns. **That is wrong** — measured twice:

- Halo (rev 0x11 / npu5), FLM 0.9.43: three separate `flm serve` processes
  loaded and answered concurrently (@expelledboy).
- Strix Point (rev 0x10 / npu4), FLM 1.0.3: `--asr 1 --embed 1` on one serve —
  #655's exact trigger — loaded Whisper + Embedding-Gemma + Llama-3.2-1B and
  served clean.

`flm validate` printing "8 columns" describes the array, not a claim on it.
Don't re-test this; the open question is what changed after FLM 0.9.44 and
whether it is gated on the `npu6` device profile:

| rev | profile | `--asr 1 --embed 1` |
|---|---|---|
| 0x10 | npu4 (Strix Point) | works on 1.0.3 |
| 0x11 | npu5 (Halo) | works on 0.9.43; **1.0.3 pending** |
| 0x20 | npu6 (Krackan) | broken from 0.9.45 |

- [ ] Fill the npu5-on-1.0.3 cell. If it passes, [ROCm/FastFlowLM#655](https://github.com/ROCm/FastFlowLM/issues/655)
      is an npu6-profile bug; if it fails, the regression isn't Krackan-specific
      and npu4 is the outlier. Test Llama-3.2-1B first — it's untouched by the
      Q4_1→Q4_K re-quant, so a load failure can't be confused with a weights
      problem.
