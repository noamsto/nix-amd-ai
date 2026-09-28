# OFLM-Next server-api conformance vs patched `flm serve`, on halo (after #173)

Red/green for #173 (model-tag substitution), using the same method as
[`oflm-api-conformance-2026-09-27-after-171`](../oflm-api-conformance-2026-09-27-after-171/):
the same `run_spec_tests.py` shim, the same OFLM-Next commit, and the same models.
Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Old build (red):** `main` at `c9d378c`, meaning the #171 patches without #173 —
`/nix/store/8pgdcx429na9a9wxiqiwwa0faz8rm3dl-fastflowlm-1.0.6`. Its logs are in [`before/`](before/).
**New build (green):** this branch, adding `pkgs/fastflowlm/patches/model-identity.patch` —
`/nix/store/lp2xwjayy36j0byma058nrfdvili4b0r-fastflowlm-1.0.6`. Its logs are in this directory.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` and `gemma4-it:e4b` (chat), `embed-gemma:300m` (embedding). All were already pulled.

Commands were run identically against both builds (`$FLM` = the build's `bin/flm`, and
`LD_LIBRARY_PATH` as in the #171 README, per #148):

```
LD_LIBRARY_PATH=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib $FLM serve llama3.2:1b --port 58601
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/{test_error_status,test_finish_reason,test_request_validation}.py

LD_LIBRARY_PATH=... $FLM serve gemma4-it:e4b --port 58603
OFLM_TEST_BASE_URL=http://127.0.0.1:58603 OFLM_TEST_MODEL=gemma4-it:e4b \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_error_status.py   # -> test_error_status.gemma4.log

LD_LIBRARY_PATH=... $FLM serve llama3.2:1b --embed 1 --port 58602
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_EMBED_MODEL=embed-gemma:300m \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_embed_task_prompt.py
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_MODEL=llama3.2:1b OFLM_TEST_EMBED_MODEL=embed-gemma:300m \
  python3 run_spec_tests.py <oflm-next>/specs/server-api/tests/test_request_validation.py   # -> test_request_validation.embed.log
