#!/usr/bin/env bash
# Exercises GET /api/ps of `flm serve` across server states (no chat model
# loaded, embed-only, chat model, chat+embed, a nonchat->load transition, and
# a poll-during-the-first-load race).
# Usage: probes.sh <flm-binary> <outdir> [state...]
set -u

FLM=${1:?usage: probes.sh <flm-binary> <outdir> [state...]}
outdir=${2:?usage: probes.sh <flm-binary> <outdir> [state...]}
shift 2
mkdir -p "$outdir"

port=58601
base="http://127.0.0.1:$port"
libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
all_states=(nonchat notag chat embedonly "chat+embed" nonchat-then-load ps-during-load)
states=("$@")
[[ ${#states[@]} -eq 0 ]] && states=("${all_states[@]}")

server_pid=""
pass_count=0
fail_count=0
results=()

cleanup() {
  [[ -n "$server_pid" ]] && stop_server exit
  return 0
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

# probe METHOD PATH [BODY] -- prints "$ GET/POST ..." then body and HTTP code.
probe() {
  local method=$1 path=$2 body=${3:-}
  if [[ "$method" == GET ]]; then
    printf '$ GET %s\n' "$path"
    curl -sS -m 120 -w '\nHTTP %{http_code}\n' "$base$path"
  else
    printf '$ POST %s %s\n' "$path" "$body"
    curl -sS -m 120 -w '\nHTTP %{http_code}\n' -H 'Content-Type: application/json' \
      --data-binary "$body" "$base$path"
  fi
}

# get_silent PATH -- same as probe GET but no printing; sets last_code/last_body.
get_silent() {
  local resp
  resp=$(curl -sS -m 120 -w '\nHTTP %{http_code}\n' "$base$1")
  last_code=$(tail -n1 <<<"$resp" | awk '{print $2}')
  last_body=$(sed '$d' <<<"$resp")
}

# start_for_state STATE -- launches flm serve with the state's args in the background.
start_for_state() {
  local state=$1
  if pgrep -x flm >/dev/null; then
    echo "ABORT: flm already running before state $state" >&2
    exit 1
  fi
  case "$state" in
    nonchat | nonchat-then-load) start_server "$state" embed-gemma:300m ;;
    notag) start_server "$state" ;;
    chat) start_server "$state" llama3.2:1b ;;
    embedonly) start_server "$state" --embed 1 ;;
    "chat+embed") start_server "$state" llama3.2:1b --embed 1 ;;
    ps-during-load) start_server "$state" ;;
    *) echo "unknown state $state" >&2; return 1 ;;
  esac
}

# start_server STATE [ARGS...] -- backgrounds the server, polls /api/version up to 300s.
start_server() {
  local state=$1; shift
  LD_LIBRARY_PATH="$libpath" "$FLM" serve "$@" --port "$port" >"$outdir/server-$state.log" 2>&1 &
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $state died before becoming ready (see $outdir/server-$state.log)" >&2
      server_pid=""
      return 1
    fi
    curl -s -o /dev/null "$base/api/version" && return 0
    sleep 1
    (( waited++ ))
  done
  echo "server for $state did not become ready within 300s" >&2
  return 1
}

# stop_server STATE -- SIGTERM, wait up to 30s, then SIGKILL; confirms flm is gone.
stop_server() {
  local state=$1
  [[ -z "$server_pid" ]] && return 0
  kill -TERM "$server_pid" 2>/dev/null
  local waited=0
  while (( waited < 30 )) && kill -0 "$server_pid" 2>/dev/null; do
    sleep 1
    (( waited++ ))
  done
  kill -0 "$server_pid" 2>/dev/null && kill -KILL "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
  pgrep -x flm >/dev/null && echo "WARN: flm still running after stopping state $state" >&2
  return 0
}

record() {
  local state=$1 status=$2 reason=${3:-}
  if [[ "$status" == PASS ]]; then
    echo "PASS $state"
    results+=("PASS $state")
    (( pass_count++ ))
  else
    echo "FAIL $state: $reason"
    results+=("FAIL $state: $reason")
    (( fail_count++ ))
  fi
}

