#!/usr/bin/env bash
# Old-vs-new Strata pin rows (#347). From the repo root: rows.sh <old|new> <smoke|A|B>
# Each call is one gated run.sh row (#249): lemond is unloaded for the row and restored after it. run.sh itself holds
# $XDG_RUNTIME_DIR/halo-gpu-bench.active for the row, so this wrapper writes no second copy.
# Before the row it waits for the 1-minute loadavg to fall below 4 (cap 15 min; then the row runs and is flagged), and
# refuses (exit 2) while another bench's signal file is live. Loadavg at start and end goes to $W/load.jsonl. Strata's own threads
# push the load far above 4 during a row (#257), so a row is judged by its start and end load, not by the peak.
# Env: PIN_OLD / PIN_NEW (the two `nix build .#strata` out-links), W (work dir), CACHE (corpus cache), PY (python with the
# server's deps), PACK, MTP_RT, MMPROJ (the v31 pack, MTP runtime and projector, shared by both pins: the pack tools
# are identical between c3b3f50 and v0.2.13).
set -u
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
pin=${1:?old|new} stage=${2:?smoke|A|B}
case $pin in
old) R=${PIN_OLD:?} ;;
new) R=${PIN_NEW:?} ;;
*) echo "pin must be old or new" >&2; exit 7 ;;
esac
case $stage in
smoke | A | B) ;;
*) echo "stage must be smoke, A or B" >&2; exit 7 ;;
esac
W=${W:?}
export OUT=$W/rows.jsonl CACHE=${CACHE:?} CORPUS_REV=4166bc461d7d4c0c10bac574f543a2a6cb912157
export STRATA_PY=${PY:?} STRATA_REPO=$R/share/strata STRATA_ENGINE=$R/bin/strata STRATA_VISION_BIN=$R/bin/strata-vision
export STRATA_PACK=${PACK:?} STRATA_MTP_RT=${MTP_RT:?} STRATA_MMPROJ=${MMPROJ:?}
export LEMOND_MODEL=${LEMOND_MODEL:-Qwen3.8-Flash-Next-Strata}
export STRATA_EXPERT_CACHE=20000 STRATA_CTX=131072
unset EXTRA_ARGS
# the v31 shard the pack was built from (run.sh defaults to the September file)
export IQ4=${IQ4:-${MODELS:-/var/lib/models}/hf/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/d96201194f103c906994f283f504209dc8d2a10c/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00004.gguf}

SIGNAL_FILE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halo-gpu-bench.active
load1() { cut -d' ' -f1 /proc/loadavg; }

flag=ok
waited=0
while [ "$(load1 | cut -d. -f1)" -ge 4 ] && [ "$waited" -lt 900 ]; do
    sleep 10
    waited=$((waited + 10))
done
[ "$(load1 | cut -d. -f1)" -lt 4 ] || flag=load_above_4_at_start
holder=$(sed -n 1p "$SIGNAL_FILE" 2>/dev/null)
[ -z "$holder" ] || [ ! -d "/proc/$holder" ] || { echo "another bench holds $SIGNAL_FILE (pid $holder)" >&2; exit 2; }

start=$(load1)
case $stage in
smoke)
    label=$pin-smoke
    STRATA_CTX=8192 STRATA_EXPERT_CACHE=2048 KEEP_OFFLINE=0 "$D/run.sh" strata --label "$label" --quick --do toolcall,prefill4k,decode512,vision
    ;;
A)
    label=$pin-def-A
    KEEP_OFFLINE=0 "$D/run.sh" strata --label "$label" --do toolcall,prefill4k,decode512,decode32k,replay,vision
    ;;
B)
    label=$pin-def-B
    KEEP_OFFLINE=0 "$D/run.sh" strata --label "$label" --do decode128k
    ;;
*) echo "stage must be smoke, A or B" >&2; exit 7 ;;
esac
rc=$?
printf '{"label":"%s","rc":%s,"flag":"%s","wait_s":%s,"loadavg_start":%s,"loadavg_end":%s}\n' \
    "$label" "$rc" "$flag" "$waited" "$start" "$(load1)" >>"$W/load.jsonl"
exit "$rc"
