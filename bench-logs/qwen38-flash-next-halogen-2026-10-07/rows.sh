#!/usr/bin/env bash
# Halogen 0.16.2 rows for #258. From the repo root: rows.sh <stage> <arm>. Every stage is one lemond-offline window:
# each row runs through run.sh's `exec` preset (probe.py gate, signal file, lemond unload) with halogen.py as the
# child; lemond is reloaded at the end of the stage, after the Halogen container is confirmed gone.
# Env (no defaults): W work dir (rows, logs; outside the repo), CACHE the #249/#252 corpus cache.
# Optional: MODELS_V2 / MODELS_BYO model directories (mounted read-only), IMAGE (pinned digest), PODMAN_DIR (PATH
# entry holding podman and the newuidmap wrappers), BYO_ENV / V2_ENV (extra HALOGEN_* settings, space separated),
# LOAD_GIB (co-tenant load), FLOOR_GIB (MemAvailable abort floor), KL_PY (python with numpy), REF (#260 reference
# logits, read only), IDS (token ids written by `kl_halogen.py ids`).
# Arms: v2 (Halogen's own checkpoint), byo (the production UD-IQ4_XS GGUF repacked by the image).
# Stages: fit | smoke | audit | offline | rows | tasks | checks | cotenant | ppl <v2|byo>; `restore` reloads lemond.
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
H=bench-logs/qwen38-flash-next-halogen-2026-10-07
IMAGE=${IMAGE:-ghcr.io/peonist-ai/halogen-flash-server@sha256:0c61bf84ac22308a53f5d1ca6b86806702d7039e5ebc51cae4c66621b92fe04a}
MODELS_V2=${MODELS_V2:-/var/lib/models/halogen}
MODELS_BYO=${MODELS_BYO:-/var/lib/models/halogen-byo}
FLOOR_GIB=${FLOOR_GIB:-6}
SIGNAL=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halo-gpu-bench.active
# The same memory shape the #249 rows use: 131K context, two conversations resident.
COMMON_ENV="HALOGEN_CTX=131072 HALOGEN_KV_SLOTS=2 HALOGEN_MAX_TOK=16384 HALOGEN_VISION_TOWER=1"
[ -z "${PODMAN_DIR:-}" ] || export PATH=$PODMAN_DIR:$PATH

need() {
    local v
    for v; do [ -n "${!v:-}" ] || { echo "$v is required" >&2; exit 7; }; done
}
need W
mkdir -p "$W"

arm_vars() { # sets models, ckpt, target, arm_env
    case ${1:-} in
    v2) models=$MODELS_V2 ckpt=qwen38-flash-next-v2.hgn arm_env=${V2_ENV:-} ;;
    byo) models=$MODELS_BYO ckpt=Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf arm_env=${BYO_ENV:-} ;;
    *) echo "arm must be v2 or byo" >&2; exit 7 ;;
    esac
    target=$models/$ckpt
}

