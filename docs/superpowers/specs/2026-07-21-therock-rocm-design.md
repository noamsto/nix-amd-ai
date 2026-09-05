# TheRock ROCm — evaluate, then (maybe) integrate

**Status:** approved design (evaluation-first), pre-plan
**Date:** 2026-07-21
**Goal:** the best inference experience on Strix Halo (gfx1151). Determine *with data* whether up-to-date ROCm (via AMD "TheRock") beats the flake's current Vulkan path — and only vendor TheRock if it earns its keep.

## Why this is evaluation-first (not integrate-first)

The flake's own README benchmarks (gfx1150) recommend **Vulkan** for general LLM inference: Vulkan wins decode at every size tested (+26% on Gemma-26B tg128) and ties/wins prefill; ROCm is "kept as a fallback and for ecosystem tooling." whisper already runs Vulkan; RADV/Vulkan is arch-agnostic and works on gfx1151.

**But that data is Vulkan vs *nixpkgs ROCm 7.2.3*** — the old runtime with known gfx1151 VRAM faults.

> **Correction (2026-09-05):** the "nixpkgs ROCm 7.2.3 faults on gfx1151"
> premise in this dated document is false — measured on a Ryzen AI MAX+ 395,
> stock `llama-cpp-rocm` runs there without faulting. See the Correction
> section in `docs/therock-eval-results.md`. Left otherwise unedited as a
> record of what was believed at the time.
 The open question is whether **up-to-date TheRock ROCm (native gfx1151 kernels)** changes that verdict. Nobody has that A/B. Vendoring a whole per-arch SDK + rebuilding backends is a large, ongoing, solo-maintained cost (see "Integration cost" below); we do not pay it on an unmeasured premise.

So: **measure first (Phase 0). Integrate only if TheRock ROCm meaningfully beats Vulkan on the backend that matters.**

## Hard constraint (verified)

