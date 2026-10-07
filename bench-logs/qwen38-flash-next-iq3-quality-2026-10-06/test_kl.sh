#!/usr/bin/env bash
# Tests for kl.sh's lemond-offline window and signal-file handling, against a stub run.sh (KL_RUN_DIR). Touches no
# lemond, GPU or llama binary. Needs an idle host: kl.sh's busy() is exercised as is, not bypassed.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KL=$HERE/kl.sh

if pgrep -x 'llama-perplexit|llama-server|llama-bench' >/dev/null ||
    pgrep -f '(^|/)(bash|python3?) +[^ -][^ ]*(run\.sh|probe\.py)( |$)' >/dev/null; then
    echo "skip: another benchmark process is running (kl.sh would refuse)" >&2
    exit 77
fi

T=$(mktemp -d)
bgpids=()
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    local p
    for p in "${bgpids[@]}"; do kill -KILL "$p" 2>/dev/null; done
    pkill -KILL -f -- "$T/stub/" 2>/dev/null
    rm -rf -- "$T"
}
trap cleanup EXIT

mkdir -p "$T/stub" "$T/w" "$T/xdg" "$T/models"
# Records its env and argv; STUB_SLEEP_LABEL sleeps in that row (dying on TERM), STUB_FAIL_LABEL fails it,
# STUB_KILL_LABEL dies by SIGKILL in that row after logging "unloaded" (run.sh's reload trap cannot run), and
# STUB_FIT_RC is the exit code of the fit-check-only restore call.
cat >"$T/stub/run.sh" <<'EOF'
#!/usr/bin/env bash
label=
prev=
for a; do
    [ "$prev" = --label ] && label=$a
    prev=$a
done
echo "label=$label keep=${KEEP_OFFLINE:-} fit=${FIT_CHECK_ONLY:-} dev=${EXEC_DEV:-} argv=$*" >>"$STUB_LOG"
[ "${FIT_CHECK_ONLY:-0}" = 1 ] && exit "${STUB_FIT_RC:-0}"
if [ -n "$label" ] && [ "$label" = "${STUB_SLEEP_LABEL:-}" ]; then
    echo "$$" >"$STUB_PIDFILE"
    sleep 60 &
    sp=$!
    trap 'kill "$sp" 2>/dev/null; echo "term label=$label" >>"$STUB_LOG"; exit 143' TERM
    echo "sleeping label=$label" >>"$STUB_LOG"
    wait "$sp"
fi
if [ -n "$label" ] && [ "$label" = "${STUB_KILL_LABEL:-}" ]; then
    echo "unloaded label=$label" >>"$STUB_LOG"
    kill -KILL $$
fi
[ -n "$label" ] && [ "$label" = "${STUB_FAIL_LABEL:-}" ] && exit 1
exit 0
EOF
chmod +x "$T/stub/run.sh"
: >"$T/models/ref.gguf"
: >"$T/w/ref.logits"

export KL_RUN_DIR=$T/stub W=$T/w XDG_RUNTIME_DIR=$T/xdg STUB_LOG=$T/stub.log STUB_PIDFILE=$T/stub.pid
export GSQ_BIN=$T/bin/llama-server IQ4=$T/models/iq4.gguf IQ3=$T/models/iq3.gguf REF=$T/models/ref.gguf
export TOK=$T/bin/llama-tokenize CHUNKS=2
SIGNAL=$T/xdg/halo-gpu-bench.active
ROWS='iq4-vs-ref iq3-vs-ref iq4-save iq3-vs-iq4 iq4-cpu4 iq4-gpu-vs-cpu4'

