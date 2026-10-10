#!/usr/bin/env bash
# run.sh refuses, without contacting lemond, while another live bench holds the GPU signal file; a stale file is ignored.
# shellcheck disable=SC2016 # check() evals its single-quoted condition
set -u
d=$(mktemp -d)
holder=
trap '[ -z "$holder" ] || kill "$holder" 2>/dev/null; rm -rf "$d"' EXIT
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$d/bin" "$d/run"
# stub curl: record the request, fail like an unreachable lemond
cat >"$d/bin/curl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
exit 22
S
chmod +x "$d/bin/curl"
export STUB_LOG=$d/curl.log XDG_RUNTIME_DIR=$d/run PATH=$d/bin:$PATH LEMOND=http://127.0.0.1:1/api/v1
sig=$d/run/halo-gpu-bench.active
fail=0
run() { # <label> <env assignments...> -- <run.sh args...>; sets rc
    local env=()
    while [ "$1" != -- ]; do env+=("$1"); shift; done
    shift
    : >"$STUB_LOG"
    env -u OUT -u CACHE -u CORPUS_REV -u KEEP_OFFLINE -u FIT_CHECK_ONLY "${env[@]}" bash "$here/run.sh" "$@" >"$d/out" 2>&1
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
exit $fail
