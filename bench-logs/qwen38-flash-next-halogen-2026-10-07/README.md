# Halogen 0.16.2 (closed OCI image) on halo for Flash-Next (#258)

[Halogen](https://github.com/peonist-ai/halogen-flash-server) ranked second in the engine survey (#253). It is closed
source and ships as an OCI image, so this bench is also a verdict on running a closed container as a lemond backend.

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel 7.2.9)**,
measured 2026-10-07 with image `ghcr.io/peonist-ai/halogen-flash-server@sha256:0c61bf84ac22308a53f5d1ca6b86806702d7039e5ebc51cae4c66621b92fe04a`
(tag `0.16.2`, engine and API both report 0.16.2), rootless podman 5.8.7, the #249 harness groups, corpus rev `4166bc4`,
the same agent replay. Nothing here transfers to gfx1150. **IOMMU mode for every row: default (translated), no `iommu` or
`amd_iommu` option on the kernel command line.** Halogen's own README puts IOMMU off at 13–16 % of prefill, so some of any
gap to its published figures is the host. Kernel requirements it documents are met: KFD node 1 (gfx1151) reports the SVM
capability bit and the `cwsr_size`/`ctl_stack_size` relation its README gives (the gfx1151 KFD fixes), and the kernel has
`CONFIG_HSA_AMD_SVM=y`. Both arms ran with vision on (`HALOGEN_VISION_TOWER=1`), 131072 context, two KV slots.

## Verdict

**A closed container is acceptable as an opt-in lemond backend, and its v2 checkpoint is the fastest engine measured on
halo; it should not replace the resident model until a soak and a decode re-measure on agent traffic have run.**

- **Gain.** Agent replay (normalized) **68.0 s** vs 84.1 s Strata fast, 116.1 s tuned GSQHalo, 179.2 s Vulkan: −19 % /
  −41 % / −62 %. Prefill 1432 t/s at 4K and ~1600–1660 at 32K and 130K, 1.3–1.4× Strata fast and 2× the production
  GSQHalo (rows below). Time to first token summed over the replay is 32.4 s (Strata fast 47.8 s).
- **Decode did not reproduce and is noisy.** Claimed 34–46 t/s at 32K. Measured 17–45 t/s depending on the row, because
  the decode rows here generate prose (a chat "write a long essay" prompt, as the Strata rows did, since Halogen ignores
  `ignore_eos`) and its acceptance on prose is low (0.63–0.69). Halogen's own licence text says the same build spans
  about 20 t/s on prose to about 42 on code. These decode figures say nothing about agent traffic. Host load peaked at 7.4
  (1-minute loadavg) during the v2 row, so treat single decode cells as unconfirmed.
- **Quality is level with UD-IQ4_XS, with a caveat.** On the #260 eval text against #260's Q8_0 reference, v2 has top-128
  mean KL 0.0965 vs 0.0879 for the same GGUF run through Halogen (+10 %), top token 90.8 % vs 91.5 %, but a *lower*
  perplexity ratio (1.0176 vs 1.0252). #260's 16 tasks: v2 16/16 greedy and 75/76 sampled, the same as UD-IQ4_XS (#260).
- **Costs.** 113 GiB on disk (v2 62.1 GiB, n-gram table 47.7 GiB, head, vision tower, tokenizer); a resident footprint
  of 69 GiB (file-backed and pinned) that cannot coexist with lemond's 72 GiB model; a closed binary pinned by digest,
  which nobody here can patch; one maintainer.
- **Security.** No connected outbound flow seen over a container lifetime, and the container loads and serves on an
  `--internal` network with no route out (the offline row). The run line below uses podman's default network, so adopt
  it with an internal network. `--ipc=host` also gives the container read-write access to the host's `/dev/shm`. See the
  Security section.
- **Not done:** a soak, concurrency, thinking-on workloads, a decode row on code and agent text, a real build as the
  co-tenant (a 20 GiB memory holder was used), and the BYO arm confirmation (below).

## Baselines (halo, same harness; Vulkan and GSQHalo are #252's same-day rows, Strata is #269's)

