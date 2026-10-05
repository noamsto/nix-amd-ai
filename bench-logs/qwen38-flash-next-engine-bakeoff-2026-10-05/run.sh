#!/usr/bin/env bash
# One engine bake-off probe row against a Strix Halo host's lemond-managed Qwen3.8-Flash-Next.
#
# Usage (repo root): OUT=rows.jsonl CACHE=cache.json CORPUS_REV=<sha> \
#     bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh <preset> [probe.py args...]
# Presets: corpus vulkan strix-hip strix-hip-hlb gsq-hip gsq-hip-hlb gufo vulkan-q4kxl
# Remaining args go to probe.py (e.g. --label vulkan-speed --do prefill4k,decode512). Each call is one probe
# invocation. VULKAN_BIN / STRIX_BIN / GSQ_BIN are required by the presets that use them.
#
# Fit check first (exit 5, lemond untouched): NEED_GIB must fit in the GPU's GTT+VRAM and in MemAvailable plus
# what lemond's loaded model frees (GTT in use + its llama-server RSS). FIT_CHECK_ONLY=1 stops after that check.
# Then waits (30 min cap) for host load to settle, unloads Qwen3.8-Flash-Next-MTP from lemond (two copies do not
# fit), runs the probe with --strict-load --max-load-wait $OFFLINE_WAIT_BUDGET, and reloads lemond on every exit
# path (KEEP_OFFLINE=1 skips the reload after a probe that exited 0, so a later call can continue offline; the
# last one must not set it). Exit: 0 ok, 1 row error (JSON already in $OUT), 2 foreign benchmark busy,
# 3 memory gate, 4 paused on host load, 5 does not fit.
set -u
: "${OUT:?}" "${CACHE:?}" "${CORPUS_REV:?}"
MODELS=${MODELS:-/var/lib/models}
UNSLOTH=$MODELS/hf/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/38bb39ee97821de2c9009abb7e93950eec396e66
GGML=$MODELS/hf/hub/models--ggml-org--Qwen3.8-Flash-Next-GGUF/snapshots/052beeaca7bec4a303e59cc7bc630c4f3a1b845d
IQ4=${IQ4:-$UNSLOTH/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf}
Q4KXL=${Q4KXL:-$UNSLOTH/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf}
DRAFT_GGML=${DRAFT_GGML:-$GGML/mtp-Qwen3.8-Flash-Next-Q8_0.gguf}
DRAFT_SHARED=${DRAFT_SHARED:-$UNSLOTH/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf}
GUFO_IMAGE=${GUFO_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime@sha256:b280a3781e0588154149f76b6d3fb6f0bc5f56da0f5352887af521f0a62dcf70}
OFFLINE_WAIT_BUDGET=${OFFLINE_WAIT_BUDGET:-1800}
LEMOND=http://127.0.0.1:13305/api/v1
MODEL=Qwen3.8-Flash-Next-MTP
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 1
cd "$ROOT" || exit 1

[ $# -gt 0 ] || { echo "usage: run.sh <preset> [probe.py args...]" >&2; exit 1; }
preset=$1
shift
mode=llama
case $preset in
corpus)
    : "${VULKAN_BIN:?}"
    mode=corpus
    NEED_GIB=${NEED_GIB:-77}
    args=(corpus --server "$VULKAN_BIN" --target "$IQ4" --corpus-root "$ROOT")
    ;;
vulkan)
    : "${VULKAN_BIN:?}"
    NEED_GIB=${NEED_GIB:-77}
    args=(llama --server "$VULKAN_BIN" --target "$IQ4" --draft "$DRAFT_GGML" --extra "--lazy-mode on -ub 2048 -b 2048")
    ;;
strix-hip | strix-hip-hlb)
    : "${STRIX_BIN:?}"
    NEED_GIB=${NEED_GIB:-85}
    args=(llama --server "$STRIX_BIN" --target "$IQ4" --draft "$DRAFT_GGML" --extra "-lzm on -ub 4096 -b 4096")
    ;;
gsq-hip | gsq-hip-hlb)
    : "${GSQ_BIN:?}"
    NEED_GIB=${NEED_GIB:-85}
    args=(llama --server "$GSQ_BIN" --target "$IQ4" --draft "$DRAFT_GGML"
        --extra "-lzm on-direct -ub 8192 -b 8192 --spec-draft-p-min 0.3")
    ;;
gufo)
    mode=gufo
    NEED_GIB=${NEED_GIB:-92}
    args=(gufo --image "$GUFO_IMAGE" --target "$Q4KXL" --draft "$DRAFT_SHARED")
    ;;
vulkan-q4kxl)
    : "${VULKAN_BIN:?}"
    NEED_GIB=${NEED_GIB:-92}
    args=(llama --server "$VULKAN_BIN" --target "$Q4KXL" --draft "$DRAFT_GGML" --extra "--lazy-mode on -ub 2048 -b 2048")
    ;;
