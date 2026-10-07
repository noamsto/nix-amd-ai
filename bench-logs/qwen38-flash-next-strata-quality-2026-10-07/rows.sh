#!/usr/bin/env bash
# Gated rows for #276 (Strata fast-config quality, soak and vision on halo). From the repo root: rows.sh <stage> ...
# Every row goes through #249's run.sh memory gate (probe.py), lemond offline for the row and restored after the last
# row of a stage (KEEP_OFFLINE=1 between them).
# Stages:
#   kl <chunks> <arm>...        Strata top-256 scoring against the #260 reference (kl_strata.py run), one engine start per
#                               arm; arms are def, fast, fast-<switch>[,<switch>], def+<switch> (see kl_strata.py)
#   llama <chunks> <stock|stock-hip|gsq>...
#                               llama-perplexity --kl-divergence against the same reference on the GPU (stock = Vulkan
#                               build, stock-hip = HIP build, gsq = GSQHalo, f16 KV as #260)
#   probe <def|fast> <label> <groups> [probe.py args...]
#                               one `run.sh strata[-fast]` row (a Strata server, vision on) running probe.py groups, e.g.
#                               soak, longsoak (--soak-minutes N), bigimage (--vision-max-tokens 1024, SCREENSHOT_PNG), quirks,
#                               correctness (NO_MTP=1 drops the draft layer)
# Env (no defaults): W work dir (reference logits, rows, run logs), REF reference logits, IQ4 shard 1 of the UD-IQ4_XS file,
# STRATA_ENGINE STRATA_PACK STRATA_REPO STRATA_MTP_RT (kl; the other stages also take run.sh's STRATA_ variables),
# PY python with numpy (kl), CACHE STRATA_PY STRATA_VISION_BIN STRATA_MMPROJ (probe; run.sh's strata variables), STOCK_BIN / STOCK_HIP_BIN / GSQ_BIN (llama; the server binary, llama-perplexity sits beside it).
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
Q=bench-logs/qwen38-flash-next-strata-quality-2026-10-07
: "${W:?}" "${REF:?}" "${IQ4:?}"
mkdir -p "$W/kl"

# One job at a time: a second run.sh's EXIT trap would reload lemond under a running child.
if pgrep -x 'llama-perplexit|llama-server|llama-bench|strata' >/dev/null ||
    pgrep -f '(^|/)(bash|python3?) +[^ -][^ ]*(run\.sh|probe\.py|kl_strata\.py)( |$)' >/dev/null; then
    echo "another benchmark process is running; refusing" >&2
    exit 2
fi

# After a `more` row lemond is offline until the next run.sh or the `last` row: a signal or a bad argument in that gap
# would strand it, so the exit trap restores it through a no-op run.sh (its own EXIT trap reloads the model).
offline=0
# shellcheck disable=SC2329 # invoked by the EXIT trap
restore_lemond() {
    [ "$offline" = 1 ] || return 0
    trap '' INT TERM HUP
    FIT_CHECK_ONLY=1 KEEP_OFFLINE=0 OUT=$W/rows.jsonl EXEC_DEV=cpu TARGET=$IQ4 EXEC_LOG=$W/restore.log NEED_GIB=1 \
        "$D/run.sh" exec -- true || echo "lemond restore FAILED (exit $?)" >&2
}
trap restore_lemond EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# exec_row <more|last> <label> <need_gib> <child argv...>
exec_row() {
    local pos=$1 label=$2 need=$3 keep=1
    shift 3
    [ "$pos" = last ] && keep=0
    KEEP_OFFLINE=$keep OUT=$W/rows.jsonl EXEC_DEV=gpu TARGET=$IQ4 EXEC_LOG=$W/$label.log NEED_GIB=$need \
        "$D/run.sh" exec --label "$label" -- "$@" || { echo "ROW FAILED: $label (exit $?)" >&2; exit 1; }
    if [ "$pos" = last ]; then offline=0; else offline=1; fi
}

