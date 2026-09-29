# `flm serve` cancels non-streaming `/api/chat` and keeps pre-handler cancels (#200, #201), on halo

Red/green for #200 and #201. Both belong to #191's invariant: once the client
is gone (socket closed, or `POST /api/cancel`), the request stops promptly and
releases the NPU, whether the cancel arrives while the request is queued, during
a model load, during prefill or during decode. Also included: byte-identity of
normal non-streaming `/api/chat` answers, a half-close characterisation with a
check of real clients, and reruns of #198's slot probes, #206's
reset-before-accept probe and OFLM-Next's server-api conformance suite.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`; kernel 7.2.8).
**Old build (red):** `main` at cf4e7cd —
`/nix/store/xxr38aa48rivwjk9vn2ds0h1463anc75-fastflowlm-1.0.6`.
**New build (green):** this branch, adding `cancel-chat-nonstream.patch` and
`cancel-keep-early.patch` after `model-list-download-check.patch` —
`/nix/store/2v6yb1wpn4qpqygnwljwz3n85hna7qy1-fastflowlm-1.0.6`.
**OFLM-Next commit:** `eb656007856579c38bafaaa7f86f2f08cc980890`.
**Models** (`flm list` on halo: every downloaded chat model):
`llama3.2:1b` (Llama3), `gemma4-it:e4b` (Gemma4e), `gemma4e-flash:e4b`
(Gemma4e_Flash) and `qwen3.6-moe:35b-a3b` (Qwen3_6_MOE).

`pgrep -x flm` was empty before and after every run, and the host `lemond` had
no model loaded; it was never touched. Each `flm serve` was stopped by its PID.

## #200: non-streaming `/api/chat`

`handle_chat`'s non-streaming branch calls `generate_with_prompt()`, which took
no cancellation predicate in any model class. A client that left kept the NPU
until `num_predict`. `insert()` + `generate()` is not an option, because it
changes answers for Qwen3.5, Qwen3.6-MoE and GPT-OSS (#180).

The fix adds a defaulted trailing `std::function<bool()> is_cancelled` to
`generate_with_prompt` in `AutoModel` and all 25 overrides. Each override
forwards it to the `insert()` and `_shared_generate()`/`generate()` it already
calls, and no other line changes. Nanbeige's inlined decode loop gets the cancel
check its `generate()` has. `handle_chat` passes the token, without calling
`reset()`. A cancel surfaces the way non-streaming `/api/generate` shows one
after #195:

- Cancelled with nothing produced: `{}` and `Prefill Cancelled!`. This is not a
  strict prefill/decode split, since a decode cancelled before any visible token
  also gets `{}`.
- Otherwise: 200 with the partial reply, `done_reason: "cancel"`, and
  `Generation Cancelled!`.

A cancel never throws, so #186's 400/500 classification is untouched.

## #201: why upstream calls `reset()`, and what dropping it does

History in ROCm/FastFlowLM (`git log -S`):

- `CancellationToken::reset()` appeared in v0.9.24 (8b9d0a8, 2025-12-23).
- It was first called in v0.9.25 (d7ac033, 2026-01-08), before `insert()` in
  streaming `/v1/chat/completions`.
- At that point the token was already built fresh per request in
  `process_task`, right before the handler. The only things that could cancel
  it were `send_chunk_data`'s write error (nothing has been written yet at that
  point) and `POST /api/cancel`.
- The disconnect monitor (`start_client_disconnect_monitor`) came later, in
  4ffe631 (2026-04-24).

So the reset was not written to guard against the monitor. On a fresh token it
can only erase a real cancel. #195 copied it into the streaming branches of
`/api/generate`, `/api/chat` and `/v1/completions`. Upstream `main` (ef60a5f)
still has it in `/v1/chat/completions`.

**A monitor false positive does exist, and the reset masks it by race.** A
client that half-closes its socket (`shutdown(SHUT_WR)`) after sending a request
reads as EOF, and the monitor cancels. `halfclose.sh` (llama3.2:1b, 5 streaming
requests each for `/api/chat` and `/v1/chat/completions`, plus 5 of each without
the half-close as a control):

| build | `/api/chat`, half-close | `/v1/chat/completions`, half-close | controls |
| --- | --- | --- | --- |
| red | 4 × `length`, 1 × `cancel` | 5 × `length` | 10 × `length` |
| green | 5 × `cancel` | 5 × `cancel` | 10 × `length` |

On red the monitor logged `Client disconnected` for all 10 half-closed requests
([log](before/server-halfclose-red.log)). The streaming handler's `reset()`,
running on another I/O thread, erased 9 of those cancels. With the resets
dropped, a half-closing streaming client is always cancelled, as every
non-streaming branch already did on `main`.

