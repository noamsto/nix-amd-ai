#!/usr/bin/env bash
# Malformed requests that get past require_field and throw inside a handler.
# Usage: probes.sh <base-url>
set -u
base=${1:-http://127.0.0.1:58601}

probe() {
  local path=$1 body=$2
  printf '$ POST %s %s\n' "$path" "$body"
  curl -sS -m 120 -w '\nHTTP %{http_code}\n' -H 'Content-Type: application/json' \
    --data-binary "$body" "$base$path"
}

probe /v1/chat/completions '{"model":"llama3.2:1b","messages":[{"role":"user","content":"hi"}],"stream":"yes"}'
probe /api/chat '{"model":"llama3.2:1b","messages":[{"role":"user","content":"hi"}],"options":"x"}'
probe /api/generate '{"model":"llama3.2:1b","prompt":"hi","stream":"yes"}'
probe /v1/chat/completions '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say ok."}],"max_tokens":8}'