*)
    echo "unknown preset: $preset" >&2
    exit 1
    ;;
esac
case $preset in *-hlb) args+=(--env HIP_LAUNCH_BLOCKING=1) ;; esac
if [ "$mode" = corpus ]; then
    args+=(--cache "$CACHE" --corpus-rev "$CORPUS_REV")
else
    args+=(--cache "$CACHE" --need-gib "$NEED_GIB" --strict-load --max-load-wait "$OFFLINE_WAIT_BUDGET")
fi
case $NEED_GIB in '' | *[!0-9]*) echo "NEED_GIB must be an integer, got '$NEED_GIB'" >&2; exit 1 ;; esac

post() { curl -sS -X POST "$LEMOND/$1" -H 'Content-Type: application/json' -d "$2"; }
loaded() { curl -sS "$LEMOND/health" | jq -r '.all_models_loaded | length'; }

# Sum VmRSS (bytes) of the processes whose parent is lemond.
lemond_rss() {
    local -A lemond=()
    local pid ppid comm kib total=0
    while read -r pid ppid comm; do
        [ "$comm" = lemond ] && lemond[$pid]=1
    done < <(ps -eo pid=,ppid=,comm=)
    while read -r pid ppid comm; do
        [ -n "${lemond[$ppid]:-}" ] || continue
        kib=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
        total=$((total + ${kib:-0} * 1024))
    done < <(ps -eo pid=,ppid=,comm=)
    echo "$total"
}

# Exit 5 unless NEED_GIB fits the GPU and the memory that is free once lemond's model is gone.
fit_check() {
    local dev card best='' gtt total=0 vram gtt_used=0 rss=0 avail_kib avail need foot
    for dev in /sys/class/drm/card*/device; do
        [ -r "$dev/mem_info_gtt_total" ] || continue
        gtt=$(<"$dev/mem_info_gtt_total")
        if [ -z "$best" ] || [ "$gtt" -gt "$total" ]; then
            best=$dev
            total=$gtt
        fi
    done
    [ -n "$best" ] || { echo "fit: no amdgpu card with mem_info_gtt_total" >&2; exit 1; }
    card=${best%/device}
    card=${card##*/}
    vram=$(<"$best/mem_info_vram_total")
    if [ "$(loaded)" != 0 ]; then
        gtt_used=$(<"$best/mem_info_gtt_used")
        rss=$(lemond_rss)
    fi
    avail_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    avail=$((avail_kib * 1024))
    foot=$((gtt_used + rss))
    need=$((NEED_GIB * 1073741824))
    awk -v need="$NEED_GIB" -v card="$card" -v gtt="$total" -v vram="$vram" -v avail="$avail" -v gu="$gtt_used" -v rss="$rss" \
        'BEGIN { g = 1073741824; printf "fit: need %d GiB; %s gtt %.1f + vram %.1f = %.1f GiB; MemAvailable %.1f + lemond (gtt used %.1f + rss %.1f) = %.1f GiB\n", need, card, gtt/g, vram/g, (gtt+vram)/g, avail/g, gu/g, rss/g, (avail+gu+rss)/g }' >&2
    if [ "$need" -gt $((total + vram)) ] || [ "$need" -gt $((avail + foot)) ]; then
        echo "fit: refusing, $NEED_GIB GiB does not fit; lemond untouched" >&2
        exit 5
    fi
}

fit_check
[ "${FIT_CHECK_ONLY:-0}" = 1 ] && exit 0

# shellcheck disable=SC2329 # invoked by the EXIT trap
reload() {
    local rc=$?
    [ "${KEEP_OFFLINE:-0}" = 1 ] && [ "$rc" = 0 ] && return
    local n
    n=$(loaded) || n=
    case $n in '' | 0) ;; *) return ;; esac
    post load "{\"model_name\":\"$MODEL\"}" >&2 || echo "reload: POST /load failed" >&2
    echo >&2
    curl -sS "$LEMOND/health" | jq '{model_loaded, pinned_models, loaded: [.all_models_loaded[] | {model_name, status, pinned}]}' >&2
}
trap reload EXIT

if [ "$(loaded)" != 0 ]; then
    python3 "$HERE/probe.py" wait-load --max-load-wait 1800 >&2
    post unload "{\"model_name\":\"$MODEL\"}" >&2
    echo >&2
fi
[ "$(loaded)" = 0 ] || { echo "lemond still has a model loaded" >&2; exit 1; }

if [ "$mode" = corpus ]; then
    python3 "$HERE/probe.py" "${args[@]}" "$@"
else
    python3 "$HERE/probe.py" "${args[@]}" "$@" >>"$OUT"
fi
rc=$?
case $rc in
0) ;;
2 | 3) echo "aborting: probe.py exit $rc: $preset $*" >&2 ;;
4) echo "paused: host load" >&2 ;;
*) echo "row failed (exit $rc): $preset $*" >&2 ;;
esac
exit "$rc"
