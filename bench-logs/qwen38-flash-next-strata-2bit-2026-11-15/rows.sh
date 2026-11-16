#!/usr/bin/env bash
# 2-bit Flash-Next quants on Strata (#352). From the repo root: rows.sh <base|q2_0|iq2_xs|ud_q2_0> <stage> [expert-cache]
# Candidates: base is the production UD-IQ4_XS-v31 (its pack already exists); the others are the 2-bit GGUFs under test.
# Stages:
#   pack    CPU-only iq_pack.py of the candidate's GGUF into $WORK/<cand>/pack, run niced; no GPU, lemond stays up. Not for base.
#   smoke   run.sh strata --quick at 8K context and expert cache 2048: does it load, tool call, prefill 4K, decode 512, vision
#   foot    run.sh strata at the default 128K config: tool call, prefill 4K, decode 512, with the footprint sampler. The optional
#           expert-cache argument (blob count) replaces 20000 for this row only
#   A       run.sh strata, the 2026-11-12 A stage: tool call, prefill 4K, decode 512, decode 32K, replay, vision
#   B       run.sh strata, the 2026-11-12 B stage: decode 128K
#   kl      one `kl_strata.py run --arm def --chunks 64` row against the Q8_0 reference through run.sh exec
# Each GPU stage is one gated run.sh row (#249) with KEEP_OFFLINE=0: lemond is unloaded for the row and restored after it.
# run.sh holds $XDG_RUNTIME_DIR/halo-gpu-bench.active for the row, so this wrapper writes no second copy.
# Before any stage it waits for the 1-minute loadavg to fall below 4 (cap 15 min; then the row runs and is flagged), and
# the GPU stages refuse (exit 2) while another bench's signal file is live. A row is judged by its start and end loadavg
# and the signal file, not by the peak: the engine's own threads push the 1-minute average over 4 during every row.
# Per GPU row: loadavg at start and end, the flag, the wait and the exit code go to $W/load.jsonl, together with the number
# of amdgpu fault lines (BO_VA, -12, ring timeout) that `journalctl -k` shows since the row started ("unreadable" when the
# journal cannot be read). Any hit prints AMDGPU WEDGE SUSPECTED and exits 9: stop and do not reboot. footprint.py runs
# beside the row (descendants of this script only, so lemond's resident engine is not counted) and writes
# $W/foot-<label>.json plus the raw series $W/foot-<label>.raw.jsonl.
# Exit: the row's own status, 2 another bench is live, 7 usage or configuration error (before anything is touched), 9 wedge.
# Env (all required): WORK (parent work dir; each candidate gets $WORK/<cand>), CACHE (corpus cache.json), PY (python with
# numpy regex jinja2 pyyaml requests psutil pillow tqdm), STRATA_OUT (the `nix build .#strata` out-link: share/strata,
# bin/strata, bin/strata-vision), MTP_RT (the one shared MTP runtime), MMPROJ, REF (Q8_0 reference logits), BASE_PACK and
# BASE_SHARD (the v31 pack dir and its shard 1). Plus the shard 1 path of the candidate being run: Q2_0_SHARD,
# IQ2_XS_SHARD or UD_Q2_0_SHARD. Optional: LEMOND_MODEL (default Qwen3.8-Flash-Next-Strata), GGUF_PY (the ggml gguf-py dir
# for the pack stage; default from `nix eval .#strata.ggml`).
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
Q=bench-logs/qwen38-flash-next-strata-quality-2026-10-07
B=bench-logs/qwen38-flash-next-strata-2bit-2026-11-15

usage() { echo "usage: rows.sh <base|q2_0|iq2_xs|ud_q2_0> <pack|smoke|foot|A|B|kl> [expert-cache (foot only)]" >&2; exit 7; }
die() { echo "rows.sh: $*" >&2; exit 7; }

