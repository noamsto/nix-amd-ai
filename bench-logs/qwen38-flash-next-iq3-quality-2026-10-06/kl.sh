#!/usr/bin/env bash
# KL-divergence stages for #260. From the repo root: kl.sh <stage>. Every llama-perplexity child runs through run.sh's
# `exec` preset (probe.py gate, lemond unloaded for the child and restored after it).
# Env (no defaults): W work dir for eval text, logits, logs and rows; GSQ_BIN the GSQHalo llama-server (its sibling
# llama-perplexity is used for every run, CPU and GPU, so base-file format and tokenizer are identical); REF shard 1
# of the reference quant; TOK a llama-tokenize that loads the vocab (the GSQHalo one does not; use the Vulkan
# build's); IQ4, IQ3 shard 1 of the candidates; CHUNKS number of 2048-token chunks. KL_RUN_DIR overrides the directory
# that holds run.sh (tests).
# kl.sh owns the lemond-offline window: every row but the last keeps lemond unloaded, and kl.sh itself reloads it when
# the last row is skipped as complete or kl.sh is killed or fails mid-window. A row is complete once "<log>.ok" exists.
# Stages:
#   evaltext        build $W/eval.txt from the repo at CORPUS_REV, print bytes, sha256 and token count
#   ref-cpu         reference logits on the CPU backend ($W/ref.logits); CHUNKS=2 times it (go/no-go)
#   candidates      one lemond-offline window: IQ4 vs ref, IQ3 vs ref, IQ4 logits saved, IQ3 vs IQ4, then the
#                   backend noise floor (IQ4 on CPU for 4 chunks, IQ4 on the GPU scored against it)
#   cpu-candidates  one lemond-offline window: IQ4 and IQ3 vs ref on the CPU backend (quantisation only), then a short GPU row
#   summary <log>   print the statistics block of a child log
set -u
D=${KL_RUN_DIR:-bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05}
CORPUS_REV=${CORPUS_REV:-4166bc461d7d4c0c10bac574f543a2a6cb912157}
: "${W:?}" "${GSQ_BIN:?}"
PPL=$(dirname "$GSQ_BIN")/llama-perplexity
TOK=${TOK:-}
EVAL=$W/eval.txt
EVAL_BYTES=${EVAL_BYTES:-570000}
CTX=2048
THREADS=${THREADS:-28}
mkdir -p "$W"

need() {
    local v
    for v; do [ -n "${!v:-}" ] || { echo "$v is required" >&2; exit 7; }; done
}

# Other crews on the host defer CPU-heavy gates while this file exists and its pid is alive.
SIGNAL=${XDG_RUNTIME_DIR:-/tmp}/halo-gpu-bench.active
# 1 from just before any row's run.sh launches until the last row succeeds: run.sh may unload lemond at any point and
# die by a signal that skips its own reload, and restore_lemond is a no-op when the model is loaded.
offline=0
child=
armed=

# One job at a time: a second run.sh's EXIT trap would reload lemond under a running child.
busy() {
    if pgrep -x 'llama-perplexit|llama-server|llama-bench' >/dev/null ||
        pgrep -f '(^|/)(bash|python3?) +[^ -][^ ]*(run\.sh|probe\.py)( |$)' >/dev/null; then
        echo "another benchmark process is running; refusing" >&2
        exit 2
    fi
}

# Load lemond's model back if absent: a fit-check-only run.sh exits 0 through its reload() trap, which is a no-op when
# the model is loaded. Signals are ignored meanwhile (inherited by run.sh) so a kill cannot cut the reload short.
restore_lemond() {
    trap '' INT TERM HUP
    FIT_CHECK_ONLY=1 KEEP_OFFLINE=0 OUT=$W/rows.jsonl EXEC_DEV=cpu TARGET=${IQ4:-${REF:-}} EXEC_LOG=$W/restore.log \
        NEED_GIB=1 "$D/run.sh" exec -- true || { echo "lemond restore FAILED (exit $?)" >&2; return 1; }
    offline=0
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
    local rc=$?
    if [ "$offline" = 1 ]; then restore_lemond || rc=6; fi
    [ "$(head -n 1 -- "$SIGNAL" 2>/dev/null)" = "$$" ] && rm -f -- "$SIGNAL"
    exit "$rc"
}

