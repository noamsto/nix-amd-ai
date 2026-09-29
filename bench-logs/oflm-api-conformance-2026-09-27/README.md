# OFLM-Next server-api conformance vs `flm serve`, on halo

First run of OpenFlowLM-Next's server conformance spec against this flake's
FastFlowLM server. Refs #147, closes #164. Step 5 of the recommendation in
[`docs/research/openflowlm.md`](../../docs/research/openflowlm.md) §4.2.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`).
**`flm --version`:** `FLM v1.0.6`, resolved from
`fastflowlm-wrapped/bin/flm` — this
flake's build, carrying the `pkgs/fastflowlm/patches/http-error-status.patch`
fix for #157.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`
([Atomic-Germ/OpenFlowLM-Next](https://github.com/Atomic-Germ/OpenFlowLM-Next)),
cloned into a scratch dir outside this repo; the engine was **not** built.
**Models:** `llama3.2:1b` (chat, already pulled) and `embed-gemma:300m`
(embedding, pulled for this run — ~620 MB, cheap).

## What actually ran

The task named `oflm-test --api`/`--embedding`, but that CLI (`utilities/oflm-test/`)
depends on the `openai` Python SDK and friends — not stdlib-only. The spec
itself (`specs/server-api/spec.md:28-32`) says the **real** stdlib-only
artifact is `specs/server-api/tests/*.py`: four files that import nothing but
`urllib`/`json`/`math`, and additionally `pytest` for markers only ("a bare
checkout can run them against a running server without installing the
`oflm-test` package first"). No `pytest` was on this host, so this run used
[`run_spec_tests.py`](run_spec_tests.py), a ~140-line stdlib-only shim that
implements just enough of `pytest.mark.skipif`/`parametrize` to collect and
run those four files with plain `python3`, in their original definition order
(critical — see below), with a per-test wall-clock guard (`signal.alarm`) so
one hung/crashed request doesn't silently swallow the rest of a run. This
corrects `docs/research/openflowlm.md` §4.2's loose citation, which conflated
the CLI and the stdlib-only tests under one "stdlib-only Python" label.

Exact commands (chat server on port 58521, embed server on port 58522):

```
git clone https://github.com/Atomic-Germ/OpenFlowLM-Next <scratch>/oflm-next
git -C <scratch>/oflm-next checkout eb656007856579c38bafaaa7f86f2f08cc980890

flm serve llama3.2:1b --port 58521
OFLM_TEST_BASE_URL=http://127.0.0.1:58521 OFLM_TEST_MODEL=llama3.2:1b \
  python3 run_spec_tests.py <scratch>/oflm-next/specs/server-api/tests/test_error_status.py
OFLM_TEST_BASE_URL=http://127.0.0.1:58521 OFLM_TEST_MODEL=llama3.2:1b \
  python3 run_spec_tests.py <scratch>/oflm-next/specs/server-api/tests/test_finish_reason.py
OFLM_TEST_BASE_URL=http://127.0.0.1:58521 OFLM_TEST_MODEL=llama3.2:1b \
  python3 run_spec_tests.py <scratch>/oflm-next/specs/server-api/tests/test_request_validation.py

flm serve llama3.2:1b --embed 1 --port 58522   # loads embed-gemma:300m, FLM's only pulled embed model
OFLM_TEST_BASE_URL=http://127.0.0.1:58522 OFLM_TEST_EMBED_MODEL=embed-gemma:300m \
  python3 run_spec_tests.py <scratch>/oflm-next/specs/server-api/tests/test_embed_task_prompt.py
```

`flm serve` was restarted between files whenever a prior test crashed it (see
below); each server was stopped by tracked PID after the run, verified against
a `pgrep -af flm` baseline (empty before and after — no lemond-owned process
was touched).

## Pass/fail table

| Test file (traces) | PASS | FAIL | ERROR | SKIP |
| --- | --- | --- | --- | --- |
| `test_error_status.py` (SERVER-ERROR-STATUS, SERVER-MODEL-IDENTITY) | 1 | 5 | 2 | 0 |
| `test_finish_reason.py` (SERVER-FINISH-REASON, SERVER-STREAM-PARITY) | 7 | 0 | 0 | 0 |
| `test_request_validation.py` (SERVER-REQUEST-VALIDATION) | 0 | 14 | 0 | 8 |
| `test_embed_task_prompt.py` (SERVER-EMBED-TASK-PROMPT, SERVER-MODEL-IDENTITY) | 0 | 3 | 0 | 8 |

**SERVER-FINISH-REASON and SERVER-STREAM-PARITY are fully compliant** on FLM
1.0.6 — the only clean pass in this run.

## AC2 — verifying #157's status-code fix on hardware

**Documented failure of this check.** Every request built to land in one of
the three `code:500` `catch` blocks that #157's patch maps to a real HTTP
status (`handle_openai_chat_completion`, `handle_openai_audio_transcriptions`,
`handle_openai_completion` in FastFlowLM's `rest_handler.cpp`) instead crashed
the server outright before any response was constructed — undefined behavior
(`request["field"]` on a `const json&` for a missing key) fires before the
`catch` mechanism gets a chance to run, so the very code path #157 fixed the
*status of* is never reached in these cases. See the status-code check and
"Server crashes" below.

The one clean, reproducible, non-crashing case of an error body sent back
with a `2xx` status found on hardware:

```
POST /v1/embeddings {"input":"probe"}     (no "model" field; on a chat+embed server or one with no embed model loaded)
→ HTTP 200
  {"error":"[json.exception.type_error.302] type must be string, but is invalid"}
```

This *does* verify something about #157, just not the "confirmed" direction:
the patch (`pkgs/fastflowlm/patches/http-error-status.patch`) only maps a
status when `response_data["error"]` is a JSON **object** with a `.code`
field (`if (code >= 400 && code <= 599)`). This response's `"error"` is a bare
**string** — `.contains("code")` on a JSON string returns `false` without
throwing — so the mapping code is never even reached, and the status stays
the default `http::status::ok`. **#157's fix does not cover this error
shape**, confirmed on hardware.

## Server crashes (the dominant finding)

`POST {}` (a required field missing entirely) crashed the whole `flm serve`
process — not a wrong status, no response at all (`curl` exit 56, then
`ECONNREFUSED` on every subsequent request until restart) — independently
confirmed on:

- `/api/show` (probe 2)
- `/v1/chat/completions` (probe 3, and again as the first case in
  `test_request_validation.py`'s parametrized `REQUIRED` list)
- `/api/generate` (probe 5)

`/api/chat` and `/v1/completions` were **not independently isolated** — their
FAILs in the `test_request_validation.py` run are cascading `ECONNREFUSED` from the
`/api/show` crash earlier in the same parametrize sequence, not their own
confirmed crash. Given the pattern above and the fact that all five endpoints
share the same `request["field"]`-on-missing-key code shape
(`SERVER-REQUEST-VALIDATION`'s own text: "on this build it segfaults... `POST
{}` killed the server on `/api/show`, `/api/generate`, `/v1/completions` and
`/v1/embeddings`"), a crash on those two as well is likely but **not
measured** in this run.

Separately, a non-JSON body containing an invalid UTF-8 byte
(`test_a_body_that_is_not_json_is_refused_and_the_server_keeps_serving`)
reproduced the exact double-throw described in
[`docs/research/openflowlm.md`](../../docs/research/openflowlm.md) §4.1 and in
`specs/server-api/spec.md`'s `SERVER-ERROR-STATUS` section: the server logs
`🟢 NPU Locked!`, then throws a second time trying to report the malformed
bytes (`invalid UTF-8 byte at index 174`), and never logs `🔵 NPU Lock
Released!` — every later NPU-needing request queues forever. This is why
this test file's def-order matters: the file's own comment says it is "last
on purpose", and an earlier, buggy version of `run_spec_tests.py` that
alphabetized test names instead of preserving source order ran it *first*,
wedging the NPU before any other test in the file could execute. Fixed before
the recorded run (see `run_spec_tests.py`'s history in this PR).

**Net finding:** the malformed/incomplete-request-body crash and lock-leak
bugs are far more severe on hardware than the status-code-mapping bug #157
fixes — they take the whole server down (or wedge the NPU permanently)
instead of merely returning the wrong HTTP status. #157's carried patch does
not address either.

## Per-failure classification (AC3)

| Test | Verdict | Classification | Evidence |
| --- | --- | --- | --- |
| `test_unknown_model_is_refused_with_a_400_error_body` | FAIL | **FLM deviation** (SERVER-MODEL-IDENTITY) | An unrecognized model tag is answered fluently by whatever model is loaded (here, itself, since only one was loaded), echoing the requested tag back in `model` — HTTP 200, `"choices"` present. `spec.md:70-102`. |
| `test_error_code_is_a_string` | ERROR | Same root cause | `KeyError: 'error'` — there is no error body, because the request above wasn't refused. |
| `test_no_error_body_comes_back_with_a_2xx_status` | FAIL | Same root cause | Same silent-substitution behavior across `/v1/chat/completions`, `/v1/completions`, empty model, `model-faker` sentinel. |
| `test_unknown_model_is_not_answered_by_another_model` | FAIL | Same root cause | `"choices"` present in a response to an unknown-model request. |
| `test_unknown_model_is_refused_in_streaming_mode_too` | FAIL | Same root cause | Same substitution, streaming mode. |
| `test_a_refused_request_leaves_the_served_model_loaded` | FAIL | Same root cause | The premise (a refusal) never holds — nothing to test. |
| `test_a_body_that_is_not_json_is_refused_and_the_server_keeps_serving` | ERROR (60s alarm) | **FLM deviation** (SERVER-ERROR-STATUS / SERVER-REQUEST-VALIDATION) | NPU lock leaked permanently on a malformed-UTF-8 body; see "Server crashes" above. `spec.md:36-68`. |
| `test_an_accepted_request_reports_the_model_it_was_asked_for` | PASS | Compliant | — |
| `test_an_answer_cut_at_max_tokens_reports_length` … (all 7 in `test_finish_reason.py`) | PASS | Compliant | `finish_reason` mapping and stream/non-stream parity both hold. |
| `test_an_empty_object_is_refused_and_the_server_keeps_serving[/api/show]` | FAIL | **FLM deviation** (SERVER-REQUEST-VALIDATION) | Server crash, confirmed independently (probe 2). |
| `test_an_empty_object_is_refused_and_the_server_keeps_serving[/api/generate,/api/chat,/v1/completions,/v1/chat/completions]` | FAIL | **FLM deviation, cascading** | `ECONNREFUSED` after the `/api/show` crash above; `/api/generate` and `/v1/chat/completions` independently confirmed crashing too (probes 5, 3); `/api/chat` and `/v1/completions` not independently isolated (see "Server crashes"). |
| `test_a_required_field_of_the_wrong_type_is_refused[*]` (4 cases) | FAIL | Same cascading crash | Server was already dead from the first test in the file. |
| `test_a_non_string_request_id_is_refused_and_does_not_hold_the_npu[*]` (4 cases) | FAIL | Same cascading crash | Same. |
| `test_a_string_request_id_is_accepted` | FAIL | Same cascading crash | Same. |
| `test_embeddings_*` (7 tests) | SKIP | **Suite assumption** | Gated on `OFLM_TEST_EMBED_MODEL=bge-base:en-v1.5` (the suite's default), which FLM does not ship; only tested against `embed-gemma:300m`, which the module-level probe didn't recognize as ready under that name. Not run this session for either reason (crash, then model-name mismatch). |
| `test_embeddings_without_an_embedding_model_is_refused_not_200` | SKIP | **FLM deviation, found by manual probe instead** | The probe this test depends on (`_post({"input":"probe"})`) returned 200 with a flat `{"error":"..."}` body rather than 400, so the skip guard (which expects to *detect* "no embed model" via a 400) never fired as designed. Manually confirmed as a real deviation — see AC2 section above; same underlying bug as `SERVER-ERROR-STATUS`. |
| `test_a_model_that_declares_prompts_refuses_a_request_without_one`, `test_the_refusal_names_the_offending_value_and_the_accepted_ones`, `test_the_task_prompt_changes_the_vector`, `test_each_task_prompt_is_reproducible`, `test_task_type_is_an_accepted_alias_for_prompt_name`, `test_the_two_spellings_may_both_be_sent_when_they_agree`, `test_prompt_name_and_task_type_that_disagree_are_refused` | SKIP | **Suite assumption** | These need a model that declares prompt names (`nomic-embed-text:v1.5` in the suite's default). FLM does not ship that tag; `embed-gemma:300m` declares none. |
| `test_a_model_with_no_task_concept_refuses_a_prompt_name` | SKIP | **Suite assumption (naming gap)** | Gated on `FAMILY in {bge-base, bge-small, bge-large, all-minilm, gte-multilingual}`; `embed-gemma` isn't in that hardcoded list even though it behaviorally has no task concept (see the two FAILs below) — a suite coverage gap for FLM's own embed tag, not an FLM bug. |
| `test_an_unknown_task_name_is_refused` | FAIL | **FLM deviation** (SERVER-EMBED-TASK-PROMPT) | `prompt_name="not_a_task"` is silently accepted and embedded (HTTP 200 with a vector) instead of refused with 400 `invalid_value`. `spec.md:147-193`. |
| `test_a_non_string_prompt_name_is_refused` | FAIL | Same deviation | `prompt_name=7` (int) also silently accepted. |
| `test_an_embedding_request_naming_another_model_is_refused` | FAIL | **FLM deviation** (SERVER-MODEL-IDENTITY) | A request naming a nonexistent embed model tag (`oflm-test-no-such-embed:0b`) returns `embed-gemma:300m`'s real vectors, labelled with the requested (wrong) tag — the exact bug `spec.md:79-81` describes for bge-base/gte-multilingual, reproduced on FLM's own embed model. |

## Not measured

- **Lemonade's OpenAI endpoint** was not run against the suite — task marked
  this optional ("if cheap"); given the crash-prone findings above, running a
  second target was deprioritized in favor of documenting the FLM findings
  thoroughly.
- **`/api/chat` and `/v1/completions`** crash on `POST {}` — likely, per the
  pattern above and `spec.md`'s own historical account, but not independently
  isolated this session (see "Server crashes").
- **Audio and vision tests** (`oflm-test --audio`/`--vision`) — out of scope;
  the task named only `--api`/`--embedding`.
- **Whether the crash is a segfault or an abort** — the process disappears
  from `pgrep` with no trace in `flm serve`'s own stdout/stderr log
  (`journalctl`/core dump were not checked); "crash" here means "the process
  is gone and the port stops accepting connections," not a confirmed signal.
- **SERVER-PARAM-ISOLATION** (per-request reasoning/temperature leaking across
  clients) — no test file in this OFLM-Next commit's `specs/server-api/tests/`
  covers it (`spec.md:129-146` cites `specs/tool-calling/tests/` instead,
  which is out of this task's scope).
