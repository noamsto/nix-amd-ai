# Tuning tradeoffs we don't automate

Kernel and CPU settings the module deliberately leaves alone, with the evidence behind that choice. The README keeps only the warning that matters for module users.

## `amd_iommu=off` would kill the NPU

The Strix Halo wiki suggests `amd_iommu=off` for a small memory-read speedup.
It is not small, and on a compute-bound prefill it is not a memory-read effect:
peonist-ai measured the IOMMU costing 13-16% of prefill on their gfx1151 host,
by way of a power budget the translation machinery spends and the shaders then
do not get. Their numbers, mechanism, and caveats are in
[halogen-flash-teardown.md](halogen-flash-teardown.md); none of it is
reproduced here, and they never measured Translated mode, which is what our
hosts run.

**Do not do this on a host that uses the NPU.** amdxdna needs the IOMMU present
for PASID; with `amd_iommu=off` there is no IOMMU at all and the NPU dies.
`amd_iommu=off` is only viable on a GPU-only host that has given up XDNA.

`enableNPU` asserts on this, because the param does not always come from the
line you wrote: any module in the closure can contribute to `boot.kernelParams`,
and Jovian-NixOS ships `amd_iommu=off` in the SteamOS cmdline defaults that
`jovian.steamos.useSteamOSConfig` turns on. Enabling Steam Gaming Mode on an NPU
host is enough to do it. To see the merged list:

```console
$ nix eval --json .#nixosConfigurations.<host>.config.boot.kernelParams
```

You also don't need it for large-model headroom, which is the usual reason
people reach for it. The 128 GB Halo host measured in [gpu-memory.md](gpu-memory.md) boots
`iommu.passthrough=0` — full IOMMU translation, the demanding case — with the
NPU driver loaded, and still loads both a 67 GB llama.cpp model and an 80.76 GiB
`ds4` model into the GTT pool.

The IOMMU default-domain *mode* is a separate knob. amdxdna historically
required *Translated* mode (SVA/PASID), so the module used to pin
`iommu.passthrough=0`. Since the June 2026 amdxdna fix (upstream `5b96159`,
"skip PASID tag in non-SVA mode") the driver no longer tags DMA with an invalid
PASID under an identity default domain, so the NPU works with `iommu=pt` too.
The module no longer forces the mode — it leaves the kernel default (Translated
on NixOS), and hosts that want passthrough can set `iommu=pt` themselves.

> **Don't expect a prefill win from `iommu=pt`.** peonist-ai's A/B makes
> passthrough the *slow* arm: it measured `iommu=pt` at 385 tok/s against 460
> with the IOMMU off entirely, on more package power and lower shader clocks.
> If that generalises, passthrough keeps the NPU alive without recovering the
> prefill that `amd_iommu=off` buys. Unmeasured here, and unmeasured against
> Translated anywhere.

## CPU performance tuning (not implemented — pending A/B)

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