run_state() {
  local state=$1
  echo "== state $state =="
  if ! start_for_state "$state"; then
    record "$state" FAIL "server did not become ready"
    stop_server "$state"
    return
  fi

  case "$state" in
    nonchat | notag)
      probe GET /api/ps
      get_silent /api/ps
      if [[ "$last_code" == 200 ]] && jq -e '.models == []' >/dev/null 2>&1 <<<"$last_body"; then
        record "$state" PASS
      else
        record "$state" FAIL "expected 200 + empty models, got HTTP $last_code: $last_body"
      fi
      ;;
    chat)
      probe GET /api/ps
      get_silent /api/ps
      if [[ "$last_code" == 200 ]] && jq -e '
          (.models|length==1) and (.models[0].name=="llama3.2:1b") and
          (.models[0].model=="llama3.2:1b") and (.models[0]|has("size")) and
          (.models[0]|has("details")) and (.models[0]|has("expires_at"))
        ' >/dev/null 2>&1 <<<"$last_body"; then
        record "$state" PASS
      else
        record "$state" FAIL "chat model entry mismatch, got HTTP $last_code: $last_body"
      fi
      ;;
    embedonly)
      probe GET /api/ps
      get_silent /api/ps
      if [[ "$last_code" == 200 ]] && jq -e '[.models[].name] == ["embed-gemma:300m"]' >/dev/null 2>&1 <<<"$last_body"; then
        record "$state" PASS
      else
        record "$state" FAIL "expected only embed-gemma:300m, got HTTP $last_code: $last_body"
      fi
      ;;
    "chat+embed")
      probe GET /api/ps
      get_silent /api/ps
      if [[ "$last_code" == 200 ]] && jq -e '[.models[].name] == ["llama3.2:1b","embed-gemma:300m"]' >/dev/null 2>&1 <<<"$last_body"; then
        record "$state" PASS
      else
        record "$state" FAIL "expected chat+embed model set, got HTTP $last_code: $last_body"
      fi
      ;;
    nonchat-then-load)
      probe GET /api/ps
      probe POST /v1/chat/completions '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say ok."}],"max_tokens":8}'
      probe GET /api/ps
      get_silent /api/ps
      if [[ "$last_code" == 200 ]] && jq -e '[.models[].name] == ["llama3.2:1b"]' >/dev/null 2>&1 <<<"$last_body"; then
        record "$state" PASS
      else
        record "$state" FAIL "expected only llama3.2:1b after load, got HTTP $last_code: $last_body"
      fi
      ;;
    ps-during-load)
      local chat_out
      chat_out=$(mktemp)
      curl -sS -m 120 -w '\nHTTP %{http_code}\n' -H 'Content-Type: application/json' \
        --data-binary '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say ok."}],"max_tokens":8}' \
        "$base/v1/chat/completions" >"$chat_out" 2>&1 &
      local chat_pid=$!

      local poll_count=0
      local observations=()
      while kill -0 "$chat_pid" 2>/dev/null; do
        local resp code body names
        resp=$(curl -sS -m 10 -w '\nHTTP %{http_code}\n' "$base/api/ps")
        code=$(tail -n1 <<<"$resp" | awk '{print $2}')
        body=$(sed '$d' <<<"$resp")
        names=$(jq -c '[.models[].name]' 2>/dev/null <<<"$body") || names=${body:0:200}
        observations+=("HTTP $code $names")
        (( poll_count++ ))
        sleep 0.1
      done
      wait "$chat_pid" 2>/dev/null

      printf '$ POST /v1/chat/completions %s\n' \
        '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say ok."}],"max_tokens":8}'
      cat "$chat_out"
      rm -f "$chat_out"

      echo "polls during load: $poll_count"
      local uniq_obs
      uniq_obs=$(printf '%s\n' "${observations[@]}" | sort | uniq -c)
      echo "$uniq_obs"

      probe GET /api/ps
      get_silent /api/ps

      local bad_obs=""
      for obs in "${observations[@]}"; do
        if [[ "$obs" != "HTTP 200 []" && "$obs" != 'HTTP 200 ["llama3.2:1b"]' ]]; then
          bad_obs=$obs
          break
        fi
      done

      if [[ -n "$bad_obs" ]]; then
        record "$state" FAIL "bad observation during load: $bad_obs"
      elif (( poll_count < 5 )); then
        record "$state" FAIL "load window not exercised ($poll_count polls)"
      elif [[ "$last_code" == 200 ]] && jq -e '[.models[].name] == ["llama3.2:1b"]' >/dev/null 2>&1 <<<"$last_body"; then
        record "$state" PASS
      else
        record "$state" FAIL "expected only llama3.2:1b after load, got HTTP $last_code: $last_body"
      fi
      ;;
    *)
      record "$state" FAIL "unknown state"
      ;;
  esac

  stop_server "$state"
}

for state in "${states[@]}"; do
  run_state "$state"
done

echo "== summary =="
for r in "${results[@]}"; do
  echo "$r"
done
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