TheRock is a **monolithic prebuilt SDK tarball, per gfx arch** (`therock-dist-linux-gfx1151-7.11.0aNNNN.tar.gz`), from a fast-moving nightly S3 bucket. Not shaped like nixpkgs `rocmPackages`. Consequences: no drop-in override; each backend must be **rebuilt against the SDK** (needs the SDK's `hipcc`/clang/comgr **at build time in the sandbox**, not just runtime `.so`s); per-arch builds (gfx1150 + gfx1151). Packaging the SDK's *runtime libs* is easy (`fetchurl` + `autoPatchelfHook`); getting its *compiler toolchain* to run in the nix sandbox is the real risk (Phase-1 spike). Community precedent: `demyanrogozhin/nix-llama-rocm`, `hellas-ai/nix-strix-halo` — both rebuild backends against the SDK.

---

## Phase 0 — Evaluation (the immediate work)

**Deliverable:** a documented A/B benchmark of **Vulkan vs TheRock ROCm** for the candidate backends, on real hardware, using the repo's existing `pkgs/benchmark-go` harness (`.#benchmark`). Output feeds the go/no-go decision below.

### What to measure
- **llama.cpp**: decode (tg) + prefill (pp) across the README's model sizes (Gemma-26B, Qwen3.5-9B), Vulkan vs TheRock ROCm. Power/thermal if cheap (ryzenadj/amdgpu_top, as the harness already surfaces).
- **stable-diffusion.cpp** (secondary): is there a viable **Vulkan sd-cpp** path at all? If yes, Vulkan-sd vs TheRock-ROCm-sd images/sec. (Image gen is the likeliest place ROCm still wins, since llama already favours Vulkan.)

### Hardware
- **gfx1150 (this P14s, now):** Vulkan vs TheRock-ROCm-7.1x. Informative even though README shows Vulkan beats *old* ROCm here — the question is whether *new* ROCm closes/reverses the gap.
- **gfx1151 (incoming Strix Halo):** the real target. Re-run when hardware lands. This is where old ROCm is broken, so it's the decisive A/B.

### Kernel is a controlled variable (and a deliverable)
The repo's only kernel guidance today is a **`>= 6.14` floor driven by the NPU (`amdxdna`)** (README:114, hard assertion `modules/amd-npu.nix:217`) — there is **no gfx1151-GPU-tuned recommendation**. Real-world Strix Halo guidance clusters at **Linux 6.18.4+** (RDNA3.5 patches merged), with **6.19.x misidentifying gfx1151 as gfx1100** (needs `HSA_OVERRIDE_GFX_VERSION`) — so newer ≠ better. Therefore:
- The A/B must **hold the kernel constant at a known-good gfx1151 version**, or the Vulkan-vs-ROCm result is confounded.
- Phase 0 output includes the **validated known-good gfx1151 kernel** (for both Vulkan and TheRock ROCm), fed back into a **README gfx1151 kernel recommendation** (a per-host note, *not* a global assertion bump — the 6.14 floor stays correct for gfx1150 / Hawk Point).

### How to get a TheRock-ROCm backend *cheaply* for the eval (no vendoring commitment)
Use the community flakes as a **bridge/cookbook**, not a dependency: build a throwaway TheRock-ROCm `llama-server` (and sd `sd-server` if feasible) from `demyanrogozhin/nix-llama-rocm` or `hellas-ai/nix-strix-halo` (adding a gfx1150 target/pin if their set omits it), and point the benchmark harness at it. This avoids paying the vendoring cost before the data justifies it. (The critic explicitly endorses hellas-ai as a legitimate short-term bridge / reference.)

### Decision gate (end of Phase 0)
Split by **context regime** (community gfx1151 data shows the answer flips with context length — short: Vulkan; long/agentic: optimized ROCm+rocWMMA):
- **Long-context (8K–32K+, the coding-agent regime):** if optimized **TheRock ROCm + rocWMMA + FA + hipBLASLt** holds decode where Vulkan collapses (community shows ~51 vs ~32 t/s @ 8K) → **GO** for a per-arch (gfx1151-only) rocWMMA ROCm llama path → Integration (below) + critic fixes.
- **Short-context / image-gen / whisper:** **Vulkan-first** — keep llama-short + whisper on Vulkan, add a Vulkan sd-cpp (independently worth doing now — image-gen isn't long-token-decode), keep nixpkgs ROCm as fallback/tooling.
- The realistic outcome is likely **both**: Vulkan for short-ctx + image-gen, an optimized-ROCm gfx1151 path for long-ctx LLM. gfx1150 stays Vulkan (rocWMMA regressed there). Document the numbers either way.

---

## Integration (Phase 1+) — CONTINGENT on Phase 0

Only if Phase 0 says TheRock wins. Approach: **vendor TheRock in-repo, deliberately pinned, phased by the winning backend first, in a separate hand-gated update lane, with nixpkgs ROCm kept as a live fallback.** Rejected: consuming `hellas-ai` as a runtime flake *input* (couples reproducibility + Cachix to a third party; use as cookbook only).

### The auto-merge safety hole (core maintainability principle)
Today auto-merge is safe because a green build ⇒ a nixpkgs-*vetted* working ROCm. Building against TheRock breaks that proxy: nightlies compile clean and then fault on hardware, and CI has **no gfx1151 GPU**. So the TheRock lane cannot auto-merge; it must be **quarantined** so it can't contaminate the working nixpkgs lane.

### Architecture (contingent)
1. **SDK package** `pkgs/rocm-therock/`: `fetchurl` + `autoPatchelfHook`, parameterised per gfx target; `rocm-sources.json` = `{url,sha256,version}` per arch (`gfx1150`,`gfx1151`). Model on demyanrogozhin's `rocm7-bin.nix`.
2. **Backends rebuilt against the SDK**, winning backend first (per Phase 0). Custom derivation with cmake → SDK; **explicit spike: does autoPatchelf yield a working in-sandbox `hipcc`, and do device-lib/bitcode (`amdgcn`) paths resolve** (B3). Crib patches from the community flakes.
3. **Module rework (NOT "unchanged" — B1).** `modules/amd-npu.nix` hardcodes nixpkgs ROCm in ≥4 places: `ldLibraryPath` (`rocmPackages.clr`), `LEMONADE_GGML_HIP_PATH` (×2), the `llamacpp-rocm` symlink source, and `systemPackages` clr. The lemond service sets a **service-wide `LD_LIBRARY_PATH` with nixpkgs clr 7.2.3**; a TheRock `llama-server` subprocess would inherit it and load the old (faulting) ROCm ahead of its own RPATH — the exact #57 shadowing class. Phase 1 must: make the ROCm provider selectable, key `LD_LIBRARY_PATH` / `LEMONADE_GGML_HIP_PATH` / `systemPackages` clr to the selected provider, and **isolate a TheRock backend from the nixpkgs ROCm libs still used by sd-cpp/whisper in the same service**.
4. **Per-arch + fallback.** Expose per-arch TheRock backends; a **module option selects provider, defaulting to `nixpkgs`** so existing hosts' eval is unchanged (back-compat). Keep nixpkgs `llama-cpp-rocm` alive as fallback — **note: on gfx1151 the nixpkgs fallback is the faulting 7.2.3, so it's a gfx1150-safe fallback only**, and keeping both providers ~doubles CI build + Cachix surface (not free).
5. **#57 interaction:** the `will_install_therock → false` patch (PR #59) stays — it stops lemonade's *runtime* download; our vendored SDK is a *build-time* dep. Complementary.

### Update automation (contingent)
- **Deliberate pins, never weekly-auto.** Pin a chosen TheRock build (release/branch tag if usable — open question; else a hand-picked nightly), bump a few times/quarter.
- **Split lanes with real edits (B4).** There is **no** generic tricky-bump facility — `update.yml` auto-merge is hardcoded to `mtp_override_needs_update != 'true'`. Adding TheRock means concrete edits to `check-updates.sh` (detect TheRock updates) and the auto-merge `if:` (exclude the TheRock lane). Do not describe this as "reusing an existing mechanism."
- **Smoke gate must be real or labelled unenforced (B4).** A "manual checkbox" is enforced by nothing without branch protection + a named required status check. Either stand up a self-hosted gfx1150/gfx1151 runner emitting a required check, **or** downgrade to "maintainer-discipline checklist, unenforced — accepted risk" and say so. No hand-waving.

### License / Cachix (B5 — gate before any public caching)
Before pushing TheRock-derived outputs to public `nix-amd-ai.cachix.org`: **confirm AMD/TheRock redistribution terms permit it** (ROCm is largely MIT/NCSA so likely OK, but bundles may carry closed bits — verify). Quantify added per-arch closure/cache size and CI build-time delta (these outputs are **not** Hydra-cached, unlike today's `pkgs.llama-cpp-rocm`). Option: cache only the `fetchurl` FOD, not the derived toolchain. **License is a hard blocker for public caching; not a blocker for Phase 0 (local).**

---

## Open questions (resolve at the integration gate, not Phase 0)
1. TheRock usable release/branch tags vs curated nightlies (pin discipline).
2. Backend build recipe against the SDK; in-sandbox `hipcc` + bitcode resolution (the B3 spike).
3. Per-arch selection UX (explicit option vs auto-detect); confirmed default = `nixpkgs`.
4. Smoke-test runner: self-hosted GH runner vs unenforced checklist.
5. gfx1150 SDK bundle exact tarball name (lemonade already pulled `gfx1150-7.13.0`, so it exists).
6. AMD redistribution license for public Cachix (B5).

## Out of scope
- Making the TheRock path auto-merge (rejected).
- vLLM / PyTorch / Python-wheel stack.
- Replacing nixpkgs ROCm for anything beyond the named backends.

## Related
- #57 / PR #59 (lemonade runtime TheRock-download fix) — complementary; the `libatomic` shadowing there is the same bug class as B1.
- Memory: incoming-strix-halo-128gb, upstream-versions-to-watch, perf-baselines-gfx1150, bench-ciru-ai (RADV/Vulkan on gfx1151), rocwmma-build-flag (rocWMMA regressed on gfx1150 — re-test per arch), mtp-ab-benchmark (harness methodology).
- Cookbook refs: `demyanrogozhin/nix-llama-rocm`, `hellas-ai/nix-strix-halo`.