# Someone else's GPU row holds the signal file: wait, never run.sh beside it (its reload would load lemond's model).
wait_free() {
    local pid
    while pid=$(sed -n 1p "$SIGNAL" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$pid" != "$$" ]; do
        echo "waiting: GPU row of pid $pid holds $SIGNAL ($(sed -n 2p "$SIGNAL"))" >&2
        sleep 60
    done
}

gtt_used() { cat /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | sort -n | tail -1; }

lemond_loaded() { curl -fsS "${LEMOND:-http://127.0.0.1:13305/api/v1}/health" | jq -e '.all_models_loaded | length > 0' >/dev/null; }

# No labelled container, and GTT below 6 GiB (nothing is loaded), before lemond may load.
assert_clean() {
    local left used
    left=$(podman ps -aq --filter label=bench=halogen258 | wc -l)
    [ "$left" = 0 ] || { echo "ABORT: $left halogen container(s) still present; lemond not reloaded" >&2; return 1; }
    used=$(gtt_used)
    [ "${used:-0}" -lt 6442450944 ] || { echo "ABORT: GTT used $used with nothing loaded; lemond not reloaded" >&2; return 1; }
}

restore() {
    trap '' INT TERM HUP
    lemond_loaded && return 0 # run.sh's own exit path already reloaded it (after a row failure)
    assert_clean || return 1
    FIT_CHECK_ONLY=1 KEEP_OFFLINE=0 OUT=$W/rows.jsonl EXEC_DEV=cpu TARGET=${target:-$MODELS_BYO/x} EXEC_LOG=$W/restore.log \
        NEED_GIB=1 "$D/run.sh" exec -- true >&2 || { echo "lemond restore FAILED (exit $?)" >&2; return 1; }
}

offline=0
child=
# shellcheck disable=SC2329 # invoked by the traps
on_exit() {
    local rc=$?
    [ "$offline" = 0 ] || restore || rc=6
    exit "$rc"
}
# shellcheck disable=SC2329 # invoked by the traps
on_signal() {
    # shellcheck disable=SC2046 # one word per pid
    kill -TERM $(jobs -p) 2>/dev/null
    while [ -n "$(jobs -pr)" ]; do wait; done
    exit "$1"
}
trap on_exit EXIT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap 'on_signal 130' INT

# exec_row <more|last> <need_gib> <label> <row|cotenant|ppl> <subcommand args...>
exec_row() {
    local pos=$1 need=$2 label=$3 sub=$4 keep=1 rc kv
    local -a envflags=()
    shift 4
    for kv in $COMMON_ENV $arm_env; do envflags+=(--env "$kv"); done
    [ "$pos" = last ] && keep=0
    if [ -e "$W/$label.ok" ]; then echo "skip: $label already complete" >&2; return; fi
    wait_free
    offline=1
    KEEP_OFFLINE=$keep OUT=$W/rows.jsonl EXEC_DEV=gpu TARGET=$target EXEC_LOG=$W/$label.log NEED_GIB=$need \
        EXEC_SWAP_LIMIT_GIB="${EXEC_SWAP_LIMIT_GIB:-8}" \
        "$D/run.sh" exec --label "$label" -- python3 "$H/halogen.py" "$sub" --image "$IMAGE" --models "$models" \
        --checkpoint "$ckpt" --label "$label" --out "$W/$label.row.json" --need-gib "$need" --floor-gib "$FLOOR_GIB" \
        "${envflags[@]}" "$@" &
    child=$!
    while :; do
        wait "$child"
        rc=$?
        kill -0 "$child" 2>/dev/null || break
    done
    child=
    [ "$rc" = 0 ] || { echo "ROW FAILED: $label (exit $rc)" >&2; exit 1; }
    touch "$W/$label.ok"
    if [ "$pos" = last ]; then offline=0; fi
}

stage=${1:-}
arm_vars "${2:-byo}"
need_gib=${NEED_GIB_OVERRIDE:-$(awk -v b="$(du -Lb --apparent-size -c "$models"/*.gguf "$models"/$ckpt 2>/dev/null | tail -1 | cut -f1)" \
    'BEGIN { printf "%d", b / 1073741824 + 8 }')}
case $stage in
fit)
    wait_free
    FIT_CHECK_ONLY=1 OUT=$W/fit.jsonl EXEC_DEV=gpu TARGET=$target EXEC_LOG=$W/fit.log NEED_GIB=$need_gib "$D/run.sh" exec -- true
    ;;
smoke)
    need CACHE
    exec_row last "$need_gib" "halogen-$2-smoke" row --cache "$CACHE" --decode-via chat --quick --do toolcall,prefill4k,decode512,vision,checks
    ;;
audit | offline)
    # the egress watch runs in every row; `offline` also drops the container's route out
    need CACHE
    offline_flag=()
    [ "$stage" = offline ] && offline_flag=(--offline)
    exec_row last "$need_gib" "halogen-$2-$stage" row --cache "$CACHE" --decode-via chat --quick \
        --do toolcall,prefill4k,decode512,vision,checks "${offline_flag[@]}"
    ;;
rows)
    need CACHE
    exec_row last "$need_gib" "halogen-$2-rows" row --cache "$CACHE" --decode-via chat \
        --do toolcall,prefill4k,decode512,decode32k,decode128k,replay,correctness,vision
    ;;
tasks)
    need CACHE
    exec_row last "$need_gib" "halogen-$2-tasks" row --cache "$CACHE" --do tasks
    ;;
checks)
    need CACHE
    exec_row last "$need_gib" "halogen-$2-checks" row --cache "$CACHE" --do checks
    ;;
cotenant)
    need LOAD_GIB
    exec_row last $((need_gib + LOAD_GIB)) "halogen-$2-cotenant" cotenant --load-gib "$LOAD_GIB"
    ;;
ppl)
    need IDS REF KL_PY
    # KL against #260's Q8_0 reference: Halogen's own top-128 dump over the reference's 64 x 2048 token ids, scored
    # with kl_halogen.py (second half of each chunk, as llama-perplexity does). The ids file is /ids in the container.
    mkdir -p "$W/ppl"
    ln -f "$IDS" "$W/ppl/ids.bin" 2>/dev/null || cp "$IDS" "$W/ppl/ids.bin"
    exec_row last "$need_gib" "halogen-$2-ppl" ppl --scratch "$W/ppl" -- "/models/$ckpt" --ids /ppl/ids.bin --seq 2048 --json \
        --ref-out "/ppl/halogen-$2.href" --per-pos "/ppl/halogen-$2.perpos"
    ;;
restore)
    restore
    ;;
*)
    echo "usage: rows.sh fit|smoke|audit|offline|rows|tasks|checks|cotenant|ppl|restore <v2|byo>" >&2
    exit 7
    ;;
esac