# pos <index> <count>: last for the stage's final row
pos() { [ "$1" -eq "$2" ] && echo last || echo more; }

case ${1:-} in
kl)
    chunks=${2:?chunks}
    shift 2
    : "${PY:?}" "${STRATA_ENGINE:?}" "${STRATA_PACK:?}" "${STRATA_REPO:?}" "${STRATA_MTP_RT:?}"
    [ $# -gt 0 ] || { echo "no arms" >&2; exit 7; }
    i=0
    for arm in "$@"; do
        i=$((i + 1))
        label=kl-$arm-$chunks
        # the run dir is the row's output; a rerun starts it over
        rm -rf "${W:?}/kl/$label"
        exec_row "$(pos "$i" $#)" "$label" 95 "$PY" "$Q/kl_strata.py" run --arm "$arm" --ref "$REF" --target "$IQ4" \
            --chunks "$chunks" --out "$W/kl/$label"
    done
    ;;
llama)
    chunks=${2:?chunks}
    shift 2
    [ $# -gt 0 ] || { echo "no builds" >&2; exit 7; }
    for b; do # before the first row: a bad later build must not strand lemond after an earlier KEEP_OFFLINE row
        case $b in
        stock) : "${STOCK_BIN:?}" ;;
        stock-hip) : "${STOCK_HIP_BIN:?}" ;;
        gsq) : "${GSQ_BIN:?}" ;;
        *) echo "unknown build: $b" >&2; exit 7 ;;
        esac
    done
    i=0
    for b in "$@"; do
        i=$((i + 1))
        case $b in
        stock) bin=${STOCK_BIN:?} lazy=(--lazy-mode on) ;;
        stock-hip) bin=${STOCK_HIP_BIN:?} lazy=(--lazy-mode on) ;;
        gsq) bin=${GSQ_BIN:?} lazy=(-lzm on-direct) ;;
        *) echo "unknown build: $b" >&2; exit 7 ;;
        esac
        ppl=$(dirname "$bin")/llama-perplexity
        # -ub/-b 2048: one chunk per batch as #260; Vulkan and HIP take the same flags
        exec_row "$(pos "$i" $#)" "llama-$b-$chunks" 85 "$ppl" -m "$IQ4" -f "$W/eval.txt" -c 2048 -b 2048 -ub 2048 \
            --chunks "$chunks" -ngl 99 -fa on -ctk f16 -ctv f16 "${lazy[@]}" --kl-divergence --kl-divergence-base "$REF"
    done
    ;;
probe)
    arm=${2:?arm} label=${3:?label} groups=${4:?groups}
    shift 4
    : "${CACHE:?}" "${STRATA_PY:?}" "${STRATA_ENGINE:?}" "${STRATA_PACK:?}" "${STRATA_REPO:?}"
    [ "${NO_MTP:-0}" = 1 ] && unset STRATA_MTP_RT || : "${STRATA_MTP_RT:?}"
    : "${STRATA_VISION_BIN:?}" "${STRATA_MMPROJ:?}" "${STRATA_EXPERT_CACHE:?}"
    case $arm in
    def) preset=strata ;;
    fast) preset=strata-fast ;;
    *) echo "unknown arm: $arm" >&2; exit 7 ;;
    esac
    export STRATA_CTX=${STRATA_CTX:-131072} CORPUS_REV=4166bc461d7d4c0c10bac574f543a2a6cb912157
    unset EXTRA_ARGS
    KEEP_OFFLINE=0 OUT=$W/rows.jsonl "$D/run.sh" "$preset" --label "$label" --do "$groups" "$@" || { echo "ROW FAILED: $label (exit $?)" >&2; exit 1; }
    ;;
*)
    echo "usage: rows.sh kl <chunks> <arm>... | llama <chunks> <stock|stock-hip|gsq>... | probe <arm> <label> <groups> [args]" >&2
    exit 7
    ;;
esac
