# Typed-decision models (Jev / Laya) next to local LLMs — exploration spec

**Status:** draft, pre-plan (revision 1 after spec-critic)
**Date:** 2026-09-22
**Closes:** #149
**Host for any measurement:** halo — Ryzen AI MAX+ 395 (Strix Halo, gfx1151 iGPU, XDNA2 NPU fw 1.1.2.65), 32 threads, 128 GB, NixOS kernel 7.2.6, lemonade 11.9.0 running.

## Goal

Produce a **design exploration document** that ranks what typed-decision models
(TypeSafe Jev, open-weight Laya) could do *together with* the local LLMs this
flake ships, and — for the idea the ranking puts first — a **throwaway
prototype** that produces measured numbers or kills it. Nothing in this task
changes a production package or module.

## Non-goals

- Packaging Laya, ort-server, or a ROCm torch for Laya as a flake output.
- Any change under `pkgs/`, `modules/`, or `flake.nix` outputs.
- Fine-tuning Laya. (The doc may recommend it as a next step.)
- Calling the hosted Jev API. Jev is analysed from its documentation only
  (no API key on this host); every Jev figure in the doc is marked "published,
  not measured here".
- Benchmarking Laya on the iGPU or NPU. A ROCm torch is not realised on this
  host (`pkgs/vllm-rocm` would fetch a 7.6 GB bundle) and the NPU has no path
  for a BERT-family encoder (see Facts). Those cells stay **unmeasured**.

## Citation form

lemonade facts cite `lemonade-sdk/lemonade@v11.9.0:<repo-relative path>:<line>`
— the tag `pkgs/lemonade/default.nix` fetches (`rev = "v${version}"`). The
same tree is unpacked at `/nix/store/9viywx7wzwl7fkrpi00wxwmy1rjznfgb-source`
on halo, which is how the lines below were read; the store path is not
reader-stable and does not appear in the doc. Laya facts cite
`NandhaKishorM/laya@v0.3.5:<path>`.

## Facts the doc must build on (verified this session)

The doc may not claim more than these support.

**lemonade 11.9.0**

- `collection.router` policies: ordered rules, first match wins, fall-open to
  `default_model`. Deterministic conditions (`keywords_any`, `regex`,
  `min_chars`, `min_total_chars`, `has_tools`, `has_images`, `metadata`) and
  model-backed ones (`semantic_similarity` via an embedding model, `classifier`
  via `/v1/classify` or LLM-as-classifier, `llm` label pick). —
  `docs/dev/router-policy.md`.
- `metadata` is a deterministic condition over the OpenAI `metadata` field of
  the request (`{key, equals|any|exists}`) — `docs/dev/router-policy.md:75`.
  A caller-side component can therefore drive routing without lemonade
  running any model.
- `POST /v1/routing/validate` evaluates a policy against a prompt and returns
  the decision + trace without registering it; model-backed conditions do
  load and run their models — `docs/api/lemonade.md:117-141`. A judge model
  used this way is loaded into the routing-helper pool on the shared host.
- Every routed response carries `x-lemonade-route`; `"route_trace": true`
  attaches the full trace — `docs/dev/router-policy.md:218-238`.
- `ModelType::CLASSIFICATION` exists (`src/cpp/include/lemon/model_types.h:58`);
  the router calls `/v1/classify` only for models of that type and otherwise
  falls back to LLM-as-classifier via chat —
  `src/cpp/server/routing_classifier_services.cpp:276-304`,
  `src/cpp/include/lemon/routing_classifier_services.h:24-31`. **Contradiction
  to flag in the doc:** `docs/api/lemonade.md:56` still says the live
  routing-policy wiring "is tracked in #2384"; the code above is the wiring.
  The doc cites the code and notes the stale sentence rather than picking one.
- The only `/v1/classify` backend is `onnxruntime` → prebuilt
  `lemonade-sdk/ort-server`, CPU EP only, contract
  `POST /classify {text} -> {"labels": {label: score}}` —
  `src/cpp/server/backends/onnxruntime/onnxruntime_server.cpp:109-118`;
  `docs/dev/backends-reference.md:19,52-54`. There is no `onnxruntime_bin`
  override (only `onnxruntime_args`, `docs/dev/backends-reference.md:131-135`),
  unlike `llamacpp.rocm_bin` / `vllm.rocm_bin` which `modules/amd-npu.nix`
  uses.
