# TheRock ROCm — Phase 0 Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a documented, GPU-validated A/B benchmark of **Vulkan vs up-to-date TheRock ROCm** for llama.cpp (and, if cheap, stable-diffusion.cpp) on Strix Halo-class hardware, so the go/no-go on vendoring TheRock is decided by data — not the premise that "newer ROCm must be better."

**Architecture:** Reuse the repo's existing `pkgs/benchmark-go` harness and `llama-bench` for measurement; get a TheRock-ROCm backend for the eval via the community flakes as a **throwaway bridge** (no in-repo vendoring commitment). Hold the kernel constant at a known-good gfx1151 version. Two tracks: a gfx1150 bring-up/methodology track runnable now, and the decisive gfx1151 track gated on the incoming hardware.

**Tech Stack:** Nix flakes, `llama-bench` (from `llama-cpp-vulkan` / TheRock llama), `pkgs/benchmark-go` (`.#benchmark`), `amdgpu_top` / `rocminfo` for GPU-utilisation validation, `demyanrogozhin/nix-llama-rocm` + `hellas-ai/nix-strix-halo` as build cookbooks.

**Spec:** `docs/superpowers/specs/2026-07-21-therock-rocm-design.md` (Phase 0 section).

---

## Notes for the executor

- This is an **evaluation spike**, not feature code. "Tests" here are **validity gates**: every ROCm/Vulkan number is worthless unless you prove the GPU (not CPU) actually ran the work. The repo's harness already has a silent-CPU-fallback guardrail (`pkgs/benchmark-go/internal/preflight`) — use it, and cross-check with `amdgpu_top`.
- **Do not add community flakes as permanent inputs to this repo's `flake.nix`.** Build them out-of-tree via `nix build github:...#attr` or a scratch flake under the scratchpad. The repo's `flake.lock` stays clean until (and unless) the go decision is "vendor."
- Record every number in `docs/therock-eval-results.md` (created in Task 1). Commit results as you go.
- Hold the model files constant across backends (same GGUF, same quant) or the A/B is meaningless.

---

## Task 1: Lock the Vulkan baseline on gfx1150 + create the results doc

**Files:**
- Create: `docs/therock-eval-results.md`

- [ ] **Step 1: Build the Vulkan llama-bench and confirm the GPU is visible**

Run:
```bash
cd ~/git/noamsto/nix-amd-ai-worktrees/feat-therock-rocm
VULKAN_LLAMA=$(nix build --no-link --print-out-paths .#llama-cpp-vulkan)
"$VULKAN_LLAMA/bin/llama-bench" --help >/dev/null && echo "llama-bench OK"
rocminfo 2>/dev/null | grep -E 'Name: *gfx' | head -1   # expect gfx1150 on this host
```
Expected: `llama-bench OK` and a `gfx1150` line.

- [ ] **Step 2: Run the Vulkan baseline on the two README models**

