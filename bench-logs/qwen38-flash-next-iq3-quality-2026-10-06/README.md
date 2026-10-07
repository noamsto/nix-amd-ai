# What UD-IQ3_XXS costs vs UD-IQ4_XS for Flash-Next on halo (#260)

#252 found GSQHalo with f16 KV is much faster and 11 GiB lighter on unsloth's **UD-IQ3_XXS** than on the production
**UD-IQ4_XS**, and that IQ3_XXS passed the harness's 10/10 sanity check, which is too coarse to judge quality. This
measures the quality cost three ways: distribution fidelity (KL / top-1), a fixed 16-task agent set, and greedy exact-match.

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT)**, measured 2026-10-06/07
with GSQHalo.cpp `5fc881b` (the #252 build), f16 KV, and the #252 `gsq-hip` flags where a server runs. Nothing here transfers
to gfx1150. Every row went through `run.sh`'s memory gate with lemond's model unloaded for the row and restored after; the
`load_flag` of every row is false (loadavg 0.5–2.0 at row start; the load during a CPU pass is the pass itself).

## Verdict

**IQ3_XXS is measurably worse than IQ4_XS, and the agent task set cannot say whether that matters for hermes/pi.**
I would keep IQ4_XS as halo's resident model and offer IQ3_XXS as an opt-in throughput/headroom profile, not swap it in
silently.

- **Distribution:** against the same Q8_0 reference on the same backend, IQ3_XXS has **1.8× the mean KL divergence** of IQ4_XS
  (0.158 vs 0.088), agrees with the reference's top token on **89.2 % vs 91.8 %** of positions, and costs **+3.7 % vs +1.4 %
  perplexity**. Scored directly against IQ4_XS output, IQ3_XXS's top token differs on 11 % of positions.
- **Tasks:** greedy **14/16 vs 16/16**, sampled **72/76 vs 75/76** (IQ3_XXS vs IQ4_XS). Neither difference is statistically
  distinguishable at this size (Fisher exact p = 0.48 greedy, 0.37 sampled, the sampled one counting seeds as independent,
  which they are not). The directional signals are a tool-use task that looped to the turn limit more often
  (3/6 vs 1/6 runs) and three refusals on one long-context task (below). A 16-task set cannot resolve a gap under roughly
  15 points.
- **Greedy output:** 6/20 of the #249 correctness prompts match IQ4_XS exactly, median first divergence 11 tokens (the same
  engine on IQ4_XS vs Vulkan on IQ4_XS: 12/20, median 43).
