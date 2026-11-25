#!/usr/bin/env bash
# What llama-server argv does lemond build for a user-pulled Inkling-2-Mini GGUF on the ROCm backend, and what
# ctx_size would it auto-resolve? Starts a scratch lemond on loopback, pulls the (already cached) checkpoint,
# prints the model options (resolved_ctx_size), loads once at an explicit small ctx_size, prints the spawned
# llama-server argv, then unloads and stops lemond. Meant to run as the child of the gated harness, never against
# the GPU directly:
#
#   LEMOND_MODEL=<resident lemond model> EXEC_DEV=gpu TARGET=<Q4_K_XL gguf> NEED_GIB=28 OUT=row.json EXEC_LOG=argv.log \
#     bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh exec -- \
#     env LEMONADE=<lemonade pkg> ROCM_BIN=<llama-cpp-rocm> VULKAN_BIN=<llama-cpp-vulkan> HUB=<hf hub-cache dir> \
#     bench-logs/inkling-2-mini-rocm-compute-buffer-2026-11-25/lemond-argv.sh
#
# HUB must hold models--unsloth--Inkling-2-Mini-GGUF (refs/main, snapshots/<sha>/ with the UD-Q4_K_XL gguf and
# mmproj-F16.gguf) so the pull downloads nothing. Optional: LPORT (default 13999, loopback), LLAMACPP_ARGS
# (default `--flash-attn on`, as the NixOS module sets it).
set -euo pipefail
: "${LEMONADE:?}" "${ROCM_BIN:?}" "${VULKAN_BIN:?}" "${HUB:?}"
lport=${LPORT:-13999}
args=${LLAMACPP_ARGS:---flash-attn on}
api="http://127.0.0.1:$lport/api/v1"
name=user.Inkling-2-Mini-UD-Q4_K_XL
ctx=4096
work=$(mktemp -d)
lemond=
llama=
found=
loadpid=
cleanup() {
    if [ -n "$loadpid" ]; then kill "$loadpid" 2>/dev/null || true; wait "$loadpid" 2>/dev/null || true; loadpid=; fi
    if [ -n "$lemond" ]; then
        if declare -F find_llama >/dev/null && found=$(find_llama 2>/dev/null); then llama=$found; fi
        curl -fsS --max-time 30 -X POST "$api/unload" >/dev/null 2>&1 || true
        kill "$lemond" 2>/dev/null || true
        for _ in $(seq 1 30); do kill -0 "$lemond" 2>/dev/null || break; sleep 1 & wait $!; done
        kill -KILL "$lemond" 2>/dev/null || true
        wait "$lemond" 2>/dev/null || true
        lemond=
    fi
    if [ -n "$llama" ] && [[ $({ tr '\0' '\n' <"/proc/$llama/cmdline"; } 2>/dev/null | head -n1) == */llama-server ]]; then
        kill -KILL "$llama" 2>/dev/null || true
    fi
    llama=
    rm -rf -- "$work"
}
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
trap cleanup EXIT

if curl -fsS --max-time 5 "$api/health" >/dev/null 2>&1; then
    echo "port $lport already in use" >&2
    exit 1
fi

mkdir "$work/cache" "$work/config"
jq -n --arg args "$args" --arg rocm "$ROCM_BIN/bin/llama-server" --arg vulkan "$VULKAN_BIN/bin/llama-server" \
    '{global_timeout: 0, broadcast: false, auto_check_model_updates: false, log_file: "disabled",
      llamacpp: {args: $args, rocm_bin: $rocm, vulkan_bin: $vulkan, backend: "rocm"}}' >"$work/defaults.json"

hub_bytes() { du -sb -- "$HUB" | cut -f1; }
hub_before=$(hub_bytes)

env -u LD_LIBRARY_PATH -u HF_HOME -u LEMONADE_CACHE_DIR \
    LEMONADE_DEFAULTS_PATH="$work/defaults.json" HF_HUB_CACHE="$HUB" LEMONADE_GGML_HIP_PATH="$ROCM_BIN/lib/libggml-hip.so" \
    setpriv --pdeathsig KILL -- "$LEMONADE/bin/lemond" --port "$lport" --host 127.0.0.1 "$work/cache" "$work/config" \
    >"$work/lemond.log" 2>&1 &
lemond=$!

ready=0
for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "$api/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    kill -0 "$lemond" 2>/dev/null || { echo "lemond exited before health"; exit 1; }
    sleep 1 & wait $!
done
[ "$ready" = 1 ] || { echo "lemond not healthy after 60 s"; exit 1; }
echo "=== lemond $(curl -fsS --max-time 5 "$api/health" | jq -r .version)"

