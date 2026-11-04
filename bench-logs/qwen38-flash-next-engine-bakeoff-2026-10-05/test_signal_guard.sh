#!/usr/bin/env bash
# run.sh refuses, without contacting lemond, while another live bench holds the GPU signal file; a stale file is ignored.
# shellcheck disable=SC2016 # check() evals its single-quoted condition
set -u
d=$(mktemp -d)
holder=
trap '[ -z "$holder" ] || kill "$holder" 2>/dev/null; rm -rf "$d"' EXIT
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$d/bin" "$d/run"
# stub curl: record the request, fail like an unreachable lemond unless STUB_OK=1
cat >"$d/bin/curl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
url=
for a; do case $a in http*) url=$a ;; esac; done
if [ "${STUB_OK:-0}" != 1 ]; then exit 22; fi
if [ -n "${STUB_RACE_PID:-}" ] && [ "$(wc -l <"$STUB_LOG")" -le 1 ]; then
    printf '%s\n%s\n' "$STUB_RACE_PID" "racing row" >"$STUB_RACE_FILE"
fi
case $url in
*/health)
    if [ "$(cat "$STUB_STATE" 2>/dev/null)" = loaded ]; then
        printf '{"all_models_loaded":[{"model_name":"%s"}]}\n' "$STUB_MODEL"
    else
        printf '{"all_models_loaded":[]}\n'
    fi
    ;;
*/unload) printf 'empty\n' >"$STUB_STATE" ;;
*/load) printf 'loaded\n' >"$STUB_STATE" ;;
esac
exit 0
S
chmod +x "$d/bin/curl"
# stub python3: the row never runs the real probe.py
cat >"$d/bin/python3" <<'S'
#!/usr/bin/env bash
exit 0
S
chmod +x "$d/bin/python3"
export STUB_LOG=$d/curl.log STUB_STATE=$d/state STUB_MODEL=Qwen3.8-Flash-Next-MTP XDG_RUNTIME_DIR=$d/run PATH=$d/bin:$PATH LEMOND=http://127.0.0.1:1/api/v1
sig=$d/run/halo-gpu-bench.active
fail=0
run() { # <label> <env assignments...> -- <run.sh args...>; sets rc
    local env=()
    while [ "$1" != -- ]; do env+=("$1"); shift; done
    shift
    : >"$STUB_LOG"
    env -u OUT -u CACHE -u CORPUS_REV -u KEEP_OFFLINE -u FIT_CHECK_ONLY -u STUB_OK -u STUB_RACE_PID -u STUB_RACE_FILE "${env[@]}" bash "$here/run.sh" "$@" >"$d/out" 2>&1
    rc=$?
}
check() { # <desc> <ok?>
    if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1 (rc=$rc)" >&2; sed 's/^/  | /' "$d/out" >&2; fail=1; fi
}

sleep 300 &
holder=$!
printf '%s\n%s\n' "$holder" "other-bench row" >"$sig"
cases=(
    "bad preset|OUT=$d/o CACHE=$d/c CORPUS_REV=x|nonesuch"
    "missing env|X=1|corpus"
    "no args|X=1|"
    "fit check only|OUT=$d/o CACHE=$d/c CORPUS_REV=x FIT_CHECK_ONLY=1|corpus"
    "real row|OUT=$d/o CACHE=$d/c CORPUS_REV=x|corpus"
    "exec|OUT=$d/o TARGET=t EXEC_DEV=cpu EXEC_LOG=$d/l|exec"
)
for c in "${cases[@]}"; do
    IFS='|' read -r name envs arg <<<"$c"
    # shellcheck disable=SC2086 # envs and arg are word lists
    run $envs -- $arg
    check "held by live pid, $name: exit 2, lemond untouched" '[ $rc = 2 ] && [ ! -s "$STUB_LOG" ] && grep -q "other-bench row" "$d/out" && grep -q "pid $holder" "$d/out"'
    check "held by live pid, $name: signal file kept" '[ "$(sed -n 1p "$sig")" = "$holder" ]'
done

kill "$holder"
wait "$holder" 2>/dev/null
holder=
# stale pid: behaves as without the file, so the EXIT trap still asks lemond (stub: unreachable, exit 6)
printf '%s\n%s\n' 999999999 stale >"$sig"
run X=1 -- corpus
check "stale pid: proceeds to the usual config error path (lemond contacted by reload)" '[ $rc = 6 ] && grep -q /health "$STUB_LOG" && grep -q "OUT is required" "$d/out"'
printf 'garbage\n' >"$sig"
run X=1 -- corpus
check "unparsable pid: same as stale" '[ $rc = 6 ] && grep -q /health "$STUB_LOG"'
rm -f "$sig"
run X=1 -- corpus
check "no file: same as stale" '[ $rc = 6 ] && grep -q /health "$STUB_LOG"'

if ! compgen -G '/sys/class/drm/card*/device/mem_info_gtt_total' >/dev/null; then
    [ "$fail" = 0 ] || exit "$fail"
    echo "skip: no amdgpu card with mem_info_gtt_total; the claim cases need fit_check to pass" >&2
    exit 77
fi

# a live foreign holder wins the claim race: refuse without touching lemond
sleep 300 &
racer=$!
holder=$racer
echo loaded >"$d/state"
rm -f "$sig"
run STUB_OK=1 STUB_RACE_PID="$racer" STUB_RACE_FILE="$sig" OUT="$d/o" TARGET="$d/target" EXEC_DEV=cpu EXEC_LOG="$d/l" -- exec -- true
check "claim race: exit 2, lemond untouched" '[ $rc = 2 ] && ! grep -qE "/(un)?load" "$STUB_LOG"'
check "claim race: signal file still names the racer" '[ "$(sed -n 1p "$sig")" = "$racer" ]'
kill "$racer"
wait "$racer" 2>/dev/null
holder=

# stale holder at claim time: remove and retry once, then run the row
printf '%s\n%s\n' 999999999 stale >"$sig"
echo loaded >"$d/state"
run STUB_OK=1 OUT="$d/o" TARGET="$d/target" EXEC_DEV=cpu EXEC_LOG="$d/l" -- exec -- true
check "stale holder at claim: row runs and unloads lemond" '[ $rc = 0 ] && grep -q /unload "$STUB_LOG"'
check "stale holder at claim: signal file gone on exit" '[ ! -e "$sig" ]'
exit $fail
