# halogen-flash-server 0.5.6: what it is, and what it tells us

[peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server)
is a closed-source inference engine built for gfx1151 alone, shipped as a
container image under a bespoke EULA. It serves one model family
(Qwen3.8-Flash-Next) and hard-rejects other architectures.

Nothing here is packageable — there is no source, and the flake builds from
source. It is the only expert-tuned gfx1151 engine with published numbers, and
two of its claims bear directly on settings this repo recommends.

**Everything under "What they publish" is their measurement on their machine,
not ours.** Their reference host is a Ryzen AI Max+ 395 with 128 GB at ROCm
7.14.0 and roughly 85 W sustained package power, with the IOMMU off. None of it
has been reproduced here.

## What we verified ourselves

The image is 16 layers and about 850 MiB compressed; weights download
separately and are not in it. An anonymous ghcr token and the blob endpoint are
enough to unpack it, so no container runtime is needed to look.

| fact | value |
| --- | --- |
| `flash_serve` | 12,045,040 bytes, stripped x86-64 |
| `.hip_fatbin` | 10,853,960 bytes of embedded gfx1151 code objects |
| matrix library | `libhipblaslt.so.1` — **rocBLAS is not linked at all** |
| GEMM plan | `/opt/halogen/flash-tune.plan`, 30,644 bytes, magic `HGNTUNE3` |
| HTTP front-end | `serve_api.py`, 149,064 bytes of plain Python source |

**hipBLASLt is the lead worth following.** The fastest published gfx1151 engine
routes every GEMM through it with an offline-tuned per-shape plan baked into the
image, while llama.cpp's HIP backend reaches for rocBLAS through hipBLAS
instead. Whether that path is worth anything for llama.cpp on this hardware is
**unmeasured**, and nothing here says it is.

The tuning plan is their own container format rather than a hipBLASLt tuning
file, so it cannot be dropped into another stack as-is. Their docs describe
regenerating one by running with `HALOGEN_MATMUL_ALGOS=8` against a path that
does not exist yet, which is the shape of hipBLASLt's offline algo selection.
The method transfers even though the file does not.

Their notices also record ROCm **7.14.0** from AMD's `whl-multi-arch` wheels
with a `rocm_sdk_device_gfx1151` component, which is a newer per-arch wheel than
the 7.13.0 gfx1150 build measured in [therock-eval-results.md](therock-eval-results.md).

## Reverse engineering: permitted, and mostly not worth it

The EULA declines to prohibit it in as many words, and calls interoperability
and security research welcome. It asks that derived source or kernels not be
redistributed as our own work, and that ask is a request rather than a
condition.

Going further than the teardown above still fails on its merits. The kernels are
written for one model family's shapes (Gated DeltaNet and QSA, per their
changelog), so they do not drop into llama.cpp, which needs general ones. This
repo packages engines and does not author kernels, so the output would be work
that then has to be written and landed upstream. And shipping their kernels is
the one outcome that would justify the effort and the one thing they asked us
not to do.

The EULA expressly permits benchmarking and publication with no approval, and
they state plainly that their comparison table is other people's published
figures rather than a head-to-head they ran. A same-machine comparison against
our patched llama.cpp is therefore both sanctioned and unclaimed. It is not run
yet; it needs a 118 GiB weights download.

## What they publish that bears on our settings

### The IOMMU costs more than "a small memory-read speedup"

The Strix Halo wiki's framing, which this repo carried, is that `amd_iommu=off`
buys a small memory-read win. On a compute-bound prefill peonist-ai measured
something both larger and differently caused — a power budget the translation
machinery spends and the shaders then do not get:

| arm | package power | shader clock | prefill @ 2048 |
| --- | --- | --- | --- |
| IOMMU off | 108–118 W | 2549–2713 MHz | 460 tok/s |
| `iommu=pt` | 122–127 W | 2357–2409 MHz | 385 tok/s |

Every bandwidth-bound figure held exactly across the two arms, and they bisected
it on one kernel, so it is the IOMMU rather than the kernel version.

Passthrough is the **slow** arm here, so recommending `iommu=pt` for a
memory-read win rests on a mechanism this contradicts, and the NPU trade is
bigger than a rounding error: keeping the IOMMU costs 13 to 16 percent of
prefill on their host.

Their caveats are load-bearing: one machine, and they compared off against
passthrough only. **Translated mode was never measured, and Translated is what
our hosts run.** See [halo-bringup-checklist.md](halo-bringup-checklist.md) for
the A/B that would settle it here.

### A firmware graphics carve-out is invisible and costs page cache

A UMA frame buffer assigned in firmware is taken before the kernel boots. It
appears nowhere in `/proc/meminfo`; the machine simply reports itself smaller,
and the loss lands on the file cache. Their advice is Auto or minimum, which
reports about 512 MiB on this hardware, because the iGPU allocates through GTT
either way.

Our halo host is carrying one. Measured 2026-09-11:

```console
$ cat /sys/class/drm/card1/device/mem_info_vram_total
2147483648        # 2.00 GiB carved out in firmware
$ cat /sys/class/drm/card1/device/mem_info_gtt_total
111669149696      # 104.00 GiB, the ttmSizeGiB = 104 ceiling
```

1.5 GiB above the minimum is small enough not to explain anything we have seen,
and dropping it has not been A/B'd here. Check the BIOS before tuning anything
else regardless: on a host that carves out 16 GiB the effect is not small.

### Free memory can be plentiful and the wrong shape

Their startup path counts free 2 MiB contiguous blocks before allocating,
because a host with plenty of free bytes and none of them contiguous stalls for
minutes at 100% of one core with no disk activity, which is indistinguishable
from a hang. They also report that locked weights are counted as reclaimable
page cache, so `free` and `MemAvailable` overstate available memory by the size
of the model while `Mlocked` and `Unevictable` both stay at zero.

That is a candidate mechanism for the one thing the README records and cannot
explain: running ds4 beside lemond ended with *both* endpoints unresponsive
rather than the second one failing to load. It stays a hypothesis — the original
event was not instrumented and has not been reproduced.

Our halo host is healthy on this metric at idle, for a baseline. From
`/proc/buddyinfo`, zone Normal, 2026-09-11:

```
order-9 (2 MiB): 1079 blocks      order-10 (4 MiB): 12952 blocks
```

Their warning threshold is 512 blocks of 2 MiB. The remedy when it fires is to
stop other large workloads and, as root, `echo 1 > /proc/sys/vm/compact_memory`.

## Benchmark policy worth copying

Their tooling is covered by the EULA and must not be copied. The policy behind
it is not, and this repo publishes numbers under the same pressures:

- **Never quote an engine-side fixture number as a serving number.** They got
  this wrong twice, most sharply when a fixture put speculative decoding at
  -23% on chat and live traffic measured +5 to +7 percent.
- **Split the two benchmarks and never read across them**: real prompt shapes
  for the number of record, a synthetic size sweep for anything placed beside a
  llama-bench pp/tg table.
- **Name the prompt set with every speculative figure.** Acceptance spans
  roughly 2x between prose and code, so a bare number is not reproducible.
- **Three repetitions minimum before quoting, with the per-case spread
  published** so the noise floor is visible rather than assumed.
- **Prompt sets are append-only.** Editing a case silently breaks every
  cross-release comparison.
- **Publish the power envelope.** An independent tester on a 70 W handheld
  landed 11 to 12 percent under both of their decode figures, consistently,
  which is the signature of an envelope difference rather than a disagreement
  about the engine. `bench-logs/` records neither package power nor median
  shader clock today.