cand=${1:-} stage=${2:-} cache_arg=${3:-}
case $cand in
base | q2_0 | iq2_xs | ud_q2_0) ;;
*) usage ;;
esac
case $stage in
pack | smoke | foot | A | B | kl) ;;
*) usage ;;
esac
[ $# -le 3 ] || usage
if [ -n "$cache_arg" ]; then
    [ "$stage" = foot ] || die "the expert-cache argument is only for the foot stage"
    [[ $cache_arg =~ ^[1-9][0-9]*$ ]] || die "expert-cache must be a positive integer (blob count), got: $cache_arg"
fi
[ "$stage $cand" != "pack base" ] || die "base's pack already exists (BASE_PACK)"

for v in WORK CACHE PY STRATA_OUT MTP_RT MMPROJ REF BASE_PACK BASE_SHARD; do
    [ -n "${!v:-}" ] || die "$v is required"
done
case $cand in
base) IQ4=$BASE_SHARD PACK=$BASE_PACK ;;
q2_0) [ -n "${Q2_0_SHARD:-}" ] || die "Q2_0_SHARD is required"; IQ4=$Q2_0_SHARD PACK=$WORK/q2_0/pack ;;
iq2_xs) [ -n "${IQ2_XS_SHARD:-}" ] || die "IQ2_XS_SHARD is required"; IQ4=$IQ2_XS_SHARD PACK=$WORK/iq2_xs/pack ;;
ud_q2_0) [ -n "${UD_Q2_0_SHARD:-}" ] || die "UD_Q2_0_SHARD is required"; IQ4=$UD_Q2_0_SHARD PACK=$WORK/ud_q2_0/pack ;;
esac
W=$WORK/$cand
STRATA_REPO=$STRATA_OUT/share/strata STRATA_ENGINE=$STRATA_OUT/bin/strata STRATA_VISION_BIN=$STRATA_OUT/bin/strata-vision
[ -f "$IQ4" ] || die "candidate shard not found: $IQ4"
[ -f "$STRATA_REPO/tools/iq_pack.py" ] && [ -x "$STRATA_ENGINE" ] || die "STRATA_OUT is not a built strata package"
if [ "$stage" = pack ]; then
    [ ! -e "$PACK" ] || die "$PACK already exists; move it away to rebuild"
else
    [ -d "$PACK" ] || die "no pack at $PACK; run the pack stage first"
fi

export OUT=$W/rows.jsonl CACHE CORPUS_REV=4166bc461d7d4c0c10bac574f543a2a6cb912157
export STRATA_PY=$PY STRATA_PACK=$PACK STRATA_MTP_RT=$MTP_RT STRATA_MMPROJ=$MMPROJ
export STRATA_REPO STRATA_ENGINE STRATA_VISION_BIN IQ4
# run.sh defaults to another model name and refuses (exit 6) when the resident is a different one
export LEMOND_MODEL=${LEMOND_MODEL:-Qwen3.8-Flash-Next-Strata}
# set per stage, always explicitly: kl_strata.py reads the same variable, so a lever row's value must never leak
export STRATA_CTX=131072 STRATA_EXPERT_CACHE=20000
unset EXTRA_ARGS
mkdir -p "$W"

SIGNAL_FILE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halo-gpu-bench.active
load1() { cut -d' ' -f1 /proc/loadavg; }

sampler='' pack_tmp=''
stop_sampler() {
    [ -n "$sampler" ] || return 0
    kill "$sampler" 2>/dev/null
    # a trapped signal ends a bare `wait` early, while the sampler is still writing its summary
    while kill -0 "$sampler" 2>/dev/null; do wait "$sampler" 2>/dev/null; done
    sampler=
}
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    stop_sampler
    [ -z "$pack_tmp" ] || rm -rf "$pack_tmp"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

flag=ok
waited=0
while [ "$(load1 | cut -d. -f1)" -ge 4 ] && [ "$waited" -lt 900 ]; do
    sleep 10
    waited=$((waited + 10))
done
[ "$(load1 | cut -d. -f1)" -lt 4 ] || flag=load_above_4_at_start

if [ "$stage" = pack ]; then
    [ "$flag" = ok ] || echo "warning: loadavg still above 4 after ${waited}s; packing anyway" >&2
    gguf_py=${GGUF_PY:-}
    [ -n "$gguf_py" ] || gguf_py=$(nix eval --raw .#strata.ggml.outPath)/gguf-py || die "cannot resolve gguf-py; set GGUF_PY"
    # built beside the final dir and moved into place, so a failed or interrupted run leaves no half-written pack
    pack_tmp=$W/pack.tmp
    rm -rf "$pack_tmp"
    nice -n 19 ionice -c3 env STRATA_GGUF_PY="$gguf_py" "$PY" "$STRATA_REPO/tools/iq_pack.py" --gguf "$IQ4" --out "$pack_tmp" --compat-bf16 || exit $?
    mv "$pack_tmp" "$PACK" || exit $?
    pack_tmp=
    exit 0
fi

holder=$(sed -n 1p "$SIGNAL_FILE" 2>/dev/null)
[ -z "$holder" ] || [ ! -d "/proc/$holder" ] || { echo "another bench holds $SIGNAL_FILE (pid $holder)" >&2; exit 2; }

case $stage in
smoke) label=$cand-smoke STRATA_CTX=8192 STRATA_EXPERT_CACHE=2048 ;;
foot) label=$cand-foot${cache_arg:-20000} STRATA_EXPERT_CACHE=${cache_arg:-20000} ;;
A) label=$cand-def-A ;;
B) label=$cand-def-B ;;
kl) label=$cand-kl-def-64 ;;
esac
export STRATA_CTX STRATA_EXPERT_CACHE

