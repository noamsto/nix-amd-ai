# Plan — typed-decision models (Jev / Laya) exploration

**Spec:** `docs/superpowers/specs/2026-09-22-typed-decisions-exploration-design.md` (accepted by spec-critic, revision 2)
**Closes:** #149
**Host:** halo (Ryzen AI MAX+ 395, gfx1151, XDNA2 NPU, 32 threads, 128 GB, lemonade 11.9.0 on `:13305`)
**Tier:** deep — steps run as sonnet subagents; none is tagged for escalation (no concurrency, security, or wide-blast-radius step; the deliverable is a doc plus a throwaway script).

## Files

New (all of it; nothing under `pkgs/`, `modules/`, or `flake.nix` changes):

| path | purpose |
|---|---|
| `docs/research/typed-decisions-local-models.md` | Deliverable 1 — the ranked exploration doc, §1–§8 per the spec |
| `experiments/laya/README.md` | how to run the throwaway prototype; "not a flake output" |
| `experiments/laya/shell.nix` | pinned-nixpkgs CPU torch shell with Laya vendored on `PYTHONPATH` |
| `experiments/laya/bench.py` | one script, subcommands `probe`, `laya-latency`, `grade`, `baselines`, `report`, `contention` |
| `experiments/laya/results/halo-2026-09-22.json` | every measured datum, machine-readable, committed |
| `experiments/laya/results/halo-2026-09-22.md` | rendered tables the doc §8 copies from |

Already on the branch: the spec above and this plan.

## Fixed inputs (do not re-derive)

- Laya source: `fetchFromGitHub { owner = "NandhaKishorM"; repo = "laya"; rev = "v0.3.5"; hash = "sha256-cbUuLBMBC7WwqAf7m7Ihs6qkx7H7FdwhPVMWfgnfg8c="; }` (rev `573e5b62696ba441230cd6be71d593331b5d23af`, prefetched this session). The package is the `laya/` subdirectory of that tree; `PYTHONPATH` points at the tree root.
- Pinned nixpkgs: `(import ../../default.nix).inputs.nixpkgs` (flake-compat exposes `inputs`; verified with `nix eval -f default.nix inputs.nixpkgs.outPath`). `python3.withPackages (ps: [ ps.torch ps.transformers ps.safetensors ps.huggingface-hub ps.numpy ps.pyarrow ])` substitutes from cache — `nix build --dry-run --inputs-from .` reported nothing to build for any of them.
- Checkpoints: HF `convaiinnovations/laya` — root (English, 512 ctx) is the default; `typed-decisions` subfolder is the second run if time allows. Weights go to `$HF_HOME`/default HF cache, never into the repo.
- Dataset: HF dataset `allenai/ai2_arc`, files `ARC-Challenge/test-00000-of-00001.parquet` and `ARC-Easy/test-00000-of-00001.parquet`, via `huggingface_hub.hf_hub_download(repo_type="dataset")`, read with `pyarrow.parquet`.
- lemonade endpoints on halo: `POST /api/v1/chat/completions` (answers), `POST /api/v1/completions` non-stream with `logprobs` (`lemonade-sdk/lemonade@v11.9.0:docs/api/openai.md:220`; not on chat, `:34`), `POST /api/v1/routing/validate` (`docs/api/lemonade.md:117-141`), `GET /api/v1/health` (residency).
- Small candidate: `llama3.2-1b-FLM`; pre-registered fallback `Qwen3.5-4B-GGUF` only if the FLM probe fails outright (the NPU may be held by a sibling task). Judge for the `llm` baseline: `Qwen3.5-4B-GGUF`. Never pull a model; use only these already-pulled names.
- Pre-registered thresholds (copied verbatim from the spec, Deliverable 2 — the script encodes them as constants and prints PASS/KILL per criterion):
  - sequential grading until ≥ 40 incorrect **and** ≥ 40 correct, cap 400 (600 on the 4B fallback); 25–39 positives at cap → proceed with realised counts; < 25 → "unmeasurable with this candidate", no candidate switch;
  - unparseable answer (no letter, several letters, refusal) → incorrect, counted separately;
  - **kill I1/I2 if** Laya AUC < 0.65, **or** ≤ best-baseline AUC + 0.05 (best of own-logprob and Easy/Challenge), **or** Laya warm p50 ≥ 250 ms on halo CPU, **or** Laya p50 ≥ `llm`-judge p50.
- Every printed number is prefixed `halo / AMD RYZEN AI MAX+ 395 / CPU 32 threads` (read from `socket.gethostname()` and `/proc/cpuinfo`, not hard-coded).