Pick a model already in the HF cache (reuse the repo's benchmark model set). Run, for each model GGUF path `$M`:
```bash
"$VULKAN_LLAMA/bin/llama-bench" -m "$M" -ngl 999 -p 256 -n 128 -r 3 -o md
```
Expected: a markdown table with non-trivial `pp`/`tg` t/s. Capture the exact numbers.

- [ ] **Step 3: Validity gate — prove Vulkan used the GPU**

In a second shell during the run:
```bash
# NOTE: `-d` is a one-shot device-info dump, NOT sampling. For a busy% time series use JSON sampling:
# amdgpu_top -J -n <iters> -s <ms>  and read devices[0].gpu_activity.GFX
amdgpu_top -J -n 20 -s 150 2>/dev/null | jq '.devices[0].gpu_activity.GFX'   # GPU busy % should climb well above idle
```
Expected: GPU utilisation rises during the bench (not ~0 with CPU pegged). If the GPU stays idle, the run is invalid — stop and fix `-ngl`/device selection before recording.

- [ ] **Step 4: Record baseline + methodology**

Create `docs/therock-eval-results.md` with: host arch (gfx1150), kernel version (`uname -r`), llama.cpp build number, exact model files + quant, the Vulkan `pp`/`tg` numbers, and the GPU-utilisation evidence. This is the fixed "A" side of every later A/B.

- [ ] **Step 5: Commit**

```bash
git add docs/therock-eval-results.md
git commit -m "docs(eval): lock gfx1150 Vulkan llama.cpp baseline + methodology"
```

---

## Task 2: Cheap preliminary probe — TheRock ROCm *runtime* under the existing stack (gfx1150)

Goal: a fast, zero-build signal for whether the *newer ROCm runtime* moves llama.cpp perf on gfx1150, before investing in a faithful TheRock build. **Caveat to record loudly:** this runs the *nixpkgs-compiled* `llama-server` on the *TheRock ROCm runtime* (same sonames, shadowed via `LD_LIBRARY_PATH`) — it is an ABI-mixed probe, not a faithful "TheRock-built llama.cpp" test. Treat it as directional only.

**Files:** none in-repo (scratch only).

- [ ] **Step 1: Obtain the TheRock gfx1150 runtime libs**

Reuse the SDK tarball lemonade already knows how to fetch (`therock-dist-linux-gfx1150-*`), or the copy under a lemonade cache if present. Unpack to a scratch dir `$THEROCK/lib`. Confirm it carries `libamdhip64.so.7`, `librocblas.so.5`, `libhipblas.so.3`.

- [ ] **Step 2: Run llama-bench with the TheRock runtime shadowing the nix ROCm libs**

Build the nix ROCm llama-bench, then run it with TheRock libs + `libatomic` (the #57 dep) prepended:
```bash
ROCM_LLAMA=$(nix build --no-link --print-out-paths .#llama-cpp-rocm)
LIBATOMIC=$(dirname $(nix eval --raw nixpkgs#gcc.cc.lib)/lib/libatomic.so.1 2>/dev/null || echo /nix/store)  # resolve libatomic dir
LD_LIBRARY_PATH="$THEROCK/lib:$LIBATOMIC" "$ROCM_LLAMA/bin/llama-bench" -m "$M" -ngl 999 -p 256 -n 128 -r 3 -o md
```
Expected: it runs (no exit 127 — libatomic present) and reports `pp`/`tg`. If it faults/crashes, record that as a signal (ABI mismatch between nix-ggml-hip and TheRock runtime) and move to the faithful build in Task 3.

- [ ] **Step 3: Validity gate + record**

Confirm GPU used (`amdgpu_top`). Append to `docs/therock-eval-results.md` under a clearly-labelled "PRELIMINARY / ABI-mixed probe (directional only)" heading, next to the Vulkan baseline.

- [ ] **Step 4: Commit**

```bash
git add docs/therock-eval-results.md
git commit -m "docs(eval): preliminary ABI-mixed TheRock-runtime probe on gfx1150"
```

---

## Task 3: Faithful TheRock-built llama.cpp for gfx1150 (the real bring-up + B3 de-risk)

Goal: build llama.cpp actually compiled against the TheRock SDK for gfx1150, using `demyanrogozhin/nix-llama-rocm` as the cookbook. This is the spike that answers spec open-question B3 (does an in-sandbox `hipcc` + bitcode path work).

**Files:**
- Create: `<scratchpad>/therock-eval/flake.nix` (throwaway; NOT in the repo)
- Create: `<scratchpad>/therock-eval/rocm-sources.json` (adds a `gfx1150` pin)

- [ ] **Step 1: Find the TheRock gfx1150 nightly tarball URL + hash**

```bash
# demyanrogozhin's update script shows the bucket + naming; adapt for gfx1150
gh api repos/demyanrogozhin/nix-llama-rocm/contents/update-rocm.py --jq '.content' | base64 -d | grep -iE 'therock|s3|gfx|url' | head
# then resolve the gfx1150 asset:
nix store prefetch-file --json "https://therock-nightly-tarball.s3.amazonaws.com/therock-dist-linux-gfx1150-<VER>.tar.gz" | jq '{hash,storePath}'
```
Expected: a valid `sha256` for a `gfx1150` tarball (lemonade already pulled `gfx1150-7.13.0`, so one exists — pin whatever current nightly resolves).

- [ ] **Step 2: Vendor demyanrogozhin's derivations into a scratch flake with a gfx1150 target**

In `<scratchpad>/therock-eval/`, write a flake that (a) takes `demyanrogozhin/nix-llama-rocm` as an input, (b) overrides its `rocm-sources.json` to add the `gfx1150` entry from Step 1, and (c) exposes `llama-cpp-gfx1150`. Crib the exact override from their `pkgs/llamacpp-rocm.nix` + `pkgs/rocm7-bin.nix`.

- [ ] **Step 3: Build it — this is the B3 spike**

```bash
nix build ~/.../scratchpad/therock-eval#llama-cpp-gfx1150 2>&1 | tee build.log
```
Expected: SUCCESS. If it fails on `hipcc`/device-lib/bitcode resolution in the sandbox, capture the exact error — that failure *is* a key Phase-0 finding (it quantifies the vendoring cost). Record it either way.

- [ ] **Step 4: Benchmark the faithful TheRock-built llama vs Vulkan**

```bash
THEROCK_LLAMA=<scratch build out path>
"$THEROCK_LLAMA/bin/llama-bench" -m "$M" -ngl 999 -p 256 -n 128 -r 3 -o md
```
Same models, same flags as Task 1. Validity-gate with `amdgpu_top`.

- [ ] **Step 5: Record the faithful gfx1150 A/B**

Append to `docs/therock-eval-results.md`: faithful TheRock-built numbers vs the Vulkan baseline, the build effort/patches needed (B3 evidence), and whether TheRock changed the gfx1150 verdict.

- [ ] **Step 6: Commit**

```bash
git add docs/therock-eval-results.md
git commit -m "docs(eval): faithful TheRock-built llama.cpp A/B on gfx1150 + B3 spike notes"
```

---

## Task 4: Preliminary decision checkpoint (gfx1150 data)

**Files:**
- Modify: `docs/therock-eval-results.md`

- [ ] **Step 1: Summarise the gfx1150 signal**

Write a "gfx1150 preliminary verdict" section: did faithful TheRock ROCm beat Vulkan on decode/prefill? By how much? How hard was the build (B3)? Note that gfx1150 is *not* decisive (both backends work here; the driver is gfx1151), so this only sizes the effort and gives an early lean.

- [ ] **Step 2: Commit + surface to maintainer**

```bash
git add docs/therock-eval-results.md
git commit -m "docs(eval): gfx1150 preliminary verdict"
```
Then stop and report the gfx1150 numbers + B3 build cost to the maintainer before the gfx1151 hardware work.

---

## Task 5: Decisive gfx1151 protocol (GATED on the incoming Strix Halo)

Do not start until the gfx1151 machine is in hand. This is the run that actually decides.

**METHODOLOGY CORRECTION (from community gfx1151 data — see `docs/therock-eval-results.md` "Community gfx1151 data" section):** the gfx1150 run measured ROCm's *worst* case (short ctx, plain HIP). On gfx1151, ROCm's win is at **long context with a fully-optimized build**. So Task 5 MUST:
- Bench at **long context (8K / 16K / 32K)**, not just pp512/tg128. Report pp and tg at each length — the crossover is the whole point (Vulkan decode collapses ~32 t/s @ 8K while HIP+rocWMMA holds ~51 t/s).
- Build the ROCm/HIP side **fully optimized: rocWMMA ON + Flash-Attention + hipBLASLt** (not plain HIP). Use TheRock ROCm (nixpkgs 7.2.3 faults on gfx1151). Vulkan side keeps `-fa` too.

> **Correction (2026-09-05):** the "nixpkgs ROCm 7.2.3 faults on gfx1151"
> premise in this dated document is false — measured on a Ryzen AI MAX+ 395,
> stock `llama-cpp-rocm` runs there without faulting. See the Correction
> section in `docs/therock-eval-results.md`. Left otherwise unedited as a
> record of what was believed at the time.

- Frame the go/no-go around the **coding-agent (long-context) regime**, which is the actual reason for Strix Halo — not short-context chat.

**Files:**
- Modify: `docs/therock-eval-results.md`
- Modify (only if go): `README.md` (kernel recommendation)

- [ ] **Step 1: Pin the known-good gfx1151 kernel**

Boot a kernel in the validated gfx1151 range (currently ~6.18.6–6.18.14; **avoid 6.19.x** which misIDs gfx1151 as gfx1100). Record `uname -r` and confirm `rocminfo` reports `gfx1151` (not `gfx1100`, and without needing `HSA_OVERRIDE_GFX_VERSION`). Hold this kernel constant for both backends.

- [ ] **Step 2: Vulkan baseline on gfx1151**

Repeat Task 1 steps 2–3 on gfx1151. Record. (This also confirms RADV/Vulkan works on gfx1151, the cheap-path hypothesis.)

- [ ] **Step 3: TheRock-built llama on gfx1151**

Use `demyanrogozhin`/`hellas-ai`'s **gfx1151** target directly (it's their primary target — no gfx1150 hacking needed): `nix build github:demyanrogozhin/nix-llama-rocm#<gfx1151 llama attr>`. Benchmark, validity-gate.

- [ ] **Step 4: (If cheap) sd-cpp Vulkan-vs-ROCm on gfx1151**

Check whether a Vulkan `stable-diffusion.cpp` exists/builds; if so, A/B images-per-second Vulkan-sd vs TheRock-ROCm-sd. This is the likeliest ROCm win.

- [ ] **Step 5: Record the decisive A/B + apply the go/no-go gate**

Append gfx1151 numbers. Apply the spec's decision gate:
- **TheRock clearly wins** on a backend that matters → GO: proceed to the contingent Integration plan (write it next, folding in critic fixes B1/B3/B4/B5).
- **Vulkan wins/ties** → NO-GO: Vulkan-first; keep nixpkgs ROCm as fallback/tooling; shelve the vendor. Document so it isn't re-litigated.

- [ ] **Step 6: Update the gfx1151 kernel recommendation (regardless of go/no-go)**

Add a README note recommending the validated known-good gfx1151 kernel for Strix Halo hosts (a per-host note — do NOT bump the global `>= 6.14` NPU assertion). Commit.

```bash
git add docs/therock-eval-results.md README.md
git commit -m "docs(eval): decisive gfx1151 A/B + verdict; README gfx1151 kernel note"
```

---

## Self-review (done by plan author)

- **Spec coverage:** Phase 0 "what to measure" → Tasks 1–5; "how to get a TheRock backend cheaply" → Tasks 2 (probe) + 3/5 (faithful, via community bridge, no repo input); "kernel controlled variable + deliverable" → Task 5 steps 1 & 6; "decision gate" → Tasks 4 & 5.5; B3 spike → Task 3.3; sd-cpp secondary → Task 5.4. Integration (Phase 1+) is intentionally out of this plan — it's contingent and gets its own plan on GO.
- **No placeholders:** commands are concrete; the two genuinely-unknown values (gfx1150 tarball hash, exact model GGUF paths) are resolved *by an explicit command in-step*, not hand-waved.
- **Consistency:** results doc `docs/therock-eval-results.md` created in Task 1, appended in 2/3/4/5; validity gate (`amdgpu_top`) applied uniformly.
