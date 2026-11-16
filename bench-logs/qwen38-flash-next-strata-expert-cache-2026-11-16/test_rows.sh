#!/usr/bin/env bash
# rows.sh (#352, expert-cache sweep #354) argument handling and resolved row config, through its ROWS_DRY_RUN seam, plus
# the probe.py options the sweep needs. Never starts an engine: every rows.sh call is a dry run or a usage error that
# exits before anything is touched, with an unreachable LEMOND and stub paths as a second line of defence.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../.." || exit 1
rows_sh=bench-logs/qwen38-flash-next-strata-2bit-2026-11-15/rows.sh
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
probe=$D/probe.py

# fail closed: an rows.sh without the seam would run the row for real
grep -q ROWS_DRY_RUN "$rows_sh" || { echo "no dry-run seam in $rows_sh" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/pack" "$T/strata/share/strata/tools" "$T/strata/bin" "$T/work/base/kl/kl-def-64"
: >"$T/cache.json" && : >"$T/py" && : >"$T/mtp" && : >"$T/mmproj" && : >"$T/ref" && : >"$T/shard"
: >"$T/strata/share/strata/tools/iq_pack.py"
: >"$T/strata/bin/strata" && chmod +x "$T/strata/bin/strata"
: >"$T/strata/bin/strata-vision" && chmod +x "$T/strata/bin/strata-vision"
: >"$T/work/base/kl/kl-def-64/sentinel"
mkdir -p "$T/work/q2_0/pack"

export LEMOND=http://127.0.0.1:9/api/v1 XDG_RUNTIME_DIR=$T/run
export WORK=$T/work CACHE=$T/cache.json PY=$T/py STRATA_OUT=$T/strata MTP_RT=$T/mtp MMPROJ=$T/mmproj REF=$T/ref
export BASE_PACK=$T/pack BASE_SHARD=$T/shard Q2_0_SHARD=$T/shard

fail=0
total=0
rc=0
rows() { ROWS_DRY_RUN=1 timeout 20 bash "$rows_sh" "$@" >"$T/out" 2>"$T/err"; rc=$?; }
report() { # <name> <ok 0/1>
    total=$((total + 1))
    [ "$2" = 0 ] && return
    fail=$((fail + 1))
    echo "FAIL: $1 (rc=$rc)" >&2
    sed 's/^/  out| /' "$T/out" >&2
    sed 's/^/  err| /' "$T/err" >&2
}
ok_case() { # <name> <args as one word list> <expected line>...
    local name=$1 line good=0
    # shellcheck disable=SC2086 # the argument string is a word list
    rows $2
    shift 2
    [ "$rc" = 0 ] || good=1
    for line; do grep -qxF -- "$line" "$T/out" || { good=1; echo "  missing: $line" >&2; }; done
    report "$name" "$good"
}
argv_has() { grep '^argv=' "$T/out" | grep -qF -- "$1"; }
bad_case() { # <name> <args as one word list> <message substring>
    local name=$1 good=0
    # shellcheck disable=SC2086
    rows $2
    [ "$rc" = 7 ] || good=1
    grep -qF -- "$3" "$T/err" || good=1
    report "$name" "$good"
}

o=$T/work/base/rows.jsonl
rs=$D/run.sh
foot_do=toolcall,prefill4k,decode512
a_do=toolcall,prefill4k,decode512,decode32k,replay,vision
klv() { echo "$T/work/base/kl/kl-def-64$1"; }
kl_argv() { # <suffix>
    echo "argv=$rs exec --label kl-def-64$1 -- $T/py bench-logs/qwen38-flash-next-strata-quality-2026-10-07/kl_strata.py run --arm def --ref $T/ref --target $T/shard --chunks 64 --out $(klv "$1")"
}
kl_env() { echo "env=KEEP_OFFLINE=0 EXEC_DEV=gpu TARGET=$T/shard EXEC_LOG=$T/work/base/kl-def-64$1.log NEED_GIB=95"; }

# defaults: byte-identical to the unmodified script
ok_case "foot default" "base foot" label=base-foot20000 STRATA_EXPERT_CACHE=20000 STRATA_CTX=131072 "OUT=$o" \
    env=KEEP_OFFLINE=0 "argv=$rs strata --label base-foot20000 --do $foot_do"
ok_case "A default" "base A" label=base-def-A STRATA_EXPERT_CACHE=20000 STRATA_CTX=131072 "OUT=$o" \
    env=KEEP_OFFLINE=0 "argv=$rs strata --label base-def-A --do $a_do"
ok_case "B default" "base B" label=base-def-B STRATA_EXPERT_CACHE=20000 STRATA_CTX=131072 "OUT=$o" \
    env=KEEP_OFFLINE=0 "argv=$rs strata --label base-def-B --do decode128k"
ok_case "kl default" "base kl" label=base-kl-def-64 STRATA_EXPERT_CACHE=20000 STRATA_CTX=131072 "OUT=$o" \
    "kl_dir=$(klv "")" "EXEC_LOG=$T/work/base/kl-def-64.log" "$(kl_env "")" "$(kl_argv "")"
ok_case "A 20000 same as default" "base A 20000" label=base-def-A STRATA_EXPERT_CACHE=20000 \
    "argv=$rs strata --label base-def-A --do $a_do"
ok_case "kl 20000 same as default" "base kl 20000" label=base-kl-def-64 "kl_dir=$(klv "")" "$(kl_argv "")"
ok_case "smoke unchanged" "base smoke" label=base-smoke STRATA_EXPERT_CACHE=2048 STRATA_CTX=8192 env=KEEP_OFFLINE=0 \
    "argv=$rs strata --label base-smoke --quick --do toolcall,prefill4k,decode512,vision"

# explicit sizes
ok_case "foot 5000" "base foot 5000" label=base-foot5000 STRATA_EXPERT_CACHE=5000 STRATA_CTX=131072 env=KEEP_OFFLINE=0 \
    "argv=$rs strata --label base-foot5000 --do $foot_do"
ok_case "A 5000" "base A 5000" label=base-def-A-c5000 STRATA_EXPERT_CACHE=5000 STRATA_CTX=131072 env=KEEP_OFFLINE=0 \
    "argv=$rs strata --label base-def-A-c5000 --do $a_do"
ok_case "B 10000" "base B 10000" label=base-def-B-c10000 STRATA_EXPERT_CACHE=10000 STRATA_CTX=131072 env=KEEP_OFFLINE=0 \
    "argv=$rs strata --label base-def-B-c10000 --do decode128k"
ok_case "kl 10000" "base kl 10000" label=base-kl-def-64-c10000 STRATA_EXPERT_CACHE=10000 \
    "kl_dir=$(klv -c10000)" "EXEC_LOG=$T/work/base/kl-def-64-c10000.log" "$(kl_env -c10000)" "$(kl_argv -c10000)"
ok_case "kl 5000" "base kl 5000" label=base-kl-def-64-c5000 STRATA_EXPERT_CACHE=5000 \
    "kl_dir=$(klv -c5000)" "EXEC_LOG=$T/work/base/kl-def-64-c5000.log" "$(kl_env -c5000)" "$(kl_argv -c5000)"
[ -e "$(klv "")/sentinel" ]
report "dry run left the 20000 kl dir alone" $?

# reload
ok_case "reload 5000 cold" "base reload 5000 cold" label=base-reload5000-cold STRATA_EXPERT_CACHE=5000 STRATA_CTX=131072 \
    "OUT=$o" env=KEEP_OFFLINE=0 "argv=$rs strata --label base-reload5000-cold --do firsttoken --evict-before"
ok_case "reload 5000 warm" "base reload 5000 warm" label=base-reload5000-warm STRATA_EXPERT_CACHE=5000 \
    env=KEEP_OFFLINE=0 "argv=$rs strata --label base-reload5000-warm --do firsttoken"
argv_has --evict-before
report "reload warm has no --evict-before" $((!$? ))
ok_case "reload 20000 warm" "base reload 20000 warm" label=base-reload20000-warm STRATA_EXPERT_CACHE=20000 \
    env=KEEP_OFFLINE=0 "argv=$rs strata --label base-reload20000-warm --do firsttoken"
argv_has --evict-before
report "reload 20000 warm has no --evict-before" $((!$? ))
# #352's reproduce block runs "foot 20000" for every candidate
ok_case "foot cache on a non-base candidate" "q2_0 foot 20000" label=q2_0-foot20000 STRATA_EXPERT_CACHE=20000

# usage errors: exit 7 before anything is touched
bad_case "non-integer cache" "base foot abc" "positive integer"
bad_case "zero cache" "base A 0" "positive integer"
bad_case "negative cache" "base B -5" "positive integer"
bad_case "cache on pack" "q2_0 pack 5000" "expert-cache"
bad_case "cache on smoke" "base smoke 5000" "expert-cache"
bad_case "cache with non-base candidate" "q2_0 A 5000" "base"
bad_case "reload without cache" "base reload" "reload"
bad_case "reload without cold|warm" "base reload 5000" "cold|warm"
bad_case "reload tepid" "base reload 5000 tepid" "cold|warm"
bad_case "reload non-base" "q2_0 reload 5000 cold" "base"
bad_case "reload non-integer cache" "base reload x cold" "positive integer"
bad_case "fifth argument" "base reload 5000 cold extra" "usage"
bad_case "temperature on A" "base A 5000 cold" "usage"

# probe.py: the group and the option exist (never run with a full argv: it would start an engine)
grep -qE '^GROUPS = .*"firsttoken"' "$probe"
report "firsttoken in GROUPS" $?
grep -q 'if "firsttoken" in do:' "$probe"
report "firsttoken dispatched" $?
grep -q -- '"--evict-before"' "$probe"
report "--evict-before registered" $?
timeout 20 python3 "$probe" strata --help >"$T/out" 2>"$T/err"
rc=$?
[ "$rc" = 0 ] && grep -q -- '--evict-before' "$T/out"
report "strata --help lists --evict-before" $?

echo "$((total - fail))/$total passed"
exit $((fail > 0))
