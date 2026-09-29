# Rebase onto main after #206 (accept-loop-rearm.patch)

`disconnect.sh` (from `bench-logs/oflm-api-conformance-2026-09-28-after-191/`)
run with `ENDPOINTS="chat generate"` against the build rebased onto
`origin/main` at 35a61ad (#206, `accept-loop-rearm.patch`), on both llama3.2:1b
and gemma4-it:e4b. 16 passed, 0 failed. Scoped to `chat`/`generate` since #206
only touches the accept path these probes connect through, not decode/cancel
behavior -- the full six-endpoint matrix was already run in
`../oflm-api-conformance-2026-09-28-after-191/`.
