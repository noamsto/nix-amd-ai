#!/usr/bin/env bash
# One engine bake-off probe row against a Strix Halo host's lemond-managed Qwen3.8-Flash-Next.
#
# Usage (repo root): OUT=rows.jsonl CACHE=cache.json CORPUS_REV=<sha> \
#     bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh <preset> [probe.py args...]
# Presets: corpus vulkan stock-hip strix-hip strix-hip-hlb gsq-hip gsq-hip-hlb gufo vulkan-q4kxl strata strata-fast exec
# The strata presets (Strata's own server and engine, #257) need STRATA_REPO (checkout), STRATA_PY (python with the
# server's deps), STRATA_ENGINE (the `strata` binary), STRATA_PACK (iq_pack output) and STRATA_EXPERT_CACHE (an explicit
# --expert-cache blob count: `auto` sizes from MemAvailable on a unified-memory APU and can exceed the GTT limit).
# Optional: STRATA_MTP_RT (draft layer dir), STRATA_MMPROJ + STRATA_VISION_BIN (images on), STRATA_LIB_DIRS (colon
# separated), STRATA_TUNING (hipBLASLt table), STRATA_CTX (default 131072).
# Remaining args go to probe.py (e.g. --label vulkan-speed --do prefill4k,decode512). Each call is one probe
# invocation. VULKAN_BIN / STOCK_BIN / STRIX_BIN / GSQ_BIN are required by the presets that use them. EXTRA_ARGS is
# appended to a llama preset's server flags (e.g. EXTRA_ARGS="-ctk f16 -ctv f16"; later flags win).
#
# exec runs an arbitrary child behind the same gate and lemond handoff: `run.sh exec [probe.py args] -- cmd...`.
# Env: OUT (row file), TARGET (model shard 1, sizes the floor), EXEC_DEV=gpu|cpu, EXEC_LOG (the child's stdout and
# stderr; OUT only gets probe's JSON row), optional DRAFT; CACHE and CORPUS_REV are not used. NEED_GIB defaults to 85
# (gpu) or 24 (cpu). The lazy-mode flags and the shard floor come from the child's argv. cpu: no floor, no GTT
# comparison (the child must not grow GTT), NEED_GIB is an anonymous-memory budget and also the child's kill limit.
# EXEC_SWAP_LIMIT_GIB (default 4) kills the child when system swap use grows by more than that.
#
# Fit check first (exit 5, lemond untouched): NEED_GIB must fit in GTT and in MemAvailable plus what lemond's
# loaded model frees (GTT in use + its llama-server RSS). With lazy mode off the weights are resident, so need is
# raised to the target shards + draft in GiB + 6. FIT_CHECK_ONLY=1 stops after that check. lemond must be reachable
# and hold no model other than Qwen3.8-Flash-Next-MTP (exit 6, untouched).
# While a row runs it holds $XDG_RUNTIME_DIR/halo-gpu-bench.active (line 1 pid, line 2 preset and label) so other
# crews on the host defer CPU-heavy gates; removed on every exit path.
# Then waits (30 min cap) for host load to settle, unloads Qwen3.8-Flash-Next-MTP from lemond (two copies do not
# fit), runs the probe with --strict-load --max-load-wait $OFFLINE_WAIT_BUDGET, and reloads lemond on every exit
# path, signals and configuration errors included (KEEP_OFFLINE=1 skips the reload after a probe that exited 0, so a
# later call can continue offline; the last one must not set it). Relative OUT and CACHE resolve against the
# caller's cwd.
# Exit: 0 ok, 1 row error (probe printed a JSON row), 2 foreign benchmark busy, 3 memory gate, 4 paused on host
# load, 5 does not fit, 6 lemond failure (unreachable, other models loaded, reload failed, still loaded),
# 7 configuration or usage error, 129/130/131/143 signalled (HUP/INT/QUIT/TERM).
set -u
LEMOND=${LEMOND:-http://127.0.0.1:13305/api/v1}
MODEL=Qwen3.8-Flash-Next-MTP
prc=1
rc=1 # the final status for reload(): the probe's once it has run
child=

SIGNAL_FILE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halo-gpu-bench.active
# shellcheck disable=SC2329 # invoked by the EXIT trap and reload()
signal_clear() { [ "$(sed -n 1p "$SIGNAL_FILE" 2>/dev/null)" != "$$" ] || rm -f "$SIGNAL_FILE"; }

post() { curl -fsS -X POST "$LEMOND/$1" -H 'Content-Type: application/json' -d "$2"; }
# 0 loaded, 1 cleanly absent, 2 unreachable or unparseable
has_model() {
    local h
    h=$(curl -fsS "$LEMOND/health") || return 2
    jq -e --arg m "$MODEL" 'any(.all_models_loaded[]; .model_name == $m)' <<<"$h" >/dev/null
    case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
# Fails when health is unreachable or unparseable.
other_models() {
    local h
    h=$(curl -fsS "$LEMOND/health") || return 2
    jq -r --arg m "$MODEL" '.all_models_loaded[] | select(.model_name != $m) | .model_name' <<<"$h"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
reload() {
    local i
    trap '' INT TERM HUP QUIT # a signal must not kill the in-flight /load; ignored dispositions pass to curl
    [ "${KEEP_OFFLINE:-0}" = 1 ] && [ "$rc" = 0 ] && return
    has_model && return
    local o
    o=$(other_models) && [ -z "$o" ] || { echo "reload: skipped, lemond unreachable or holding other models" >&2; exit 6; }
    post load "{\"model_name\":\"$MODEL\"}" >&2 || echo "reload: POST /load failed" >&2
    echo >&2
    for ((i = 0; i < 60; i++)); do
        has_model && break
        sleep 2
    done
    curl -fsS "$LEMOND/health" | jq '{model_loaded, pinned_models, loaded: [.all_models_loaded[] | {model_name, status, pinned}]}' >&2
    has_model || { echo "reload FAILED: $MODEL not loaded" >&2; signal_clear; exit 6; }
}

# shellcheck disable=SC2329 # invoked by the signal traps
on_signal() {
    [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
    while [ -n "$child" ] && kill -0 "$child" 2>/dev/null; do wait "$child"; done
    exit "$1"
}
trap 'reload; signal_clear' EXIT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 131' QUIT

need() {
    local v
    for v; do [ -n "${!v:-}" ] || { echo "$v is required" >&2; exit 7; }; done
}
if [ "${1:-}" = exec ]; then
    need OUT TARGET EXEC_DEV EXEC_LOG
else
    need OUT CACHE CORPUS_REV
fi
MODELS=${MODELS:-/var/lib/models}
UNSLOTH=$MODELS/hf/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/38bb39ee97821de2c9009abb7e93950eec396e66
GGML=$MODELS/hf/hub/models--ggml-org--Qwen3.8-Flash-Next-GGUF/snapshots/052beeaca7bec4a303e59cc7bc630c4f3a1b845d
IQ4=${IQ4:-$UNSLOTH/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf}
Q4KXL=${Q4KXL:-$UNSLOTH/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf}
DRAFT_GGML=${DRAFT_GGML:-$GGML/mtp-Qwen3.8-Flash-Next-Q8_0.gguf}
DRAFT_SHARED=${DRAFT_SHARED:-$UNSLOTH/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf}
GUFO_IMAGE=${GUFO_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime@sha256:b280a3781e0588154149f76b6d3fb6f0bc5f56da0f5352887af521f0a62dcf70}
OFFLINE_WAIT_BUDGET=${OFFLINE_WAIT_BUDGET:-1800}
STRATA_CTX=${STRATA_CTX:-131072}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE=${PROBE:-$HERE/probe.py}
ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 7
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
if [ "${1:-}" = exec ]; then
    case $EXEC_LOG in /*) ;; *) EXEC_LOG=$PWD/$EXEC_LOG ;; esac
else
    case $CACHE in /*) ;; *) CACHE=$PWD/$CACHE ;; esac
fi
cd "$ROOT" || exit 7

# Run probe.py in the background so a signal reaches run.sh's trap instead of waiting out the child; sets prc.
probe() {
    python3 "$PROBE" "$@" &
    child=$!
    while :; do
        wait "$child"
        prc=$?
        kill -0 "$child" 2>/dev/null || break
    done
    child=
}

[ $# -gt 0 ] || { echo "usage: run.sh <preset> [probe.py args...]" >&2; exit 7; }
preset=$1
shift
mode=llama
target='' draft='' flags='' bin=''
case $preset in
corpus)
    need VULKAN_BIN
    mode=corpus
    NEED_GIB=${NEED_GIB:-77}
    bin=$VULKAN_BIN target=$IQ4
    ;;
vulkan)
    need VULKAN_BIN
    NEED_GIB=${NEED_GIB:-77}
    bin=$VULKAN_BIN target=$IQ4 draft=$DRAFT_GGML
    flags="--lazy-mode on -ub 2048 -b 2048${EXTRA_ARGS:+ $EXTRA_ARGS}"
    ;;
stock-hip)
    need STOCK_BIN
    NEED_GIB=${NEED_GIB:-85}
    bin=$STOCK_BIN target=$IQ4 draft=$DRAFT_GGML
    flags="--lazy-mode on -ub 2048 -b 2048${EXTRA_ARGS:+ $EXTRA_ARGS}"
    ;;
strix-hip | strix-hip-hlb)
    need STRIX_BIN
    NEED_GIB=${NEED_GIB:-85}
    bin=$STRIX_BIN target=$IQ4 draft=$DRAFT_GGML
    flags="-lzm on -ub 4096 -b 4096${EXTRA_ARGS:+ $EXTRA_ARGS}"
    ;;
gsq-hip | gsq-hip-hlb)
    need GSQ_BIN
    NEED_GIB=${NEED_GIB:-85}
    bin=$GSQ_BIN target=$IQ4 draft=$DRAFT_GGML
    flags="-lzm on-direct -ub 8192 -b 8192 --spec-draft-p-min 0.3${EXTRA_ARGS:+ $EXTRA_ARGS}"
    ;;
strata | strata-fast)
    need STRATA_REPO STRATA_PY STRATA_ENGINE STRATA_PACK STRATA_EXPERT_CACHE
    mode=strata
    NEED_GIB=${NEED_GIB:-95}
    target=$IQ4
    profile=$STRATA_REPO/data/expert-profile.bin
    profile="'${profile//\'/\'\\\'\'}'" # single-quoted: the flag string is shlex-split by probe.py, which %q does not always survive
    # Strata's setup defaults (--prefill auto --spec 4 --spec-min-p 0.5, int8 KV above 8K context), lookup chain off,
    # with two changes for a unified-memory host shared with other work: --mmap-experts (no host arena; the experts sit
    # in the GPU cache and the page cache) and an explicit --expert-cache count instead of `auto`, which sizes from
    # MemAvailable.
    flags="--prefill auto --spec 4 --spec-min-p 0.5 --kv int8 --mmap-experts --expert-profile $profile --expert-cache $STRATA_EXPERT_CACHE --vram-reserve-mib 700"
    strata_env=("STRATA_HIPBLASLT_TUNING=${STRATA_TUNING:-$STRATA_REPO/tools/hip/gfx1151-hipblaslt-100401.txt}")
    if [ "$preset" = strata-fast ]; then
        # The maintainers' fast configuration (STRIX_HALO.md): bit-changing switches on, --mtp-q4 all, --prefill 16384.
        flags="--prefill 16384 --spec 4 --spec-min-p 0.5 --mtp-q4 all --kv int8 --mmap-experts --expert-profile $profile --expert-cache $STRATA_EXPERT_CACHE --vram-reserve-mib 700"
        strata_env+=(STRATA_PF_FUSED=1 STRATA_PF_GEMM=1 STRATA_HC_UPMIX=1 STRATA_PA_FAST=1 STRATA_HIP_WMMA=1
            STRATA_SELECT_WMMA=1 STRATA_HC_Q8=1 STRATA_PF_SWITCH_MIN_T=4096)
    fi
    flags="$flags${EXTRA_ARGS:+ $EXTRA_ARGS}"
    ;;
gufo)
    mode=gufo
    NEED_GIB=${NEED_GIB:-92}
    target=$Q4KXL draft=$DRAFT_SHARED
    ;;
vulkan-q4kxl)
    need VULKAN_BIN
    NEED_GIB=${NEED_GIB:-92}
    bin=$VULKAN_BIN target=$Q4KXL draft=$DRAFT_GGML
    flags="--lazy-mode on -ub 2048 -b 2048${EXTRA_ARGS:+ $EXTRA_ARGS}"
    ;;
exec)
    mode="exec"
    case $EXEC_DEV in
    gpu) NEED_GIB=${NEED_GIB:-85} ;;
    cpu) NEED_GIB=${NEED_GIB:-24} ;;
    *) echo "EXEC_DEV must be gpu or cpu, got '$EXEC_DEV'" >&2; exit 7 ;;
    esac
    # shellcheck disable=SC2153 # TARGET is the exec env contract, not a typo for target
    target=$TARGET draft=${DRAFT:-}
    execv=() seen=0
    for w; do
        if [ $seen = 1 ]; then execv+=("$w"); elif [ "$w" = -- ]; then seen=1; fi
    done
    [ ${#execv[@]} -gt 0 ] || { echo "usage: run.sh exec [probe.py args] -- cmd..." >&2; exit 7; }
    flags="${execv[*]}"
    ;;
*)
    echo "unknown preset: $preset" >&2
    exit 7
    ;;
esac
case $mode in
corpus) args=(corpus --server "$bin" --target "$target" --corpus-root "$ROOT") ;;
gufo) args=(gufo --image "$GUFO_IMAGE" --target "$target" --draft "$draft") ;;
strata)
    args=(strata --repo "$STRATA_REPO" --python "$STRATA_PY" --engine-bin "$STRATA_ENGINE" --pack "$STRATA_PACK"
        --target "$target" --extra "$flags" --ctx "$STRATA_CTX")
    [ -z "${STRATA_MTP_RT:-}" ] || args+=(--mtp-rt "$STRATA_MTP_RT")
    if [ -n "${STRATA_MMPROJ:-}" ]; then
        need STRATA_VISION_BIN
        args+=(--mmproj "$STRATA_MMPROJ" --vision-bin "$STRATA_VISION_BIN")
    fi
    IFS=: read -ra libdirs <<<"${STRATA_LIB_DIRS:-}"
    for d in "${libdirs[@]}"; do args+=(--lib-dir "$d"); done
    for kv in "${strata_env[@]}"; do args+=(--env "$kv"); done
    [ "${KEEP_OFFLINE:-0}" = 1 ] || args+=(--evict-after) # last row of a stage: lemond reloads next, with a clean page cache
    ;;
exec) args=(exec --target "$target" --dev "$EXEC_DEV" --child-log "$EXEC_LOG" --label exec) ;;
*) args=(llama --server "$bin" --target "$target" --draft "$draft" --extra "$flags") ;;
esac
case $preset in *-hlb) args+=(--env HIP_LAUNCH_BLOCKING=1) ;; esac
if [ "$mode" = corpus ]; then
    args+=(--cache "$CACHE" --corpus-rev "$CORPUS_REV")
elif [ "$mode" = exec ]; then
    [ -z "$draft" ] || args+=(--draft "$draft")
    args+=(--need-gib "$NEED_GIB" --strict-load --max-load-wait "$OFFLINE_WAIT_BUDGET")
else
    args+=(--cache "$CACHE" --need-gib "$NEED_GIB" --strict-load --max-load-wait "$OFFLINE_WAIT_BUDGET")
fi
case $NEED_GIB in '' | *[!0-9]*) echo "NEED_GIB must be an integer, got '$NEED_GIB'" >&2; exit 7 ;; esac

# Sum VmRSS (bytes) of every descendant of lemond: the backend may sit below a wrapper, and its anonymous memory is what an
# unload gives back. PROC_ROOT is /proc unless a test points it elsewhere.
lemond_rss() {
    local -A tree=()
    local pid ppid comm kib total=0 grew=1
    while read -r pid ppid comm; do
        [ "$comm" = lemond ] && tree[$pid]=1
    done < <(ps -eo pid=,ppid=,comm=)
    while [ "$grew" = 1 ]; do
        grew=0
        while read -r pid ppid comm; do
            [ -n "${tree[$pid]:-}" ] || [ -z "${tree[$ppid]:-}" ] && continue
            tree[$pid]=2
            grew=1
            kib=$(awk '/^VmRSS:/ {print $2}' "${PROC_ROOT:-/proc}/$pid/status" 2>/dev/null)
            total=$((total + ${kib:-0} * 1024))
        done < <(ps -eo pid=,ppid=,comm=)
    done
    echo "$total"
}

# True iff the last --lazy-mode/-lzm value in the flag string $1 starts with "on".
lazy_on() {
    local -a w
    local i lazy=off
    read -ra w <<<"$1"
    for ((i = 0; i < ${#w[@]} - 1; i++)); do
        case ${w[i]} in --lazy-mode | -lzm) lazy=${w[i + 1]} ;; esac
    done
    [[ $lazy == on* ]]
}

# Bytes of a GGUF, summed over its -NNNNN-of-NNNNN shards when it has them.
gguf_bytes() {
    local sizes
    local -a files=("$1")
    if [[ $1 =~ ^(.*)-[0-9]{5}-of-[0-9]{5}\.gguf$ ]]; then
        files=("${BASH_REMATCH[1]}"-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9].gguf)
    fi
    sizes=$(stat -L -c %s -- "${files[@]}") || return 1
    awk '{ s += $1 } END { print s + 0 }' <<<"$sizes"
}

# Exit 5 unless the need fits GTT and the memory that is free once lemond's model is gone. exec on cpu skips the GTT
# comparison and has no floor. Sets anon_gib, the need that was checked.
fit_check() {
    local dev card best='' gtt total=0 vram gtt_used=0 rss=0 avail_kib avail need foot floor=0 bytes dbytes cpu=0
    [ "$mode" = exec ] && [ "$EXEC_DEV" = cpu ] && cpu=1
    for dev in /sys/class/drm/card*/device; do
        [ -r "$dev/mem_info_gtt_total" ] || continue
        gtt=$(<"$dev/mem_info_gtt_total")
        if [ -z "$best" ] || [ "$gtt" -gt "$total" ]; then
            best=$dev
            total=$gtt
        fi
    done
    [ -n "$best" ] || { echo "fit: no amdgpu card with mem_info_gtt_total" >&2; exit 7; }
    card=${best%/device}
    card=${card##*/}
    vram=$(<"$best/mem_info_vram_total")
    if has_model; then
        gtt_used=$(<"$best/mem_info_gtt_used")
        rss=$(lemond_rss)
    fi
    if [ $cpu = 0 ] && ! lazy_on "$flags"; then
        bytes=$(gguf_bytes "$target") || { echo "fit: cannot stat $target" >&2; exit 7; }
        if [ -n "$draft" ]; then
            dbytes=$(gguf_bytes "$draft") || { echo "fit: cannot stat $draft" >&2; exit 7; }
            bytes=$((bytes + dbytes))
        fi
        floor=$(((bytes + 1073741823) / 1073741824 + 6))
    fi
    avail_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    avail=$((avail_kib * 1024))
    foot=$((gtt_used + rss))
    need=$((NEED_GIB > floor ? NEED_GIB : floor))
    anon_gib=$need
    if [ $cpu = 1 ]; then
        awk -v need="$need" -v card="$card" -v avail="$avail" -v gu="$gtt_used" -v rss="$rss" \
            'BEGIN { g = 1073741824; printf "fit: need %d GiB anonymous (cpu: lazy-off floor and GTT comparison skipped); %s; MemAvailable %.1f + lemond (gtt used %.1f + rss %.1f) = %.1f GiB\n", need, card, avail/g, gu/g, rss/g, (avail+gu+rss)/g }' >&2
        if [ $((need * 1073741824)) -gt $((avail + foot)) ]; then
            echo "fit: refusing, $need GiB does not fit; lemond untouched" >&2
            exit 5
        fi
        return
    fi
    awk -v need="$need" -v ng="$NEED_GIB" -v floor="$floor" -v card="$card" -v gtt="$total" -v vram="$vram" -v avail="$avail" -v gu="$gtt_used" -v rss="$rss" \
        'BEGIN { g = 1073741824; printf "fit: need %d GiB (NEED_GIB %d, lazy-off floor %s); %s gtt %.1f GiB (vram %.1f); MemAvailable %.1f + lemond (gtt used %.1f + rss %.1f) = %.1f GiB\n", need, ng, floor ? floor : "n/a", card, gtt/g, vram/g, avail/g, gu/g, rss/g, (avail+gu+rss)/g }' >&2
    if [ $((need * 1073741824)) -gt "$total" ] || [ $((need * 1073741824)) -gt $((avail + foot)) ]; then
        echo "fit: refusing, $need GiB does not fit; lemond untouched" >&2
        exit 5
    fi
}

others=$(other_models) || { trap - EXIT; echo "lemond unreachable or health unparseable: $LEMOND" >&2; exit 6; }
others=${others//$'\n'/,}
[ -z "$others" ] || { trap - EXIT; echo "refusing: lemond has other models loaded ($others); untouched" >&2; exit 6; }
anon_gib=
fit_check
[ "$mode" = exec ] && args+=(--anon-limit-gib "$anon_gib" --swap-limit-gib "${EXEC_SWAP_LIMIT_GIB:-4}")
[ "${FIT_CHECK_ONLY:-0}" = 1 ] && { rc=0; exit 0; }

# Tell other crews on this host a GPU row is running; the file is ours only while its pid is this process.
row_label=$preset
for ((i = 1; i < $#; i++)); do [ "${!i}" = --label ] && { j=$((i + 1)); row_label="$preset ${!j}"; }; done
printf '%s\n%s\n' "$$" "$row_label" >"$SIGNAL_FILE"

has_model
case $? in
0)
    probe wait-load --max-load-wait 1800 >&2
    post unload "{\"model_name\":\"$MODEL\"}" >&2
    echo >&2
    ;;
2) trap signal_clear EXIT; echo "lemond unreachable: $LEMOND" >&2; exit 6 ;;
esac
has_model
[ $? = 1 ] || { echo "lemond still has $MODEL loaded or is unreachable" >&2; exit 6; }

if [ "$mode" = corpus ]; then
    probe "${args[@]}" "$@"
else
    probe "${args[@]}" "$@" >>"$OUT"
fi
rc=$prc
case $rc in
0) ;;
2 | 3) echo "aborting: probe.py exit $rc: $preset $*" >&2 ;;
4) echo "paused: host load" >&2 ;;
7) echo "usage error in probe args (no row): $preset $*" >&2 ;;
*) echo "row failed (exit $rc): $preset $*" >&2 ;;
esac
exit "$rc"
