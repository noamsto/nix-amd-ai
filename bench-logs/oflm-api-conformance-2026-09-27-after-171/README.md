# OFLM-Next server-api conformance vs patched `flm serve`, on halo (after #171)

Rerun of PR #169's
[`oflm-api-conformance-2026-09-27`](../oflm-api-conformance-2026-09-27/) suite
against the `flm serve` build patched for #171 (request validation, the
NPU-lock RAII guard, and the extended error-status mapping). Same host, same
models, same `run_spec_tests.py` shim, same OFLM-Next commit — only the
patched package under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`).
**`flm --version`:** `FLM v1.0.6`, built by this branch's
`pkgs/fastflowlm/patches/server-error-handling.patch` +
`pkgs/fastflowlm/patches/request-validation.patch` (suite run against out
path `fastflowlm-1.0.6`; a later
review round extended `safe_dump()` coverage to two more serialization sites
that none of these probes exercise — the AC2 probes below were rerun on the final out path
`fastflowlm-1.0.6`, re-verified
after that change).
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890` (same as
PR #169).
**Models:** `llama3.2:1b` (chat) and `embed-gemma:300m` (embedding), both
already pulled.

Exact commands (chat server on port 58601, embed server on port 58602 — the
patched binary needs `LD_LIBRARY_PATH` pointed at the XDNA driver plugin
directory to see the NPU at all when run outside the NixOS module's wrapper,
per #148; the module-wrapped `fastflowlm-wrapped` binary needs no such
override):

```
LD_LIBRARY_PATH=$XRT_LIB_DIR \
  flm serve llama3.2:1b --port 58601
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_error_status.py
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_finish_reason.py
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_request_validation.py

LD_LIBRARY_PATH=$XRT_LIB_DIR \
  flm serve llama3.2:1b --embed 1 --port 58602
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_EMBED_MODEL=embed-gemma:300m \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_embed_task_prompt.py
```

Unlike PR #169's run, `flm serve` never crashed and needed no restart between
files — that is the headline result below. Each server was stopped by
tracked PID after its file(s), verified against a `pgrep -af flm` baseline
(empty before and after — no `lemond`-owned process was touched; `lemond`
itself, pid unchanged across the whole run, was left running throughout).

## Before/after pass/fail comparison

| Test file | Before (PR #169) | After (#171) |
| --- | --- | --- |
| `test_error_status.py` | PASS 1, FAIL 5, ERROR 2 | PASS 2, FAIL 5, ERROR 1 |
| `test_finish_reason.py` | PASS 7 | PASS 7 (unchanged) |
| `test_request_validation.py` | PASS 0, FAIL 14, SKIP 8 | **PASS 14**, FAIL 0, SKIP 8 |
| `test_embed_task_prompt.py` | FAIL 3, SKIP 8 | FAIL 3, SKIP 8 (unchanged) |

**`test_request_validation.py` went from 0 passes to all 14** — every
`POST {}` / wrong-type / non-string-`request_id` case that used to crash or
cascade-fail the server (see PR #169's "Server crashes" section) now returns
a proper 400 and the server keeps serving. This is bug 1 (crash on a missing
required field) and part of bug 2 (the non-string `request_id` lock leak,
ported from OFLM-Next alongside `safe_dump`) from #171, confirmed on
hardware.

**`test_error_status.py`'s `test_a_body_that_is_not_json_is_refused_and_the_server_keeps_serving`
moved from ERROR (60s alarm, NPU lock leaked) to PASS** — this is bug 2 (the
invalid-UTF-8 double-throw that used to leak the NPU lock permanently),
confirmed on hardware; see also the AC3 probe below, whose server log brackets the request with
`NPU Locked!`/`NPU Lock Released!` lines.

## AC2-AC4 manual probes

Manual probes from #171's own acceptance criteria, run against the same
patched build: AC2 (5 missing-required-field probes, each
4xx, server answers a normal chat request afterward), AC3
(invalid-UTF-8 body, 4xx, `NPU Locked!`/`NPU Lock Released!` bracket it, a
normal request afterward completes), AC4 (`/v1/embeddings`
with no `model`, 4xx not 200).

## Remaining failures — all out of scope for #171

Unchanged from PR #169's baseline; #171 did not touch either area:

| Test | Reason |
| --- | --- |
| `test_unknown_model_is_refused_with_a_400_error_body`, `test_error_code_is_a_string`, `test_no_error_body_comes_back_with_a_2xx_status`, `test_unknown_model_is_not_answered_by_another_model`, `test_unknown_model_is_refused_in_streaming_mode_too`, `test_a_refused_request_leaves_the_served_model_loaded` | Model-identity substitution: an unrecognized model tag is still answered fluently by whatever model is loaded, echoing the requested tag back. Explicitly out of scope per #171's task. |
| `test_an_unknown_task_name_is_refused`, `test_a_non_string_prompt_name_is_refused`, `test_an_embedding_request_naming_another_model_is_refused` | Embedding prompt-name / model-identity validation on `/v1/embeddings`. Explicitly out of scope per #171's task. |
| `test_embeddings_*` SKIPs (8 in `test_request_validation.py`, 8 in `test_embed_task_prompt.py`) | Suite-assumption gaps — gated on `bge-base:en-v1.5` / `nomic-embed-text:v1.5`, neither of which FLM ships; only `embed-gemma:300m` was tested. Same as PR #169's baseline. |

See #171's PR body for the model-identity-substitution and
embedding-prompt-name-validation follow-up notes.
