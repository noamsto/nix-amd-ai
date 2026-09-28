# `flm serve` `GET /api/ps` with no chat model loaded (#178), on halo

Red/green for #178, and a rerun of OFLM-Next's server-api conformance suite
using the same method as
[`oflm-api-conformance-2026-09-28-after-174`](../oflm-api-conformance-2026-09-28-after-174/):
the same `run_spec_tests.py` shim, OFLM-Next commit, models and ports. Only the
`flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Old build (red):** the #174 tip (`de32509`, no `ps-loaded-models.patch`; its
tree is identical to `328ebd2`, #182's squash-merge that this branch sits on),
`/nix/store/8gq9j6m68klpv79xs933s1m4xqvgxjg6-fastflowlm-1.0.6`. This is the same
out path the after-174 run ended on.
**New build (green):** this branch, adding `pkgs/fastflowlm/patches/ps-loaded-models.patch`
after `embed-task-prompt.patch`,
`/nix/store/hyfz6rf9453d7p322vczrkc7wv8qxaq4-fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` and `gemma4-it:e4b` (chat), `embed-gemma:300m` (embedding).

`pgrep -a flm` was empty before and after every run. `lemond` had no model
loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was left
running and never touched. Each `flm serve` was stopped by its PID.

## Red/green: `/api/ps` per server state

[`probes.sh`](probes.sh) `<flm> <outdir>` starts `flm serve` once per state on
port 58601 (with `LD_LIBRARY_PATH` as in the #171 README, per #148). It reads
`GET /api/ps` and checks the result against the oracle. Old build:
[`before/probes.txt`](before/probes.txt). New build: [`probes.txt`](probes.txt).
Server logs are the `server-<state>.log` files.

| State (`flm serve …`) | Expected | Old build | New build |
| --- | --- | --- | --- |
| `embed-gemma:300m` (non-chat tag) | 200 `{"models":[]}` | **400** `Invalid request` | 200 `{"models":[]}` |
| no tag | 200 `{"models":[]}` | **400** `Invalid request` | 200 `{"models":[]}` |
| `llama3.2:1b` | 200, one `llama3.2:1b` entry | 200, one entry | 200, same entry |
| `--embed 1`, no tag | 200, `embed-gemma:300m` | **400** `Invalid request` | 200, `embed-gemma:300m` |
| `llama3.2:1b --embed 1` | 200, `llama3.2:1b` then `embed-gemma:300m` | 200, `llama3.2:1b` only | 200, both |
| `embed-gemma:300m`, then a chat request for `llama3.2:1b` | 200, `llama3.2:1b` | 200, `llama3.2:1b` | 200, `llama3.2:1b` |

On the old build, the 400 body is the generic one from
`no-exception-text.patch`. The cause is in the server log:
`[ERROR] handle_ps: [json.exception.invalid_iterator.207] cannot use key() for
non-object iterators`. `handle_ps` looked up the `model-faker` sentinel, and
`rectify_model_tag` indexed a missing key on a const json. That is undefined
behavior, so a 400 was not guaranteed either. The new build never looks the
sentinel up. It lists the chat model only while a chat engine is loaded. The
`llama3.2:1b` entry has the same fields and values as before; only
`expires_at` differs.

The two `--embed 1` rows also show the embedding change. A loaded embedding
model is now listed after the chat model, because Ollama's `/api/ps` lists
every model resident in memory, embedding models included. OpenFlowLM-Next's
`specs/server-api/spec.md` has no `/api/ps` requirement, and its `handle_ps`
has the same single-entry code (both at the pinned commit and at current
`main`, `8c83712`). Whisper (`--asr 1`) is not listed: Ollama has no speech
models, and no `/api/*` endpoint can use one.

**After a failed load:** not reproduced. The one cheap trigger, a model the
downloader reports as incompatible, is refused before anything is unloaded,
so the served model stays loaded and the sentinel is never set. Every path in
`ensure_model_loaded` that does set it also resets `auto_chat_engine`. That is
the same state as the two no-chat startups above. The patch keys on the
engine, so the sentinel is never looked up.

## Conformance rerun

[`conformance.sh`](conformance.sh) `<flm> <outdir> <oflm-next>` runs the same
servers and test files as the after-174 run: llama on 58601, gemma4 on 58603,
and llama with `--embed 1` on 58602. Server logs are `server-conformance-*.log`.

| Test file | After #174 | After #178 | Log |
| --- | --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 | [log](test_error_status.log) |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 | [log](test_error_status.gemma4.log) |
| `test_finish_reason.py` | PASS 7 | PASS 7 | [log](test_finish_reason.log) |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 | [log](test_request_validation.log) |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 | [log](test_request_validation.embed.log) |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 | [log](test_embed_task_prompt.log) |

For each file, the sorted per-test PASS/FAIL/SKIP lines are identical to the after-174 logs.
