# Rebase onto main after #206 (accept-loop-rearm.patch)

`disconnect.sh` (from `bench-logs/oflm-api-conformance-2026-09-28-after-191/`)
run with `ENDPOINTS="chat generate"` against the build rebased onto
`origin/main` at 35a61ad (#206, `accept-loop-rearm.patch`), on both llama3.2:1b
and gemma4-it:e4b. 16 passed, 0 failed. Scoped to `chat`/`generate` since #206
only touches the accept path these probes connect through, not decode/cancel
behavior -- the full six-endpoint matrix was already run in
`../oflm-api-conformance-2026-09-28-after-191/`.

**Host:** halo (Ryzen AI MAX+ 395, XDNA2 NPU).

Result, per model and endpoint, for the four abort points (`full` = client reads
to the end, `decode` = disconnect mid-decode, `prefill` = disconnect during
prefill, `server-alive` = the server still answers afterwards):

```
== summary ==
PASS llama/chat/{full,decode,prefill,server-alive}
PASS llama/generate/{full,decode,prefill,server-alive}
PASS gemma4/chat/{full,decode,prefill,server-alive}
PASS gemma4/generate/{full,decode,prefill,server-alive}
16 passed, 0 failed
```

The decisive gemma4 `generate` prefill case: the client closed after 0.301 s,
the NPU was released 6.165 s later (`npu_hold_s`), no further prefill chunks ran
after the close, and the follow-up request got a 200.

The per-request stream captures and server logs are not committed; rerun
`disconnect.sh` to regenerate them.
