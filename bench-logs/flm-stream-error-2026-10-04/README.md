# `flm serve` streaming error body after a generate() fault (#199), on halo

Red/green for #199, plus a byte-for-byte check that the normal stream is
unchanged and a connection-slot check that #194 does not regress. The method is
the same as
[`oflm-api-conformance-2026-09-28-after-180`](../oflm-api-conformance-2026-09-28-after-180/):
a scratch fault-injection patch (never shipped) forces the mid-stream failure,
and the client capture is raw socket bytes.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU at `/dev/accel/accel0`, driver
`amdxdna`).
**Models:** `llama3.2:1b` (chat), already pulled.
**Builds:** `red` = the patch series without `stream-error-body.patch` + the
test-only injection; `green` = the series with `stream-error-body.patch` + the
injection; `shipped` = the series with `stream-error-body.patch` and no
injection. Store paths are not committed; each was built with
`nix build .#fastflowlm --no-link --print-out-paths` on this branch (the
unmodified base is substituted from cache).
**Injection:** [`inject-faults.patch`](inject-faults.patch) adds, to
`AutoModel::_shared_generate`, a `FLM_INJECT_DECODE_FAULT_AFTER=<N>` check after
the Nth token is written to the stream's `ostream`, throwing
`std::runtime_error("injected mid-stream decode fault")`. That is a fault
*after* the 200 + chunk headers and at least one chunk, which is the branch #199
is about. It is not added to `default.nix` in the committed tree.

`pgrep -a flm` was empty before and after every run; each `flm serve` was
started and stopped by `probe.sh`'s tracked PID.

## Red/green: raw client bytes

[`probe.sh`](probe.sh) `<flm> <outdir> <label> <none|N> <expect>` starts
`flm serve llama3.2:1b` (with `FLM_INJECT_DECODE_FAULT_AFTER=N` when given),
sends a streaming request over a raw socket with
[`capture.py`](capture.py), and reads until EOF **or a read timeout** — the
timeout is required on red, where the server neither writes an error nor closes
the socket. Fact fields: `error_event` = a generic `{"error":{"message":
"Internal error",...}}` in the bytes; `terminator` = the response ends with the
chunked terminator `0\r\n\r\n`; `sse_done` = a `[DONE]` sentinel.
Raw captures and server logs are not committed; rerun `probe.sh`.

| Build | Endpoint | bytes | `error_event` | `terminator` | Outcome |
| --- | --- | --- | --- | --- | --- |
| red | Ollama `/api/chat` | 1129 | no | **no** | truncated (last bytes are a data chunk) |
| red | OpenAI `/v1/chat/completions` | 2073 | no | **no** | truncated |
| green | Ollama `/api/chat` | 1167 | **yes** | **yes** | `{"error":"Internal error"}` (string, as Ollama clients require) then `0\r\n\r\n` |
| green | OpenAI `/v1/chat/completions` | 2160 | **yes** | **yes** | `data: {"error":{...}}` then `0\r\n\r\n` |

The green error is the handler's existing generic body (#175), reshaped per
protocol: Ollama's `error` field is a **string** (its Python and Go clients read
it as one and would fail to parse an object), OpenAI's stays the object its
clients expect. Every captured byte is free of `injected mid-stream`, while each
server log carries
`[ERROR]  handle_chat: injected mid-stream decode fault` /
`[ERROR]  handle_openai_chat_completion: injected mid-stream decode fault`
(14 lines per run: 2 captures + 12 slot-fault requests). The fault reaches the
`handle_chat` and `handle_openai_chat_completion` inner generate catches, not a
post-success path.

## Connection slot still released (#194)

After the two captures, the probe forces the fault 12 more times and then opens
a fresh `/api/version` connection. On **both** red and green the final
connection is `200` and the server log has no `Connection limit reached` line —
red releases the slot in `handle_request` (the #194 branch), green releases it
through `send_chunk_data(..., is_final=true)`. #199 does not regress #194.

## Normal stream unchanged

Against the `shipped` build with no injection, `probe.sh … none normal`:

| Endpoint | bytes | `error_event` | `terminator` | `sse_done` |
| --- | --- | --- | --- | --- |
| Ollama `/api/chat` | 434310 | no | yes | n/a |
| OpenAI `/v1/chat/completions` | 917068 | no | yes | yes |

Both streams complete with the normal final framing and no error event.

## Not measured

- `insert()`-failure-after-chunks: `insert()` runs before any chunk is emitted,
  so on this tree it is a pre-stream error and takes the unchanged HTTP 4xx
  path. The generate fault is the reachable mid-stream case; the fix covers the
  shared `res_` path both use.
- A query string on `/v1/chat/completions`: the router matches targets exactly,
  so `?…` never reaches a streaming handler (`404`). The framing choice matches
  on the `/v1/` prefix defensively.
- The deferred-session variant is out of scope (#199 scopes non-deferred); a
  deferred streaming error still takes `write_response_from_callback`.
- Other model families: measured on `llama3.2:1b` only.