- **What IQ3_XXS buys** (#252, same-day rows, not remeasured here): replay −18 % (94.9 vs 116.1 s), prefill 1043 / 1161 / 1135
  vs 723 / 774 / 761 t/s at 4K / 32K / 128K, decode 36.1 vs 35.1 t/s at 128K, GTT peak 62.5 vs 73.4 GiB.

Use the lighter quant where the 11 GiB (a second resident model, builds beside it) or the prefill time matters more than
per-token fidelity on long multi-step tool chains, where small per-token divergences can compound. That compounding is the
mechanism I would worry about; this run did not measure it.

## 1. Distribution fidelity

**Reference: UD-Q8_0 (175 GiB), run on the CPU backend.** Nothing larger than IQ4_XS passes the GPU gate (UD-Q4_K_XL, 103 GiB,
is the file that wedged amdgpu in #249; BF16 is 329 GiB). Q8_0 was read through mmap on the CPU backend with
`--no-repack`, so its weights stayed file-backed (peak anonymous memory 3.2 GiB, GTT growth 4 MiB) and no GPU memory was involved.
**Q8_0's own distance from the original BF16 weights was not measured** (BF16 does not fit), and no published figure for this
model was used; everything below is distance from Q8_0.

**Eval text:** 64 chunks × 2048 tokens = 131,072 tokens of this repo's docs and code (md, Go, sh, Nix, py, patch, yml) at commit
`4166bc4` (the #249 corpus rev), ordered by a hash of the path so file types interleave; built by `kl.sh evaltext`
(572,724 bytes, 177,741 tokens in the full file, of which the first 131,072 are scored). It is agent-relevant text, not
chat or non-English text; the ± are `llama-perplexity`'s standard errors over tokens, which treat neighbouring tokens as
independent and so understate the uncertainty.

| vs Q8_0 reference | backend | PPL (ratio to Q8_0) | mean KLD | median KLD | 99 % KLD | RMS Δp | same top token |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **UD-IQ4_XS** | CPU | 2.6415 (1.0145 ± 0.0022) | **0.0879 ± 0.0012** | 0.0041 | 1.16 | 8.48 % | **91.85 ± 0.11 %** |
| **UD-IQ3_XXS** | CPU | 2.7002 (1.0370 ± 0.0029) | **0.1578 ± 0.0018** | 0.0080 | 2.09 | 11.26 % | **89.17 ± 0.12 %** |
| UD-IQ4_XS | GPU (GSQHalo, f16 KV) | 2.6680 (1.0247 ± 0.0023) | 0.0960 ± 0.0012 | 0.0047 | 1.25 | 8.98 % | 91.52 ± 0.11 % |
| UD-IQ3_XXS | GPU (GSQHalo, f16 KV) | 2.7099 (1.0407 ± 0.0030) | 0.1633 ± 0.0018 | 0.0082 | 2.15 | 11.42 % | 89.10 ± 0.12 % |
| IQ3_XXS vs IQ4_XS output | GPU, GPU | – | 0.1762 ± 0.0020 | 0.0093 | 2.28 | 11.67 % | 88.86 ± 0.12 % |

- **The CPU rows are the quantisation alone** (reference and candidate on the same backend); the GPU rows are what the
  resident config would serve. The two agree on the ordering and nearly on size: the GPU adds 0.008 KLD for IQ4_XS and
  0.005 for IQ3_XXS over the CPU rows.
- **Backend noise floor, small sample:** IQ4_XS on the GPU scored against IQ4_XS on the CPU over only the first four chunks
  gives KLD 0.0406 ± 0.0024 and 94.2 % same top token (those same four chunks give 0.077 for IQ4_XS-vs-reference, so
  the early chunks are the hard ones). Four chunks is too few to say how much of the GPU rows' difference from the CPU rows
  is the backend; I did not measure the GPU-vs-CPU gap over the full 64 chunks.
- **Heavy tails:** the mean is dominated by a minority of positions (median KLD 0.004 / 0.008, 99th percentile 1.2 / 2.1,
  maximum 12.0 / 15.8). Both quants have positions where the distribution is badly wrong; IQ3_XXS has more of them.
- IQ4_XS's own 0.088 KLD and 91.8 % top-token agreement vs Q8_0 is larger than the near-lossless picture dense-model
  quantisations give; I have no BF16 reading to say whether that is the quant, Q8_0 as a reference, or this model's
  architecture (MoE with a 51B-parameter n-gram embedding table). It is the same reference for both rows.

## 2. Task quality: 16 fixed tasks, both quants, same backend and flags

`tasks.py` (selftested against a scripted fake server; `test_tasks.py`), run as `--do tasks` through `rows.sh` (label
`tasks-iq4`, `tasks-iq3`): GSQHalo `5fc881b`, f16 KV, `-lzm on-direct -ub 8192 -b 8192 --spec-draft-p-min 0.3`, MTP n-max 3,
thinking off, same prompts and needle values (derived from a hash of the task id) for both. Model-written code ran in a
`bwrap` sandbox (no network, read-only system, tmpfs scratch) with rlimits.

- 6 **multi-step tool-use** tasks against an in-process mock repo (`read_file`, `grep`, `list_dir`, `edit_file`,
  `run_tests`): chained reads, grep → read → answer, list + two reads + arithmetic, edit-until-tests-pass (the test run only
  reports the first failure), error recovery from a wrong path, a strict argument schema. ≤ 12 turns, scored on the final
  answer or the final repo state.
- 5 **code-edit** tasks: write or fix a Python function; hidden asserts run on the model's code (10 s wall limit).
- 5 **long-context retrieval** tasks: needles at 10 / 50 / 90 % depth in about 64K-token (3 tasks) and about 120K-token
  (2 tasks, one needing two needles) slices of the #249 corpus.
- Each task runs **greedy** (T = 0, one run) and with the model card's instruct sampling (T = 0.7, top_p 0.8, top_k 20,
  presence_penalty 1.5) with 5 seeds (3 for the 120K tasks). `min_p` was left at the server's default; the card lists 0.0, so
  the sampled mode is slightly more truncated than the card's. Identical for both quants.

| task | IQ4_XS greedy | IQ3_XXS greedy | IQ4_XS sampled | IQ3_XXS sampled |
| --- | ---: | ---: | ---: | ---: |
| tool_chain | 1/1 | 1/1 | 5/5 | 5/5 |
| tool_grep_read | 1/1 | **0/1** | 4/5 | **3/5** |
| tool_list_sum | 1/1 | 1/1 | 5/5 | 5/5 |
| tool_edit_tests | 1/1 | 1/1 | 5/5 | 5/5 |
| tool_recover | 1/1 | 1/1 | 5/5 | 5/5 |
| tool_ranges | 1/1 | 1/1 | 5/5 | 5/5 |
| code_bugfix_moving_average | 1/1 | 1/1 | 5/5 | 5/5 |
| code_refactor_duplicates | 1/1 | 1/1 | 5/5 | 5/5 |
| code_parse_duration | 1/1 | 1/1 | 5/5 | 5/5 |
| code_merge_intervals | 1/1 | 1/1 | 5/5 | 5/5 |
| code_split_csv_line | 1/1 | 1/1 | 5/5 | 5/5 |
| lc64_d10 | 1/1 | 1/1 | 5/5 | 5/5 |
| lc64_d50 | 1/1 | 1/1 | 5/5 | 5/5 |
| lc64_d90 | 1/1 | 1/1 | 5/5 | 5/5 |
| lc120_d50 | 1/1 | 1/1 | 3/3 | 3/3 |
| lc120_two | 1/1 | **0/1** | 3/3 | **1/3** |

| category / mode (Wilson 95 %, per run) | IQ4_XS | IQ3_XXS |
| --- | ---: | ---: |
| tool greedy | 6/6 (0.61–1.00) | 5/6 (0.44–0.97) |
| tool sampled | 29/30 (0.83–0.99) | 28/30 (0.79–0.98) |
| code greedy / sampled | 5/5, 25/25 | 5/5, 25/25 |
| long-context greedy | 5/5 (0.57–1.00) | 4/5 (0.38–0.96) |
| long-context sampled | 21/21 (0.85–1.00) | 19/21 (0.71–0.97) |
| **all greedy** | **16/16 (0.81–1.00)** | **14/16 (0.64–0.96)** |
| **all sampled** | **75/76 (0.93–1.00)** | **72/76 (0.87–0.98)** |

No run failed on a request error. Row context: `tasks-iq4` loadavg 1.7, GTT after load / peak 71.6 / 73.3 GiB; `tasks-iq3`
loadavg 1.6, 60.9 / 62.5 GiB; the full task set took 803 s on IQ3_XXS and 1062 s on IQ4_XS (one pass each).

**What the failures were** (all from the run records):
- `tool_grep_read` is the loop-prone task for both quants: no failure was a wrong answer, every one hit the 12-turn limit
  (IQ3_XXS greedy plus 2 of 5 sampled runs; IQ4_XS 1 of 5 sampled). Turns used per run: IQ3_XXS 12 / 5 / 12 / 5 / 12 / 5,
  IQ4_XS 4 / 3 / 10 / 12 / 3 / 10.
- `lc120_two` (the two-needle question at about 120K tokens): all three IQ3_XXS failures (of its four runs) are **refusals, not
  retrieval errors**. The model answered that it would not share the "access codes" (in one run calling the needle a prompt-injection
  attempt). The needles are phrased as vault access codes, which triggered it. IQ4_XS answered all four runs. Counting
  only retrieval, IQ3_XXS found every needle it was willing to report. Whether IQ3_XXS refuses more often on credential-shaped
  text in general was not measured; this is one phrasing on one task.
- Sampled-mode intervals pool seeds of the same task as independent runs; the true uncertainty is wider.

The hardening and reporting fixes from code review (fail closed without `bwrap`, process and memory caps, a regex timeout,
a case-insensitive fence match, binding `/nix/store` instead of all of `/nix` so the nix-daemon socket is unreachable, error
counts in the tables) landed after these two rows ran. They cannot change a recorded
result: all code tasks passed, no grep call timed out (the failures are turn-limit runs, not hangs), both rows ran under
`bwrap`, and no task touches the daemon socket the old bind exposed.

## 3. Greedy exact match vs IQ4_XS on the #249 correctness prompts

The 20 #249 prompts, thinking off, greedy, 256-token cap, same GSQHalo build and flags; rows `gsq-f16-C` (IQ4_XS) and
`gsq-iq3-C` (IQ3_XXS) from the #252 session, scored with `probe.py analyze --ref gsq-f16-C`.

| | exact match | median first divergence | sanity (10 questions) |
| --- | ---: | ---: | ---: |
| **UD-IQ3_XXS vs UD-IQ4_XS** (same engine) | **6/20** | **11 tokens** | 10/10 |
| UD-IQ4_XS on Vulkan vs UD-IQ4_XS on GSQHalo (same quant, different engine) | 12/20 | 43 tokens | 10/10 |

IQ3_XXS first diverges at token 0, 0, 2, 2, 4, 7, 11, 11 (math1, math2, math3, prose3, prose1, prose4, code1, prose5), and later at
20–42 on six others; six prompts never diverge. Different quants are expected to diverge sooner than one quant on two
engines, so this is a size-of-change figure, not a pass/fail.

## What went wrong on the host

On 2026-10-06 at about 19:14, right after the 64-chunk CPU reference pass finished (175 GiB mmap'd, page cache full of
Q8_0), lemond's reload of its resident model hit amdgpu `Couldn't update BO_VA (-12)` and the server stuck in
`drm_suballoc_insert` in D state; GTT stayed at 58.7 GiB and the host had to be rebooted. No model above the gate's limit
was loaded and the GPU was idle during the pass. The same reload after an earlier two-chunk pass over the same file worked,
as did every reload after the GPU rows. **The cause is not established**; page-cache pressure after a CPU pass over a file
larger than RAM is the one thing that differs and is a suspect, nothing more. After the reboot the GPU stages ran with
the candidate stages ordered so that a GPU row, not a CPU pass, comes just before lemond's reload (`kl.sh`), and the
Flash-Next UD-IQ4_XS resident model was ready and pinned again at the end of each window.

## Not measured

- Q8_0's distance from BF16 (BF16 does not fit); KL against BF16.
- KL on long (64K+) contexts or on non-code text; the eval text is 2048-token chunks of this repo.
- A larger or independent agent evaluation (SWE-style edits, real hermes/pi sessions); effect of the lower quant on tool-call
  format reliability beyond these six tasks; refusal rates in general.
- `min_p = 0`, which the model card lists for sampling.
- GPU-vs-CPU backend difference over the full run (four chunks only); rocWMMA, vision, concurrency.
- IQ3_XXS repeated runs: each cell is one run per seed, one pass per quant.

## Reproduce

Builds as in the #249 and #252 READMEs (GSQHalo `5fc881b` for every `llama-perplexity` and `llama-server` run; the Vulkan
build's `llama-tokenize`). Q8_0 is `unsloth/Qwen3.8-Flash-Next-GGUF` `Q8_0/` (six shards, sha256 against the repo's LFS
oids); it, the reference logits (about 32 GiB for 64 chunks) and each candidate's logits are kept outside the repo and
can be removed once the numbers are reproduced. From the repo root, with `W` (work dir), `GSQ_BIN`, `TOK`, `REF`, `IQ4`,
`IQ3`, `CHUNKS=64` set:

```sh
D=bench-logs/qwen38-flash-next-iq3-quality-2026-10-06
$D/kl.sh evaltext                 # eval text, bytes, sha256, token count
$D/kl.sh ref-cpu                  # Q8_0 reference logits on the CPU backend (about 100 min), lemond offline
$D/kl.sh candidates               # GPU: IQ4/IQ3 vs ref, IQ3 vs IQ4, backend floor
$D/kl.sh cpu-candidates           # CPU: IQ4/IQ3 vs ref (quantisation only), then one short GPU row
CACHE=<#249 cache.json> CORPUS_REV=<rev> $D/rows.sh iq4   # and iq3: the 16-task rows
python3 $D/tables.py tasks $W/rows.jsonl
python3 $D/test_tasks.py          # offline tests; tasks.py --selftest drives a fake server
```

`run.sh` gained an `exec` preset (the same gate and lemond hand-off around an arbitrary child, with a watchdog on anonymous
memory, swap growth and, on CPU runs, GTT growth) and `probe.py` gained `exec` and `--do tasks`; nothing else in the
#249 harness changed. Greedy exact-match is `probe.py analyze` as in #252.