fails=0
check() { # description, then a test command
    local d=$1
    shift
    if "$@"; then echo "ok   $d"; else echo "FAIL $d"; fails=$((fails + 1)); fi
}
labels() { sed -n 's/^label=\([^ ]\+\) .*/\1/p' "$STUB_LOG" | tr '\n' ' ' | sed 's/ $//'; }
keeps() { sed -n 's/^label=[^ ]\+ keep=\([^ ]*\) .*/\1/p' "$STUB_LOG" | tr '\n' ' ' | sed 's/ $//'; }
restores() { grep -c '^label= keep=0 fit=1 dev=cpu ' "$STUB_LOG"; }
reset() {
    rm -f -- "$T"/w/*.log "$T"/w/*.ok "$T/w/rows.jsonl" "$SIGNAL" "$STUB_LOG" "$STUB_PIDFILE"
    unset STUB_SLEEP_LABEL STUB_FAIL_LABEL STUB_KILL_LABEL STUB_FIT_RC
    : >"$STUB_LOG"
}
# shellcheck disable=SC2329 # run through check
wait_for() { # file pattern: up to ~10 s
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
# shellcheck disable=SC2329 # run through check
eq() { [ "$1" = "$2" ] || { echo "     got '$1', want '$2'" >&2; return 1; }; }

echo "== 1. normal run: rows in order, only the last reloads, no restore"
reset
nice -n 10 bash "$KL" candidates 2>/dev/null
check "exit 0" eq $? 0
check "rows in order" eq "$(labels)" "$ROWS"
check "only the last has KEEP_OFFLINE=0" eq "$(keeps)" "1 1 1 1 1 0"
check "no restore call" eq "$(restores)" 0
check "every row has an .ok marker" eq "$(find "$T/w" -name '*.log.ok' | wc -l)" 6
check "signal file removed" test ! -e "$SIGNAL"

echo "== 2. rerun with every marker: all skipped, nothing ran, no restore"
: >"$STUB_LOG"
nice -n 10 bash "$KL" candidates 2>/dev/null
check "exit 0" eq $? 0
check "stub never called" eq "$(wc -l <"$STUB_LOG")" 0
check "signal file never written" test ! -e "$SIGNAL"

echo "== 3. marker for the last row only: earlier rows run, restore once at the end"
reset
touch "$T/w/iq4-gpu-vs-cpu4.log.ok"
nice -n 10 bash "$KL" candidates 2>/dev/null
check "exit 0" eq $? 0
check "five rows ran" eq "$(labels)" "iq4-vs-ref iq3-vs-ref iq4-save iq3-vs-iq4 iq4-cpu4"
check "all five kept lemond offline" eq "$(keeps)" "1 1 1 1 1"
check "one restore call" eq "$(restores)" 1
check "restore is the last call" eq "$(tail -n 1 "$STUB_LOG" | cut -d' ' -f1-4)" "label= keep=0 fit=1 dev=cpu"

echo "== 4. SIGTERM during a more row: run.sh child dies, lemond is restored"
reset
STUB_SLEEP_LABEL=iq3-vs-ref nice -n 10 bash "$KL" candidates 2>/dev/null &
klpid=$!
bgpids+=("$klpid")
check "second row is running" wait_for "$STUB_LOG" 'sleeping label=iq3-vs-ref'
stubpid=$(cat "$STUB_PIDFILE" 2>/dev/null)
kill -TERM "$klpid"
wait "$klpid"
check "kl.sh exits 143" eq $? 143
check "stub run.sh terminated" bash -c "! kill -0 '$stubpid' 2>/dev/null"
check "stub saw the TERM" grep -q '^term label=iq3-vs-ref' "$STUB_LOG"
check "one restore call after it" eq "$(restores)" 1
check "restore follows the TERM" eq "$(tail -n 1 "$STUB_LOG" | cut -d' ' -f1-4)" "label= keep=0 fit=1 dev=cpu"
check "interrupted row has no marker" test ! -e "$T/w/iq3-vs-ref.log.ok"
check "finished row keeps its marker" test -e "$T/w/iq4-vs-ref.log.ok"
check "signal file removed (owned)" test ! -e "$SIGNAL"

echo "== 5. a failed row: no marker, exit 1, restore call (a no-op when run.sh already reloaded)"
reset
STUB_FAIL_LABEL=iq3-vs-ref nice -n 10 bash "$KL" candidates 2>/dev/null
check "exit 1" eq $? 1
check "no marker for the failed row" test ! -e "$T/w/iq3-vs-ref.log.ok"
check "the stage stopped there" eq "$(labels)" "iq4-vs-ref iq3-vs-ref"
check "lemond restored once" eq "$(restores)" 1

echo "== 5b. the first row's run.sh dies by SIGKILL after unloading lemond: kl.sh still restores"
reset
STUB_KILL_LABEL=iq4-vs-ref nice -n 10 bash "$KL" candidates 2>/dev/null
check "exit 1" eq $? 1
check "no marker for the killed row" test ! -e "$T/w/iq4-vs-ref.log.ok"
check "the stage stopped there" eq "$(labels)" "iq4-vs-ref"
check "lemond restored once" eq "$(restores)" 1
check "restore follows the kill" eq "$(tail -n 1 "$STUB_LOG" | cut -d' ' -f1-4)" "label= keep=0 fit=1 dev=cpu"

echo "== 5c. a failed restore after the last row was skipped as complete: exit 6"
reset
touch "$T/w/iq4-gpu-vs-cpu4.log.ok"
STUB_FIT_RC=6 nice -n 10 bash "$KL" candidates 2>/dev/null
check "exit 6" eq $? 6
check "five rows ran" eq "$(labels)" "iq4-vs-ref iq3-vs-ref iq4-save iq3-vs-iq4 iq4-cpu4"

echo "== 5d. a failed restore after TERM during a more row: exit 6, not 143"
reset
STUB_FIT_RC=6 STUB_SLEEP_LABEL=iq3-vs-ref nice -n 10 bash "$KL" candidates 2>/dev/null &
klpid=$!
bgpids+=("$klpid")
check "second row is running" wait_for "$STUB_LOG" 'sleeping label=iq3-vs-ref'
kill -TERM "$klpid"
wait "$klpid"
check "kl.sh exits 6" eq $? 6
check "restore was attempted" test "$(restores)" -ge 1

echo "== 6. summary and a busy-refused invocation leave a foreign signal file alone"
reset
printf '1\nforeign\n' >"$SIGNAL"
printf 'Mean KLD: 0.1\n' >"$T/child.log"
nice -n 10 bash "$KL" summary "$T/child.log" >/dev/null 2>&1
check "summary exit 0" eq $? 0
check "signal file survives summary" eq "$(head -n 1 "$SIGNAL")" 1
STUB_SLEEP_LABEL=iq4-vs-ref nice -n 10 bash "$KL" candidates 2>/dev/null &
klpid=$!
bgpids+=("$klpid")
check "first invocation is running" wait_for "$STUB_LOG" 'sleeping label=iq4-vs-ref'
printf '1\nforeign\n' >"$SIGNAL"
nice -n 10 bash "$KL" candidates 2>/dev/null
check "second invocation refused (exit 2)" eq $? 2
check "signal file survives the refusal" eq "$(head -n 1 "$SIGNAL")" 1
kill -TERM "$klpid"
wait "$klpid"
check "signal file survives the first invocation's exit" eq "$(head -n 1 "$SIGNAL")" 1

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; fi
exit $((fails > 0))
