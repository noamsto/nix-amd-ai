# `flm serve` honours `prompt_name`/`task_type` on `/v1/embeddings` (#174), on halo

Red/green for #174 plus task-prompt probes, using the same method as
[`oflm-api-conformance-2026-09-28-after-175`](../oflm-api-conformance-2026-09-28-after-175/):
the same `run_spec_tests.py` shim, the same OFLM-Next commit, and the same
models and ports. Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Old build (red):** the #175 tip (`9397a50`, no `embed-task-prompt.patch`),
`fastflowlm-1.0.6`.
**New build (green):** this branch, adding `pkgs/fastflowlm/patches/embed-task-prompt.patch`
after `no-exception-text.patch`,
`fastflowlm-1.0.6` (the branch head,
which after the #178/#183 squash also carries `ps-loaded-models.patch`; that
patch touches `/api/ps` only and not the embedding path). This is the #182 review
fix pass: the patch's task helpers and the `handle_embeddings` resolution block
are now under one `FASTFLOWLM_LINUX_LIMITED_MODELS` guard (see below), and
`embed-task-probes.py`'s alias rows assert the non-default task. (`8gq9j6m6...`,
`r2csw5wb...` and `mwmqyki...` carried the same guard; `5kacynz5...` was the
pre-guard patch. The probes here were rerun with the repaired alias checks.)
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`
(`specs/server-api/spec.md:147-193`, `SERVER-EMBED-TASK-PROMPT`).
**Models:** `llama3.2:1b` (chat), `gemma4-it:e4b` (chat), `embed-gemma:300m`
(embedding). All already pulled.
**Ports:** 58601 chat, 58602 embed, 58603 gemma4.

Commands (run from this directory; `$FLM` = the build's `bin/flm`,
`LD_LIBRARY_PATH` as in the #171 README, per #148):

```
LD_LIBRARY_PATH=$XRT_LIB_DIR \
  $FLM serve llama3.2:1b --embed 1 --port 58602
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_EMBED_MODEL=embed-gemma:300m \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_embed_task_prompt.py
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_EMBED_MODEL=embed-gemma:300m \
  python3 embed-task-probes.py --dump probes-new.json
```

Each server was stopped by PID after its tests. `pgrep -a flm` and `pgrep -a
oflm` were empty before every server run and after the last; `lemond` kept
running with no model loaded (`all_models_loaded: []`). The NPU is
single-tenant, so a probe run made while another process held it produced
non-reproducible document vectors; the runs reported here had the NPU
quiet (checked before each run).

## Red/green: `test_embed_task_prompt`

| Test | Old build | New build |
| --- | --- | --- |
| `test_an_unknown_task_name_is_refused` (`prompt_name="not_a_task"`) | **FAIL** 200 + vector | **PASS** 400 `invalid_value` |
| `test_a_non_string_prompt_name_is_refused` (`prompt_name=7`) | **FAIL** 200 + vector | **PASS** 400 `invalid_value` |
| `test_an_embedding_request_naming_another_model_is_refused` | PASS | PASS |
| the other 8 | SKIP (need nomic/bge, not shipped) | SKIP |

Old: `FAIL 2, PASS 1, SKIP 8`.
New: `FAIL 0, PASS 3, SKIP 8`.
`embed-gemma:300m` declares no prompt names, so the "a model that declares
prompts requires one" half of the requirement stays SKIP — the same
suite-assumption gap as the #171/#175 runs.

## Task-prompt probes

[`embed-task-probes.py`](embed-task-probes.py) checks both the vector
behaviour and the refusals. The alias rows compare against the **non-default**
`document` task (and assert the result is not the query vector), so a server that
ignores `task_type` fails them instead of passing by comparing against the
default. Old build `10 FAIL`;
new build all PASS.

| Probe | Old | New |
| --- | --- | --- |
| no `prompt_name` -> 200, default `task_query` | PASS | PASS |
| `query` and `document` differ | **FAIL** cosine 1.000000 | PASS cosine 0.957706 |
| each prompt reproducible | PASS | PASS |
| `task_type` alias (`task_type=document`) | **FAIL** returns the query vector | PASS |
| agreeing spellings (`prompt_name=document, task_type=search_document`) | **FAIL** returns the query vector | PASS |
| disagreeing spellings -> 400 `invalid_value` naming both | **FAIL** 200 | PASS |
| unknown name -> 400 `invalid_value`, message quotes it and the accepted names | **FAIL** 200 | PASS |
| non-string `prompt_name`/`task_type` -> 400 `invalid_value` | **FAIL** 200 | PASS |

### LIMITED build guard

`embed-task-prompt.patch`'s task helpers and the `handle_embeddings`
resolution block reference `embedding_task_type_t`, which `rest_handler.hpp`
only pulls in when embedding models are built. They are now under the same
`#ifndef FASTFLOWLM_LINUX_LIMITED_MODELS` as the embed loop they feed, so a
LIMITED build stops failing on the undeclared enum. Scratch compile of the
patched `rest_handler.cpp` with `-DFASTFLOWLM_LINUX_LIMITED_MODELS=1` (cmake +
ninja, full dependency include path):

- pre-guard patch: fails with `'embedding_task_type_t' was not declared in this scope` (`rest_handler.cpp:84`).
- post-guard patch (this branch): compiles clean.

### Manual prefix check

`embed-gemma`'s prefixes are known
from `_get_task_prefix()`: `query` -> `"task: search result | query: "`,
`document` -> `"title: none | text: "`. The old build applies the query prefix
unconditionally, so its no-prompt vector **is** the query prefix applied by
hand: it is byte-identical to the new build's `prompt_name="query"` vector
(cosine 1.0). For `document`, v1.0.6 has no unprefixed embedding path —
`embed()` always prepends `_get_task_prefix()` — so `f("title: none | text: " + T)`
cannot be produced through the API for a byte comparison; the prefix and the
name->enum mapping are established by source, and `prompt_name="document"` is
reproducible and differs from `query`.

Decision on a request with no `prompt_name` (documented in the PR): keep
today's default `task_query`. `embed-gemma` declares no prompt names (its
prefixes are hardcoded), which is the spec's OpenGemma case; the spec only
*requires* a prompt when the model declares names, so this is backward
compatible.

## No regressions

| Test file | After #175 | After #174 |
| --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 |
| `test_finish_reason.py` | PASS 7 | PASS 7 |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 |

Each file's sorted PASS/FAIL/SKIP lines diff empty against after-175.
