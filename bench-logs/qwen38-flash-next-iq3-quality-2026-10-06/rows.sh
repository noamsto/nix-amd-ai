#!/usr/bin/env bash
# Agent-task rows for #260: the same task set on UD-IQ4_XS and UD-IQ3_XXS, GSQHalo with f16 KV and the gsq-hip preset
# flags, each through run.sh's memory gate. From the repo root: rows.sh <smoke|iq4|iq3>.
# Env (no defaults): W work dir (rows go to $W/rows.jsonl); CACHE the #249/#252 corpus cache; GSQ_BIN the GSQHalo
# llama-server; CORPUS_REV; IQ3 shard 1 of UD-IQ3_XXS (the production UD-IQ4_XS is run.sh's default).
# Run only when no kl.sh stage is active: both take lemond offline.
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
: "${W:?}" "${CACHE:?}" "${GSQ_BIN:?}" "${CORPUS_REV:?}"
export OUT=$W/rows.jsonl CACHE CORPUS_REV GSQ_BIN
F16="-ctk f16 -ctv f16"
mkdir -p "$W"
unset EXTRA_ARGS IQ4 # a leftover export must not change a labelled row

if pgrep -x 'llama-perplexit|llama-server|llama-bench' >/dev/null ||
    pgrep -f '(^|/)(bash|python3?) +[^ -][^ ]*(run\.sh|probe\.py)( |$)' >/dev/null; then
    echo "another benchmark process is running; refusing" >&2
    exit 2
fi

# Other crews on the host defer CPU-heavy gates while this file exists and its pid is alive.
SIGNAL=${XDG_RUNTIME_DIR:-/tmp}/halo-gpu-bench.active
printf '%s\n%s\n' "$$" "tasks-${1:-}" >"$SIGNAL"
trap '[ "$(head -n 1 -- "$SIGNAL" 2>/dev/null)" = "$$" ] && rm -f -- "$SIGNAL"' EXIT

case ${1:-} in
smoke)
    : "${IQ3:?}"
    IQ4=$IQ3 EXTRA_ARGS=$F16 NEED_GIB=85 "$D/run.sh" gsq-hip --label tasks-smoke --do tasks --quick || exit 1
    ;;
iq4)
    EXTRA_ARGS=$F16 "$D/run.sh" gsq-hip --label tasks-iq4 --do tasks || exit 1
    ;;
iq3)
    : "${IQ3:?}"
    IQ4=$IQ3 EXTRA_ARGS=$F16 NEED_GIB=85 "$D/run.sh" gsq-hip --label tasks-iq3 --do tasks || exit 1
    ;;
*)
    echo "usage: rows.sh smoke|iq4|iq3" >&2
    exit 7
    ;;
esac
