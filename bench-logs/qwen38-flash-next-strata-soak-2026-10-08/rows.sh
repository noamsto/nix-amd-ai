#!/usr/bin/env bash
# Gated rows for #282 (Strata soak, concurrency, long context and two sessions on halo). From the repo root:
#   rows.sh <row>...        run the named rows in order; lemond stays offline between them and is restored after the last
#   rows.sh list
# Every row goes through #249's run.sh memory gate and lemond hand-off. Rows:
#   Strata, the fast config with vision on (run.sh strata-fast), the deployed build:
#     soak           the 8-turn replay x3, 2 and 4 concurrent requests, one request at a time
#     soak-batch     the same with --batch 4
#     bigimage       a 1,024-token screenshot through the CPU encoder with a concurrent text request (SCREENSHOT_PNG)
#     longsoak       SOAK_MINUTES (default 60) of mixed thinking-on requests, a canary every 5 minutes
#     depth192       one agent session grown to the end of a 196,608-token context
#     depth256       the same at 262,144
#     two128         two sessions of ~119K tokens each, --batch 2
#     two128-nobatch the same without --batch: one slot, two sessions arriving in turn
#     two128-mtp     the same with --batch 2 --batch-mtp
#     two256-park    two sessions of ~238K tokens each at the 262,144 limit, --batch 2 --conversation-cache-mib 8192
#     nomtp-depth128 depth to a 131,072-token context with the MTP draft layer left out: the one-stream control for the batch rows
#     two128-park    the same with --batch 2 --conversation-cache-mib 8192: sessions parked in RAM between requests
#   GSQHalo llama.cpp with f16 KV as the resident lemond model runs it (run.sh gsq-hip):
#     gsq-depth192 gsq-depth256   -c 196608 / 262144, one slot
#     gsq-two128                  -c 262144 -np 2: two slots of 131072
# Env (no defaults): W work dir, CACHE (the #249 corpus cache), the STRATA_ variables of run.sh (STRATA_PY STRATA_REPO
# STRATA_ENGINE STRATA_VISION_BIN STRATA_PACK STRATA_MTP_RT STRATA_MMPROJ STRATA_EXPERT_CACHE), GSQ_BIN, IQ4 (shard 1 of
# the UD-IQ4_XS file), SCREENSHOT_PNG for bigimage.
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
: "${W:?}" "${CACHE:?}" "${IQ4:?}"
mkdir -p "$W"

if [ "${1:-}" = list ] || [ $# -eq 0 ]; then
    sed -n '/^# Every row/,/^# Env/p' "$0" | sed '$d'
    exit 0
fi

# One job at a time: a second run.sh's EXIT trap would reload lemond under a running child.
if pgrep -x 'llama-server|strata' >/dev/null ||
    pgrep -f '(^|/)(bash|python3?) +[^ -][^ ]*(run\.sh|probe\.py)( |$)' >/dev/null; then
    echo "another benchmark process is running; refusing" >&2
    exit 2
fi

# After a row that kept lemond offline, a signal or a bad row name in the gap would strand it: the exit trap restores it
# through a no-op run.sh (its own EXIT trap reloads the model).
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

for row; do
    case $row in
    soak | soak-batch | bigimage | longsoak | depth192 | depth256 | two128 | two128-nobatch | two128-mtp | two128-park | two256-park | nomtp-depth128 | gsq-depth192 | gsq-depth256 | gsq-two128) ;;
    *) echo "unknown row: $row" >&2; exit 7 ;;
    esac
done
: "${STRATA_PY:?}" "${STRATA_REPO:?}" "${STRATA_ENGINE:?}" "${STRATA_VISION_BIN:?}" "${STRATA_PACK:?}" "${STRATA_MTP_RT:?}"
: "${STRATA_MMPROJ:?}" "${STRATA_EXPERT_CACHE:?}"
export OUT=$W/rows.jsonl CACHE CORPUS_REV=4166bc461d7d4c0c10bac574f543a2a6cb912157
unset EXTRA_ARGS LLAMA_CTX LLAMA_SLOTS
mtp_rt=$STRATA_MTP_RT

i=0
for row; do
    i=$((i + 1))
    keep=1
    [ "$i" -eq $# ] && keep=0
    preset=strata-fast ctx=131072 extra='' probe_args=()
    export STRATA_MTP_RT=$mtp_rt
    case $row in
    soak) groups=soak ;;
    soak-batch) groups=soak extra='--batch 4' ;;
    bigimage)
        : "${SCREENSHOT_PNG:?}"
        groups=bigimage probe_args=(--vision-max-tokens 1024) ;;
    longsoak) groups=longsoak probe_args=(--soak-minutes "${SOAK_MINUTES:-60}") ;;
    depth192) groups=depth ctx=196608 ;;
    depth256) groups=depth ctx=262144 ;;
    two128) groups=twosession extra='--batch 2' ;;
    two128-nobatch) groups=twosession ;;
    two128-mtp) groups=twosession extra='--batch 2 --batch-mtp' ;;
    two256-park) groups=twosession ctx=262144 extra='--batch 2 --conversation-cache-mib 8192' ;;
    nomtp-depth128) groups=depth; unset STRATA_MTP_RT ;;
    two128-park) groups=twosession extra='--batch 2 --conversation-cache-mib 8192' ;;
    gsq-depth192) preset=gsq-hip groups=depth ctx=196608 ;;
    gsq-depth256) preset=gsq-hip groups=depth ctx=262144 ;;
    gsq-two128) preset=gsq-hip groups=twosession ctx=262144 ;;
    esac
    case $preset in
    strata-fast) export STRATA_CTX=$ctx ;;
    gsq-hip)
        : "${GSQ_BIN:?}"
        # the resident model's KV type (lemond's launch line), which the probe's default q8_0 would override
        extra='-ctk f16 -ctv f16'
        export LLAMA_CTX=$ctx LLAMA_SLOTS=1
        [ "$row" = gsq-two128 ] && export LLAMA_SLOTS=2 ;;
    esac
    [ -z "$extra" ] || export EXTRA_ARGS=$extra
    echo "=== $row $(date +%T)" >&2
    KEEP_OFFLINE=$keep "$D/run.sh" "$preset" --label "s282-$row" --do "$groups" "${probe_args[@]}" ||
        { echo "ROW FAILED: $row (exit $?)" >&2; exit 1; }
    if [ "$keep" = 1 ]; then offline=1; else offline=0; fi
    unset EXTRA_ARGS LLAMA_CTX LLAMA_SLOTS
done