| | Vulkan b11382 | GSQHalo f16 KV (production) | Strata fast | **Halogen v2** | Halogen BYO UD-IQ4_XS (unconfirmed) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Agent replay, normalized (s) | 179.2 | 116.1 | 84.1 | **68.0** | 89.5 |
| Replay, time to first token summed (s) | 123.9 | 63.6 | 47.8 | **32.4** | 33.8 |
| Prefill 4K / 32K / 128K (t/s) | 474 / 415 / 267 | 723 / 774 / 761 | 1052 / 1229 / 1209 | **1432 / 1662 / 1599** | 1359 / 1628 / 1599 |
| Decode 512 / 32K / 128K, T=0.7 (t/s) | 27.0 / 37.3 / 25.6 | 28.3 / 40.9 / 35.1 | 43.7 / 42.5 / 40.6 | 37.6 / 21.0 / 37.9 | 30.9 / 31.7 / 29.5 |
| GTT after load / peak | 70.8 / 74.3 GiB | 71.6 / 73.4 GiB | 66.8 / 66.9 GiB | 15.4 GiB peak delta (see Memory) | 18.3 GiB peak delta |

Prefill at 32K and 128K is the prefill of the decode rows' prompts (32,840 and 130,072 tokens) over HTTP, unique prompts,
no prompt-cache hit (`cached_tokens` is 0 on every speed run). The Strata best result from #276 (open, #279) is a quality
and quirks bench; it reports no new speed rows, so #269's fast configuration stays the speed baseline.

**Claimed vs measured** (Halogen's README, v2/w4b rows, IOMMU off, ~85 W): prefill 1,584 / 1,567 / 1,517 t/s at
8K / 32K / 128K, measured 1432–1662 here with the IOMMU on; serial decode 34.1 and speculative 46.0 at 32K, not reproduced
(above).

### v2 rows

| | v2 checkpoint | BYO UD-IQ4_XS |
| --- | ---: | ---: |
| Prefill 4K (t/s) | 1432 | 1359 |
| Prefill at 512 / 32K / 130K prompts (t/s) | 852 / 1662 / 1599 | 748 / 1628 / 1599 |
| Decode 512, T=0.7 mean of 3 (t/s) | 37.6 (runs 45, 42, 26) | 30.9 (33, 30, 30) |
| Decode 32K, T=0.7 (t/s) | 21.0 (23, 19, 20) | 31.7 (31, 32, 32) |
| Decode 128K, T=0.7 (t/s) | 37.9 (42, 30, 41) | 29.5 (33, 33, 22) |
| Decode T=0 at 512 / 32K / 128K (t/s) | 19.5 / 18.8 / 40.5 | 33.3 / 31.6 / 18.4 |
| Draft acceptance 512 / 32K / 128K | 0.69 / 0.63 / 0.68 | 0.64 / 0.64 / 0.67 |
| Replay normalized / wall / TTFT summed (s) | 68.0 / 37.6 / 32.4 | 89.5 / 42.0 / 33.8 |
| Tool call, vision, sanity | ok, ok, 10/10 | ok, ok, 10/10 |
| Load time (s) | 30 | 21 |

The decode cells swing between rows of the same arm (v2 T=0 128K 40.5 t/s vs 18.8 at 32K), which no engine property
explains; one row per arm, host loadavg peaked at 7.4 (v2) and 8.8 (BYO). **The BYO column is a single unconfirmed run**: the
confirmation re-run was dropped by the owner's decision.

### Memory per row

| | v2 | BYO |
| --- | ---: | ---: |
| GTT peak delta (GiB) | 15.4 | 18.3 |
| Container cgroup after load / end (GiB) | 62.6 / 69.1 | 71.7 / 77.9 |
| cgroup anon / file at end (GiB) | 1.7 / 67.0 | 72.5 / 5.2 |
| Lowest MemAvailable during the rows (GiB) | 98.8 | 25.9 |
| Swap used at end (GiB) | 1.12 | 1.07 |

Halogen pins its weights as registered host memory, so GTT stays small (15–18 GiB) while the container holds 69–78 GiB.
v2's weights are a file mapping, which the kernel counts as available memory even though they are pinned: the 98.8 GiB
minimum overstates the headroom. BYO repacks the GGUF into 72 GiB of anonymous memory and left 25.9 GiB.

## Quality

**Against #260's Q8_0 reference** (same 64 × 2048 tokens, same 65,472 scored positions as #260 and #276):

| | v2 | BYO UD-IQ4_XS | #260 UD-IQ4_XS, GSQHalo GPU |
| --- | ---: | ---: | ---: |
| Mean KL (estimator) | 0.0965 ± 0.0011 | 0.0879 ± 0.0011 | 0.0960 (full vocabulary) |
| Median / p99 KL | 0.0051 / 1.23 | 0.0045 / 1.18 | 0.0047 / 1.25 |
| Same top token | 90.83 ± 0.11 % | 91.47 ± 0.11 % | 91.52 % |
| PPL (ratio to Q8_0) | 2.6496 (1.0176 ± 0.0023) | 2.6693 (1.0252 ± 0.0023) | 2.6680 (1.0247) |

**How Halogen was scored, and the bias.** Halogen exposes no full logits. Over HTTP it returns top-20 log-probabilities for
the first generated token only (`logprobs` at `temperature: 0` and past one token are refused with a 400, as is
`stream: true` with logprobs), which would need one request per position. Its `ppl` mode writes the candidate's top-128
log-probabilities plus the tail mass at every position (`--ref-out`); `kl_halogen.py` reads that, takes #260's reference
logits, and computes KL(reference ‖ candidate) over the candidate's 128 tokens plus one bucket for the rest. That is a lower
bound. Applied to GSQHalo's own saved IQ4_XS logits from #260 it reads **7.2 % below the full-vocabulary KL** (0.0889 vs
0.0958 over all 64 chunks), so scale these by about 1.08 when comparing with full-vocabulary rows (v2 ≈ 0.104, BYO ≈ 0.095).
The scored positions, floor and bucket follow #276's `kl_strata.py` (vendored readers; #276's branch is unmerged). The engine
ran the 64 chunks as sequences of 2048 with the state reset, as `--seq 2048`, with its chunk-1024 prefill kernels; Halogen's
README says its numbers are not `llama-perplexity`'s. PPL here is over positions 1024–2046 of each chunk, as #260's.
Quantisation noise and the engine are not separable: v2 is a different quantisation of the model, BYO is the same GGUF as #260
through a different engine.