```

Each server was stopped by PID after its tests. `pgrep -a flm` was empty before the first run
and after the last. No `flm` process was owned by `lemond`, and `lemond` kept running throughout.

## Why the suite was also run with gemma4-it:e4b

On a server started with `llama3.2:1b`, an eviction does not show up in the served-model name.
For an unknown tag, the old build's `get_auto_model()` falls back to `llama3.2:1b`, so it evicts
llama and reloads llama. `/api/ps`, and `test_a_refused_request_leaves_the_served_model_loaded`'s
follow-up request, then look identical before and after. A server started with `gemma4-it:e4b`
makes the eviction visible. On the old build, the first bogus request replaces gemma with llama,
so every later test that names gemma reloads it. The old-build gemma failures therefore partly
cascade from that first eviction; they are not separate bugs.

## Before/after

| Test file | Old build | New build | Log |
| --- | --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 2, FAIL 5, ERROR 1 | **PASS 8** | [before](before/test_error_status.log) / [after](test_error_status.log) |
| `test_error_status.py` (gemma4-it:e4b) | PASS 2, FAIL 5, ERROR 1 | **PASS 8** | [before](before/test_error_status.gemma4.log) / [after](test_error_status.gemma4.log) |
| `test_finish_reason.py` | PASS 7 (#171 run) | PASS 7 | [after](test_finish_reason.log) |
| `test_request_validation.py` (chat server) | PASS 14, SKIP 8 | **PASS 15**, SKIP 7 | [before](before/test_request_validation.log) / [after](test_request_validation.log) |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 | [before](before/test_request_validation.embed.log) / [after](test_request_validation.embed.log) |
| `test_embed_task_prompt.py` | FAIL 3, SKIP 8 | FAIL 2, **PASS 1**, SKIP 8 | [before](before/test_embed_task_prompt.log) / [after](test_embed_task_prompt.log) |

- All six unknown-model tests in `test_error_status.py` go from red to green, and so does
  `test_error_code_is_a_string`: unknown tag, `""`, `"model-faker"`, streaming, and
  "a refusal leaves the served model loaded".
- `test_embeddings_without_an_embedding_model_is_refused_not_200` moves from SKIP to PASS on
  the chat-only server. `/v1/embeddings` without `--embed 1` used to answer 200 with a `null`
  body; it now answers 400 `model_not_found`.
- `test_an_embedding_request_naming_another_model_is_refused` goes from red to green.
- The two remaining `test_embed_task_prompt.py` failures, `test_an_unknown_task_name_is_refused`
  and `test_a_non_string_prompt_name_is_refused`, are #174 and out of scope here.
- The SKIPs are gated on `bge-base:en-v1.5` / `nomic-embed-text:v1.5`, which FLM does not ship.
  They are the same as in the #171 run.

## No-eviction evidence (AC3)

[`before/AC3.txt`](before/AC3.txt) / [`AC3.txt`](AC3.txt): a server serving `gemma4-it:e4b`,
then `/api/ps`, a bogus-tag chat request, and `/api/ps` again, with the server log lines that
request produced.

- **Old:** HTTP 200 with `"model":"oflm-test-no-such-model:0b"`. `/api/ps` flips to
  `llama3.2:1b`. The log shows `Model tag '...' is not supported` followed by
  `Loading model: .../Llama-3.2-1B-NPU2`.
- **New:** HTTP 400 `model_not_found`. `/api/ps` still shows `gemma4-it:e4b`. The log shows
  only `unknown model '...' -- refusing; 'gemma4-it:e4b' stays loaded`, with no load. Across the
  whole new-build gemma suite, the server log has exactly one `Loading model` line (startup).

[`probes.txt`](probes.txt) runs the other endpoints on the new build against a `llama3.2:1b`
server, with `/api/ps` checked after each request:

| Request | Result |
| --- | --- |
| unknown tag, `""`, `"model-faker"` on `/v1/chat/completions` | 400 |
| unknown tag on `/v1/completions`, `/api/chat`, `/api/generate` | 400 |
| `embed-gemma:300m` on the chat endpoint | 400, not a chat model |
| omitted `model` | 200, served by the loaded model |
| `Ollama/llama3.2:1b` and bare `llama3.2` | 200, with no reload |

The server log shows one `Loading model` line in total.

[`embed-probes.txt`](embed-probes.txt) covers `/v1/embeddings`:

| Request | Result |
| --- | --- |
| `embed-gemma:300m` or bare `embed-gemma` | 200 |
| an unknown tag or `""` | 400, naming the loaded model |
| omitted `model` | 400 `missing_required_parameter` (unchanged, #171 AC4) |

[`startup-nonchat.txt`](startup-nonchat.txt) is `flm serve embed-gemma:300m`, a known tag that
is not a chat model. The old build loaded llama3.2:1b in its place. The new build starts with no
chat model:

| Request | Result |
| --- | --- |
| omitted `model` | 400 `model_not_found` |
| `llama3.2:1b` named explicitly | loaded and served (200) |

In this no-model state, `GET /api/ps` answers 400 with a JSON-exception body. That is the
existing `model-faker` behaviour of `handle_ps`, which this change does not touch; it is tracked
as a follow-up.

## Not probed live: known-but-unloadable → 500

This path was not probed live. It needs a known, already-pulled model whose load fails: a
corrupted model directory, or an unpulled tag with the network cut. Neither is safe to set up on
the owner's machine; an unpulled tag starts a multi-GB download. Code path:
`ensure_model_loaded()` catches a `load_model()` exception, or sees an `Incompatible` download
status, and returns `ModelLoad::LoadFailed`. `model_error()` turns that into
`{"type":"server_error","code":"model_load_failed"}`. The `send_response` status mapping in
`server.cpp` maps a non-numeric-code error of type `server_error` to 500.