## Steps

Steps 1 and 2 are independent and run in parallel; 3 waits for both; 4 and 5 are sequential.

- [ ] **Step 1 — draft the doc, §2–§7, with §1 and §8 as placeholders.** (sonnet)
  Write `docs/research/typed-decisions-local-models.md` following the spec's
  eight-section structure exactly. Inputs the subagent reads: the spec (its
  Facts section is the citation source — cite `lemonade-sdk/lemonade@v11.9.0:<path>:<line>`
  and `NandhaKishorM/laya@v0.3.5:<path>`), `README.md` §"Strix Halo" for the
  NPU/iGPU coexistence table and `README.md:534` for TTFT,
  `docs/rocm-gfx1151-numerics.md` for I7's failure description, and lemonade's
  `docs/dev/router-policy.md` + `docs/guide/configuration/multi-model.md` from
  the unpacked tree at `/nix/store/9viywx7wzwl7fkrpi00wxwmy1rjznfgb-source`
  (read there, cite by repo path). Requirements:
  - §5 covers I1–I9 (may add/merge), each with the seven fields the spec lists
    incl. "measurable on halo today? (yes/no + how)"; I4/I5/I6/I8/I9 are "no"
    with the design that would make them measurable; I9 is the zero-new-software
    alternative, unmeasured, never "the bar".
  - §4 states the four run targets with the blocked/unmeasured reasons from the
    spec; power is **unmeasured**.
  - §3 constraints table flags the `docs/api/lemonade.md:56` "#2384" sentence
    against `routing_classifier_services.cpp:276-304` without resolving it.
  - §6 ranking table is **final in this step**; the selection rule (top-ranked
    idea whose measurable cell is yes) is applied and named at the end of §6:
    "Prototype target: I<n>". If the target is not I1/I2, say which arm
    (I3 or I7 per the spec) the prototype will run.
  - §1 and §8 contain only `<!-- PENDING: filled from experiments/laya/results -->`.
  - Every number in §2–§7 has a host label or the word **unmeasured**; Jev is
    "published, not measured here"; Laya base checkpoints are never called
    zero-shot decision engines.
  Done when: the file exists, `rg -c 'unmeasured' docs/research/…` ≥ 5, `rg -n 'lemonade-sdk/lemonade@v11.9.0' …` ≥ 8 hits, §6 ends with a "Prototype target" line.

- [ ] **Step 2 — prototype scaffold + first Laya measurement.** (sonnet)
  Create `experiments/laya/shell.nix`, `README.md`, and `bench.py` with the
  `probe` and `laya-latency` subcommands, then run them.
  - `shell.nix`: as in Fixed inputs; `mkShell` with the python env, `curl`,
    `jq`; `PYTHONPATH = "${laya}"`; `HF_HUB_DISABLE_TELEMETRY = "1"`. Style:
    two-space indent like `pkgs/*.nix`.
  - `bench.py probe`: `GET /api/v1/health` → print residency; one chat
    request (`max_tokens: 8`) to `llama3.2-1b-FLM` with a 20 s timeout; on
    any failure print `FLM probe failed: <reason>` and set the candidate to
    `Qwen3.5-4B-GGUF` in the results JSON (`candidate`, `candidate_reason`).
  - `bench.py laya-latency [--checkpoint root|typed-decisions] [--n 120]`:
    `laya.load("convaiinnovations/laya", device="cpu", subfolder=…)`; report
    load seconds; warm up 5 calls; then `agent.predict({"request": p},
    laya.router_questions())` per prompt over the first `--n` ARC prompts
    (same pool/seed/filter as Step 3 — put the pool builder in a shared
    function now); record per-prompt wall time and the full `answers`
    dict; print p50/p95, `torch.get_num_threads()`, and the host prefix.
    Also run a 10-question batched call once to report per-question cost.
  - Results JSON schema (one file, merged by subcommand): `{host, cpu,
    threads, candidate, laya: {checkpoint, load_s, p50_ms, p95_ms, n,
    per_prompt: {<id>: {ms, difficulty_score, needs_tools, is_sensitive,
    domain}}}, …}`. Field sources, pinned: `answers["difficulty"]["score"]`
    (expected ordinal 0–3, `laya/agent.py:350`), `answers["needs_tools"]["noul"]`,
    `answers["is_sensitive"]["noul"]`, `answers["domain"]["choice"]` — the
    four keys `router_questions()` defines (`laya/presets.py:154-187`).
    `per_prompt` is keyed by ARC id so Step 3 can extend it.
  - `README.md`: `nix-shell experiments/laya/shell.nix --run "python
    experiments/laya/bench.py …"` lines for each subcommand, the host label
    rule, "throwaway — not a flake output", and that weights/dataset land in
    the HF cache.
  - Run: `nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py probe"`
    then `… laya-latency --n 120`. Commit the JSON.
  Done when: JSON has `laya.p50_ms` and `candidate`; the shell evaluates
  without building anything (only substitutions); the README runs as written.
  If `import laya` fails under transformers 5.17, stop and record the exact
  error in the JSON as `laya.import_error` — that is the result (spec Risks).