The read side cannot tell a half-close from a full close: both deliver FIN, and
only a write can show the difference. Moving the reset to before the monitor is
armed would be a no-op on a fresh token, so the same trade-off applies either
way. The four resets were dropped after the dispatcher agreed, on the condition
that real clients were shown not to half-close.

**Real clients do not half-close.** [`client-halfclose.sh`](client-halfclose.sh)
against the green build ([results](client-halfclose.txt),
[run](client-halfclose-run.txt)):

- **Through an isolated `lemond`** 11.9.0 (temp HOME, cache and config, port
  13399, `flm.npu_bin` set to the green `flm` through an exec wrapper that logs
  its `serve` output): 3 × streaming `/v1/chat/completions` (`length`),
  1 × non-streaming (`length`) and 1 × streaming Ollama `/api/chat` (`stop`),
  all complete. The flm log has 0 `Client disconnected` during a POST. There is
  one on lemond's startup readiness poll (`GET /api/tags`, abandoned while flm
  was still starting; that route never had a `reset()`).
  [flm log](server-lemond-e2e.log).
- **lemonade source:** it proxies to flm through libcurl
  (`HttpClient::post_stream`). The only socket `shutdown()` in its tree is
  `SHUT_RDWR` in `tcp_jsonl_client.cpp`, which is not on the flm path.
- **Direct:** `curl -N`, python `requests` (stream) and `httpx` (stream), each
  on streaming `/api/chat` and `/v1/chat/completions`: all `length`, 0
  `Client disconnected` ([log](server-client-direct.log)).

## Red/green: `disconnect.sh`

