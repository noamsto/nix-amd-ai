# Typed-decision models (Jev / Laya) next to local LLMs

Exploration for #149: what TypeSafe Jev and open-weight Laya could do
*together with* the local LLMs this flake ships. Host for any measurement:
halo — Ryzen AI MAX+ 395 (Strix Halo, gfx1151 iGPU, XDNA2 NPU fw 1.1.2.65),
32 threads, 128 GB, lemonade 11.9.0.

## 1. TL;DR

The ranking (§6) puts **I1 — calibrated route signal** first and **I2 —
cascade** second. The prototype ran the shared I1/I2 arm and **killed both**
as tested on halo: Laya's `difficulty` AUC vs small-model-incorrect was
**0.5565** (halo) against the pre-registered 0.65 floor, and Laya's warm p50
was **797.2 ms** (halo, CPU, 32 threads, n=120) against the 250 ms line —
both pre-registered kill criteria fired (§8). I2's `adequate` signal scored
worse, 0.4409 (halo).

Do not build the caller-side `metadata` shim on Laya's base checkpoint —
that is what was just killed. The only path that could revive routing is a
fine-tune on this host's own routing labels (Laya's published zero-shot
0.36 → fine-tuned 0.766 gap suggests headroom, unmeasured here); that is a
human go/no-go decision, roughly **2–4 days**, and needs a labelled routing
set that does not exist yet. Cheaper measurable follow-ups not run in this
pass: **I7** coherence canary (0.5–1 day) and **I3** grounding (0.5–1 day).

These numbers say nothing about the iGPU, the NPU, or a fine-tuned Laya
checkpoint — all three remain unmeasured (§8).

## 2. What a typed-decision model is

A typed-decision model is a small encoder that answers a closed, single-turn
question over a given piece of text and returns a calibrated probability or
score rather than free text — Jev and Laya both expose exactly three
primitives (`choice`, `score`, `noul`) and no generation. The one-line rule
for when this beats "just ask the LLM": use a typed-decision model when the
question is *closed* (a fixed, small answer space), the state it's asked
over is *short*, and the answer needs to be a *calibrated probability* — not
prose that then has to be parsed, and not an LLM's own token confidence,
which is not a calibrated estimate of correctness. When the question is
open-ended, needs multi-step reasoning, or the state doesn't fit the
encoder's context budget, an LLM call (or a human) is still the right tool.

## 3. Constraints table

| | Jev 1.13 | Laya v0.3.5 | lemonade `llm` condition | lemonade `semantic_similarity` | lemonade `classifier` |
|---|---|---|---|---|---|
| Weights | hosted only, no weights (published, not measured here) | open, `convaiinnovations/laya` on HF, Apache-2.0 | N/A — routes to a resident LLM | needs a resident embedding model | needs an onnxruntime-served encoder |
| Primitives | `choice`/`score`/`noul`, up to 255 options | same three primitives, one forward pass answers every question in a request | free-form label pick by a chat model | cosine similarity to reference text | per-label scores from a classifier head |
| Latency | 236–276 ms p50, third-party numbers Laya cites (published, not measured here) | T4 GPU 32.8–39.5 ms/question, 7.2 ms/question batched ×10; CPU 193–464 ms/request with preload — upstream's run, host unspecified, **does not transfer to halo** | one full LLM chat call | one embedding call | one classify call, CPU EP only |
| Price | $42 / 1B input tokens, output free | free (local compute) | free (local compute) | free (local compute) | free (local compute) |
| Context | 64k | 512 tok (root), 1024 tok (`typed-decisions`, `multilingual`), split into a `head_max_len` budget (192/256 tok) and a state budget (~320/~768 tok) — Laya README "Honest limits" | whatever the LLM's context is | whatever the embedding model's context is | whatever the encoder's context is |
| Documented jaggedness | literal reading; math/counting/numeric encodings; date comparison; indirection; distractor-heavy state; adversarial content; contradictory instructions/criteria; no structural invariants across questions (`P(noul) ≠ 1 − P(not noul)`, probabilities not comparable across questions); no generation (Jev docs, model-jaggedness page) | near-chance zero-shot on the typed-decisions benchmark for base checkpoints (0.36 vs 0.318 random, 0.461 majority — the 0.766 figure is the *fine-tuned* checkpoint); over-confident as shipped (ECE 0.466 → 0.081 only after temperature refit, `multilingual` ships no temperatures); `score` is the weakest primitive (SST-5 0.372); prompt-injection held-out 0.698; >20-option `choice` degrades (Banking77 0.425 vs Jev 0.870) | whatever jaggedness the resident LLM has as a judge — unbounded, model-dependent | embedding-space jaggedness (synonymy, negation) — not characterised here | encoder-family jaggedness, plus the architecture allowlist below |
| Fit with lemonade today | not integrable — hosted API only, no local wiring | not wired to any lemonade endpoint; would need a caller-side shim (§5 I1) or a future `classifier` backend | native `collection.router` condition, `lemonade-sdk/lemonade@v11.9.0:docs/dev/router-policy.md` | native `collection.router` condition, same doc | native condition type, but see allowlist below |