# shellcheck disable=SC2329 # invoked by the signal traps
on_signal() {
    # the job table, not $child: a signal between `&` and `child=$!` must still reach the row
    # shellcheck disable=SC2046 # one word per pid
    kill -TERM $(jobs -p) 2>/dev/null
    while [ -n "$(jobs -pr)" ]; do wait; done
    exit "$1" # runs the EXIT trap
}
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap 'on_signal 130' INT

# exec <more|last> <dev> <target> <need_gib> <log> <child args...>: KEEP_OFFLINE=1 unless last.
exec_row() {
    local pos=$1 dev=$2 target=$3 need=$4 log=$5 keep=1 rc
    shift 5
    # a rerun after a failed or killed run skips the rows that finished
    if [ -e "$log.ok" ]; then
        echo "skip: $(basename "$log") already complete" >&2
        if [ "$pos" = last ] && [ "$offline" = 1 ]; then restore_lemond || exit 6; fi
        return
    fi
    [ "$pos" = last ] && keep=0
    printf '%s\n%s\n' "$$" "$(basename "$log" .log)" >"$SIGNAL"
    [ -n "$armed" ] || { trap on_exit EXIT; armed=1; }
    offline=1
    # in the background so a signal reaches the handler instead of waiting out run.sh
    KEEP_OFFLINE=$keep OUT=$W/rows.jsonl EXEC_DEV=$dev TARGET=$target EXEC_LOG=$log NEED_GIB=$need \
        EXEC_SWAP_LIMIT_GIB="${EXEC_SWAP_LIMIT_GIB:-24}" \
        "$D/run.sh" exec --label "$(basename "$log" .log)" -- "$@" &
    child=$!
    while :; do
        wait "$child"
        rc=$?
        kill -0 "$child" 2>/dev/null || break
    done
    child=
    [ "$rc" = 0 ] || { echo "ROW FAILED: $log (exit $rc)" >&2; exit 1; }
    touch "$log.ok"
    if [ "$pos" = last ]; then offline=0; fi
}

# Child argv. GPU: the candidate config (GSQHalo, f16 KV, fa on, direct lazy loading). CPU: mmap'd weights stay
# file-backed (--no-repack), the n-gram table is read on demand.
gpu_args() { # model chunks [kl flags...]
    local model=$1 chunks=$2
    shift 2
    echo "$PPL" -m "$model" -f "$EVAL" -c $CTX -b $CTX -ub $CTX --chunks "$chunks" -ngl 99 -fa on -ctk f16 -ctv f16 -lzm on-direct "$@"
}
cpu_args() {
    local model=$1 chunks=$2
    shift 2
    echo nice -n 10 "$PPL" -m "$model" -f "$EVAL" -c $CTX -b $CTX -ub $CTX --chunks "$chunks" -ngl 0 -dev none --no-repack -lzm on -t "$THREADS" "$@"
}

case ${1:-} in
evaltext)
    need CORPUS_REV
    git cat-file -e "$CORPUS_REV^{commit}" || exit 7
    : >"$EVAL.tmp"
    # hash-ordered so docs, Nix, shell and Go interleave instead of one file type filling the budget
    git ls-tree -r --name-only "$CORPUS_REV" | grep -E '\.(md|go|sh|nix|py|patch|yml)$' |
        while read -r f; do printf '%s %s\n' "$(printf %s "$f" | sha256sum | cut -c1-16)" "$f"; done | sort |
        while read -r _ f; do
            [ "$(stat -c %s "$EVAL.tmp")" -ge "$EVAL_BYTES" ] && break
            {
                printf '=== %s ===\n' "$f"
                git cat-file blob "$CORPUS_REV:$f"
                printf '\n\n'
            } >>"$EVAL.tmp"
        done
    mv "$EVAL.tmp" "$EVAL"
    need IQ4 TOK
    echo "eval.txt: $(stat -c %s "$EVAL") bytes, sha256 $(sha256sum "$EVAL" | cut -d' ' -f1), rev $CORPUS_REV"
    "$TOK" -m "$IQ4" --ids --log-disable --stdin <"$EVAL" | python3 -c 'import ast, sys; print("tokens:", len(ast.literal_eval(sys.stdin.read().strip())))'
    ;;