**Tasks (#260's 16-task set, thinking off, sampled at the model card's settings)**:

| | v2 | BYO (unconfirmed) |
| --- | ---: | ---: |
| greedy, all | 16/16 | 14/16 (2 request errors) |
| sampled, all | 75/76 | 70/76 (6 request errors) |

BYO's failures are all on the two ~120K-token tasks and are connection resets ("Remote end closed connection"); every
other task passed. The cause was **not established**: the re-run that would have captured the
container log was cancelled. BYO held 72.5 GiB anonymous with 25.9 GiB left at the lowest point, which is the nearest
suspect and nothing more. v2 completed both tasks without error.

## Checks added by the dispatcher (v2 and BYO ran them; the table is v2)

- **Sampling defaults.** A request that sends no `temperature` decodes greedy (3/3 identical); `server_defaults` is empty
  because no `HALOGEN_TEMPERATURE` was set. A sampled request that omits `top_k`/`top_p` gets 20 and 0.95 (from the model's
  `generation_config.json`, reported in `/health` under `sampling.filter_defaults`). Request values win: with
  `temperature: 1`, `top_k: 1` and `top_p: 0.01` each gave 3 identical outputs of 3, a `seed` reproduced, `min_p` was accepted,
  and without a filter 4 of 4 outputs differed. A `repetition_penalty` on a greedy request is a 400.
- **The literal tool-call token as text.** Asked to copy `<tool_call>{...}</tool_call>` and then write `DONE`: with **no
  tools** in the request the text came back intact and the reply reached `DONE` (streamed and not). With **tools enabled** the
  server parsed the written token as a real call: `finish_reason: "tool_calls"`, empty content, and `DONE` never arrives
  (streamed and not). A spurious tool call that truncates the reply, the same behaviour #276 found for Strata.
- **Speculation on and off.** Greedy output with `"drafter": "mtp"` (plus prompt lookup) and `"drafter": "serial"` is
  token-identical on 6 of 6 prompts (same completion token counts), with 22–70 draft tokens proposed on the speculative side
  and none on the serial side. Both arms.

## Egress and Security (owner question: does the closed image phone home?)

1. **Audit.** For a full container lifetime of the audit row (start, weight pin, tool call, prefill, decode, vision and the checks, stop) the host-side
   `passt` process's sockets were sampled with `ss -tunp` about once a second, recording every connected non-loopback
   peer: **none**. The sampler is validated by a TCP positive control: a container deliberately connecting to a public
   address shows up (`tcp <host LAN address> -> 1.1.1.1:443`). Limits: one-second sampling can miss a shorter flow;
   unconnected UDP sockets, ICMP and a loopback resolver stub were not recorded by the sampler that ran, and no UDP
   positive control was run; hostnames are not visible. Only the audit and offline rows were sampled (the co-tenant and
   `ppl` containers were not), and the audit row's network was podman's default (pasta NAT). The offline row is the
   stronger evidence: a container with no route out loaded and served.
2. **Offline run.** A representative v2 row (tool call, prefill 4K, decode, vision, and the checks) ran on an `--internal`
   netavark network with the port still published to 127.0.0.1. From inside the container, a connection to `1.1.1.1:443` and a
   lookup of `huggingface.co` both failed; Halogen loaded, served and passed every check, with no licence check and no
   download. (A pasta network with its DHCP/RA options off does *not* cut egress, because podman configures the address and
   routes itself; the internal network does.)
3. **What Halogen says.** Its licence, section 5 "No telemetry": "The Software performs no telemetry, no license checks, and no
   usage reporting, and it makes no callback to us of any kind. We receive no information whatsoever about your use of it,
   and there is no configuration that changes that. By default it opens no outbound network connections at all … if you set
   `HALOGEN_DOWNLOAD`, the Software fetches model weights at startup from the repository you name." The README repeats that with
   `HALOGEN_DOWNLOAD` unset the container opens no outbound connections. The licence permits benchmarking and publishing
   with no approval (section 4) and asks that figures name the version and the prompt set; both are here. The audit and the
   offline run are evidence for those statements on this image, not proof for other versions.
4. **Remaining exposure.** `--ipc=host` (the image's documented run line; whether the image works without it was not
   tested): the container shares the host IPC namespace **and gets the host's `/dev/shm` read-write**, so the closed image
   can read and modify every shared-memory file the user's session owns (browser, audio and game segments on a desktop
   host), and in rootless podman its root is that user. `--group-add keep-groups` adds the user's supplementary groups.
   `/dev/kfd` and `/dev/dri` (the kernel driver attack surface, as with any GPU container). A writable scratch mount for
   the `ppl` mode only (`/ppl`, outputs; the token ids are a separate read-only mount; the serving container mounts
   models read-only). An unauthenticated engine protocol, which the run line keeps off the network (the engine port is
   not published; the API port is bound to 127.0.0.1). No `--memory` or `--pids-limit` is set; the memory floor in
   `halogen.py` kills the container below 6 GiB MemAvailable. The image is
   pinned by digest, so a tag move cannot change what runs; whoever updates the pin must repeat the audit.

