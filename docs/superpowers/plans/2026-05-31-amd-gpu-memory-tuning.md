# GPU Memory Headroom + Tuning Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, no-cost GTT memory-headroom option (`hardware.amd-npu.gpuMemory.{ttmSizeGiB,pagePoolSizeGiB}`) to the module, plus README docs for the `amd_iommu`↔NPU tradeoff and the deferred CPU-tuning A/B.

**Architecture:** Two new nullable options under the existing `hardware.amd-npu` namespace. When set, they emit a single `boot.extraModprobeConfig` line (`options ttm pages_limit=… page_pool_size=…`), with the GiB→page conversion (`× 262144`) done in Nix so callers never compute page counts. Default `null` → module emits nothing → today's behavior is byte-for-byte unchanged. Two assertions keep the inputs coherent. Verification rides the flake's existing `checks.*` `nixosSystem`-eval harness.

**Tech Stack:** Nix / NixOS module system, flake-parts, the flake's `checks` outputs (`nix build .#checks.x86_64-linux.<name>`).

**Spec:** `docs/superpowers/specs/2026-05-31-amd-gpu-memory-tuning-design.md`

---

## File Structure

- `modules/amd-npu.nix` — add `gpuMemory.*` options (in `options.hardware.amd-npu`), the `gttPages` helper (in the top `let`), the two assertions (append to existing `assertions` list), and the `boot.extraModprobeConfig` emission (in `config`). Single file, follows existing style.
- `flake.nix` — add `checks.module-eval-gtt` (positive + negative grep). Follows the existing `module-eval-*` pattern.
- `README.md` — add a "GPU memory headroom" section and a "Tuning tradeoffs we don't automate" subsection.

---

## Task 1: Failing check for the GTT modprobe emission

**Files:**
- Modify: `flake.nix` (add a new entry to the `checks` attrset, after `module-eval-vulkan-true`, around `flake.nix:194`)

- [ ] **Step 1: Write the failing check**

Add this entry inside the `checks = { … };` attrset in `flake.nix`, immediately after the `module-eval-vulkan-true` block (before the closing `};` of `checks`):

```nix
          # GTT headroom: configured system emits the ttm modprobe line with
          # GiB→page conversion; default system emits no ttm line.
          module-eval-gtt = let
            mkSys = extra: (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                inputs.self.nixosModules.default
                {
                  boot.loader.grub.enable = false;
                  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
                  hardware.amd-npu = {
                    enable = true;
                    lemonade.user = "testuser";
                  } // extra;
                  users.users.testuser = {
                    isNormalUser = true;
                    extraGroups = ["video" "render"];
                  };
                }
              ];
            }).config.boot.extraModprobeConfig;
            configured = mkSys {
              gpuMemory = { ttmSizeGiB = 120; pagePoolSizeGiB = 60; };
            };
            default = mkSys {};
          in
            pkgs.runCommand "module-eval-gtt" {
              inherit configured default;
            } ''
              echo "$configured" | grep -F 'options ttm pages_limit=31457280 page_pool_size=15728640'
              echo "$default" | grep -vq 'pages_limit' || { echo "default must not set pages_limit"; exit 1; }
              touch $out
            '';
```

- [ ] **Step 2: Run the check to verify it fails**