if [ "$stage" = kl ]; then
    # Not the quality rows.sh: its start-up check refuses while lemond's resident `strata` engine is up. This keeps its
    # refusal for another benchmark of ours, matched by script name on a bash/python argv[1], never by `strata`.
    mapfile -t busy < <(
        pgrep -f '(^|/)(bash|python3?) +[^ -][^ ]*(run\.sh|probe\.py|kl_strata\.py)( |$)'
        pgrep -x 'llama-perplexit|llama-bench'
    )
    for pid in "${busy[@]}"; do
        [ "$pid" != "$$" ] || continue
        echo "another benchmark process is running (pid $pid); refusing" >&2
        exit 2
    done
    # the run dir is the row's output; a rerun starts it over
    rm -rf "${W:?}/kl/kl-def-64"
    mkdir -p "$W/kl"
fi

# From here a signal must not skip the wedge check below: an interrupted row is the one most likely to have wedged the GPU.
# run.sh restores lemond itself on a signal; this wrapper only records it and carries on to the kernel-log check.
sig_rc=''
trap 'sig_rc=143' TERM
trap 'sig_rc=130' INT

# the job's descendants only: the sampler never sees lemond's resident engine
python3 "$B/footprint.py" watch --root-pid $$ --out "$W/foot-$label.json" --raw "$W/foot-$label.raw.jsonl" &
sampler=$!

row_start=$(date '+%Y-%m-%d %H:%M:%S')
start=$(load1)
[ -z "$sig_rc" ] || exit "$sig_rc" # signalled before any GPU work began: nothing to check
case $stage in
smoke) KEEP_OFFLINE=0 "$D/run.sh" strata --label "$label" --quick --do toolcall,prefill4k,decode512,vision ;;
foot) KEEP_OFFLINE=0 "$D/run.sh" strata --label "$label" --do toolcall,prefill4k,decode512 ;;
A) KEEP_OFFLINE=0 "$D/run.sh" strata --label "$label" --do toolcall,prefill4k,decode512,decode32k,replay,vision ;;
B) KEEP_OFFLINE=0 "$D/run.sh" strata --label "$label" --do decode128k ;;
kl)
    KEEP_OFFLINE=0 EXEC_DEV=gpu TARGET=$IQ4 EXEC_LOG=$W/kl-def-64.log NEED_GIB=95 \
        "$D/run.sh" exec --label kl-def-64 -- "$PY" "$Q/kl_strata.py" run --arm def --ref "$REF" --target "$IQ4" \
        --chunks 64 --out "$W/kl/kl-def-64"
    ;;
esac
rc=$?
[ -z "$sig_rc" ] || rc=$sig_rc
end=$(load1)
stop_sampler
[ -s "$W/foot-$label.json" ] || echo "warning: no footprint summary for $label" >&2

hits=unreadable
if out=$(journalctl -k --since "$row_start" --no-pager 2>&1); then
    case $out in
    *"insufficient permissions"* | *"No journal files"*) ;;
    *) hits=$(printf '%s\n' "$out" | grep -cE 'BO_VA|amdgpu.*-12|ring .* timeout') ;;
    esac
fi
[ "$hits" != unreadable ] || echo "warning: kernel log unreadable; amdgpu wedge check skipped for $label" >&2
hits_json=$hits
[[ $hits =~ ^[0-9]+$ ]] || hits_json=\"$hits\"
[ -z "$sig_rc" ] || rc=$sig_rc # a signal during the checks above still ends the script non-zero
printf '{"label":"%s","started":"%s","rc":%s,"flag":"%s","wait_s":%s,"loadavg_start":%s,"loadavg_end":%s,"kernel_hits":%s}\n' \
    "$label" "$row_start" "$rc" "$flag" "$waited" "$start" "$end" "$hits_json" >>"$W/load.jsonl"
if [[ $hits =~ ^[0-9]+$ ]] && [ "$hits" -gt 0 ]; then
    echo "AMDGPU WEDGE SUSPECTED: $hits kernel log lines since $row_start (row $label, exit $rc). Stop; do not reboot." >&2
    exit 9
fi
exit "$rc"