pull_body=$(jq -n --arg m "$name" '{model_name: $m, checkpoint: "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_XL", mmproj: "mmproj-F16.gguf", recipe: "llamacpp"}')
pull_out=$(curl -sS --max-time 600 -X POST "$api/pull" -H 'Content-Type: application/json' -d "$pull_body")
model=$(jq -r 'select(.status == "success") | .model_name // empty' <<<"$pull_out" 2>/dev/null || true)
if [ -z "$model" ]; then
    echo "pull failed: $(jq -r '.error.message // .error // .' <<<"$pull_out" 2>/dev/null | head -c 300)"
    exit 1
fi
hub_after=$(hub_bytes)
echo "pulled $model; HUB bytes before $hub_before after $hub_after"
if [ "$hub_after" -gt $((hub_before + 1048576)) ]; then
    echo "!!! WARNING: HUB grew by $((hub_after - hub_before)) bytes: the pull downloaded something, so the HUB was not complete"
fi

echo "=== options"
opt_code=$(curl -sS --max-time 60 -o "$work/options.json" -w '%{http_code}' "$api/models/$model/options" || echo 000)
if [ "$opt_code" = 200 ]; then
    jq -c '{resolved_ctx_size, effective}' "$work/options.json"
else
    echo "options endpoint absent or failed: HTTP $opt_code $(jq -r '.error.message // .error // empty' "$work/options.json" 2>/dev/null | head -c 200)"
fi

# Auto ctx_size would size the KV cache to free memory; this run only reads argv, so never load at auto.
[[ $ctx =~ ^[0-9]+$ ]] && [ "$ctx" -le 8192 ] || { echo "refusing load: ctx_size '$ctx' is not an explicit integer <= 8192" >&2; exit 2; }
post_load() {
    jq -n --arg m "$model" --argjson ctx "$ctx" '{model_name: $m, ctx_size: $ctx, llamacpp_backend: "rocm"}' |
        curl -sS --max-time 330 -o "$work/load.json" -w '%{http_code}' -X POST "$api/load" -H 'Content-Type: application/json' -d @- \
            >"$work/load.code" || echo 000 >"$work/load.code"
}

find_llama() { # first child of lemond whose argv[0] is llama-server
    local c
    while read -r -d ' ' c; do
        if [[ $({ tr '\0' '\n' <"/proc/$c/cmdline"; } 2>/dev/null | head -n1) == */llama-server ]]; then
            echo "$c"
            return 0
        fi
    done < <(cat /proc/"$lemond"/task/*/children 2>/dev/null)
    return 1
}

print_argv() {
    local -a argv
    local a prev='' first=1
    mapfile -d '' -t argv <"/proc/$llama/cmdline"
    echo "=== llama-server argv (ctx_size $ctx, backend rocm)"
    for a in "${argv[@]}"; do
        if [ "$first" = 1 ]; then
            first=0
            echo "${a/"$ROCM_BIN"/<ROCM_BIN>}"
            continue
        fi
        case $prev in
            -m | --model) echo "<gguf>" ;;
            --mmproj) echo "<mmproj>" ;;
            --port) echo "<port>" ;;
            *) echo "$a" ;;
        esac
        prev=$a
    done
}

post_load &
loadpid=$!
argv_done=0
loaded=0
for _ in $(seq 1 150); do
    if [ "$argv_done" = 0 ] && llama=$(find_llama); then
        print_argv
        argv_done=1
    fi
    if curl -fsS --max-time 5 "$api/health" 2>/dev/null |
        jq -e --arg m "$model" '[.all_models_loaded[]? | select(.model_name == $m and (.status == "ready" or .status == "in_use"))] | length > 0' >/dev/null; then
        loaded=1
        break
    fi
    kill -0 "$loadpid" 2>/dev/null || break
    sleep 2 & wait $!
done
if [ "$loaded" = 0 ] && kill -0 "$loadpid" 2>/dev/null; then
    echo "load still running after 300 s"
else
    wait "$loadpid" 2>/dev/null || true
    loadpid=
    # The load POST can return before the poll above sees the model in health.
    if [ "$loaded" = 0 ] && [ "$(cat "$work/load.code" 2>/dev/null)" = 200 ]; then loaded=1; fi
    if [ "$loaded" = 1 ]; then
        echo "=== loaded"
    else
        echo "=== load failed: HTTP $(cat "$work/load.code" 2>/dev/null) $(jq -r '.error.message // .error // empty' "$work/load.json" 2>/dev/null | head -c 400)"
    fi
fi
[ "$argv_done" = 1 ] || echo "no llama-server child of lemond was seen"
[ "$loaded" = 1 ] || exit 1