Run: `nix build .#checks.x86_64-linux.module-eval-gtt -L`
Expected: FAIL during evaluation — `error: The option 'hardware.amd-npu.gpuMemory' does not exist.` (the option isn't defined yet).

- [ ] **Step 3: Commit the failing check**

```bash
git add flake.nix
git commit -m "test(module): add failing check for gpuMemory GTT emission (#19)"
```

---

## Task 2: Implement the `gpuMemory` options

**Files:**
- Modify: `modules/amd-npu.nix` — top `let` (around `:6-25`), `options.hardware.amd-npu` (around `:27-90`), `assertions` (around `:93-98`), `config` body (after the `boot.kernelParams`/`boot.kernelModules` lines, around `:101`).

- [ ] **Step 1: Add the `gttPages` helper to the top `let`**

In `modules/amd-npu.nix`, add this binding to the existing `let` block (e.g. right after the `cfg = config.hardware.amd-npu;` line at `:8`):

```nix
  # 4096-byte pages: pages = GiB * 1024^3 / 4096 = GiB * 262144.
  gttPages = gib: gib * 262144;
```

- [ ] **Step 2: Add the `gpuMemory` options**

Insert this option block inside `options.hardware.amd-npu = { … };`, after the `lemonade = { … };` block and before the closing `};` (around `:89`):

```nix
    gpuMemory = {
      ttmSizeGiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          GTT pool ceiling in GiB, emitted as the `ttm` `pages_limit` modprobe
          option (page count is computed for you: GiB * 262144).

          null (default) leaves the kernel default untouched. No-op on Strix
          Point / 64 GB — the default (~27 GB addressable) already covers
          17-22 GB models. This is the lever a Strix Halo / 128 GB host needs
          to expose its large unified pool. See the README "GPU memory
          headroom" section for recommended Halo values.
        '';
      };

      pagePoolSizeGiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          Pre-cached GTT pool size in GiB, emitted as the `ttm` `page_pool_size`
          modprobe option (pages kept warm rather than freed back). Requires
          ttmSizeGiB and must be <= it. null (default) leaves the kernel
          default untouched.
        '';
      };
    };
```

- [ ] **Step 3: Add the assertions**

Append these two entries to the existing `assertions = [ … ];` list in `config` (after the kernel-version assertion, around `:97`):

```nix
      {
        assertion = cfg.gpuMemory.pagePoolSizeGiB == null || cfg.gpuMemory.ttmSizeGiB != null;
        message = "hardware.amd-npu.gpuMemory.pagePoolSizeGiB requires ttmSizeGiB to be set.";
      }
      {
        assertion =
          cfg.gpuMemory.pagePoolSizeGiB == null
          || cfg.gpuMemory.ttmSizeGiB == null
          || cfg.gpuMemory.pagePoolSizeGiB <= cfg.gpuMemory.ttmSizeGiB;
        message = "hardware.amd-npu.gpuMemory.pagePoolSizeGiB must be <= ttmSizeGiB.";
      }
```

- [ ] **Step 4: Emit the modprobe line**

In `config`, replace the existing single-line `boot.kernelParams`/`boot.kernelModules` region:

```nix
    # Kernel configuration
    boot.kernelParams = ["iommu.passthrough=0"];
    boot.kernelModules = ["amdxdna"];
```

with:

```nix
    # Kernel configuration
    boot.kernelParams = ["iommu.passthrough=0"];
    boot.kernelModules = ["amdxdna"];

    # GTT pool sizing (opt-in). Raises what's *addressable*, not consumed — no
    # power cost. Needed on Strix Halo / 128 GB for large models; no-op on
    # Strix Point / 64 GB. modprobe.d form matches the Strix Halo wiki verbatim.
    boot.extraModprobeConfig = mkIf (cfg.gpuMemory.ttmSizeGiB != null) ''
      options ttm pages_limit=${toString (gttPages cfg.gpuMemory.ttmSizeGiB)}${optionalString (cfg.gpuMemory.pagePoolSizeGiB != null) " page_pool_size=${toString (gttPages cfg.gpuMemory.pagePoolSizeGiB)}"}
    '';
```

- [ ] **Step 5: Run the check to verify it passes**

Run: `nix build .#checks.x86_64-linux.module-eval-gtt -L`
Expected: PASS (builds `module-eval-gtt`; both greps succeed).

- [ ] **Step 6: Verify the default/unset path still evaluates clean**

Run: `nix build .#checks.x86_64-linux.module-eval-rocm-false -L`
Expected: PASS (proves the new `mkIf`-gated emission doesn't perturb the options-unset configuration).

- [ ] **Step 7: Commit**

```bash
git add modules/amd-npu.nix
git commit -m "feat(module): opt-in GTT pool sizing via gpuMemory options (#19)"
```

---

## Task 3: README — GPU memory headroom section

**Files:**
- Modify: `README.md` — add a new `## GPU memory headroom` section. Place it after the "What the module configures" section and before "Troubleshooting".

- [ ] **Step 1: Add the section**

Insert this section into `README.md` (after the "Why the module flags matter" / module-configures material, before `## Troubleshooting`):

```markdown
## GPU memory headroom

The iGPU draws GPU memory from the GTT pool. By default the kernel exposes
~27 GB addressable, which covers the 17–22 GB models this flake targets on a
64 GB Strix Point host — so **leave these options unset there; they're a no-op.**

On a **128 GB Strix Halo** host you need to raise the ceiling to expose the
large unified pool for big models. The module takes sizes in **GiB** and
computes the `ttm` page counts for you (`pages = GiB × 262144`):

```nix
hardware.amd-npu.gpuMemory = {
  ttmSizeGiB = 120;       # GTT pool ceiling  → ttm pages_limit
  pagePoolSizeGiB = 60;   # pre-cached pool   → ttm page_pool_size
};
```

This emits `options ttm pages_limit=31457280 page_pool_size=15728640` via
`boot.extraModprobeConfig`. Recommended starting point for 128 GB:

| Option | Value (128 GB) | Meaning |
|---|---|---|
| `ttmSizeGiB` | 120 | Hard ceiling on the GTT pool; leaves ~8 GiB for the OS/CPU. |
| `pagePoolSizeGiB` | 60 | Pre-cached pool inside that ceiling. |

> **Note:** these Halo values are guidance from the [Strix Halo wiki](https://strixhalo.wiki/AI/AI_Capabilities_Overview),
> **not measured on a Halo host by this flake** (the development target is a
> 64 GB Strix Point P14s). Treat them as a starting point, not a validated tune.

**Leave RAM headroom** — don't set `ttmSizeGiB` to your full physical RAM; the
CPU and OS still need their share (the 120/128 example keeps a margin).
```

- [ ] **Step 2: Verify it renders**

Run: `grep -n "GPU memory headroom" README.md`
Expected: one match for the new heading.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): document opt-in GTT headroom + Halo values (#19)"
```

---

## Task 4: README — tuning tradeoffs we don't automate

**Files:**
- Modify: `README.md` — add a `## Tuning tradeoffs we don't automate` section (after "GPU memory headroom", before "Troubleshooting").

- [ ] **Step 1: Add the section**

Insert into `README.md`:

```markdown
## Tuning tradeoffs we don't automate

### `amd_iommu=off` would kill the NPU

The Strix Halo wiki suggests `amd_iommu=off` for a small memory-read speedup.
**Do not do this on a host that uses the NPU.** amdxdna binds the NPU through
IOMMU SVA/PASID (`iommu_sva_bind_device`, IOMMU group 25, IOMMU in *Translated*
mode); `amd_iommu=off` or `iommu.passthrough=1` makes the bind fail
(`*ERROR* Can not assign PASID` / `SVA get pasid failed`) and the NPU dies. The
module already pins `iommu.passthrough=0` for this reason. `amd_iommu=off` is
only viable on a GPU-only host that has given up XDNA.

### CPU performance tuning (not implemented — pending A/B)

The wiki recommends biasing the CPU to `performance` (governor + HWP boost) for
+3% memory bandwidth / +5–8% `pp512`. We don't wire this, because on a
shared-TDP APU the tradeoff is murky:

- There's **no direct CPU-governor → GPU-clock link** — the iGPU has its own
  clock domain. Pinning CPU cores to `performance` doesn't raise GPU clocks.
- On shared package power, forcing the CPU to max frequency **steals TDP from
  the iGPU** during bandwidth-bound decode — a bounded, possibly net-negative
  lever.
- The knob actually aimed at decode is the **C-state latency floor**
  (`/dev/cpu_dma_latency`), which keeps the fabric/memory subsystem clocked;
  the governor is not.
- Prefill (`pp512`) does have a CPU component, so the wiki's prefill claim is
  plausible — for prefill, not decode.

It's left out until an A/B on an idle/AC host (governor pinned `performance`)
confirms whether the wiki's numbers reproduce on Strix Point. Tracked in
[#19](https://github.com/noamsto/nix-amd-ai/issues/19).
```

- [ ] **Step 2: Verify it renders**

Run: `grep -n "Tuning tradeoffs we don't automate" README.md`
Expected: one match.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): document amd_iommu↔NPU + deferred CPU-tuning A/B (#19)"
```

---

## Task 5: Full verification

- [ ] **Step 1: Run the whole check suite**

Run: `nix flake check -L`
Expected: PASS — all `module-eval-*` checks (including the new `module-eval-gtt`) succeed; no eval errors.

- [ ] **Step 2: Sanity-check the assertion fires**

Temporarily add `gpuMemory.pagePoolSizeGiB = 60;` (without `ttmSizeGiB`) to the `module-eval-rocm-false` check config, then run:

Run: `nix build .#checks.x86_64-linux.module-eval-rocm-false -L`
Expected: FAIL — `Failed assertions: … pagePoolSizeGiB requires ttmSizeGiB to be set.`
Then **revert that temporary edit** (do not commit it).

---

## Self-Review Notes

- **Spec coverage:** ttmSizeGiB/pagePoolSizeGiB options (Task 2) ✓; GiB→page math via `gttPages` (Task 2 Step 1) ✓; `boot.extraModprobeConfig` delivery (Task 2 Step 4) ✓; assertions (Task 2 Step 3) ✓; default-null = no-op (Task 1 negative grep, Task 2 Step 6) ✓; README GPU-memory section + Halo table + un-measured caveat + RAM-headroom caveat (Task 3) ✓; README amd_iommu note (Task 4) ✓; README CPU-tuning deferred-A/B note (Task 4) ✓. `performanceMode` implementation explicitly deferred — no task, by design.
- **Type consistency:** `gttPages`, `ttmSizeGiB`, `pagePoolSizeGiB`, `module-eval-gtt` used identically across all tasks; expected emitted string `options ttm pages_limit=31457280 page_pool_size=15728640` matches the `× 262144` math (120 → 31457280, 60 → 15728640).
- **No placeholders:** every code/command step is concrete.