- `/v1/classify` accepts only BERT, DistilBERT, RoBERTa, XLM-RoBERTa, DeBERTa,
  ELECTRA, ALBERT, CamemBERT; other families are **rejected at load** —
  `docs/api/lemonade.md:47-56`. ModernBERT (Laya's encoder) is not on the list.
  Laya's heads also take marker positions and a question-type id per forward
  (`laya/agent.py:295-301`), so it is not a plain sequence-classification
  export with labels fixed at export time.
- Routing helpers live in a separate residency pool; an internal routing load
  never evicts a resident model (HTTP 409 `router_residency_conflict`) —
  `docs/guide/configuration/multi-model.md:23-61`.
- `flm` on the NPU may hold 1 LLM + 1 embedding model + 1 ASR at once —
  `docs/guide/configuration/multi-model.md:69`. `flm list` on halo offers
  `embed-gemma:300m` as **downloadable, not pulled**; an NPU-resident
  embedding model for `semantic_similarity` is therefore a documented path
  that is unmeasured here.
- This host's `/api/v1/health` reports `max_models.classification: 1` and
  `pinned_helper_models` — the pools above are live on halo.
- Models pulled on halo: `llama3.2-1b-FLM` (NPU), `Qwen3.5-4B-GGUF`,
  `Ornith-1.5-9B`, `Qwen3-Coder-30B-A3B-Instruct-GGUF`, `Qwen3.8-27B-GGUF`,
  `gpt-oss-120b-mxfp-GGUF`, `DeepSeek-V4-Flash-0731-GGUF` (llamacpp).

**Laya v0.3.5** (https://github.com/NandhaKishorM/laya, Apache-2.0, released 2026-09-21)

- Three checkpoints under HF `convaiinnovations/laya`: root (ModernBERT-large
  421M, 512 ctx, English), `multilingual/` (mmBERT-base 322M, 1024 ctx),
  `typed-decisions/` (ModernBERT-large, 1024 ctx). Context splits into a
  `head_max_len` option budget (192 / 256) and the remaining state budget
  (~320 / ~768 tokens) — README "Honest limits".
- API: `laya.load(repo, device=, subfolder=)` → `agent.predict(state,
  questions)`; all questions of a request answered in **one forward pass**;
  primitives `choice` (probabilities + confidence), `score` (ordinal rubric),
  `noul` (P(true)). Presets `router_questions()`, `guard_questions()`,
  `triage_questions()`, `moderation_questions()` (`laya/presets.py`).
- Device handling knows only `cuda` / `mps` / `cpu` (`laya/agent.py:166-182`).
  A ROCm torch presents as `cuda`, so the code path exists but is unmeasured.
- Deps: `torch>=2.0`, `transformers>=4.48`, `safetensors`, `huggingface_hub`,
  `numpy` (`pyproject.toml`). Pure Python, 8 files.
- Published figures (T4 GPU, upstream's run — not ours): 32.8–39.5 ms for one
  question, 7.2 ms/question batched ×10; CPU 193–464 ms per request with
  preload (host unspecified). **None of these transfer to halo.**
- Published limits: base checkpoints are *near chance zero-shot* on the
  typed-decisions benchmark (0.36 vs 0.318 random, 0.461 majority); the 0.766
  figure is the fine-tuned checkpoint. Over-confident as shipped (ECE 0.466 →
  0.081 only after temperature refit); `multilingual` ships no temperatures.
  `score` is the weakest primitive (SST-5 0.372). Prompt-injection held-out
  0.698. >20-option `choice` degrades (Banking77 0.425 vs Jev 0.870).
- Laya's own comparison to Jev uses third-party Jev numbers (236–276 ms p50).

**Jev 1.13** (https://docs.typesafe.ai/, verified by the dispatcher 2026-09-22
and re-read this session)

- Hosted only, `POST /v1/systemone`; no weights; $42 per 1B input tokens,
  output free; 64k context; same three primitives; up to 255 options.
- Documented jaggedness (https://docs.typesafe.ai/model-jaggedness/jev-1.13):
  literal reading; math/counting/numeric encodings; date comparison;
  indirection; distractor-heavy state; adversarial content; contradictory
  instructions/criteria; no structural invariants across questions
  (P(noul) ≠ 1 − P(not noul), probabilities not comparable across questions);
  no generation.

**This host:** system `python3` has no torch/transformers; the flake-pinned
nixpkgs substitutes `python3.14-torch-2.13.0` (CPU) and
`transformers-5.17.0` (no local build). Network reachable. lemond active.
HF dataset `allenai/ai2_arc` is served as parquet (`ARC-Easy/`,
`ARC-Challenge/` splits), which gives a public labelled multiple-choice set
with a coarse difficulty label and a gradeable answer key.

## Deliverable 1 — `docs/research/typed-decisions-local-models.md`

Structure (fixed so the plan can be checked against it):

1. **TL;DR** — top recommendation, its kill criterion, effort range, and the
   prototype's verdict (proved / killed / unmeasurable, with the number).
2. **What a typed-decision model is, in one paragraph** — and the one-line
   rule for when it beats "just ask the LLM": a *closed* semantic question
   whose answer must be a calibrated probability, on a short state, where the
   LLM's own answer would be slower, un-calibrated, or need parsing.
3. **Constraints table** — Jev vs Laya vs lemonade's existing model-backed
   conditions (`llm`, `semantic_similarity`, `classifier`), with the facts
   above. Includes the *division-of-labour* rule: code/LLM does math, dates,
   counting, de-duplication; the typed model gets a pre-digested state.
4. **Where Laya could run on our hardware** — CPU torch (measured by the
   prototype), ROCm torch on the iGPU (unmeasured; path exists via
   `device="cuda"`), ort-server (blocked: architecture allowlist + non-standard
   heads), NPU (no path: FLM's model list is fixed and lemonade's XDNA ONNX
   route is Windows-only). The budget *next to a resident LLM* is stated from
   measurement where the prototype has it (the contention arm below) and
   marked **unmeasured** where it does not — power in particular is unmeasured
   unless the run reads RAPL.
5. **Ideas** — at least eight, each with: mechanism · why typed beats
   ask-the-LLM · which jaggedness bites · fit with lemonade/the flake · cost to
   try (range) · kill criterion · **measurable on halo today? (yes/no + how)**.
   Seed list (the doc may add, merge, or demote):
   - **I1 Calibrated route signal for lemonade's router.** Laya
     `router_questions()` (difficulty `score`, domain `choice`, needs-tools
     `noul`, high-stakes `noul`) decides NPU 1B / iGPU 4B–9B / iGPU 30B–120B
     per request. Two integration shapes, both honest to the facts: (a) a
     caller-side shim that sets request `metadata` and a policy that routes on
     `metadata` — zero lemonade changes; (b) a future lemonade `classifier`
     backend for Laya — needs upstream work (allowlist + head contract), listed
     as the follow-up, not assumed.
   - **I2 Cascade / "should the big model run?"** The small model answers
     first; Laya `noul` "is this answer adequate for this request?" decides
     whether to re-run on the big model. Calibration lets an operator set a
     target escalation rate.
   - **I3 Grounding `noul` over retrieved context** (per-claim NLI:
     "is this sentence supported by this passage?"). Fits the 512-token state
     if chunked per claim; base checkpoint has XNLI 0.86 (en).
   - **I4 Pre-LLM guardrail / tool-call precondition** with
     `guard_questions()` before the LLM runs, composed with lemonade's
     `has_tools` leaf as the docs' `risky-tool-calls-stay-local` rule does.
   - **I5 Best-of-N verifier / reranker** with `score` over N candidates in
     one batched forward.
   - **I6 Agent stop/continue and trace-observability decisions** ("did the
     agent finish?", "is it looping?") — Laya's typed-decisions checkpoint was
     trained on an agent-trace workflow (0.730).
   - **I7 Coherence canary for the benchmark harness** — a `noul` "is this
     output a coherent answer to the prompt?" as a `pkgs/benchmark-go`
     preflight/results column, so a silently broken backend (the gfx1151 ROCm
     garbage-token bug, `docs/rocm-gfx1151-numerics.md`) fails a run without
     a perplexity reference.
   - **I8 Local eval grading** — proper-scoring-rule judge for A/B runs
     (MTP vs non-MTP equivalence, quant regressions) where the question is
     closed ("same answer?") rather than open ("which is better?").
   - **I9 Semantic-similarity on the NPU, the zero-new-software baseline** —
     lemonade's existing `semantic_similarity` condition with
     `embed-gemma:300m` on FLM. Documented, not pulled on halo, unmeasured;
     the doc presents it as the cheapest alternative to compare against, not
     as a measured bar.
6. **Ranking** — a table scoring each idea on evidence-of-value, fit, cost,
   jaggedness exposure, and measurability; pick the top 1–2 and say why the
   rest lose. **The ranking is written before the prototype runs** and is not
   revised by its result; the prototype's verdict lands in §1 and §8.
7. **Recommended next step** — with an effort range, what is excluded, and
   where a human decision blocks progress (e.g. fine-tune or not; upstream
   lemonade PR or not).
8. **Prototype results** — what ran on halo, the numbers with host + hardware
   labels, and the cells left unmeasured, each explicitly marked.

Rules for the doc:

- Every performance number carries `(halo, CPU, 32 threads)` or the upstream
  host it was published on, or the word **unmeasured**.
- Every lemonade capability cites `lemonade-sdk/lemonade@v11.9.0:<path>`;
  nothing about lemonade is asserted from memory.
- Jev is never described as runnable locally; Laya's base checkpoints are
  never described as zero-shot decision engines (upstream says the opposite).

## Deliverable 2 — throwaway prototype under `experiments/laya/`

**Selection rule:** prototype the idea §6 ranks first **if its "measurable on
halo today" cell is yes**; otherwise the highest-ranked measurable idea, and
§8 says which rank was skipped and why. If no idea in the top three is
measurable, §8 says so and no prototype is written. The rule is fixed here so
the prototype cannot bias the ranking.

**Common shape** (whichever idea is picked):

- `experiments/laya/README.md` — how to run, what it measures, that it is
  throwaway and not a flake output.
- `experiments/laya/shell.nix` — CPU torch + transformers + safetensors +
  huggingface_hub + numpy + pyarrow from the flake-pinned nixpkgs, reached
  through the repo's flake-compat `default.nix` (a `shell.nix` cannot take
  `--inputs-from`), with Laya's package vendored by `fetchFromGitHub` pinned
  to tag `v0.3.5` **with its sha256**, placed on `PYTHONPATH`. No pip at
  runtime. Weights and the dataset are fetched from HF at run time into the
  user's HF cache; nothing large is committed.
- `experiments/laya/bench.py` — prints every number prefixed with hostname and
  CPU model; reports checkpoint load time and warm p50/p95 per-request latency
  over ≥100 requests.
- Uses only models already pulled on halo for any lemonade call; never pulls.
- Contention arm (optional, run if time allows, else marked unmeasured):
  repeat the latency measurement while `llama3.2-1b-FLM` is generating on the
  NPU and while `Qwen3.5-4B-GGUF` is generating on the iGPU, so §4 can state
  the cost next to a resident LLM from measurement.

**Measurement design and numeric kill criteria per candidate idea** (only the
selected one runs; the rest are recorded in §5 as the design that *would* run):

- **I1 / I2 (shared arm — "does the difficulty signal predict small-model
  failure?")** Small candidate under test: `llama3.2-1b-FLM` — the NPU model
  a router would keep requests on, and one that errs often enough on ARC to
  yield positives. Pool: `ARC-Challenge` test + `ARC-Easy` test, filtered to
  4-choice items with keys normalised to A–D (numeric `1-4` keys mapped,
  3-/5-choice items dropped), shuffled with a fixed seed, Challenge first.
  Grade sequentially through lemonade's chat endpoint (exact letter match in
  code, model letter mapped to choice text order — no typed-model
  math/counting; **an unparseable answer — no letter, several letters, a
  refusal — counts as incorrect**, since a router cares about failure to
  answer, and its count is reported) **until ≥ 40 incorrect and ≥ 40 correct
  items are collected, capped at 400 graded items.** Pre-registered stop
  rule, decided now: 25–39 positives at the cap **proceeds** with the
  realised counts stated; < 25 positives reports "unmeasurable with this
  candidate" and stops — it does **not** switch candidate, because every
  larger resident model errs less. If the FLM path fails outright (endpoint
  error, no completions — the NPU may be held by a sibling task), the
  candidate becomes `Qwen3.5-4B-GGUF` with the same sequential rule and a
  600-item cap, and §8 says so — including that the `llm`-judge baseline is
  then the candidate judging itself (`router.model == candidate`, handled
  in-process per `docs/guide/configuration/multi-model.md:39-44`).
  Signal under test: Laya `router_questions()["difficulty"]` score (and, for
  I2, `noul` "is this answer adequate?" over the prompt + the small model's
  answer). Baselines, all on the same items: (a) the small model's **own
  logprob of its chosen letter** — the zero-extra-latency "just ask the LLM"
  alternative. lemonade exposes `logprobs` only on non-streaming
  `POST /v1/completions` (`docs/api/openai.md:220`), not on chat
  (`docs/api/openai.md:34`), so this is one extra non-stream completions call
  per item with the chat template applied by the script; marked unmeasured if
  the backend in use returns none (the FLM backend sources mention no
  logprobs, so this is expected to fire on the NPU path and be measurable on
  the 4B fallback), (b) the ARC Easy/Challenge label as
  the deterministic baseline (`min_chars` is reported too but is weak here
  because ARC prompt lengths are homogeneous — the doc says so), (c)
  lemonade's `type: "llm"` classifier with `Qwen3.5-4B-GGUF` as judge via
  `/v1/routing/validate`. Report: ROC-AUC of each signal against
  small-model-incorrect, with the realised positive/negative counts; latency
  p50/p95 for Laya (CPU) and for the `llm` judge.
  **Kill I1/I2 if** Laya's AUC < 0.65 **or** ≤ the best baseline AUC + 0.05
  (best of logprob and Easy/Challenge), **or** Laya warm p50 on halo CPU
  ≥ 250 ms — a route decision above that is no longer "milliseconds" next to
  the 1.36 s TTFT the README measured for Qwen3.5-9B on Vulkan
  (`README.md:534`; the 4B and 1B candidates' TTFT are unmeasured) — **or**
  Laya p50 ≥ the `llm`-judge p50. All thresholds are fixed before the run.
- **I3 (grounding):** 120 premise/hypothesis pairs from the public XNLI/MNLI
  English validation split via HF parquet, `noul` "is the hypothesis supported
  by the premise?"; report AUC against entailment-vs-not and latency.
  **Kill if** AUC < 0.75 (upstream's own XNLI-en 0.86 leaves headroom for
  domain shift) or p50 ≥ 250 ms.
- **I7 (coherence canary):** 60 real completions from `Qwen3.5-4B-GGUF` on
  ARC prompts + 60 synthetic garbage outputs (random tokens, repeated
  n-grams), `noul` "is this a coherent answer to the prompt?"; report AUC.
  Random-token garbage is a fair proxy for the real failure
  (`docs/rocm-gfx1151-numerics.md` describes randomised token choice from a
  corrupted output head), but passing on synthetic garbage is necessary, not
  sufficient — the design says so. **Kill if** AUC < 0.95 — a canary that
  misses 5 % of garbage is not a gate.
- **I4, I5, I6, I8, I9:** no public labelled set that matches the question is
  fetchable and gradeable without an LLM judge or a human, or (I9) the model
  is not pulled. Marked **not measurable today** with the design that would
  make them measurable.

Either outcome of the selected arm — proved or killed — is a valid,
reportable result and lands in §1 and §8 verbatim.

## Acceptance (from the task, restated as checks)

- [ ] `docs/research/typed-decisions-local-models.md` exists, ranks ≥5
      distinct ideas (target ≥8), and names one top recommendation with a kill
      criterion and an effort range.
- [ ] Every performance claim is measured-with-host or marked unmeasured.
- [ ] Every lemonade capability is cited to `lemonade-sdk/lemonade@v11.9.0`;
      no overclaim (in particular: no claim that Laya plugs into `/v1/classify`
      today; the #2384 sentence is flagged, not resolved).
- [ ] If a prototype exists it lives only under `experiments/laya/`, is not a
      flake output, and `git diff --stat` shows nothing under `pkgs/`,
      `modules/`, or `flake.nix`.
- [ ] PR assigned to @me, body carries `Closes #149`.

## Risks

- Laya weights download (~0.8–1.7 GB per checkpoint) or the nixpkgs torch
  substitution is slow — the prototype measures on a single checkpoint and
  the doc marks the rest unmeasured.
- Laya's `transformers>=4.48` floor vs nixpkgs `transformers 5.17`: upstream
  README states 5.x is supported; if the import fails, the prototype reports
  the failure as its result rather than patching Laya.
- The `llm`-judge baseline loads `Qwen3.5-4B-GGUF` into lemond's
  routing-helper pool on a shared host; it is an already-pulled model, but
  the doc reports the residency state (`/api/v1/health`) at measurement time.
- **The NPU may be unusable during this run** — a sibling task (the
  `lagoon` worker) may hold or have wedged it. The script probes
  `llama3.2-1b-FLM` with one chat request before grading and, on failure,
  takes the pre-registered `Qwen3.5-4B-GGUF` fallback above; §8 records which
  path ran and the `/api/v1/health` residency at that moment. The contention
  arm's NPU half is marked unmeasured in that case.
- Grading up to 400 ARC prompts through `llama3.2-1b-FLM` takes minutes, not
  seconds; the script caches every graded item to a JSON file so re-runs and
  the sequential stop rule are free.