ref-cpu)
    need REF CHUNKS
    busy
    # 24 GiB anonymous budget; weights stay in the page cache
    # shellcheck disable=SC2046,SC2153 # the argv builders emit words; CHUNKS is the env contract
    exec_row last cpu "$REF" "${NEED_GIB:-24}" "$W/ref-cpu.log" $(cpu_args "$REF" "$CHUNKS" --kl-divergence-base "$W/ref.logits")
    ;;
candidates)
    need IQ4 IQ3 CHUNKS
    busy
    [ -f "$W/ref.logits" ] || { echo "$W/ref.logits missing: run ref-cpu first" >&2; exit 7; }
    # A GPU row ends the window: lemond's reload straight after a long CPU pass over a model file once hung the GPU.
    # shellcheck disable=SC2046
    {
        exec_row more gpu "$IQ4" 85 "$W/iq4-vs-ref.log" $(gpu_args "$IQ4" "$CHUNKS" --kl-divergence --kl-divergence-base "$W/ref.logits")
        exec_row more gpu "$IQ3" 85 "$W/iq3-vs-ref.log" $(gpu_args "$IQ3" "$CHUNKS" --kl-divergence --kl-divergence-base "$W/ref.logits")
        exec_row more gpu "$IQ4" 85 "$W/iq4-save.log" $(gpu_args "$IQ4" "$CHUNKS" --kl-divergence-base "$W/iq4.logits")
        exec_row more gpu "$IQ3" 85 "$W/iq3-vs-iq4.log" $(gpu_args "$IQ3" "$CHUNKS" --kl-divergence --kl-divergence-base "$W/iq4.logits")
        exec_row more cpu "$IQ4" 24 "$W/iq4-cpu4.log" $(cpu_args "$IQ4" 4 --kl-divergence-base "$W/iq4-cpu4.logits")
        exec_row last gpu "$IQ4" 85 "$W/iq4-gpu-vs-cpu4.log" $(gpu_args "$IQ4" 4 --kl-divergence --kl-divergence-base "$W/iq4-cpu4.logits")
    }
    ;;
cpu-candidates)
    need IQ4 IQ3 CHUNKS
    busy
    [ -f "$W/ref.logits" ] || { echo "$W/ref.logits missing: run ref-cpu first" >&2; exit 7; }
    # Same backend as the reference, so the KL is the quantisation alone. The last row is a short GPU run for the same reason.
    # shellcheck disable=SC2046
    {
        exec_row more cpu "$IQ4" 24 "$W/iq4-cpu-vs-ref.log" $(cpu_args "$IQ4" "$CHUNKS" --kl-divergence --kl-divergence-base "$W/ref.logits")
        exec_row more cpu "$IQ3" 24 "$W/iq3-cpu-vs-ref.log" $(cpu_args "$IQ3" "$CHUNKS" --kl-divergence --kl-divergence-base "$W/ref.logits")
        exec_row last gpu "$IQ3" 85 "$W/iq3-gpu-vs-cpu4.log" $(gpu_args "$IQ3" 4 --kl-divergence --kl-divergence-base "$W/iq4-cpu4.logits")
    }
    ;;
summary)
    grep -E -i "KL divergence|Mean PPL|Mean KLD|Median|Maximum KLD|99\.9|99\.0%|Same top p|RMS|Mean *Δp|Minimum KLD|Perplexity|Mean ln|buffer|CPU_REPACK" "${2:?log}" | grep -v -E "^\s*$" | cut -c1-200
    ;;
*)
    echo "usage: kl.sh evaltext|ref-cpu|candidates|cpu-candidates|summary <log>" >&2
    exit 7
    ;;
esac