**Division-of-labour rule:** code and the LLM do math, dates, counting, and
de-duplication; the typed-decision model gets a pre-digested state and
answers a single closed semantic question over it. Math, counting, numeric
encodings, and date comparison are on Jev's documented jaggedness list, and
Laya publishes nothing that says otherwise — that work stays upstream of the
typed-decision call.

**Contradiction to flag, not resolve:**
`lemonade-sdk/lemonade@v11.9.0:docs/api/lemonade.md:56` states that the
router's `classifier` condition's live wiring "is tracked in
[#2384](https://github.com/lemonade-sdk/lemonade/issues/2384)", but
`lemonade-sdk/lemonade@v11.9.0:src/cpp/server/routing_classifier_services.cpp:276-304`
is that wiring: the router calls `/v1/classify` for models of
`ModelType::CLASSIFICATION` (`lemonade-sdk/lemonade@v11.9.0:src/cpp/include/lemon/model_types.h:58`)
and otherwise falls back to LLM-as-classifier via chat
(`lemonade-sdk/lemonade@v11.9.0:src/cpp/include/lemon/routing_classifier_services.h:24-31`).
The doc text and the code disagree about whether the feature is done. This
doc cites the code as the source of truth and leaves the stale sentence
flagged rather than picking a side — it is upstream's inconsistency to fix.

Regardless of that resolution, `/v1/classify` only serves single-sequence
encoder families — BERT, DistilBERT, RoBERTa, XLM-RoBERTa, DeBERTa, ELECTRA,
ALBERT, CamemBERT — rejected at load otherwise
(`lemonade-sdk/lemonade@v11.9.0:docs/api/lemonade.md:47-56`). Laya's encoder
is ModernBERT/mmBERT, which is not on that list, and Laya's heads take
marker positions and a question-type id per forward
(`NandhaKishorM/laya@v0.3.5:laya/agent.py:295-301`), so it is not a plain
sequence-classification export with labels fixed at export time even if the
architecture were allowed. **Laya does not plug into `/v1/classify` today.**

Any idea below that adds a model-backed condition — the `llm`-judge baseline
used to score I1/I2, or a future Laya `classifier` backend — lands in
lemonade's separate **routing-helper residency pool**, not the standard
candidate pool: an internal routing load never evicts a resident candidate
model, and a routing helper called directly by a user is demoted into the
counted standard pool in place
(`lemonade-sdk/lemonade@v11.9.0:docs/guide/configuration/multi-model.md:23-61`).
When the judge model and the candidate model are the same process
(`router.model == candidate`, the 4B-fallback case in §5's I1/I2 arm), that
promotion/demotion happens in place without a second process
(`lemonade-sdk/lemonade@v11.9.0:docs/guide/configuration/multi-model.md:39-44`).
This is why the `llm`-judge baseline doesn't compete with a resident model
for a slot on a shared host — it's a fact about lemonade's scheduler, not
something this exploration measured.

## 4. Where Laya could run on our hardware

| Target | Status | Why |
|---|---|---|
| CPU torch | to be measured (the prototype under `experiments/laya/`) | flake-pinned nixpkgs substitutes `python3.14-torch-2.13.0` (CPU) and `transformers-5.17.0` without a local build; this is the only target this exploration runs |
| ROCm torch on the iGPU | **unmeasured** | Laya's device resolution only recognises `cuda` / `mps` / `cpu` (`NandhaKishorM/laya@v0.3.5:laya/agent.py:166-182`); a ROCm torch build presents itself as `cuda` to PyTorch, so the code path exists, but this flake has no ROCm torch for Laya to run against — packaging one is out of scope (non-goal) and `pkgs/vllm-rocm` would pull a 7.6 GB bundle just to get there |
| ort-server (`onnxruntime` recipe) | **blocked** | double-blocked: the architecture allowlist rejects ModernBERT/mmBERT at load (`lemonade-sdk/lemonade@v11.9.0:docs/api/lemonade.md:47-56`), and even a permitted architecture wouldn't carry Laya's marker-position/question-type forward inputs, which a stock ONNX classification export doesn't have (`NandhaKishorM/laya@v0.3.5:laya/agent.py:295-301`) |
| NPU (FLM / `ryzenai-llm`) | **no path** | FLM's model list on halo is fixed to LLM/embedding/ASR slots, not an arbitrary encoder (`lemonade-sdk/lemonade@v11.9.0:docs/guide/configuration/multi-model.md:69`); lemonade's XDNA ONNX route (`ryzenai-llm`) is Windows-only (`lemonade-sdk/lemonade@v11.9.0:docs/dev/backends-reference.md:58`) |

Power cost is **unmeasured** across every target unless a run reads RAPL
directly — the prototype does not instrument power. The one thing measured
on halo that bears on this is the NPU+iGPU concurrency row in
`README.md` §"Strix Halo": an NPU-resident 1B model and an iGPU-resident 7B
model coexist with no measured throughput cost to the iGPU (iGPU held
37.1 t/s, "full speed, no degradation") and about a 20% NPU decode cost, at
36.2 W package power total. That number is for two LLMs, not for Laya, and
it says nothing about a CPU-resident Laya's cost — a CPU torch process
competes for the same cores lemond's CPU-side work (tokenization, request
handling, and any CPU-backend model) already uses. **This is reasoning by
analogy from a different workload, not a measurement of Laya's contention
cost**; the prototype's contention arm (if it runs) is the only measured
data point for that question, and everything else here about concurrent
cost is unmeasured.

## 5. Ideas

Seven fields per idea: mechanism · why typed beats ask-the-LLM · which
jaggedness bites · fit with lemonade/flake · cost to try · kill criterion ·
measurable on halo today?

**I1 — Calibrated route signal for lemonade's router.**
- Mechanism: Laya `router_questions()` (`NandhaKishorM/laya@v0.3.5:laya/presets.py:154-187`) returns `difficulty` (`score`), `domain` (`choice`), `needs_tools` (`noul`), `is_sensitive` (`noul`) in one forward pass; a request is routed to NPU-1B / iGPU-4B–9B / iGPU-30B–120B on that signal.
- Why typed beats ask-the-LLM: a route decision needs to happen *before* any candidate model answers, so asking an LLM to judge difficulty means running an LLM call just to decide whether to run a (possibly bigger) LLM call — the typed model is a single small forward pass instead.
- Jaggedness: Laya's `score` primitive is its weakest (SST-5 0.372); "difficulty" is a `score` question, so calibration on an unseen task family is the open risk, not the general jaggedness list.
- Fit: two integration shapes, both honest to the facts — (a) a caller-side shim sets the OpenAI `metadata` field from Laya's output and a `collection.router` policy routes on `metadata`, a deterministic condition evaluated locally with **zero lemonade changes** (`lemonade-sdk/lemonade@v11.9.0:docs/dev/router-policy.md:75`); (b) a future lemonade `classifier` backend for Laya, which needs upstream work (allowlist change + a non-standard head contract) — a follow-up, not something assumed to exist.
- Cost to try: 0.5–1 day for the shim + a `metadata`-based policy against already-pulled models.
- Kill criterion: Laya AUC < 0.65 predicting small-model failure, or ≤ best baseline AUC + 0.05 (own-logprob or Easy/Challenge split), or Laya warm p50 ≥ 250 ms on halo CPU, or Laya p50 ≥ the `llm`-judge p50.
- Measurable on halo today? Yes — the shared I1/I2 arm below: grade `llama3.2-1b-FLM` (fallback `Qwen3.5-4B-GGUF`) on ARC-Challenge/Easy through lemonade's chat endpoint, score Laya's `difficulty` against small-model-incorrect by ROC-AUC, against the logprob/Easy-Challenge/`llm`-judge baselines.

**I2 — Cascade / "should the big model run?"**
- Mechanism: the small model answers first; Laya `noul` "is `answer` a correct and adequate answer to `request`?" decides whether to re-run on a bigger model.
- Why typed beats ask-the-LLM: calibration lets an operator pick a target escalation rate (e.g. "escalate the bottom 20% by adequacy") instead of a binary LLM-as-judge verdict with no dial.
- Jaggedness: `noul` is Laya's best-behaved primitive of the three, but "adequate" is itself a judgment call the typed model has never been shown ARC-style closed-form answers for — untested domain transfer.
- Fit: same as I1 — caller-side, no lemonade change needed to *decide*; actually escalating is an ordinary second chat call to a bigger already-pulled model.
- Cost to try: 0.5 day, reuses I1's harness and the same graded pool.
- Kill criterion: same thresholds as I1 (shared arm, AUC on `1 - adequate` as the signal).
- Measurable on halo today? Yes — same shared arm as I1, `answers["adequate"]["noul"]` over `{request, answer}` on the root checkpoint, scored against small-model-incorrect.

**I3 — Grounding `noul` over retrieved context.**
- Mechanism: per-claim NLI — "is this sentence supported by this passage?" — for each sentence a RAG pipeline is about to present as grounded.
- Why typed beats ask-the-LLM: this is a closed yes/no question repeated per claim; an LLM judge would need one call per claim (or a long combined prompt with parsing), where Laya's `noul` returns a calibrated P(true) in one small forward pass per claim.
- Jaggedness: indirection and distractor-heavy state both bite here directly — retrieved passages are exactly "distractor-heavy state".
- Fit: fits the 512-token state if chunked per claim; base checkpoint reports XNLI 0.86 (en) upstream, not measured on halo.
- Cost to try: 0.5–1 day (uses public XNLI/MNLI validation data, no app-specific plumbing needed to test the signal in isolation).
- Kill criterion: AUC < 0.75 (upstream's own XNLI-en 0.86 leaves headroom for domain shift), or p50 ≥ 250 ms.
- Measurable on halo today? Yes — 120 premise/hypothesis pairs from `facebook/xnli` `en` validation, `noul` "is the hypothesis supported by the premise?", AUC against entailment-vs-not.

**I4 — Pre-LLM guardrail / tool-call precondition.**
- Mechanism: `guard_questions()` runs before the LLM, composed with lemonade's `has_tools` leaf condition — e.g. a "risky-tool-calls-stay-local" rule that keeps flagged requests off cloud candidates.
- Why typed beats ask-the-LLM: a guardrail that itself calls an LLM adds the guarded model's own jaggedness to the gate; a small typed model is a narrower, faster, separately-tunable gate.
- Jaggedness: adversarial content and contradictory instructions are exactly what a guardrail needs to be robust against, and are on Jev's documented jaggedness list; Laya's held-out prompt-injection accuracy (0.698, n=116, upstream's run) says this is real, unsolved risk, not a hypothetical.
- Fit: composes with `has_tools` at the policy level (`lemonade-sdk/lemonade@v11.9.0:docs/dev/router-policy.md`), no lemonade change.
- Cost to try: 1–2 days (needs a labelled risky/not-risky tool-call set, which does not exist publicly in the shape this needs).
- Kill criterion: not pre-registered — no dataset exists to set one against yet.
- Measurable on halo today? No — no public labelled set of tool-call requests matching this question is fetchable and gradeable without a human or an LLM judge. The design that would make it measurable: hand-label a few hundred tool-call prompts as risky/not-risky, or synthesize them from an existing agent-tool-call dataset and grade with an LLM judge as ground truth (weaker, but tractable).

**I5 — Best-of-N verifier / reranker.**
- Mechanism: `score` over N candidate answers in one batched forward pass, pick the top-scoring candidate.
- Why typed beats ask-the-LLM: an LLM-as-reranker needs N-1 pairwise calls or one long prompt holding all candidates; Laya batches all N in a single forward pass at its stated 7.2 ms/question (T4, upstream's run — unmeasured on halo).
- Jaggedness: `score` is Laya's weakest primitive (SST-5 0.372) — this idea leans hardest on the primitive least likely to transfer well.
- Fit: no lemonade wiring needed — pure caller-side scoring after N chat completions already generated.
- Cost to try: 1 day (needs a best-of-N generation harness plus a labelled "which is actually best" set to score against).
- Kill criterion: not pre-registered — no dataset exists to set one against yet.
- Measurable on halo today? No — scoring "is candidate X best" needs ground truth on which candidate is actually best, which for open-ended generation has no public gradeable set without a human or LLM judge in the loop.

**I6 — Agent stop/continue and trace-observability decisions.**
- Mechanism: "did the agent finish?", "is it looping?" as `noul` questions over an agent trace.
- Why typed beats ask-the-LLM: an LLM-based "has this agent finished" check burns a full model call per step of every agent loop; a typed model is a cheap per-step gate.
- Jaggedness: Laya's `typed-decisions` checkpoint was specifically trained on an agent-trace workflow (0.730), so this is the one idea with checkpoint-level task alignment rather than general-purpose transfer — but 0.730 is still well short of a hard gate.
- Fit: caller-side, sits in whatever orchestrates agent loops today, no lemonade change.
- Cost to try: 1–2 days (needs real multi-step agent traces from this flake's own agent usage, which don't exist as a labelled corpus yet).
- Kill criterion: not pre-registered — no dataset exists to set one against yet.
- Measurable on halo today? No — no labelled corpus of this flake's own agent traces with "finished / looping" ground truth exists yet. The design that would make it measurable: log a batch of real agent sessions, hand-label stop points, then grade.

**I7 — Coherence canary for the benchmark harness.**
- Mechanism: a `noul` "is this output a coherent answer to the prompt?" as a `pkgs/benchmark-go` preflight/results column, so a silently broken backend fails a run without needing a perplexity reference.
- Why typed beats ask-the-LLM: the whole point is to catch backend breakage *without* trusting another LLM call on the same possibly-broken hardware path; a small CPU-resident checker sidesteps that circularity, and a perplexity reference needs a known-good baseline the canary doesn't.
- Jaggedness: none of Jev's/Laya's documented jaggedness bears directly — this is closer to a garbage-detection task than a semantic-nuance one.
- Fit: `pkgs/benchmark-go` measures real decode throughput over lemonade's HTTP API and already gates against silent CPU fallback (`pkgs/benchmark-go/README.md`); a coherence canary is an additional gate of the same kind, not a lemonade capability at all — implemented purely in the benchmark harness.
- Cost to try: 0.5–1 day (synthetic garbage generation + real completions, both cheap to produce).
- Kill criterion: AUC < 0.95 on the synthetic canary — a canary that misses 5% of garbage is not a gate, stated as necessary-not-sufficient (passing on synthetic garbage doesn't prove it catches the real failure mode).
- Measurable on halo today? Yes — 60 real `Qwen3.5-4B-GGUF` completions on ARC prompts + 60 synthetic garbage outputs (random tokens, repeated n-grams — a fair proxy for the gfx1151 ROCm failure, which randomises token choice from a corrupted output head, `docs/rocm-gfx1151-numerics.md`), `noul` "is this a coherent answer to the prompt?", AUC against real-vs-garbage.

**I8 — Local eval grading.**
- Mechanism: a proper-scoring-rule judge for A/B runs (MTP vs non-MTP equivalence, quant regressions) where the question is closed ("same answer?") rather than open ("which is better?").
- Why typed beats ask-the-LLM: "same answer, semantically" is a closed `noul` question; an LLM judge for this still works but adds its own jaggedness and cost per comparison, and isn't calibrated the way a proper scoring rule needs to be for a regression gate.
- Jaggedness: numeric/date/counting jaggedness bites hardest here, since equivalence judgments on quantitative outputs are exactly where Laya's documented weak points (math, counting, date comparison) live.
- Fit: caller-side, feeds an eval pipeline; no lemonade wiring.
- Cost to try: 1 day (needs paired A/B outputs from this flake's own eval runs, plus a small hand-graded "same/different" set to validate against).
- Kill criterion: not pre-registered — no dataset exists to set one against yet.
- Measurable on halo today? No — no public labelled "same answer, semantically" set matching this flake's own A/B comparisons exists. The design that would make it measurable: hand-label a batch of this flake's own MTP-vs-non-MTP or quant-regression output pairs as same/different, then grade.

**I9 — Semantic-similarity on the NPU, the zero-new-software baseline.**
- Mechanism: lemonade's existing `semantic_similarity` router condition with `embed-gemma:300m` resident on FLM — no new software at all.
- Why typed beats ask-the-LLM: it doesn't clearly beat a typed-decision model — this is the alternative for comparison, not a typed-decision idea. It answers "is this close to a reference example" via embedding distance, a different (and cruder) signal than a calibrated probability over a specific question.
- Jaggedness: embedding-space jaggedness (synonymy, negation blindness) is not characterised in this doc.
- Fit: fully native — `lemonade-sdk/lemonade@v11.9.0:docs/dev/router-policy.md` documents `semantic_similarity` as a condition today, and `flm list` on halo offers `embed-gemma:300m` as downloadable (`lemonade-sdk/lemonade@v11.9.0:docs/guide/configuration/multi-model.md:69`).
- Cost to try: 0.5 day (pull the model, write a policy) — cheapest idea in this list by far.
- Kill criterion: not pre-registered.
- Measurable on halo today? No — `embed-gemma:300m` is not pulled on this host and this exploration does not pull new models (Fixed inputs, plan): unmeasured. This is presented as the cheapest alternative to compare a typed-decision idea against, not as a measured bar — nothing here should read "I9 beats/loses to I1" as a number, because no I9 number exists.

## 6. Ranking

Scored 1 (weak) – 3 (strong) per axis; written before the prototype runs and
not revised by its result.

| Idea | Evidence of value | Fit with lemonade/flake | Cost | Jaggedness exposure (lower = safer) | Measurable on halo today |
|---|---|---|---|---|---|
| I1 Route signal | 2 | 3 | 3 | 2 | yes |
| I2 Cascade | 2 | 3 | 3 | 2 | yes |
| I3 Grounding | 2 | 2 | 3 | 2 | yes |
| I7 Coherence canary | 2 | 2 | 3 | 3 | yes |
| I9 Semantic-similarity baseline (comparison only) | 1 | 3 | 3 | 2 | no |
| I4 Guardrail | 2 | 2 | 2 | 1 | no |
| I8 Local eval grading | 1 | 2 | 2 | 1 | no |
| I6 Agent stop/continue | 2 | 2 | 1 | 2 | no |
| I5 Best-of-N verifier | 1 | 2 | 2 | 1 | no |

I1 ranks first: it is the idea the "typed model next to local LLMs" framing
is actually about (a router signal for a router this flake already runs),
it needs zero lemonade changes to try (the `metadata` shim), and it shares a
cheap, already-designed measurement arm with I2. I2 ranks second for the
same reasons, one step removed — a cascade decision is a direct consequence
of the same difficulty/adequacy signal once it exists, but it's a second
integration (an escalation call), not the primary router decision.

I3 and I7 both rank above I4/I5/I6/I8 because they have concrete,
fetchable, already-labelled public data to grade against (XNLI, and
real-vs-synthetic-garbage completions) — the other four ideas are killed on
measurability, not on merit: I4/I5/I6/I8 each need a labelled set specific
to this flake's own usage (risky tool calls, best-of-N ground truth, agent
traces, A/B output pairs) that doesn't exist yet, so none of them gets a
pre-registered kill criterion in this pass. I9 ranks near the bottom of
evidence-of-value on purpose — it's the cheapest idea to build but has no
measured number behind it at all, and this doc does not let it stand in as
"the bar" for the others.

Prototype target: I1

## 7. Recommended next step

Run the I1/I2 shared prototype arm (already the plan's Step 3): grade
`llama3.2-1b-FLM` on ARC-Challenge/Easy, score Laya's `difficulty`/`adequate`
signals against the logprob, Easy/Challenge-split, and `llm`-judge
baselines, and apply the pre-registered kill line. Effort: **1–2 days** for
the measurement itself (already scoped in this branch's plan), plus, only
if it proves out, **2–4 days** to build the caller-side `metadata` shim
into a real router policy against this flake's own request traffic —
excluded from this task.

Explicitly excluded from this recommendation: fine-tuning Laya on
this flake's own routing decisions (Laya's own literature shows a large
zero-shot-to-fine-tuned gap, 0.36 → 0.766, so a fine-tune could plausibly
turn a killed I1 into a viable one, but that's a separate, larger effort);
upstreaming a lemonade `classifier` backend for Laya (needs the allowlist
change and the non-standard head contract this doc flags in §3, and is
lemonade's decision, not this flake's); and I3/I7, which are cheap
follow-ups but not the top-ranked measurable idea.

Two points block progress on a human decision, not on measurement:
whether it's worth fine-tuning Laya at all (only makes sense once I1's
zero-shot numbers are in and show promise, but not enough to ship as-is);
and whether to open an upstream lemonade PR for a `classifier` backend that
accepts Laya's architecture (a decision about maintaining a fork/patch vs.
waiting on upstream, independent of what this doc's numbers show).

## 8. Prototype results

What ran on halo (Ryzen AI MAX+ 395, gfx1151 iGPU, XDNA2 NPU, CPU 32 threads
unless stated): the shared I1/I2 arm from §5/§7 via
`experiments/laya/bench.py` (`probe`, `laya-latency`, `grade`, `baselines`,
`report`, `contention`); raw data and the rendered tables are
`experiments/laya/results/halo-2026-09-22.{json,md}`. Only the root
checkpoint ran — `typed-decisions` and `multilingual` are **unmeasured**.
The run used only already-pulled lemonade models; nothing was pulled for
this exploration. Residency at probe time (`health_at_probe` in the results
JSON): `max_models.llm = 1`, no model resident when the run started.

**Grading.** Candidate `llama3.2-1b-FLM` (FLM probe passed — the NPU was
usable at run time). The pre-registered stop rule reached n=84 (40 correct /
44 incorrect / 5 unparseable, counted incorrect). All 84 graded items are
ARC-**Challenge**: the pool grades Challenge before Easy and the stop rule
fired before reaching Easy, so the `easy_challenge` baseline is degenerate
(single split, AUC 0.5000) and the secondary "AUC vs split==Challenge"
column is n/a for every signal. ARC-Easy AUC is therefore **unmeasured**.

**Signal AUCs vs small-model-incorrect** (halo, n=84 unless noted):

| signal | AUC | note |
|---|---|---|
| `difficulty_score` (Laya, I1) | 0.5565 | barely above chance |
| `1 - adequate_noul` (Laya, I2) | 0.4409 | below chance |
| `min_chars` | 0.6176 | outperforms Laya's difficulty score on this set |
| `llm_judge == HARD` | 0.5000 | no discrimination — see below |
| `easy_challenge` | 0.5000 | degenerate, single split graded |
| `-own_logprob` | **unmeasured** | n=0 — see below |

Mean `difficulty_score` (halo) was 1.06 for items the 1B got wrong vs 1.00
for items it got right — the signal barely moves between the two groups,
consistent with the 0.5565 AUC. `min_chars` (raw prompt byte length)
outperformed Laya's difficulty score on this pool, even though the
pre-registered kill line (§5 I1) compares Laya only against own-logprob and
easy/challenge, not min_chars — said plainly because it bears on whether
Laya's signal adds anything a trivial heuristic doesn't already give.

`own_logprob` is **unmeasured**: FLM's `/api/v1/completions` returned no
`logprobs` object for any of the 84 graded items (expected on FLM;
`lemonade-sdk/lemonade@v11.9.0:docs/api/openai.md:220` documents where
`logprobs` is populated).

**The `llm_judge` baseline has no discrimination either.** `llm_judge`
(Qwen3.5-4B-GGUF via `/api/v1/routing/validate`, halo p50 1200.4 ms / p95
1344.4 ms) returned EASY (`matched_rule` empty, default route) for **all
84** graded items. Verified afterward as a genuine judgement, not a
fail-open: a manual validate call (outside the graded 84) on an ARC science
item returned trace
`{"condition":"classifier:hard","label":"HARD","result":false,"score":0.0}`
after ~1.5 s, and a number-theory prompt returned `result: true, score:
1.0` with a rationale. So a 4B LLM-as-judge rates every ARC-Challenge
question "easy for a 1B model" (halo) while the 1B model gets 44/84 (52%)
of them wrong — the judge baseline has no discrimination on this set
either.

**A lemonade residency behaviour observed on this run.** On halo (lemonade
11.9.0, `max_models.llm = 1`), `/api/v1/routing/validate` does not itself
load the judge model. If the judge is not resident — e.g. the FLM candidate
already holds the single LLM slot — the `llm` classifier fails closed to
`default_label` via `on_error: match_false` in ~1–13 ms with no error in
the response body
(`lemonade-sdk/lemonade@v11.9.0:docs/dev/router-policy.md:133` documents
`on_error`; `lemonade-sdk/lemonade@v11.9.0:docs/api/lemonade.md:138-141`
documents that a model-evaluation failure is handled by `on_error` and
routing continues regardless). The harness therefore sends one warm-up chat
call to the judge before the judge loop, to force residency first. This is
an observation from this run about halo's residency state at run time, not
a lemonade bug report.

**Latency** (halo, CPU):

| measurement | p50 | p95 | n |
|---|---|---|---|
| kill-line (Step 2 idle run, 32 threads) | 797.2 ms | 1916.6 ms | 120 |
| thread sweep — 8 threads (supplementary) | 618.5 ms | 796.1 ms | 40 |
| thread sweep — 16 threads (supplementary) | 468.4 ms | 606.2 ms | 40 |
| thread sweep — 32 threads (supplementary) | 833.2 ms | 7049.8 ms | 40 |
| contention — idle | 835.4 ms | 1096.4 ms | 40 |
| contention — NPU (`llama3.2-1b-FLM` streaming) | 1296.2 ms | 3317.9 ms | 40 |
| contention — iGPU (`Qwen3.5-4B-GGUF` streaming) | 2169.1 ms | 2662.3 ms | 40 |

Load 18.53 s (halo, root checkpoint); batched 10 questions 414.0
ms/question (halo). 16 threads is the best of the sweep and still nearly twice
the 250 ms line; the 32-thread p95 blow-up (7049.8 ms)
suggests SMT oversubscription on this 16-core part — an inference from the
shape of the sweep, not itself a measurement. The contention idle p50
(835.4 ms, n=40, run after grading) is **not** the kill-line p50 (797.2 ms,
n=120, Step 2) — a separate run, reported separately here and in the
results md.

**PASS/KILL** (halo, pre-registered criteria, spec Deliverable 2 / plan
Fixed inputs):

- **KILL** — Laya AUC < 0.65 (0.5565)
- **PASS** — Laya AUC > best-baseline AUC + 0.05 (0.5565 vs easy_challenge 0.5000)
- **KILL** — Laya warm p50 ≥ 250 ms (797.2 ms)
- **PASS** — Laya p50 < `llm`-judge p50 (797.2 ms vs 1200.4 ms)

**Overall: KILL** for I1; I2's `adequate` signal (AUC 0.4409) scores worse
and is killed on the same AUC floor.

**Unmeasured, listed explicitly:**

- ROCm torch on the iGPU (§4)
- NPU (§4 — no path)
- power / RAPL (not read by any run)
- `own_logprob` on the FLM candidate (no `logprobs` object returned)
- the `typed-decisions` and `multilingual` checkpoints (only root ran)
- AUC on ARC-Easy (the stop rule fired before the pool reached it)
- the secondary AUC vs split==Challenge (degenerate — single split graded)
- I3 (grounding) and I7 (coherence canary) arms — not run; I1 was the
  selected prototype target (§6)
