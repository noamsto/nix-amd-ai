# Opt-in GPU memory headroom + performance-tuning docs

**Issue:** [#19](https://github.com/noamsto/nix-amd-ai/issues/19)
**Date:** 2026-05-31
**Status:** Approved, pending implementation plan

## Summary

Add an **opt-in, no-cost** GPU-memory-headroom option to the `hardware.amd-npu`
module, and document two tuning tradeoffs we deliberately do *not* automate. The
guiding principle from the brainstorm: ship only the knobs that are *free*
(change what's addressable, not what's consumed), and *document* the
power-costly CPU knobs for a later A/B rather than forcing them globally.

This is a deliberately narrow slice of the wiki's tuning surface. The
power-costly CPU tuning (governor, C-state floor, THP, `vm.*`) is **out of
scope** and deferred to a measured A/B (see "Deferred" below).

## Scope

Three deliverables, one explicit non-goal.

### 1. `gpuMemory.ttmSizeGiB` / `pagePoolSizeGiB` (code — no-cost, static)

New options under the existing `hardware.amd-npu` namespace. Both default to
`null`, which preserves today's behavior exactly (the module emits nothing).

```nix
hardware.amd-npu.gpuMemory = {
  ttmSizeGiB = mkOption {
    type = types.nullOr types.ints.positive;
    default = null;
    description = ''
      GTT pool ceiling in GiB, emitted as the `ttm` `pages_limit` modprobe
      option. null (default) leaves the kernel default untouched.

      No-op on Strix Point / 64 GB: the default (~27 GB addressable) already
      covers 17-22 GB models. This is the lever a Strix Halo / 128 GB host
      needs to expose its large unified pool for big models. See the README
      "GPU memory headroom" section for recommended Halo values.

      Page count is computed for you: pages = GiB * 262144 (= GiB * 1024^3 / 4096).
    '';
  };

  pagePoolSizeGiB = mkOption {
    type = types.nullOr types.ints.positive;
    default = null;
    description = ''
      Pre-cached GTT pool size in GiB, emitted as the `ttm` `page_pool_size`
      modprobe option. Pages kept warm rather than freed back to the system.
      Must be <= ttmSizeGiB. null (default) leaves the kernel default untouched.
    '';
  };
};
```

**Page-count math (exact integer arithmetic):**

```
pages = GiB * 262144     # = GiB * 1024^3 / 4096  (4096-byte pages)
```

Verified against the issue's worked examples: 120 GiB -> 31457280,
60 GiB -> 15728640.

**Delivery mechanism:** `boot.extraModprobeConfig`, emitting

```
options ttm pages_limit=<pages> page_pool_size=<pages>
```

Chosen over the `ttm.pages_limit=` kernel cmdline param because it matches the
wiki's documented form verbatim (what users cross-reference) and is the form
that applies when `ttm` loads as an amdgpu dependency.

**Assertion:** if `pagePoolSizeGiB != null` then `ttmSizeGiB` must also be set
and `pagePoolSizeGiB <= ttmSizeGiB` (a pool larger than its ceiling is
nonsensical). Define the error out of existence where cheap; assert where not.

### 2. README: GPU memory headroom (doc)

A new section documenting the option and the recommended Strix Halo values.

> **Honesty caveat to bake into the prose:** these Halo numbers are
> wiki/community guidance, **not measured on a Halo host by this flake** (our
> target is the 64 GB Strix Point P14s). Label them as such; do not imply
> validation.

Recommended-values table for a 128 GB Strix Halo:

| Option | Wiki example (128 GB) | Meaning |
|---|---|---|
| `ttmSizeGiB` -> `pages_limit` | 120 | Hard ceiling on the GTT pool; leaves ~8 GiB for the OS/CPU. |
| `pagePoolSizeGiB` -> `page_pool_size` | 60 | Pre-cached pool inside that ceiling. |

Caveats in prose:
- **Leave RAM headroom** — don't set `ttmSizeGiB` to full physical RAM; the
  CPU/OS still need their share. The wiki's 120/128 leaves a margin.
- **No-op on Strix Point / 64 GB** — leave both `null`; the kernel default
  covers our model sizes. The recommendation block is for 128 GB Halo hosts.

### 3. README: tuning tradeoffs we don't automate (doc)

Two subsections capturing verified findings.

**`amd_iommu=off` <-> NPU tradeoff.** Why we keep the IOMMU on: amdxdna binds
the NPU via IOMMU SVA/PASID (`iommu_sva_bind_device`, IOMMU group 25, IOMMU in
Translated mode). `amd_iommu=off` or passthrough mode kills the NPU
(`*ERROR* Can not assign PASID` / `SVA get pasid failed`). The module already
sets `iommu.passthrough=0` for this reason. `amd_iommu=off` is only viable on a
GPU-only host that has given up XDNA.

**CPU performance tuning (not implemented, pending A/B).** Document the
mechanism worked out during the brainstorm:
- No direct CPU-governor -> GPU-clock link; the iGPU has its own clock domain.
- On shared-TDP Strix Point, forcing the CPU governor to `performance` *steals*
  package power from the iGPU on bandwidth-bound decode — a bounded, possibly
  net-negative lever.
- The C-state latency floor (`/dev/cpu_dma_latency`) is the more GPU-relevant
  knob (keeps fabric/memory clocked for bandwidth-bound decode), and the
  cleanest to scope (held fd, auto-released on close).
- Prefill (`pp512`) sees a small CPU benefit — matches the wiki's "+5-8% pp512"
  (a prefill claim, not decode).
- **Conclusion:** not implemented; blocked on an A/B on an idle/AC host with the
  `performance` governor pinned, to confirm whether the wiki's claims reproduce
  on Strix Point.

## Deferred (explicitly NOT in this PR)

- `performanceMode` / governor / C-state-floor *implementation*. Blocked on the
  A/B test result above. Documented in the README so the follow-up isn't lost.
- README perf-baseline refresh (ROCm closed the gap: 15.6/17.0 vs the older
  13.9/17.5). Tracked separately; not part of this change.

## Files touched

- `modules/amd-npu.nix` — new `gpuMemory.*` options + `boot.extraModprobeConfig`
  + assertion.
- `README.md` — "GPU memory headroom" section (option + Halo table) and a
  "tuning tradeoffs we don't automate" subsection (`amd_iommu`, CPU tuning).

## Testing / verification

- `nix flake check` / module evaluates with options unset (no behavior change).
- Evaluate with `ttmSizeGiB = 120; pagePoolSizeGiB = 60;` and confirm the
  generated `boot.extraModprobeConfig` contains
  `options ttm pages_limit=31457280 page_pool_size=15728640`.
- Assertion fires when `pagePoolSizeGiB > ttmSizeGiB` or when `pagePoolSizeGiB`
  is set without `ttmSizeGiB`.
- README renders; tables and caveats present.
