# GPU memory headroom: measurements and rationale

The option, an example and the sizing table live in the README ([GPU memory headroom](../README.md#gpu-memory-headroom)). This page holds the measurements behind them.

**`ttmSizeGiB` alone sets the ceiling, and the arithmetic is exact.** Measured
on a 128 GB Halo host (ASUS ROG Flow Z13 GZ302EA, Ryzen AI MAX+ 395, NixOS
26.11, kernel 7.1.0) running `ttm.pages_limit=25165824`:

```
$ cat /sys/class/drm/card1/device/mem_info_gtt_total
103079215104        # 96.00 GiB exactly = 25165824 × 4096
```

ROCm agrees — llama.cpp's HIP backend reports `Total VRAM: 98304 MiB`. Nothing
else is needed to reach the ceiling.

> **Do not also set `amdgpu.gttsize`.** Several third-party Halo guides tell you
> to — including [`antirez/ds4`'s `STRIXHALO.md`](https://github.com/antirez/ds4/blob/main/STRIXHALO.md),
> which the README's ds4 section links — but ROCm#5595 warns against setting
> `gttsize` and `pages_limit` together, and the measurement in this page shows
> `pages_limit` is sufficient on its own.

The ~120 row of the README sizing table is not theoretical: at a 96 GiB ceiling, loading the 80.76 GiB
DeepSeek-V4-Flash GGUF through `ds4` still ran, but fell back from fp16 to q8
kernels for want of room —

```
ds4: ROCm q8 fp16 cache budget exhausted; using q8 kernels
     (request=64.00 MiB cached=3.34 GiB free=4.80 GiB reserve=4.80 GiB total=96.00 GiB)
```

**`pagePoolSizeGiB` is unmeasured.** `page_pool_size` only pre-allocates inside
the ceiling, and three sources say `pages_limit` alone is sufficient — the Strix
Halo wiki ("in theory you could set this to 0"), `hellas-ai/nix-strix-halo`,
and AMD's `amd-ttm` utility. None of that is an A/B on this hardware, so the
option stays documented rather than deprecated, and the README example sets it
equal to `ttmSizeGiB` because that is the configuration the numbers came from —
not because the ratio has been shown to matter. See #42.

Halo measurements on this page contributed by [@expelledboy](https://github.com/expelledboy) (#42).

## Running ds4 beside lemond: why both servers stopped answering

On a 128 GB Strix Halo (gfx1151) at `ttmSizeGiB = 104`, an 80.76 GiB DeepSeek-V4-Flash `IQ2XXS-w2Q2K` quant answered in 1.3 s under ds4 alone, but with a 4B model also resident under lemond there was nothing left for page cache: lemond fell from 53 tok/s to 0.11 (71 s to process 8 prompt tokens), and shortly after *both* endpoints stopped answering. Stopping either one restored the other immediately.

Why *both* died, rather than the second one failing to load, was never
established. Contiguous-memory exhaustion is a candidate: peonist-ai report that
a host with plenty of free bytes and few free 2 MiB blocks stalls for minutes at
100% of one core with no disk activity, which is the signature we saw. See
[halogen-flash-teardown.md](halogen-flash-teardown.md). The original event
was not instrumented, so this is a hypothesis rather than a diagnosis.

The README documents the `exclusiveInference` and `ds4.autoStart` options that make the two servers take turns.
