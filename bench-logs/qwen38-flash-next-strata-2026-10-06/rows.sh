#!/usr/bin/env bash
# Row stages for #257 (Strata on halo). From the repo root: rows.sh <stage>. Every row goes through the #249 run.sh
# memory gate; lemond stays offline between the rows of a stage and is restored after the last one.
# Stages: smoke | arm <def|defL|fast|fastL>
# Arms: def = Strata's setup defaults, fast = the maintainers' fast configuration (STRIX_HALO.md); an L suffix adds
# --lookup-chain 3 (prompt lookup after the MTP drafts). Needs the builds and files from the README's Reproduce section.
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
W=${W:-$HOME/strata-bench}
export OUT=$W/rows.jsonl CACHE=${CACHE:?CACHE is required (the #249/#252 corpus cache)}
export CORPUS_REV=4166bc461d7d4c0c10bac574f543a2a6cb912157
export STRATA_PY=${STRATA_PY:?} STRATA_REPO=${STRATA_REPO:?} STRATA_ENGINE=${STRATA_ENGINE:?} STRATA_VISION_BIN=${STRATA_VISION_BIN:?}
export STRATA_PACK=${STRATA_PACK:?} STRATA_MTP_RT=${STRATA_MTP_RT:?} STRATA_MMPROJ=${STRATA_MMPROJ:?}
export STRATA_EXPERT_CACHE=${STRATA_EXPERT_CACHE:?}
mkdir -p "$W"
unset EXTRA_ARGS IQ4 # a leftover export must not change a labelled row

# run <last|more> <preset> args...: KEEP_OFFLINE=1 unless this is the stage's last row.
run() {
    local keep=1 pos=$1
    shift
    [ "$pos" = last ] && keep=0
    KEEP_OFFLINE=$keep "$D/run.sh" "$@" || { echo "ROW FAILED: $* (exit $?)" >&2; exit 1; }
}

case ${1:-} in
smoke)
    # one small gated load: proves the server, the chat-completions speed path, vision and the memory arithmetic
    # SMOKE_EXTRA adds engine flags (e.g. --mmap-experts) to the preset's
    EXTRA_ARGS=${SMOKE_EXTRA:-} STRATA_CTX=8192 STRATA_EXPERT_CACHE=${SMOKE_EXPERT_CACHE:-2048} run last strata --label "${SMOKE_LABEL:-strata-smoke}" --quick --do toolcall,prefill4k,decode512,vision
    ;;
arm)
    arm=${2:?arm name}
    case $arm in
    def) preset=strata extra='' ;;
    defL) preset=strata extra='--lookup-chain 3' ;;
    fast) preset=strata-fast extra='' ;;
    fastL) preset=strata-fast extra='--lookup-chain 3' ;;
    *) echo "unknown arm: $arm" >&2; exit 7 ;;
    esac
    export EXTRA_ARGS=$extra
    run more "$preset" --label "s-$arm-A" --do toolcall,prefill4k,decode512,decode32k,replay,vision
    run more "$preset" --label "s-$arm-B" --do decode128k
    run last "$preset" --label "s-$arm-C" --do correctness
    ;;
*)
    echo "usage: rows.sh smoke | arm <def|defL|fast|fastL>" >&2
    exit 7
    ;;
esac
