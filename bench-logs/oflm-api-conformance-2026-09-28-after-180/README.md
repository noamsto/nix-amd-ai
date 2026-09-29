# `flm serve` non-streaming `/api/chat` decode faults (#180), on halo

Red/green for #180. This directory also holds a byte-for-byte check of the
normal response and a rerun of OFLM-Next's server-api conformance suite. The
rerun uses the same method as
[`oflm-api-conformance-2026-09-28-after-178`](../oflm-api-conformance-2026-09-28-after-178/),
with the same `run_spec_tests.py` shim, OFLM-Next commit, models and ports.
Only the `flm` build under test changed.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver `amdxdna`).
**Base build:** the #178 tip, without `chat-decode-fault.patch`,
`fastflowlm-1.0.6`. This is the
out path the after-178 run ended on.
**New build:** this branch, which adds `pkgs/fastflowlm/patches/chat-decode-fault.patch`
after `ps-loaded-models.patch`,
`fastflowlm-1.0.6`.
**Fault-injection builds:** these add [`inject-faults.patch`](inject-faults.patch),
a scratch patch that is not in `default.nix`. It throws `std::runtime_error`
from `AutoModel::_shared_generate` when `FLM_INJECT_DECODE_FAULT` is set, and
from `AutoModel::_chunked_insert` when `FLM_INJECT_PREFILL_FAULT` is set.
Red (base + injection): `fastflowlm-1.0.6`.
Green (new + injection): `fastflowlm-1.0.6`.
**Rebase:** the runs below were made before this branch was rebased onto
`74dec24`, which changes only `embed-task-prompt.patch` (`handle_embeddings`).
The patch applies unchanged there. The final build is
`fastflowlm-1.0.6`: the rebased
tree plus a comment-only rewording in the patch, so the code it compiles is
unchanged.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models:** `llama3.2:1b` and `gemma4-it:e4b` (chat), `embed-gemma:300m` (embedding).

`pgrep -a flm` was empty before and after every run. `lemond` had no model
loaded (`/api/v1/health` returned `all_models_loaded: []`), so it was left
running and never touched. Each `flm serve` was stopped by its PID.

## Why not the `insert()` + `generate()` split

The issue suggested the split the other handlers use. It would change the
answer for some model families, because `generate_with_prompt()` is not
`insert()` followed by `generate()` for these classes:

- `Qwen3_5VL` and `Qwen3_6_MOE` checkpoint and restore the engine, then
  decode with `_shared_generate`. Their `generate()` is a separate loop that
  forces think tokens.
- `GPT_OSS` wraps the result in `<|start|>assistant…<|end|>`, and `generate()`
  does not.

`Gemma4e` and `Nanbeige` also decode through a different routine, but on
reading the code it samples the same way. Only engine state differs
(checkpoint placement, a forward pass on EOS), and cancellation and logging.
That equivalence was read from the code and was not measured.

The patch therefore keeps the `generate_with_prompt()` call and classifies the
fault by phase. `meta_info` is a per-request local, and `prompt_tokens` starts
at 0. Every insert path sets it right after prefill: `AutoModel::_shared_insert`,
`Qwen3VL_Flash::insert` and `Qwen3_5_Omni::insert`. Nothing else writes it. A
fault while it is still 0 (template, tokenize, prefill) stays 400
`invalid_request_error`, and a fault after it is set (sampling, decode) is 500
`server_error`.

**Residual:** a runtime fault *during* prefill stays 400. The `insert()` catch
in every other handler does the same. A path that left the count at 0 would
also keep today's 400, for example a prompt served entirely from the prefix
cache. That cannot happen on `/api/chat`, because the chat template always ends
the prompt with a generation prompt that the cached history does not
contain.

## Red/green: fault injection

[`probes.sh`](probes.sh) `<flm> <outdir>` starts `flm serve llama3.2:1b --port
58601` once per mode, with `LD_LIBRARY_PATH` set as in the #171 README (#148).
It checks each probe against the oracle. The probe and server logs are not committed; rerun `probes.sh`.

| Mode | Probe | Expected | Red build | Green build |
| --- | --- | --- | --- | --- |
| decode fault | non-stream `/api/chat` | 500 `{"message":"Internal error","type":"server_error"}` | **400** `Invalid request` | 500, generic body |
| decode fault | non-stream `/api/generate` (control) | 500, generic | 500 | 500 |
| prefill fault | non-stream `/api/chat` | 400 `Invalid request` (residual) | 400 | 400 |
| none | `/api/chat` with `"options":"x"` | 400 `Invalid request` | 400 | 400 |
| none | normal `/api/chat` | 200 | 200 | 200 |

Each server log carries the detail, and no body does. The logs read
`[ERROR]  handle_chat: injected decode fault`,
`[ERROR]  handle_chat: injected prefill fault`, and the nlohmann error for
`"options":"x"`.

A chat-template rejection probe was skipped. `llama3.2:1b`'s template raises
only for tools in a system-only conversation, and `/api/chat` does not pass
`tools` to the template, so that branch cannot be reached from this route. The
request returned 200 on both builds.

## Normal path: byte-for-byte

[`normal-path.sh`](normal-path.sh) `<flm> <prefix>` sends a greedy
(`"top_k":1`, `num_predict` 64) non-streaming `/api/chat` twice, to
`llama3.2:1b` and then to `gemma4-it:e4b`. Timing fields (`total_duration`,
`load_duration`, `prompt_eval_duration`, `eval_duration`) are removed. The
two runs within each build are identical. The base and new builds produce
identical responses for both models (compared by `normal-path.sh`; the per-run files are not committed).

## Conformance rerun

[`conformance.sh`](conformance.sh) `<flm> <outdir> <oflm-next>` is unchanged
from after-178. It was run against the new build.

| Test file | After #178 | After #180 |
| --- | --- | --- |
| `test_error_status.py` (llama3.2:1b) | PASS 8 | PASS 8 |
| `test_error_status.py` (gemma4-it:e4b) | PASS 8 | PASS 8 |
| `test_finish_reason.py` | PASS 7 | PASS 7 |
| `test_request_validation.py` (chat server) | PASS 15, SKIP 7 | PASS 15, SKIP 7 |
| `test_request_validation.py` (embed server) | PASS 14, SKIP 8 | PASS 14, SKIP 8 |
| `test_embed_task_prompt.py` | PASS 3, SKIP 8 | PASS 3, SKIP 8 |

For each file, the sorted per-test PASS/FAIL/SKIP lines are identical to the after-178 logs.
