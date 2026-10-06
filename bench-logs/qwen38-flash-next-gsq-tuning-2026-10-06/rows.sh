#!/usr/bin/env bash
# Row stages for #252. From the repo root: rows.sh <stage>. Every row goes through the #249 run.sh memory gate.
# Stages: vulkan | f16 | q8ctl | iq3 | decode128k-variants. Within a stage lemond stays offline between rows and is
# restored after the last one. Needs the builds from the README's Reproduce section.
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
W=${W:-$HOME/gsqtune}
export OUT=$W/rows.jsonl CACHE=$W/cache.json CORPUS_REV=4166bc461d7d4c0c10bac574f543a2a6cb912157
export VULKAN_BIN=$W/result-vulkan/bin/llama-server GSQ_BIN=$W/result-gsq/bin/llama-server
IQ3=${IQ3:-/var/lib/models/gsq-tuning/Qwen3.8-Flash-Next-UD-IQ3_XXS-00001-of-00003.gguf}
F16="-ctk f16 -ctv f16"
mkdir -p "$W"

# run <last|more> <preset> args...: KEEP_OFFLINE=1 unless this is the stage's last row.
run() {
    local keep=1 pos=$1
    shift
    [ "$pos" = last ] && keep=0
    KEEP_OFFLINE=$keep "$D/run.sh" "$@" || { echo "ROW FAILED: $* (exit $?)" >&2; exit 1; }
}

case ${1:-} in
vulkan)
    [ -f "$CACHE" ] || run more corpus
    run more vulkan --label vulkan-A --do toolcall,prefill4k,decode512,decode32k,replay
    run more vulkan --label vulkan-B --do decode128k
    run last vulkan --label vulkan-C --do correctness
    ;;
f16)
    export EXTRA_ARGS="$F16"
    run more gsq-hip --label gsq-f16-A --do toolcall,prefill4k,decode512,decode32k,replay
    run more gsq-hip --label gsq-f16-B --do decode128k
    run last gsq-hip --label gsq-f16-C --do correctness
    ;;
q8ctl)
    run last gsq-hip --label gsq-q8-peak --do prefill4k,decode32k,decode128k
    ;;
iq3)
    # KV type is chosen from the f16 rows: pass EXTRA_ARGS in the environment ("$F16" or empty)
    export IQ4=$IQ3 NEED_GIB=${NEED_GIB:-85}
    run more gsq-hip --label gsq-iq3-A --do toolcall,prefill4k,decode512,decode32k,replay
    run more gsq-hip --label gsq-iq3-B --do decode128k
    run last gsq-hip --label gsq-iq3-C --do correctness
    ;;
decode128k-variants)
    # flags appended after the preset's own, so the later value wins
    EXTRA_ARGS="${KV:-$F16} -ub 4096" run more gsq-hip --label gsq-ub4096 --do decode128k
    EXTRA_ARGS="${KV:-$F16} -ub 2048" run more gsq-hip --label gsq-ub2048 --do decode128k
    EXTRA_ARGS="${KV:-$F16} --spec-draft-n-max 2" run more gsq-hip --label gsq-nmax2 --do decode128k
    EXTRA_ARGS="${KV:-$F16} --spec-draft-n-max 4" run last gsq-hip --label gsq-nmax4 --do decode128k
    ;;
*)
    echo "usage: rows.sh vulkan|f16|q8ctl|iq3|decode128k-variants" >&2
    exit 7
    ;;
esac
