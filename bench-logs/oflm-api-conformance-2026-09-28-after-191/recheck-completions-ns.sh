#!/usr/bin/env bash
# recheck-completions-ns.sh <flm-binary> <outdir> <label>
#
# disconnect.sh's llama completions-ns/full reply differed between the red and
# green builds. This serves llama3.2:1b on a fresh server and sends that exact
# request twice (no other request before or between), writing
# <outdir>/<label>.{1,2}.content, so the two builds can be compared without
# any earlier request's state.
set -u

FLM=${1:?usage: recheck-completions-ns.sh <flm-binary> <outdir> <label>}
outdir=${2:?}
label=${3:?}
mkdir -p "$outdir"
libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
port=58601
pid=""

stop() {
  [[ -z "$pid" ]] && return
  kill -TERM "$pid" 2>/dev/null
  local waited=0
  while (( waited < 30 )) && kill -0 "$pid" 2>/dev/null; do sleep 1; (( waited++ )); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}
trap stop EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
LD_LIBRARY_PATH=$libpath "$FLM" serve llama3.2:1b --port "$port" >"$outdir/server-recheck-$label.log" 2>&1 &
pid=$!
for _ in $(seq 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && break
  sleep 1
done

body=$(jq -cn '{model: "llama3.2:1b", prompt: "Write a detailed essay of at least 2000 words on the history of the printing press.", top_k: 1, max_tokens: 512, stream: false}')
for i in 1 2; do
  curl -s "http://127.0.0.1:$port/v1/completions" -H 'Content-Type: application/json' -d "$body" \
    | jq -j '.choices[0].text' >"$outdir/$label.$i.content"
done
stop
pgrep -x flm >/dev/null && { echo "stray flm" >&2; exit 1; }
exit 0