- [ ] **Step 3 — the arm for the selected idea, run it, render results.** (sonnet; needs Steps 1 and 2)
  Read "Prototype target" from the doc §6. For **I1/I2** (expected):
  - `bench.py grade`: build the pool (Challenge test shuffled with seed 149,
    then Easy test shuffled with seed 149; keep 4-choice items; map keys
    `1-4`→`A-D`; drop others). Prompt: question, choices as `A. …`, then
    "Give one sentence of reasoning, then a final line `Answer: <letter>`."
    Parse the last `Answer: X` line; else the last standalone A–D token; else
    unparseable → incorrect. Chat to the candidate, `temperature 0`,
    `max_tokens 96`. Cache every item to the JSON (`graded: [{id, split,
    correct, unparseable, answer_text, ms}]`) and resume from cache on rerun.
    Stop per the pre-registered rule; write `grade.stop_reason`.
  - `bench.py baselines`: for each graded item —
    (a) **own-logprob**: non-stream `POST /api/v1/completions` on the
    candidate, body `{"model", "prompt": <the exact grading prompt text> +
    "\nAnswer:", "max_tokens": 1, "temperature": 0, "logprobs": true,
    "stream": false}` — **no chat template** (the endpoint takes a raw
    string, `docs/api/openai.md:220`); record
    `own_logprob: {template: "none", token, logprob, matches_graded_letter}`
    where `logprob` is the log-probability of the single greedy token the
    endpoint returns and `matches_graded_letter` says whether that token
    (stripped) equals the letter parsed in `grade`. The signal is `logprob`
    as-is (the model's confidence in its own next token), regardless of the
    match; the match rate is reported beside it. If the response carries no
    `logprobs` object (expected on FLM), store `null` and mark the baseline
    **unmeasured** for that candidate.
    (b) `easy_challenge` = split; (c) `min_chars` = UTF-8 length;
    (d) **`llm_judge`**: `POST /api/v1/routing/validate` with the minimal
    structurally valid policy — `{"policy": {"version": "1", "model_name":
    "user.laya-judge", "recipe": "collection.router", "components":
    ["llama3.2-1b-FLM", "Qwen3.5-4B-GGUF"], "routing": {"candidates":
    ["llama3.2-1b-FLM", "Qwen3.5-4B-GGUF"], "default_model":
    "llama3.2-1b-FLM", "classifiers": [{"id": "hard", "type": "llm",
    "model": "Qwen3.5-4B-GGUF", "labels": ["EASY", "HARD"],
    "default_label": "EASY", "on_error": "match_false", "prompt":
    "Classify how hard this request is for a 1-billion-parameter language
    model to answer correctly. HARD if it needs multi-step reasoning or
    specialist knowledge, EASY otherwise."}], "rules": [{"id": "hard-to-big",
    "match": {"classifier": "hard", "label": "HARD", "min_score": 0.5},
    "route_to": "Qwen3.5-4B-GGUF"}]}}, "prompt": <question text>}` (every
    `route_to`, `default_model`, and classifier `model` is in `components`
    per `docs/api/lemonade.md:126-128`); record `matched_rule`
    (`hard-to-big` ⇒ HARD) and wall ms; the judge always sees the 1B in the
    prompt even on the 4B fallback, and §8 notes self-judging in that case.
    (e) **I2 adequacy**: Laya `noul` "Is `answer` a correct and adequate
    answer to `request`?" over `{request: <question text>, answer:
    answer_text}` on the root checkpoint; record `answers["adequate"]["noul"]`.
    (f) **I1 difficulty for every graded id**: for each graded id missing
    from `laya.per_prompt`, run `agent.predict({"request": <question text>},
    laya.router_questions())` on the root checkpoint and store the same four
    fields as Step 2 (reuse Step 2's entries for ids it already covers), so
    the AUC in `report` is over **all** graded items, never an intersection.
  - `bench.py report`: rank-based ROC-AUC (ties averaged, pure Python — no
    sklearn) of each signal against `correct == False` — signals:
    `difficulty_score`, `1 - adequate_noul`, `-own_logprob`, `easy_challenge`,
    `min_chars`, `llm_judge == HARD`; secondary AUC against
    `split == Challenge`; latency: the **kill-line p50/p95 comes from the
    Step 2 idle run only**, with the (f) p50 (measured while lemonade calls
    interleaved) reported beside it and labelled as such; `llm_judge`
    p50/p95; realised positive/negative/unparseable counts; the top few
    greedy tokens by count from (a) so a reader sees whether the logprob
    baseline measured letter confidence or formatting confidence; PASS/KILL
    line per pre-registered criterion; write `results/halo-2026-09-22.md`
    with the host prefix on every table. The I2 question dict passed to
    `predict` uses key `"adequate"` with `"type": "noul"` so
    `answers["adequate"]["noul"]` holds.
  - `bench.py contention` (run if the graded run finished in < 30 min wall,
    else mark unmeasured): re-run `laya-latency --n 40` while a background
    thread **loops** streaming 512-token completions from `Qwen3.5-4B-GGUF`
    (iGPU) until the latency loop signals done, then cancels; repeat with
    `llama3.2-1b-FLM` (NPU) only if the probe passed; join the thread on
    every exit path (`try/finally`); report the two p50s next to the idle
    p50. No load generators; nothing outlives the script (`pgrep -f bench.py`
    empty afterwards).
  For **I3** or **I7** instead: implement only that spec arm with the same
  `report` machinery and the spec's kill line carried verbatim — I3: 120
  premise/hypothesis pairs from `facebook/xnli` `en` validation parquet,
  `noul` "Is the hypothesis supported by the premise?", **kill if AUC < 0.75
  or p50 ≥ 250 ms**; I7: 60 real `Qwen3.5-4B-GGUF` completions on ARC
  prompts + 60 synthetic garbage outputs (random tokens, repeated n-grams),
  `noul` "Is this a coherent answer to the prompt?", **kill if AUC < 0.95**,
  stated as necessary-not-sufficient.
  Done when: JSON + MD are committed, `report` prints PASS/KILL per
  criterion, and `/api/v1/health` residency at run time is in the JSON.

- [ ] **Step 4 — fill §1 and §8 of the doc from the results.** (sonnet; needs Step 3)
  Replace both placeholders: §8 copies the results tables verbatim (host
  prefix intact) and lists every unmeasured cell (iGPU torch, NPU, power,
  any baseline that returned null, the contention halves that did not run);
  §1 states the top recommendation, the kill criterion, the effort range
  (1–2 days for the next step, scoped), and the prototype verdict
  (proved / killed / unmeasurable) with the deciding number. Do not edit §6.
  Then run the acceptance sweep from the spec: ≥ 5 ranked ideas; every
  number labelled; every lemonade claim cited; no claim that Laya plugs into
  `/v1/classify`; `git diff --stat main...HEAD` touches nothing under
  `pkgs/`, `modules/`, `flake.nix`.
  Done when: no `PENDING` remains and the sweep passes.

- [ ] **Step 5 — fast deterministic gate** (worker runs; no subagent)
  `nix-instantiate --parse experiments/laya/shell.nix`,
  `nix-shell experiments/laya/shell.nix --run "python -m py_compile experiments/laya/bench.py"`,
  `nix flake check --no-build`, `git diff --stat main...HEAD`, and
  `python3 -c 'import json; json.load(open("experiments/laya/results/halo-2026-09-22.json"))'`.
  Loop to green, then the review gate.

## Acceptance (spec checklist, verbatim)

- [ ] `docs/research/typed-decisions-local-models.md` exists, ranks ≥ 5 distinct ideas (target ≥ 8), names one top recommendation with a kill criterion and an effort range.
- [ ] Every performance claim is measured-with-host or marked unmeasured.
- [ ] Every lemonade capability is cited to `lemonade-sdk/lemonade@v11.9.0`; the #2384 sentence is flagged, not resolved; no claim that Laya plugs into `/v1/classify` today.
- [ ] Prototype lives only under `experiments/laya/`, is not a flake output; nothing under `pkgs/`, `modules/`, `flake.nix` changes.
- [ ] PR assigned to @me, body carries `Closes #149`.

## Risks carried from the spec

Weights/torch fetch time (single checkpoint first); `transformers 5.17` import failure is reported as a result, not patched; NPU possibly held by a sibling task → pre-registered 4B fallback and self-judging noted in §8; grading up to 400 items takes minutes → cached and resumable.