## Co-tenant row (v2 only)

A 20 GiB anonymous-memory holder (a process that allocates and touches 20 GiB; **not a build**) ran beside the loaded v2
container, abort at MemAvailable < 6 GiB. The row completed: the holder reached 20 GiB, MemAvailable fell from 107.0 to
86.1 GiB (lowest 85.4), swap stayed at 1.65 GiB, the request with the load held completed at 56.7 t/s decode (time to first
token 17.5 s, the weights' first touch), and GTT returned to baseline after stop. The floor was not breached. The BYO arm
was **not** co-tenant tested: its lowest MemAvailable was already 25.9 GiB, so 20 GiB more would have reached the floor. CPU
and disk contention from a real build were not tested.

## The `podman run` line

```
podman run -d --rm --name <name> --label bench=halogen258 --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 -v <models>:/models:ro -p 127.0.0.1:<port>:8731 \
  -e HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn -e HALOGEN_CTX=131072 -e HALOGEN_KV_SLOTS=2 \
  -e HALOGEN_MAX_TOK=16384 -e HALOGEN_VISION_TOWER=1 \
  ghcr.io/peonist-ai/halogen-flash-server@sha256:0c61bf84ac22308a53f5d1ca6b86806702d7039e5ebc51cae4c66621b92fe04a
```

The default network is podman's (pasta NAT, outbound allowed). The offline row adds `--network <an --internal netavark network>`;
a lemond backend should always do that. Rootless podman reached the GPU nodes with
`--group-add keep-groups`, so the docker fallback was not used. No capability was added and the network is podman's default
(pasta NAT) except for the offline row. `<models>` holds `qwen38-flash-next-v2.hgn`, `-ngram.hgn`, `-mtp.hgn`, `-vision.hgn`
and `tokenizer/`, fetched at Hugging Face revision `af037250` with sha256 checked against the repository's LFS digests. The BYO arm
mounts a directory with the UD-IQ4_XS shards (hard links to the existing files), the head, the vision file and the tokenizer,
and names shard 1 in `HALOGEN_CHECKPOINT`.

**Disk:** 113 GiB for the v2 set (the BYO arm adds none). If Halogen is not adopted, the whole `<models>` directory and the
image (3.6 GB) can be deleted.

## Limits and what was not measured

- One row per cell, one request at a time. The decode rows are prose, not agent text.
- The KL estimator is a lower bound (7.2 % below full-vocabulary on GSQHalo's logits; the bias for Halogen's own
  distributions was not measured).
- Q8_0 is not BF16; #260's caveat applies.
- The #249 greedy exact-match against Vulkan was not run (the reference rows are not in the repo); the 10/10 sanity and the
  speculation identity check are what ran.
- Concurrency (four slots), thinking on, 256K context, the vision encoder at larger images, the n-gram table's paging cost
  under memory pressure, and an IOMMU-off comparison were not measured.
- A decode re-measure on code and agent turns, and a soak, would be needed before this could be resident.
- Review hardening landed after the rows ran and was not re-run on the GPU: the container is registered before
  `podman run`, the memory floor is watched during the model load, teardown raises if the container is still listed,
  `--env` accepts only `HALOGEN_*=value`, the offline network must be `--internal`, the token ids are mounted read-only,
  and `rows.sh` checks for a leftover container before each stage. None of it changes what a row measures. `run.sh` still
  reloads lemond on its own as soon as the child exits (a SIGKILLed child while a container runs is the case nothing
  here covers).

## Reproduce

From the repo root, with `W` (work dir outside the repo), `CACHE` (the #249/#252 corpus cache), `PODMAN_DIR` (PATH entry with
podman and the `newuidmap` wrappers), `MODELS_V2`/`MODELS_BYO`; the stages go through `run.sh`'s `exec` preset:

```sh
H=bench-logs/qwen38-flash-next-halogen-2026-10-07
$H/rows.sh smoke v2        # tool call, 4K prefill, decode 512, vision, the checks
$H/rows.sh rows v2         # the full harness rows
$H/rows.sh tasks v2        # #260's 16 tasks
python3 $H/kl_halogen.py ids --ref <q260 ref.logits> --out ids.bin   # token ids of #260's eval text
IDS=ids.bin REF=<q260 ref.logits> KL_PY=<python with numpy> $H/rows.sh ppl v2
python3 $H/kl_halogen.py compare --ref <q260 ref.logits> v2=$W/ppl/halogen-v2.href
LOAD_GIB=20 $H/rows.sh cotenant v2
python3 $H/tables.py $W   # the tables above
$H/rows.sh audit v2        # egress audit;  $H/rows.sh offline v2   # no route out
python3 $H/test_halogen.py; python3 $H/test_kl_halogen.py   # offline tests
```
