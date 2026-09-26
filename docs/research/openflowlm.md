# OpenFlowLM-Next: can its BERT kernels be built without an NPU, and what is it good for here?

Research for #153 (context: #147). Question: can OpenFlowLM-Next (OFLM), the
open-kernel fork of FastFlowLM, be packaged in this flake, and specifically can
the BERT kernels that fail in the Nix sandbox be built without an NPU?

The NPU-at-build-time diagnosis was first reported by
[@eyduh](https://github.com/eyduh/OpenFlowLM-Next) in #147; the packaging fork
examined below is theirs.

## 0. How to read this doc

**No NPU was used for anything in this doc.** (The machine it was written on
happens to have one; the one experiment that could have touched it ran with the
device masked, see §2.2.) Nothing below was measured on NPU hardware; where a claim depends on hardware it says so and is
marked `[untested]`. Every claim carries one label:

| label | meaning |
|---|---|
| `[source]` | read from source or config at the pinned commit below, linked to file and lines |
| `[doc]` | stated in upstream documentation, issues or PRs (linked); the doc's claim, not ours |
| `[ran]` | a command run in this no-NPU sandbox: `cmp`, hashing, `nix eval`, `gh api`, or the compile in §2.2. Says nothing about hardware behaviour |
| `[untested]` | inference or an effort estimate; nothing was run |

Pinned commits (all links in this doc are permalinks at these):

| repo | ref | commit |
|---|---|---|
| OFLM upstream, [Atomic-Germ/OpenFlowLM-Next](https://github.com/Atomic-Germ/OpenFlowLM-Next) | `main` on 2026-09-25 | `eb65600` (`eb656007856579c38bafaaa7f86f2f08cc980890`) |
| @eyduh's packaging fork, [eyduh/OpenFlowLM-Next](https://github.com/eyduh/OpenFlowLM-Next) | `main` on 2026-09-25 | `62653a0` (`62653a0bdca21264303bb347f66423b44f3e56c3`) |
| [Xilinx/mlir-aie](https://github.com/Xilinx/mlir-aie) | tag `v1.4.2` | `760932a` (`760932a4abf084bfc7abdec851703b27a03c01ba`) |
| [ROCm/FastFlowLM](https://github.com/ROCm/FastFlowLM) (what `pkgs/fastflowlm` ships) | tag `v1.0.6` | `1a40ad9` (`1a40ad9ade3d4714d48974a974a114441a5bd786`) |
| [lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) (what `pkgs/lemonade` ships) | tag `v11.9.0` | `bb39eaf` (`bb39eafc22aa7e57fc7aeb8b7d384d70b44a4531`) |

Host caveat, per `CLAUDE.md`: the only timings in this doc are the compile
runs in §2.2, from **halo** (Ryzen AI MAX+ 395, Strix Halo; NPU present but
masked for those runs, no NPU-side measurement). This doc quotes no OFLM
performance numbers, and none from upstream's Strix Point reports should be
transferred to Halo (gfx1151 / XDNA2) or to Krackan.

## 1. TL;DR

- **Why BERT needs an NPU: by accident, not by design.** The exporter builds
  each GEMM by *calling* an `@iron.jit` function with `device="npu"` tensors.
  In mlir-aie 1.4.2 that call compiles, then opens `/dev/accel/accel0`,
  allocates buffers, and runs the kernel once on zeros. The run result is
  discarded. The bytes of the design set are produced by the compile step,
  before any device access (§2.1). `[source]`
- **It can be avoided with a ~10-line patch.** Replacing the JIT *call* with
  mlir-aie's compile-only `.specialize(...).compile()` (the same API OFLM's
  own LLM kernels already use) makes the BERT export device-free. §2.2
  reports the result of doing it here with the NPU hidden and no `pyxrt`: the
  full `BERT-h384-bfp16` set compiles in under two minutes, and its
  instruction streams are byte-identical to those of a set @eyduh committed
  (whose own provenance is unclear, §2.2). The compiled kernels have not been run on hardware; that check is still owed
  (§2.2, §6). `[source]` `[ran]`
- **The other ways round it are worse.** An NPU-host builder in Nix is
  possible but host-configured, impure and not usable from a flake consumer
  or CI. First-run building does not fit the runtime. FastFlowLM ships no
  BERT kernels at all (§2.3–2.6).
- **mlir-aie and Peano can be pinned as wheel fixed-output derivations
  today.** Building them from source is days of work and gains little
  (§3). `[source]` `[untested]`
- **The most useful thing in OFLM for us is not its kernels.** FastFlowLM
  1.0.6, which we ship, answers its own HTTP 500 errors with status 200;
  OFLM fixed that (§4.1). `[source]`
- **OFLM is not ready to be the default engine.** Pre-alpha 0.1.0, no tags
  or releases, a tree that still tracks FastFlowLM's closed binaries while its
  README says it does not redistribute them, and it reports a version that
  fails lemonade's gate unless pinned by absolute path (§5). It is not a
  drop-in for `flm`.

Ranked next steps are in §6.

## 2. Q1 and Q2: why BERT needs an NPU at build time, and how to avoid it

### 2.1 Q1: the exact step

The path from the build entry point to the device touch:

1. **CMake.** `OFLM_BUILD_KERNELS` is `ON` by default on Linux and adds an
   `export_kernels` target to `ALL`
   ([src/CMakeLists.txt:1313-1327][cmake-kernels]). It passes only
   `--specs=`, so upstream has no switch that skips BERT alone; turning kernels
   off also drops the compile-only LLM sets. `[source]`
2. **`utilities/export-kernels.py`** runs the LLM sets, then
   `export_bert_sets()`, unconditionally
   ([export-kernels.py:128-151][ek-bert], [:199-200][ek-main]). Its docstring
   states the claim verbatim: the LLM kernels are "Compile-only; needs no NPU
   device", the BERT ones "allocate NPU tensors (`device="npu"`), so it needs
   pyxrt and an installed NPU" ([:9-19][ek-doc]). `docs/BUILD.md` repeats it
   without a further reason ([BUILD.md:179][build-179], [:221-224][build-224]).
   `[source]` `[doc]`
3. **`npu_offload/gemm_rtp/export_gemm_rtp.py`** is the only place a device is
   touched. There is no `pyxrt` import, no xclbin load, no timing and no
   comparison of device output in the file. `[source]` The device-relevant
   statements:

   | statement | device touch? | role |
   |---|---|---|
   | [`iron.set_current_device(from_name("npu2", n_cols=None))`, L408][egr-408] | no: a class lookup and a module global; `None` means the maximum, 8 columns | **required for correctness** (without it the arch silently falls back to NPU1, per [gemm_rtp/README.md:65-69][gr-readme-65]) but already device-free: it *is* the arch/columns flag |
   | [`iron.zeros(..., device="npu")` x3, L457-459][egr-457] | **yes**: opens the device and allocates a buffer, see below | accidental |
   | [`pretiled_array(A, B, C, M=M, ...)`, L460-467][egr-460] | compiles, **then** loads the xclbin and runs it once on the zero buffers | the compile is the artifact; the run is a discarded side effect |
   | the cross-shape `xclbin_identical_mod_uuid` check ([L235-283][egr-235]) | no | host-only byte comparison |

4. **What `device="npu"` does** (mlir-aie v1.4.2). With `pyxrt` importable,
   `iron.zeros` builds an `XRTTensor`, whose constructor calls
   `acquire_device()`, i.e. `pyxrt.device(index)`, then allocates a buffer
   object ([tensor.py:73-138][ma-xrt-tensor], [device.py:76-116][ma-device];
   the docstring says `pyxrt.device(index)` "is an open, not a lookup",
   [device.py:8-13][ma-device-doc]). Without `pyxrt` the tensor class does not
   accept the string at all: `ValueError: Unsupported device: npu`
   ([tensor_class.py:307-308][ma-tc-307]). So the literal in the exporter is
   what makes it hard-fail on a device-less builder. `[source]`
5. **What the JIT call does after compiling.** `CallableDesign.__call__`
   compiles first ([callabledesign.py:203-210][ma-cd-203]), validates the
   tensor shapes against the compiled DMA sizes, then calls the kernel
   ([:363-366][ma-cd-363]), which loads an XRT `hw_context` and runs it. The
   exporter ignores the return value. `[source]`

**Does any emitted byte depend on the device?** Reading the sources, no:

- The compile takes its architecture from the explicitly set `Device` object,
  not from XRT ([compilabledesign.py:384-385][ma-comp-384]).
- The generator is called with only the `CompileTime[...]` parameters; the
  tensors are never passed to it, and `pretiled_array` never uses `A`, `B`, `C`
  in its body ([gemm_pretiled.py:832-865][gp-832]). So the tensors cannot
  influence the emitted design.
- Every number that lands in `design.json` (columns, tile sizes, batch tiers,
  sequence length) comes from CLI flags ([export_gemm_rtp.py:515-586][egr-515]).
  Nothing reads back a column count, a firmware version or a device result.
- One backend-dependent bit exists, the DDR-patch fold ABI, chosen by tensor
  class. XRT and the CPU-only class agree (`True`); only the HRX runtime
  differs ([tensor_class.py:156][ma-tc-156]). `[source]` (so a device-less,
  `pyxrt`-less run should produce the XRT-flavoured instructions as long as
  `NPU_RUNTIME` is not `hrx`)

**Verdict on Q1:** convenience, not correctness. The only thing the device run
adds is an incidental smoke test: a design that compiles but hangs on hardware
(the `--tg-depth 3` case in [families.json][fam-note]) would fail the export.
That is not a purposeful check, and nothing in the export compares device
output. There is no tuning, profiling or JIT-at-first-load step. `[source]`

**Contrast with the LLM kernels.** `open_kernels/build_design.py` sets the
*same* device line and then calls `mod.DESIGN.specialize(**mod.SPECIALIZE).compile(xclbin_path=..., inst_path=...)`
([build_design.py:37-49][bd-37]); its docstring says "(no NPU needed)". It
never calls the JIT function, so it never touches a device. BERT's difference
is only the call style. `[source]`

Two small doc drifts found on the way, both `[source]`: `docs/BUILD.md` and
`build.ps1` say the exporter "holds a lock now" but the file contains none;
and `export_gemm_rtp.py` hard-codes `~/.npu/cache` ([L53][egr-53]) while
mlir-aie honours `NPU_CACHE_HOME`, so set `HOME` (not `NPU_CACHE_HOME`) in a
sandbox.

### 2.2 The patch, and what running it here showed

The minimal change replaces [L457-467][egr-457] with the compile-only call:

```diff
-            A = iron.zeros((M, K), dtype=a_np, device="npu")
-            B = iron.zeros((K, N), dtype=a_np, device="npu")
-            C = iron.zeros(M * N, dtype=c_np, device="npu")
-            pretiled_array(A, B, C, M=M, K=K, N=N, m=args.m, k=args.k, ...)
+            pretiled_array.specialize(M=M, K=K, N=N, m=args.m, k=args.k, ...).compile()
```

`.compile()` without explicit paths writes the same `~/.npu/cache/<hash>/`
directory the JIT call did, so `find_cache`, `purge` and the identity check are
untouched (`CallableDesign.specialize(...).compile()`,
[callabledesign.py:399-476][ma-cd-399]). `[source]`

**Running it, with the NPU hidden.** The machine this was written on turned
out to have an NPU (`/dev/accel/accel0`, driver `amdxdna`). To make the test a
real no-NPU one, every export below ran under
`bwrap --dev-bind / / --tmpfs /dev/accel ...` (so `/dev/accel` is an empty
directory), with `pyxrt` never installed (`import pyxrt` fails). All runs are from halo (§0).
No run touched the device, and **nothing here says anything about whether the
produced kernels load or compute correctly on hardware.** `[ran]`

Toolchain, exactly as upstream pins it: `mlir_aie==1.4.2` and
`llvm-aie==21.0.0.2026080301+c9c5ecb7` from `ironvenv-requirements.txt`
(both still downloadable), `xclbinutil` and `aiebu-asm` from this repo's
`nix build .#xrt`, Python 3.13 (upstream pins 3.11 only because of `pyxrt`).
Family: `BERT-h384-bfp16`, with the exact arguments from
[families.json][fam-fams] and all four batch tiers.

| run | result |
|---|---|
| unpatched, one tier | exit 1 in 0.2 s at [L457][egr-457]: `ValueError: Unsupported device: npu` (mlir-aie `tensor_class.py:308`), before any compile |
| patched, one tier | exit 0, 27 s |
| patched, full family (16 designs: 4 shapes x 4 tiers), mlir-aie 1.4.2 / Peano 21 | exit 0, 1 min 51 s, twice |
| patched, same, mlir-aie 1.4.3 / Peano 22.0.0.2026092301 (@eyduh's pair) | exit 0, 1 min 17 s, twice |

Only one further change was needed and it is not in the source: the script
iterates `~/.npu/cache` and fails with `FileNotFoundError` if it does not
exist, so create it (or set `HOME` to a directory containing it) first.

Outputs (1.4.2): 20 files, `final.xclbin` 127,454 B, `insts.bin` 69,392 B,
16 `insts_<op>_b<tier>.bin`, `design.json`, `toolchain.json` (records mlir-aie
1.4.2 and Peano `21.0.0.2026080301+c9c5ecb7`). The script's own
static-configuration identity checks between the four shapes passed, and
`check_design_sets.py --xclbins` reports `ok BERT-h384-bfp16` for the set.

Comparison, done for `BERT-h384-bfp16` only (the other four families were not
built). The oracle is @eyduh's reverted commit `bcaee46`. Its provenance is
contradictory: the message says the sets were "Generated on arcus" (an NPU host,
per the `oflm validate` output in #147) and also that "BERT embedding sets are
intentionally excluded because they require NPU access at build time", yet the
commit adds all five. They were most likely built through the JIT-call path
this doc replaces. So it is **a reference build, not a known-good one**, and
byte-equality to it shows the compile is the same computation, nothing more:

- **Same toolchain pair (1.4.3 / Peano 22):** `toolchain.json` and all 17
  `insts*.bin` are byte-identical to `bcaee46`'s. `design.json` differs only in
  the 16 `"src"` values (IRON cache directory names, not a semantic field).
  `final.xclbin` is the same size (127,406 B) and differs in 78 bytes, all in
  the header `UniqueID`/timestamp/`XclBinUUID`, the PDI uuid, and the trailing
  metadata mirror. With exactly those fields masked, the two runs here and the
  `bcaee46` file have the **same sha256**, PDI payload included.
- **Upstream's pair (1.4.2 / Peano 21):** all 17 `insts*.bin` are still
  byte-identical to `bcaee46`'s (the instruction stream comes from the IRON
  lowering, not from Peano). The xclbin differs in its `partition_main` (PDI)
  section only, 127,454 B versus 127,406 B; consistent with a different Peano
  nightly producing different core code (an inference; not disassembled).
- **Determinism:** two runs on the same toolchain give byte-identical
  `insts*.bin`, `design.json` and `toolchain.json`; the xclbin differs by 70-75
  bytes, all in the uuid/timestamp fields.

What this establishes: the BERT design set compiles with no device and no
`pyxrt`, and the instruction streams are those a reference build produced.
What it does not: any hardware behaviour. The remaining check is one person
with an NPU loading the set and comparing embedding vectors against the
existing gate ([test_open_npue.ps1](https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/utilities/test_open_npue.ps1)).
`[ran]` `[untested]` (hardware)

### 2.3 Q2(a): patch the device use out

**Viable.** See §2.2, where it was applied and run for one family. Effort to
upstream and validate the other four families: 2-4 h. Arch and columns need no new flag: they are already the explicit
`from_name("npu2", n_cols=None)` plus `--cols`. `[source]` `[untested]` (effort)

@eyduh's fork does not do this. Its `export-kernels.py` adds `--skip-bert`,
`--bert-only`, `--skip-specs`, `-j` and `OFLM_VENV_DIR`/`OFLM_SKIP_VENV_SETUP`
hooks, but `export_bert_sets` is unchanged and `export_gemm_rtp.py` is
untouched ([EY export-kernels.py:178-180][ey-ek]). Its Nix derivation defaults
to `skipBert = true` and, when BERT is requested, sets `__noChroot`
([open-kernels.nix:15-20, 87-89, 100][ey-ok-15]). `[source]`

The fork's history holds a useful oracle. Commit `bcaee46` ("xclbins: add
built open NPU kernel blobs", "Generated on arcus", mlir-aie 1.4.3 / Peano
20260923) added all five BERT sets, about 3.1 MB in total, although its message
also says BERT sets are excluded because they need NPU access; it was reverted
a minute later by `9c48448`. A device-free rebuild on the same toolchain pair
can be diffed against those files (§2.2). Whether they load or pass any
accuracy gate is not stated anywhere. `[source]` `[untested]`

### 2.4 Q2(b): build on the host's NPU through Nix

**Conditional: might work on a hand-configured host (untested), and cannot be shipped in a flake.** The pieces:

- `requiredSystemFeatures` is a scheduling gate only; it grants no device
  access. The one device Nix mounts by feature is `/dev/kvm`
  ([Nix 2.28 local-derivation-goal.cc:1887-1888][nix-kvm]). Any other node
  needs `sandbox-paths`, which does support device nodes, with a trailing `?`
  for optional ones (`man nix.conf`). `[source]` `[doc]`
- Permissions: our udev rule makes `/dev/accel/accel*` `GROUP="video"`,
  `MODE="0660"` ([modules/amd-npu.nix:751-755][amd-udev]), so the `nixbld*`
  users would need to be in `video`. Nix keeps the build user's supplementary
  groups only when the daemon is root ([local-derivation-goal.cc:2072-2077][nix-groups],
  [:998-1006][nix-setgroups]). `[source]` `[untested]` (whether this works on
  a given setup)
- The PAM memlock limit our module sets does not apply to a daemon-spawned
  builder, and whether XRT needs `/sys` or a raised `RLIMIT_MEMLOCK` inside the
  sandbox is not established. `[untested]`
- The fork's route, `__noChroot`, needs `sandbox = relaxed` on the daemon and
  gives the build the whole host. It errors under `sandbox = true`
  ([local-derivation-goal.cc:203-207][nix-noChroot]). It is unusable for
  flake consumers and CI. `[source]`

What a user would have to configure for the `sandbox-paths` route:
`nix.settings.system-features`, `extra-sandbox-paths` for the node (and
possibly `/sys`), `nixbld` in `video`, `LimitMEMLOCK` on `nix-daemon`, on every
remote builder too. All of it is host configuration that a flake package cannot
ship. `[untested]` Effort to get one host working: 3-8 h.

**Reproducibility.** Given §2.1 the *artifact* does not depend on the device,
so the derivation is conceptually pure but operationally impure: hardware
presence only decides whether a discarded run succeeds, and a device hiccup
(`ENODEV`, or the `err=-22` stale-context error mlir-aie already special-cases in
[callabledesign.py:365-397][ma-cd-365], plus the open retries in
[device.py:38-93][ma-device])
becomes a spurious build failure Nix cannot classify. Separately the xclbin
itself is not bit-reproducible run to run (UUID and `TimeStamp` fields, 402 of
631,126 bytes over five xclbins per
[gemm_rtp/README.md:136-150][gr-readme-136]) while `insts*.bin`, `design.json`
and `toolchain.json` are; that is independent of the NPU and rules out a
content-addressed output. `[doc]` `[untested]`

The NPU-host route is only worth having as a *verification* stage on top of the
device-free build (§6), not as the way to build.

### 2.5 Q2(c): defer to first run (JIT into a cache)

**Not viable in the runtime.** The C++ engine only *loads* a prebuilt set and
throws if none exists: it looks in `<model_dir>/npue_designs/`, then
`<xclbin root>/xclbins/<family>/gemm_rtp/`, and otherwise raises "no design set
for this model... They ship pre-built in the distributed package only"
([npue_embedding.cpp:185-219][npue-185]). A first-run build would mean shipping
about 400 MB of toolchain per user (249 MB mlir-aie wheel plus 147 MB Peano,
§3) and about 3-4 minutes per family ([build.ps1:6][build-ps1]). A model-local
`npue_designs/` directory is an existing channel for shipping a set with its
model ([npue_embedding.cpp:178-193][npue-185]). The only sensible variant is an
out-of-band helper script running the patched exporter. `[source]` `[untested]`
(effort: 1-3 days if built into the engine)

### 2.6 Q2(d): published blobs (fixed-output derivation vs git-lfs vs cache) and Q2(e): FastFlowLM's kernels

**Nobody publishes BERT design sets today.** Both OFLM repos have zero
releases and zero tags (`gh api .../releases`, `[ran]`); upstream's
`.gitignore` explicitly refuses them ("A binary in a repository beside the
source that produces it is a claim nobody checks",
[.gitignore:24-33][gitignore]); the `.gitignore` and the engine's error text
refer to a "distributed package" that could not be located. The only artifact source is one we build ourselves.
Five families of about 0.6 MB each (about 3.1 MB total, `[source]` from
`git ls-tree -l bcaee46`).

| approach | pros | cons |
|---|---|---|
| FOD (`fetchurl` of a release tarball we build and publish) | tiny, hash-pinned, no toolchain closure or NPU for consumers | provenance is "trust the publisher"; xclbin is not reproducible, so a rebuild changes the hash and needs a republish; needs a host |
| vendoring or git-lfs in this repo | simplest | grows on every toolchain bump (small at 3 MB); contradicts OFLM's own policy |
| binary cache holding the output of a *source* build | provenance is the device-free build; consumers substitute | a service to run; cache hit is not bit-identical to a local rebuild |

`[untested]` (trade-offs are reasoning, not measurement). Licence of what
would be published: the gemm_rtp source is MIT, relicensed on copy from
Apache-2.0 [`NpuEmbeddings`](https://github.com/vegardberget/NpuEmbeddings)
([gemm_rtp/README.md:48-50][gr-readme-48]); the compiled xclbin also embeds
mlir-aie's `mm.cc` kernel ([README:34-36][gr-readme-34]), whose header says
`Apache-2.0 WITH LLVM-exception` ([mm.cc:1-4][ma-mm]), so binary redistribution needs the notices.
This is a reading, not a legal conclusion.

**FastFlowLM's shipped kernels cannot stand in (Q2e).** FLM 1.0.6 has exactly
one embedding model, `embed-gemma:300m`, as four closed xclbins and no
`insts.bin`, `design.json` or `gemm_rtp` directory
([model_list.json:647-670][flm-models]; the four files are the directory
listing of `src/xclbins/Embedding-Gemma-300M-NPU2/`, `[ran]`); a grep for
BERT/MiniLM/bge/nomic finds nothing. OFLM's BERT layout is a different ABI: `<root>/xclbins/<family>/gemm_rtp/{final.xclbin, insts*.bin, design.json, toolchain.json}`
selected by `npue_design_family` and validated against `design.json` fields
(`hidden`, `intermediate`, `qkv_n`, `gated_ffn`, `emulate_bfp16`,
`b_layout_hash`, tiers): the design set is written by
[export_gemm_rtp.py:515-586][egr-515], located by
[npue_embedding.cpp:185-219][npue-185] and checked by `design_fits`
([npue_encoder.hpp:3938][npue-fits]). No overlap in names, layout or keys.
`[source]` `[ran]` Which models OFLM serves this way:

| model | design family |
|---|---|
| `all-minilm:l6-v2` | `BERT-h384-bfp16` |
| `bge-small:en-v1.5` | `BERT-h384-bf16` (the only one on the plain datapath) |
| `bge-base:en-v1.5` | `BERT-h768-bfp16` |
| `nomic-embed-text:v1.5`, `gte-multilingual:base` | `BERT-h768-gated-bfp16` |
| `bge-large:en-v1.5` | `BERT-h1024-bfp16` |

`[source]` ([families.json:34-66][fam-fams], `src/model_list.json`). Those six
encoders are the only models OFLM adds over FLM 1.0.6 (§4).

**Licence terms of FLM's own binaries** matter to (e) and to us. FLM 1.0.6
carries two statements that disagree: its README says the NPU kernels "are
completely free for any use, including commercial use"
([README.md:116-123][flm-readme]), while `TERMS.md` says they are "NOT open
source", "protected by pending patents", free for non-commercial use and for
companies at or below USD 10M annual revenue, and that above that "you must
obtain an explicit commercial license" ([TERMS.md:9-14][flm-terms]). The
superseded `LICENSE_BINARY.txt` also forbids redistribution outside approved
channels ([:21-24][flm-lic-bin]). Redistribution rights are not stated in
either current document. `[source]` This is a reading of the files, not a
legal conclusion; it is not resolved here. Side note: `pkgs/fastflowlm`
declares `license = lib.licenses.mit` for the whole package
([default.nix:101](https://github.com/noamsto/nix-amd-ai/blob/eaa412e08c4d4e829dbc1609d75cc460dd21f3d4/pkgs/fastflowlm/default.nix#L101)), which covers the source,
not the closed xclbins it installs; worth a separate look.

### 2.7 Q2 summary

| option | verdict | effort | reproducible? | main blocker |
|---|---|---|---|---|
| (a) device-free patch | **viable; compiled here with the NPU hidden (one family)** | 2-4 h upstream, incl. validation | `insts*`, `design.json` stable; xclbin differs by stamps only | one on-hardware load check is owed |
| (b) NPU host through Nix | conditional | 3-8 h per host | conceptually pure, operationally host-dependent | host config, not shippable in a flake |
| (c) first-run build | not viable in the engine | 1-3 days | per user | ships about 400 MB toolchain; runtime never builds |
| (d) published blobs | conditional | 1-3 h to publish | xclbin not bit-identical | no one publishes; must be our own build |
| (e) reuse FLM's kernels | **not viable** for BERT | n/a | n/a | FLM has none; different ABI; licence unclear |

## 3. Q3: mlir-aie and Peano offline

**What OFLM fetches at build time.** `[source]` unless noted (all
[upstream ironvenv-requirements.txt][up-reqs] and
[export-kernels.py][ek-clone]):

- `mlir_aie==1.4.2` from the GitHub release, and `llvm-aie==21.0.0.2026080301+c9c5ecb7`
  (Peano) from the rolling GitHub release tag `nightly`, both by `pip`;
- 12 further PyPI packages, 11 of them **unpinned** (`reuse` is pinned; several look unused for kernel
  export: gurobipy, ortools, networkx, matplotlib, psutil, pyyaml; `[untested]`
  that dense export passes with only the subset @eyduh's env installs);
- a best-effort, unpinned `git clone` of mlir-aie feeding only version
  metadata;
- for the engine: XRT, FFmpeg and zlib from source in the portable build,
  abseil inside sentencepiece, the tokenizers-cpp submodule and its Rust crates
  (no `Cargo.lock` upstream), and an optional HRX tarball with a pinned sha256
  ([src/CMakeLists.txt:89-112, 126-139, 264-268][cmake-fetch]).

`xclbinutil` and `aiebu-asm` come from XRT, not the wheel
([BUILD.md:341][build-341]). Our built `pkgs/xrt` already ships both, plus
`pyxrt` for Python 3.12 (`[ran]`: listed in the built store path). So only
mlir-aie and Peano are missing on our side.

**Versions.** OFLM's designs are written for mlir-aie 1.4.2 and "will not run
on 1.3.4" ([PROVENANCE.md:50-52][provenance]); mlir-aie v1.4.2 pins the same
Peano OFLM does ([peano-requirements.txt:5-6][ma-peano]). @eyduh's fork moved to
mlir-aie 1.4.3 with Peano `22.0.0.2026092301`, but v1.4.3 itself pins Peano
`22.0.0.2026090701`, so his pair was never tested upstream, and he documents
three dense specs that fail on it (`qwen25-3b`, `minicpm5-2b`, `phi4-mini-4b`,
[open-kernels.nix:21-28][ey-ok-21]). `[source]` `[ran]`

**Sizes** (`[ran]`: `gh api` asset sizes, and re-hashed downloads):

| artifact | compressed | notes |
|---|---|---|
| `mlir_aie` 1.4.2 cp312 | 249.0 MB | `sha256-4yHG+WToIxDP97CrByvfLNvO2+NX7H3wUrgZPjDB6tA=` |
| `llvm_aie` 21.0.0.2026080301+c9c5ecb7 | 146.7 MB | `sha256-WmwnxVFyRAQKTcNODB+pdvK9tuFLKaNVQiNvZuibE3U=` |
| 1.4.3 + Peano 22, unpacked | 869 MB + 435 MB | about 1.3 GB in the store |

Both 1.4.2-era URLs return HTTP 200 today. The two wheels' hashes for
@eyduh's pair re-hash to exactly the SRI values in his file. Neither package is
on PyPI.

**Can they be built in Nix from wheels?** Yes; @eyduh's fork already does it
with plain `fetchurl` fixed-output derivations, unzipped with no `pip`
([open-kernels-env.nix:39-47, 63-91][ey-env]). His derivation then copies the
whole ~1.3 GB tree and re-runs `patchelf` on every binary *on every build*
([open-kernels.nix:58-81][ey-ok-58]). Reading `readelf` of his unpacked wheels
(`[ran]`), the executables need only `libstdc++`, `libgcc_s`, `libc`, `libm`,
`libz` beyond what the wheel bundles, so a single `autoPatchelfHook` in its own
store path is enough. [hellas-ai/nix-strix-halo](https://github.com/hellas-ai/nix-strix-halo/blob/25640dcd619c7e6a0d6b511ef0da7596cb99a37b/pkgs/mlir-aie/default.nix)
already packages wheels this way (`autoPatchelfHook`), but at mlir-aie 1.3.4,
too old for OFLM. The pinned nixpkgs has no mlir-aie, llvm-aie or xrt
(`nix eval`, `[ran]`). `[source]`

Provenance, `[ran]`: Nix verifies the FOD sha256, which equals GitHub's own
digest, but that is trust-on-first-use. The mlir-aie wheel has a Sigstore
build-provenance attestation (`gh attestation verify` passed for 1.4.3; the
1.4.2 record exists but was not cryptographically verified). The `llvm-aie`
nightly wheels have **none**, and the `nightly` release tag has already rotated
once, so a `nightly/` URL is not durable: the FOD content must be mirrored into
our own cache.

**From source.** `[source]` `[untested]` (efforts)

| piece | feasibility | effort |
|---|---|---|
| Peano (`Xilinx/llvm-aie`) | one CMake cache, in-tree runtime cross-builds, no visible fetches | 1-2 days to a green derivation, then 1-3 h per build |
| mlir-aie | needs the ROCm LLVM fork pinned at `56bcc187` plus `eudsl-python-extras` ([clone-llvm.sh:12-20][ma-llvm], [requirements.txt:8-10][ma-eudsl]); nixpkgs' MLIR is 3 weeks past that pin and the C++ API drifts | 3-6 days, then 2-4 h per build |

**Recommendation for Q3:** wheels as fixed-output derivations, pinned to the
upstream-tested pair (mlir-aie 1.4.2 cp312 with Peano 21.0.0.2026080301), each
in its own package with `autoPatchelfHook`, mirrored into our cache. Estimate
2-4 h to write plus 1-2 h to see which of the 12 dense specs pass in the
sandbox. Peano-from-source only if the mirror-plus-hash story is judged
insufficient; mlir-aie from source not at all. `[untested]`

## 4. Q4: what is useful regardless of packaging OFLM

### 4.1 A bug we carry, fixed in OFLM

FastFlowLM 1.0.6's server maps only error code 400 to an HTTP status; the
`else if ()` is an empty stub ([server.cpp:729-745][flm-server]). Handlers
that build `{"error": {"code": 500}}` (three of them: [L1329][flm-rest], [L1392][flm-rest2], [L1526][flm-rest3]) are therefore sent as **HTTP 200**.
OFLM fixed it: the response status now comes from `openai_compat::status_for`,
with a comment saying the block "previously recognised a numeric 400 and let a
handler's own 500 out as HTTP 200"
([server.cpp:776-792][ofl-server], `specs/server-api` `SERVER-ERROR-STATUS`,
[spec.md:36-48][ofl-spec]). The fix is Vegard Berget's commit `746f6ab`
(2026-09-12), with related `2c4e548` and `cb67707` (mid-stream errors).
`[source]` `[ran]` (`git show`)

This is a candidate patch for `pkgs/fastflowlm`. Per this repo's `CLAUDE.md`, a
commit that carries it must include a
`Co-authored-by: Vegard Berget <vegardberget@gmail.com>` trailer in a *branch
commit message*. `[untested]` whether lemonade's proxy currently surfaces the
bad status to clients, and the other six `SERVER-*` requirements in that spec
(model identity, `finish_reason`, parameter isolation, embedding task prompt,
stream parity, request validation) were not diffed against FLM 1.0.6.

### 4.2 Conformance tests we can point at anything

OFLM ships a server conformance spec and an `oflm-test --api` / `--embedding`
implementation, stdlib-only Python ([specs/server-api/spec.md:28-31][ofl-spec-28]),
which can target any OpenAI-compatible endpoint, including `flm serve` or
lemonade. It would give the checklist in `docs/halo-bringup-checklist.md` an
API-level check it lacks. `[source]` `[untested]` (nobody has run it against
FLM)

### 4.3 What OFLM's kernels do and do not give us

- **It cannot build or patch FLM's kernels.** FLM's `src/xclbins/*` and engine
  libraries are closed binaries with no source in either repo. OFLM's open
  kernels are new IRON designs loaded by a different engine
  ([PROVENANCE.md:9-17][provenance], `specs/open-engine`). `[source]`
- **Models.** The open recipes are keyed by architecture, not model name
  ([open-engine spec.md:45-47][ofl-oe]), so `oflm-add` can in principle link
  fine-tunes of a supported family and models FLM lacks. There are 12 recipe
  specs (gemma3, granite, hunyuan, lfm2, llama3, phi3, qwen2, qwen3, qwen35,
  qwen36-moe families); gpt-oss, Gemma 4 and the vision models have none.
  Against FLM 1.0.6, OFLM's catalogue adds the six BERT-family encoders (§2.6)
  and lacks `gemma4e-flash`, `hy-mt2` and `qwen3vl-flash`. `[source]` `[ran]`
- **XDNA1 and other chips.** Unsupported: "XDNA1... is **not supported**"
  ([install_lin.md:43][ofl-lin]) and every design pins `from_name("npu2", ...)`.
  The toolchain itself covers NPU1, but porting the designs would be new kernel
  work, not a flag. Our README already treats Hawk Point as GPU-only, which OFLM
  does not change. `[source]` `[untested]`
- **The closed part remains.** For every family without an open recipe OFLM
  falls back to FLM's closed kernels and engine libraries, which are tracked in
  its tree (§5).

### 4.4 Hardware-gated items in this repo it could help with

From `docs/halo-bringup-checklist.md` and `README.md`:

| item | OFLM angle | status |
|---|---|---|
| Krackan / npu6 model-load failure (#79, FastFlowLM#655) | OFLM's PR text says `open_npue` was run on a Framework 13 AI 340 ([PR_open_npue.md:11-13][ofl-pr]); a Ryzen AI 5 340 is a Krackan-class part (our inference, not stated by OFLM). A differential run of an open-kernel model under `oflm` against FLM 1.0.6 would separate "amdxdna npu6 profile/firmware" from "FLM's closed engine". | `[untested]`; needs a Krackan machine we do not have |
| Q4_1 to Q4_K requantization effect on Halo | OFLM ships both a Q4_1 GEMV and a Q4_K prefill GEMM ([PROVENANCE.md:76-83][provenance]) so one model could be A/B'd in both formats on one box | `[untested]`; different engine, so it would not isolate FLM's 1.0.3 change |
| npu5-on-1.0.3 cell | a second engine data point on Halo only | `[untested]` |
| `patches/` | contains only a GPU fix; nothing NPU-related for OFLM to help with | `[source]` |

### 4.5 @eyduh's Nix code: reuse and conflicts

@eyduh's flake takes *this repo as an input* and uses our overlay for XRT
([flake.nix:7-10, 37-41][ey-flake]); it pins `eaa412e`, our current HEAD, and
sets `inputs.nixpkgs.follows`, which our README says not to do
([README.md:106](https://github.com/noamsto/nix-amd-ai/blob/eaa412e08c4d4e829dbc1609d75cc460dd21f3d4/README.md#L106)) because it invalidates the cache. `[source]`

`[ran]` (`nix eval`, no hardware): his NixOS module as documented in `NIX.md`
does **not** evaluate (infinite recursion on the module argument `self`,
[nixos-module.nix:13, 26][ey-mod]; the documented input also points at upstream,
which has no flake). With `self` supplied via `specialArgs`, enabling
`programs.openflowlm` also enables our `hardware.amd-npu`, FastFlowLM, lemonade
and the `lemond` service, because he sets `hardware.amd-npu.enable = mkDefault`
and our `enableFastFlowLM`/`enableLemonade` default to true
([modules/amd-npu.nix:274-284](https://github.com/noamsto/nix-amd-ai/blob/eaa412e08c4d4e829dbc1609d75cc460dd21f3d4/modules/amd-npu.nix#L274-L284)).

| concern | @eyduh | ours (`modules/amd-npu.nix`) | verdict |
|---|---|---|---|
| master switch | `hardware.amd-npu.enable = mkDefault cfg.enableNPU` | the module's enable | his `enableNPU = false` turns off our *whole* module, against his own docs |
| `enableNPU` | `programs.openflowlm.enableNPU` | `hardware.amd-npu.enableNPU` | same word, different scope; he never sets ours |
| kernel module, IOMMU assertions, udev, memlock | none (delegated) | all set | no duplication; ours covers his hosts |
| XRT env | `oflm` wrapper sets `XILINX_XRT` and `LD_LIBRARY_PATH` | `XILINX_XRT` session-wide from `xrt-combined`; `LD_LIBRARY_PATH` only inside the `flm` wrapper (deliberately not session-wide, #148) | consistent; he re-implements `xrt-combined` twice, verbatim from ours, so it should be exported from our overlay |
| binary and env | `oflm`, `OFLM_*`, `~/.config/oflm` | `flm`, `FLM_*`, `flm.prefer_system` | not a drop-in (§5) |
| systemd | none | `lemond`, `lemond-models`, `ds4-server` | enabling OFLM starts `lemond` by default |
| planned `hardware.amd-npu.fastflowlm.package` | n/a | being added (sibling work, not touched here) | OFLM cannot just be the package: needs an `flm`-named wrapper and the version handling in §5 |

Worth reusing, ranked: (1) the toolchain-as-data idea in `open-kernels-env.nix`
(wheel FODs, `PEANO_INSTALL_DIR` and paths), rebuilt as in §3 (pinned
upstream-tested pair, `autoPatchelfHook` once, not per build); (2) his small
`export-kernels.py` hooks (`OFLM_VENV_DIR`, `OFLM_SKIP_VENV_SETUP`,
`--skip-bert`, `--skip-specs`), which belong upstream in OFLM; (3) the engine
build shape in `nix/package.nix` (tokenizers-cpp pinned by rev and hash,
`Cargo.lock` via `importCargoLock`, `-DSPM_ABSL_PROVIDER=package`), the same
pattern as `pkgs/fastflowlm`, so a sibling `pkgs/openflowlm` is cheap
(`[untested]`, about half a day). Not worth reusing: `q4nx-build.nix` (creates
a venv and `pip install`s torch on first run), the `__noChroot` BERT package,
and `shell.nix`. His `meta.license = mit` on a package that links tracked
closed libraries is inaccurate for those blobs. `[source]`

## 5. Q5: readiness, licence, and compatibility with `flm`

### 5.1 Readiness (upstream at `eb65600`)

| fact | value |
|---|---|
| created | 2026-09-02; 24 days old at the pinned commit `[ran]` |
| history | 143 commits; 4 contributors on GitHub; 22 stars, 8 forks; 20 open issues and 9 open PRs (GitHub API, 2026-09-26) `[ran]` |
| releases and tags | **none**, both repos `[ran]` |
| version | `OFLM_VERSION 0.1.0`; `oflm version --json` prints `{ "version": "0.1.0" }` ([main.cpp:591-598][ofl-main]) |
| stated status | `docs/semantic-versioning.md`: "Before `1.0.0`... **anything may change at any time**"; issue #33 "Provide a first version" asks for a 0.0.1-beta because "the build / tooling process is too complicated" `[doc]` |
| install | build from source only; README: "Upstream remains the place to go for a turnkey install and for the closed, tuned kernels" ([README.md:38-39][ofl-readme]) |
| chips | XDNA2 only (Strix, Strix Halo, Kraken, Gorgon Point); in-tree evidence is one Strix Point and one Framework 13 AI 340 report ([PR_open_npue.md][ofl-pr]) |
| relation to FastFlowLM | forked from about FLM 1.0.4; does not track releases (1.0.5 and 1.0.6 not merged; 193 non-binary files under `src/` differ from 1.0.6 and 122 more have no counterpart there) `[ran]` |
| @eyduh's fork | 24 commits ahead and 4 behind upstream; not a descendant of `eb65600`; PR #120 was reviewed as "It doesn't merge as it stands... Split it into three PRs" `[doc]` |

The owner's earlier blocker, "once it tags releases", still stands as of this
writing. Open issues that bear on us: #81 (`oflm validate` passes on machines
where `oflm run` cannot open the NPU), #73 (three multimodal families still
need the closed engine), #74 and #91 (the 35B and GPT-OSS on open
kernels still unfinished; the Whisper issue #72 is closed but its perf follow-ups were still landing). `[doc]`

### 5.2 The closed binaries are still in the tree

OFLM's README says closed kernels "remain FastFlowLM's, under the terms
upstream sets, and are not redistributed by this repository"
([README.md:86-87][ofl-readme-86]). At `eb65600`, `[ran]`:

- git tracks **234** `.xclbin` files and **45** `.so` files (22 under
  `src/lib/hrx`, 23 under `src/lib/xrt`);
- of the 234 xclbins, 172 are byte-identical to the same path in FLM 1.0.6
  (`cmp`) and the rest differ or have no counterpart there (FLM changed some
  after 1.0.4, and OFLM adds its own). Only 2 of the 45 libraries are
  byte-identical to a same-path file in FLM 1.0.6;
- the first commit (2026-09-02) is a squashed copy of FLM's tree (its
  `FLM_VERSION` was 1.0.4).

OFLM's own inventory counts 222 closed and 24 open xclbins
([precompiled_replacement_map.md:15-22][ofl-repl], a table that lags the README).
Of the xclbin trees, only `src/xclbins/BERT-h*/` and `src/xclbins/*/open_kernels*/` are gitignored ([.gitignore][gitignore-all]). `[source]`

Also: OFLM's default model registry points 38 of 44 tags at `Atomic-Germ/*-NPU2`
on Hugging Face; the one repo compared (Llama-3.2-1B) is byte-identical to
FastFlowLM's, closed xclbins included, and its README still says "Optimized for
FastFlowLM" (`[ran]`, HF tree API). Whether FastFlowLM or AMD authorised that
is not stated anywhere read. No CMake switch was found to drop the closed
engine libraries from a build. `[untested]`

### 5.3 Licences (a reading, not a legal conclusion)

| file | covers | terms |
|---|---|---|
| `LICENSE_OPEN_RUNTIME.md` | OFLM's own code; the only top-level licence file | MIT, "OpenFlowLM Community" ([:1-3][ofl-lic]) |
| README "License" | links `./LICENSE_RUNTIME.txt`, which does not exist | says closed kernels "are not redistributed", then keeps FastFlowLM's leftover "completely free for any use, including commercial use" |
| `open_kernels/LICENSE` | the open AIE kernels | MIT, points to a `NOTICE.md` that is not in the tree ([:1-6][ofl-ok-lic]) |
| `utilities/q4nx-build/LICENSE`, `utilities/oflm-add/LICENSE` | those tools | Apache-2.0 text, no copyright line filled in |

The closed xclbins and libraries inside OFLM are FLM's, under whatever FLM's
binary terms are (§2.6: README versus `TERMS.md`). Moving `pkgs/fastflowlm`
to OFLM's tree would not change that situation, and it would additionally pull
in OFLM's re-hosted model registry and its inconsistent notices. Whether the
FLM terms are acceptable for a Nix package is for the maintainer; it is not
settled here.

### 5.4 CLI compatibility with what lemonade actually runs

Lemonade 11.9.0's `flm` backend (`src/cpp/server/backends/fastflowlm/`,
`system_info.cpp`, `backend_utils.cpp`) was read against FLM 1.0.6 (as the
baseline) and OFLM. `C` = compatible in argv and output shape, `I` =
incompatible, `U` = unknown or untested. All `[source]`; nothing was executed
against either binary, so `C` means "same argv accepted and same output shape
in code", not "tested to work".

| lemonade does | FLM 1.0.6 | OFLM `eb65600` | verdict |
|---|---|---|---|
| finds the binary: config `flm.npu_bin` or `LEMONADE_FLM_NPU_BIN` (absolute path), else PATH lookup of the exact name `flm` only if `flm.prefer_system=true`, else the managed dir ([fastflowlm_models.cpp:615-664][lem-find], [backend_utils.cpp:325-356][lem-bu]) | `flm` | `oflm` | **I by name**; C via `npu_bin` or a `flm` symlink. `flm.flm_bin` is not a key lemonade reads |
| `version --json`, prepends `v` ([:548-612][lem-ver]) | `{ "version": "1.0.6" }` ([main.cpp:581-588][flm-main]) | `{ "version": "0.1.0" }` ([main.cpp:591-598][ofl-main]) | C in shape; **version gate I** (below) |
| `validate --json` | same keys, exit code | identical structure | C (OFLM issue #81: passes while XRT cannot open the NPU) |
| `list --json`, `list --filter installed --quiet --json` | `models[]` with `name`, `installed`, `url`, `footprint`, `label` | same code; OFLM's catalogue lacks four FLM tags and adds six | C schema; **U** for embeddings (`bge-*`, `all-minilm`, `gte-*` lack "embed" in the name, so lemonade also labels them chat; its resolution of that was not read) |
| `pull <tag> [--force]` (exit code) | `pull` | same | C |
| parses pull progress lines starting `[FLM]  Downloading ` | printed as such | printed as `[OFLM]  Downloading ` ([download_model.cpp:113-115][ofl-dl]) | **I, cosmetic**: progress percentage lost; exit codes unaffected |
| `serve <tag> --ctx-len N --port P --host 127.0.0.1 [flm_args] --quiet` | defined | all flags present ([vm_args.hpp:92-118][ofl-vm]) | C |
| `flm_args` whitelist (`--pmode`, `--prefill-chunk-len`, `--img-pre-resize`, `--socket`, `--q-len`, `--preemption`) | all defined | all defined | C |
| `serve --embed 1` and `serve --asr 1` | defined | defined, plus `--embeddingmodel` | C for argv; OFLM's extra encoders are unreachable through lemonade (never passed, whitelist forbids it); Whisper on open kernels is unfinished |
| readiness `GET /api/tags`; `POST /v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/audio/transcriptions` | routes exist | routes exist | C routes; **U** bodies |
| model dir probing for `config.json` (max context) | `~/.config/flm` or `FLM_MODEL_PATH` | `~/.config/oflm`, falling back to `~/.config/flm` when absent | C when the store is `~/.config/flm` or `FLM_MODEL_PATH` is exported; otherwise max-context metadata is empty, non-fatal |

**The version gate, precisely.** Lemonade requires `installed >= expected` on
non-Windows, where `expected` is the `flm.npu` pin in `backend_versions.json`
(`v1.0.3` upstream; `pkgs/lemonade` rewrites it to `v${fastflowlm.version}`,
[default.nix:190](https://github.com/noamsto/nix-amd-ai/blob/eaa412e08c4d4e829dbc1609d75cc460dd21f3d4/pkgs/lemonade/default.nix#L190)); `oflm` reporting `0.1.0`
fails it and the backend becomes `update_required`, which lists no models
([system_info.cpp:1527-1540][lem-gate], [fastflowlm_models.cpp:220-224][lem-ready]).
The gate is **skipped when `npu_bin` is an absolute path** ("User-managed
binary; lemonade doesn't track its version",
[system_info.cpp:1494-1505][lem-skip]). This refines the guess in #147: the
"needs an update, lists no models" failure only occurs when the pin is not a
path. `[source]`

So the argv surface lemonade uses is accepted as-is (OFLM's `vm_args.hpp`,
`main.cpp` dispatch and `model_list.hpp` are near-verbatim FLM 1.0.4 with a
rename). The three real gaps are the binary name, the version gate, and the
`[OFLM]` prefix. Anything behavioural (model load, generation, `/v1/*` bodies,
embeddings) is `[untested]`, and the trouble @eyduh reported in #147 (setting `flm.flm_bin`, which
lemonade never reads) is explained by the first row.

## 6. Recommendation

Do **not** package OFLM as an alternative engine yet. The blockers in #147 are
real: no tags, a tree that tracks closed FastFlowLM binaries while saying it
does not, an unfinished open engine for many families, and version and name
mismatches with lemonade. Do the following, in this order:

| # | step | effort | notes |
|---|---|---|---|
| 1 | **Carry the FLM server error-status fix** in `pkgs/fastflowlm` (`patches/`), with `Co-authored-by: Vegard Berget` in a branch commit | 2-4 h | verify against lemonade that a 500 surfaces; unit-level only, no hardware needed. `[untested]` |
| 2 | **Upstream the device-free BERT export patch** (§2.2) to Atomic-Germ, with the comparison from §2.2 in the PR, and ask them for a tagged release | 2-4 h | the single change that removes the "needs an NPU" blocker; one person with an NPU must then confirm the set loads and the embedding vectors match |
| 3 | **`pkgs/mlir-aie` and `pkgs/llvm-aie`** as wheel FODs (1.4.2 with Peano 21), mirrored into our cache | 3-6 h | prerequisite for any OFLM kernel build; also useful to anyone doing IRON work; not needed until step 4 is wanted |
| 4 | Wait for a tag, then add `pkgs/openflowlm` (engine plus open kernels, BERT sets from a device-free build) behind the planned `hardware.amd-npu.fastflowlm.package` seam, exposing an `flm`-named wrapper and pinning `flm.npu_bin` to an absolute path | 1-2 days | only after 1-3, a release tag, and a licence clarification; needs a hardware smoke test (`list`, `serve`, one chat, one embedding) |
| 5 | Run `oflm-test --api` against `flm serve` on Halo | 0.5 day | hardware-gated; would also validate step 1 |
| 6 | Krackan differential (§4.4) | n/a | needs hardware we do not have |

**Not recommended:** an NPU-host Nix builder (§2.4), a first-run JIT (§2.5),
building mlir-aie from source (§3), and reusing @eyduh's `__noChroot` route or
his flake as it stands (§4.5).

Follow-ups surfaced for the dispatcher rather than done here (research-only
change): steps 1 and 2 above, and the `license = mit` question on
`pkgs/fastflowlm` (§2.6).

<!-- link references: every source link resolves to a full commit SHA -->
[cmake-kernels]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/CMakeLists.txt#L1313-L1327
[cmake-fetch]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/CMakeLists.txt#L89-L112
[ek-bert]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/utilities/export-kernels.py#L128-L151
[ek-main]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/utilities/export-kernels.py#L199-L200
[ek-doc]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/utilities/export-kernels.py#L9-L19
[ek-clone]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/utilities/export-kernels.py#L183-L190
[up-reqs]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/ironvenv-requirements.txt#L10-L26
[build-179]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/docs/BUILD.md#L179
[build-224]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/docs/BUILD.md#L221-L224
[build-341]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/docs/BUILD.md#L341
[egr-53]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/export_gemm_rtp.py#L53
[egr-235]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/export_gemm_rtp.py#L235-L283
[egr-408]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/export_gemm_rtp.py#L408
[egr-457]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/export_gemm_rtp.py#L457-L467
[egr-460]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/export_gemm_rtp.py#L460-L467
[egr-515]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/export_gemm_rtp.py#L515-L586
[gp-832]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/gemm_pretiled.py#L832-L865
[gr-readme-34]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/README.md#L34-L36
[gr-readme-48]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/README.md#L48-L50
[gr-readme-65]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/README.md#L65-L69
[gr-readme-136]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/README.md#L136-L150
[build-ps1]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/build.ps1#L6
[fam-note]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/families.json#L19-L22
[fam-fams]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/npu_offload/gemm_rtp/families.json#L34-L66
[bd-37]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/open_kernels/build_design.py#L37-L49
[npue-185]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/open_npue_adapter/npue_embedding.cpp#L185-L219
[gitignore]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/.gitignore#L24-L33
[provenance]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/open_kernels/PROVENANCE.md#L50-L52
[ofl-server]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/server/server.cpp#L776-L792
[ofl-spec]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/specs/server-api/spec.md#L36-L48
[ofl-spec-28]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/specs/server-api/spec.md#L28-L31
[ofl-oe]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/specs/open-engine/spec.md#L45-L47
[ofl-lin]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/docs/docs/install_lin.md#L43
[ofl-pr]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/PR_open_npue.md#L11-L13
[ofl-main]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/src/main.cpp#L591-L598
[ofl-readme]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/README.md#L38-L39
[ofl-readme-86]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/README.md#L86-L87
[ofl-repl]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/docs/precompiled_replacement_map.md#L15-L22
[ofl-lic]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/LICENSE_OPEN_RUNTIME.md#L1-L3
[ofl-ok-lic]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/open_kernels/LICENSE#L1-L6
[ofl-dl]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/pull/download_model.cpp#L113-L115
[ofl-vm]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/include/utils/vm_args.hpp#L92-L118
[ey-ek]: https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/utilities/export-kernels.py#L178-L180
[ey-ok-15]: https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/nix/open-kernels.nix#L15-L20
[ey-ok-21]: https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/nix/open-kernels.nix#L21-L28
[ey-ok-58]: https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/nix/open-kernels.nix#L58-L81
[ey-env]: https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/nix/open-kernels-env.nix#L39-L91
[ey-flake]: https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/flake.nix#L7-L41
[ey-mod]: https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/nix/nixos-module.nix#L13-L26
[ma-xrt-tensor]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/hostruntime/xrtruntime/tensor.py#L73-L138
[ma-device]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/hostruntime/xrtruntime/device.py#L38-L116
[ma-device-doc]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/hostruntime/xrtruntime/device.py#L8-L13
[ma-tc-307]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/hostruntime/tensor_class.py#L307-L308
[ma-tc-156]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/hostruntime/tensor_class.py#L156
[ma-cd-203]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/callabledesign.py#L203-L210
[ma-cd-363]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/callabledesign.py#L363-L366
[ma-cd-399]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/callabledesign.py#L399-L476
[ma-comp-384]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/compile/jit/compilabledesign.py#L384-L385
[ma-peano]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/utils/peano-requirements.txt#L5-L6
[ma-llvm]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/utils/clone-llvm.sh#L12-L20
[ma-eudsl]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/requirements.txt#L8-L10
[flm-server]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/src/server/server.cpp#L729-L745
[flm-rest]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/src/server/rest_handler.cpp#L1326-L1331
[flm-rest2]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/src/server/rest_handler.cpp#L1389-L1394
[flm-rest3]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/src/server/rest_handler.cpp#L1523-L1528
[ma-mm]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/aie_kernels/aie2p/mm.cc#L1-L4
[ma-cd-365]: https://github.com/Xilinx/mlir-aie/blob/760932a4abf084bfc7abdec851703b27a03c01ba/python/utils/callabledesign.py#L365-L397
[npue-fits]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/src/open_npue/npue_encoder.hpp#L3938-L4030
[gitignore-all]: https://github.com/Atomic-Germ/OpenFlowLM-Next/blob/eb656007856579c38bafaaa7f86f2f08cc980890/.gitignore#L24-L84
[flm-main]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/src/src/main.cpp#L581-L588
[flm-models]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/src/model_list.json#L647-L670
[flm-readme]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/README.md#L116-L123
[flm-terms]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/TERMS.md#L9-L14
[flm-lic-bin]: https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/assets/superseded/LICENSE_BINARY.txt#L21-L24
[lem-find]: https://github.com/lemonade-sdk/lemonade/blob/bb39eafc22aa7e57fc7aeb8b7d384d70b44a4531/src/cpp/server/backends/fastflowlm/fastflowlm_models.cpp#L615-L664
[lem-bu]: https://github.com/lemonade-sdk/lemonade/blob/bb39eafc22aa7e57fc7aeb8b7d384d70b44a4531/src/cpp/server/backends/backend_utils.cpp#L325-L356
[lem-ver]: https://github.com/lemonade-sdk/lemonade/blob/bb39eafc22aa7e57fc7aeb8b7d384d70b44a4531/src/cpp/server/backends/fastflowlm/fastflowlm_models.cpp#L548-L612
[lem-gate]: https://github.com/lemonade-sdk/lemonade/blob/bb39eafc22aa7e57fc7aeb8b7d384d70b44a4531/src/cpp/server/system_info.cpp#L1527-L1540
[lem-skip]: https://github.com/lemonade-sdk/lemonade/blob/bb39eafc22aa7e57fc7aeb8b7d384d70b44a4531/src/cpp/server/system_info.cpp#L1494-L1505
[lem-ready]: https://github.com/lemonade-sdk/lemonade/blob/bb39eafc22aa7e57fc7aeb8b7d384d70b44a4531/src/cpp/server/backends/fastflowlm/fastflowlm_models.cpp#L220-L224
[nix-kvm]: https://github.com/NixOS/nix/blob/2.28.0/src/libstore/unix/build/local-derivation-goal.cc#L1887-L1888
[nix-groups]: https://github.com/NixOS/nix/blob/2.28.0/src/libstore/unix/build/local-derivation-goal.cc#L2072-L2077
[nix-setgroups]: https://github.com/NixOS/nix/blob/2.28.0/src/libstore/unix/build/local-derivation-goal.cc#L998-L1006
[nix-noChroot]: https://github.com/NixOS/nix/blob/2.28.0/src/libstore/unix/build/local-derivation-goal.cc#L203-L207
[amd-udev]: https://github.com/noamsto/nix-amd-ai/blob/eaa412e08c4d4e829dbc1609d75cc460dd21f3d4/modules/amd-npu.nix#L751-L755