[`disconnect.sh`](disconnect.sh) extends
[#195's](../oflm-api-conformance-2026-09-28-after-191/disconnect.sh):

- **`chat-ns`:** non-streaming `/api/chat`, `num_predict` 512, run in three
  modes. `full` reads the answer. `decode` closes after 2 s. `queued` closes
  0.3 s after sending while a blocker `/api/chat` holds the NPU, and its hold is
  timed from its dequeue.
- **`queued-prefill`**, on every streaming endpoint: a ~12k-token prompt (three
  4096-token chunks) closed 0.3 s after sending while queued behind the blocker.
  It passes if no prefill chunk ≥ 2 starts after its dequeue and the NPU frees
  within 2 s.
- **Models:** llama3.2:1b and gemma4-it:e4b run every endpoint.
  gemma4e-flash:e4b runs `chat-ns` only: it is single-turn with a 1024-token
  context, so `_shared_insert` refuses the 12k prompt before any chunk, and its
  prefill rows could never go red. qwen3.6-moe:35b-a3b runs `chat-ns` and
  `chat`.

**Red: 60 passed, 17 failed** ([before/disconnect.txt](before/disconnect.txt));
**green: 77 passed, 0 failed** ([disconnect.txt](disconnect.txt)). The 17
failures are exactly the new rows. Every other row passes on both builds.

"NPU hold" is the time from the close (`decode`) or from the request's dequeue
(`queued`, `queued-prefill`) until the NPU is free.

| model | case | red: NPU hold, chunks ≥2 after dequeue | green |
| --- | --- | --- | --- |
| llama | chat-ns decode | 6.52 s | 0.35 s, `Generation Cancelled!` |
| llama | chat-ns queued | 8.53 s | 0.34 s, `Prefill Cancelled!` |
| llama | chat / generate / openai / completions queued-prefill | 7.65–7.71 s, 2 | 0.35 s, 0, `Prefill Cancelled!` |
| gemma4 | chat-ns decode | 37.79 s | 0.38 s |
| gemma4 | chat-ns queued | 39.83 s | 0.37 s |
| gemma4 | 4 × queued-prefill | 20.91–20.95 s, 2 | 0.37–0.42 s, 0 |
| gemma4flash | chat-ns decode | 36.91 s | 0.41 s |
| gemma4flash | chat-ns queued | 38.86 s | 0.35 s |
| qwen36 | chat-ns decode | 31.02 s | 1.57 s |
| qwen36 | chat-ns queued | 33.31 s | 0.41 s |
| qwen36 | chat queued-prefill | 43.65 s, 2 | 0.42 s, 0 |

- **Red, streaming `queued-prefill`:** the server logs `Client disconnected` on
  dequeue, then `Prefill chunk 1/3`, `2/3` and `3/3`. Green logs
  `Prefill Cancelled!` with no chunk at all: `_chunked_insert` checks the token
  before chunk 1.
- **qwen36 `chat-ns decode`, green 1.57 s:** the close landed during that
  request's one 29-token prefill chunk (about 3 s on qwen36 here), which cannot
  be interrupted. Decode then stopped at its first step
  ([log](server-qwen36.chat-ns.log)).

## Normal answers are byte-identical

[`chat-identity.sh`](chat-identity.sh) sends two non-streaming `/api/chat`
requests per model on a fresh server (top-level `top_k: 1`, `num_predict` 256).
The second request is a 3-turn conversation, except on gemma4e-flash:

- llama3.2:1b, gemma4-it:e4b, qwen3.6-moe:35b-a3b: single prompt, then the
  3-turn conversation.
- gemma4e-flash:e4b: two single prompts. It is single-turn (its `insert()`
  resets the turn), so it has no multi-turn state to exercise.

`diff -r identity/red identity/green` over the JSON bodies, with
`total_duration`, `load_duration`, `prompt_eval_duration` and `eval_duration`
removed, is empty for all four families. That covers content, `eval_count`,
`prompt_eval_count` and `done_reason`. qwen3.6-moe's thinking output was
deterministic across the two builds.

These are the four `generate_with_prompt` families that have a model downloaded
on halo. The other overrides (Nanbeige, GPT-OSS, Qwen3.5, Qwen3VL and its
Flash/Thinking variants, Qwen3, Qwen3_IT, Qwen3_TK, Qwen2, Qwen2VL, Phi4, LFM2,
LFM2_5_TK, Hunyuan, Gemma3, Gemma3_Text_Only, Gemma4_12B, Qwen3_5_Omni and both
DeepSeek R1 classes) were not run: their models are not downloaded. Their change
is the same mechanical forwarding, except Nanbeige's added in-loop check.

## Regressions

| probe | result |
| --- | --- |
| `disconnect.sh`, all 60 pre-existing rows | pass on red and green |
| #198 slot release ([after-194 `disconnect.sh`](../oflm-api-conformance-2026-09-28-after-194/disconnect.sh), 12 aborts) | 12 aborts, final connection accepted, 0 `Connection limit reached` ([slots.txt](slots.txt)) |
| #198 keep-alive / non-streaming ([`keepalive-nonstream.sh`](../oflm-api-conformance-2026-09-28-after-194/keepalive-nonstream.sh)) | 12 × `/api/version` and 12 × non-streaming `/v1/chat/completions` all 200; `/api/version` 200 after 12 streaming aborts ([log](keepalive-nonstream.log)) |
| #206 [`reset-before-accept.sh`](../flm-accept-reset-2026-09-28/reset-before-accept.sh), 15 cycles | 15/15 answered 200, 0 I/O-thread errors, 0 `Connection limit reached` ([accept-reset.txt](accept-reset.txt)) |
| OFLM-Next conformance ([`conformance.sh`](../oflm-api-conformance-2026-09-28-after-191/conformance.sh)) | every test file's sorted PASS/FAIL/SKIP identical to [flm-accept-reset-2026-09-28](../flm-accept-reset-2026-09-28/) |

The counter-level `debug-slots.sh` needs a scratch build with temporary `DBG`
prints and was not rerun. This change does not touch the slot-counter code, and
its behavioural probes above pass.

## Reproduce

```
nix build .#fastflowlm --no-link --print-out-paths   # red on cf4e7cd, green here
D=bench-logs/flm-cancel-2026-09-29
bash $D/disconnect.sh /nix/store/<flm>/bin/flm $D            # red: $D/before
bash $D/chat-identity.sh /nix/store/<flm>/bin/flm $D <red|green>
bash $D/halfclose.sh /nix/store/<flm>/bin/flm $D <label>
bash $D/client-halfclose.sh /nix/store/<flm>/bin/flm $D <scratch dir>
bash bench-logs/oflm-api-conformance-2026-09-28-after-194/disconnect.sh /nix/store/<flm>/bin/flm 58701 12 $D slots
bash bench-logs/oflm-api-conformance-2026-09-28-after-194/keepalive-nonstream.sh /nix/store/<flm>/bin/flm 58704 $D
bash bench-logs/flm-accept-reset-2026-09-28/reset-before-accept.sh /nix/store/<flm>/bin/flm 58712 15 $D green
bash bench-logs/oflm-api-conformance-2026-09-28-after-191/conformance.sh /nix/store/<flm>/bin/flm $D <oflm-next checkout>
```

Local scratch, worktree and home paths in the committed logs are replaced with
`<scratch>`, `<repo>` and `~`.
