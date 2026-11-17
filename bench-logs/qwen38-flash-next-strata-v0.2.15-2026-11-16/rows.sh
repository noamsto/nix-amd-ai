#!/usr/bin/env bash
# Old-vs-new Strata pin rows. From the repo root: rows.sh <old|new> <smoke|foot|A|B|kl>
# Runs the 2-bit bench's rows.sh for its `base` candidate (the production UD-IQ4_XS-v31 file and its existing pack) against
# one engine build: old = PIN_OLD (v0.2.13), new = PIN_NEW (v0.2.15). All gating (loadavg wait, foreign signal-file
# refusal, footprint sampler, amdgpu kernel-log check, load.jsonl) lives in that script; this wrapper only picks the build.
# Stages:
#   smoke   8K context, expert cache 2048: does it load, tool call, prefill 4K, decode 512, vision
#   foot    tool call, prefill 4K, decode 512 with the footprint sampler, at 131072 context and expert cache 20000
#   A       tool call, prefill 4K, decode 512, decode 32K, replay, vision
#   B       decode 128K
#   kl      `kl_strata.py` def arm, 64 chunks, top-256 against the stored Q8_0 reference (REF)
# The 2-bit script labels rows `base-<stage>` regardless of the build, so each pin gets its own work dir: WORK=$WORK/<pin>,
# and rows.jsonl, load.jsonl and the footprint files land in $WORK/<pin>/base/.
# Exit: the row's own status, 2 another bench is live, 7 usage or configuration error (before anything is touched),
# 9 amdgpu wedge suspected: stop and do not reboot.
# Env (all required): PIN_OLD, PIN_NEW (the two `nix build .#strata` out-links), WORK (parent work dir), and the 2-bit
# script's own set except STRATA_OUT: CACHE, PY, MTP_RT, MMPROJ, REF, BASE_PACK, BASE_SHARD.
set -u

usage() { echo "usage: rows.sh <old|new> <smoke|foot|A|B|kl>" >&2; exit 7; }
die() { echo "rows.sh: $*" >&2; exit 7; }

pin=${1:-} stage=${2:-}
[ $# -eq 2 ] || usage
case $pin in
old | new) ;;
*) usage ;;
esac
case $stage in
smoke | foot | A | B | kl) ;;
*) usage ;;
esac

for v in PIN_OLD PIN_NEW WORK CACHE PY MTP_RT MMPROJ REF BASE_PACK BASE_SHARD; do
    [ -n "${!v:-}" ] || die "$v is required"
done
# the reference logits are the fixed baseline for every KL row and must never be regenerated
if [ "$stage" = kl ]; then
    [ -f "$REF" ] && [ -r "$REF" ] || die "REF is not a readable file: $REF"
fi

case $pin in
old) STRATA_OUT=$PIN_OLD ;;
new) STRATA_OUT=$PIN_NEW ;;
esac
export STRATA_OUT WORK=$WORK/$pin

delegate=bench-logs/qwen38-flash-next-strata-2bit-2026-11-15/rows.sh
[ -x "$delegate" ] || die "run from the repo root: $delegate not found"
exec "$delegate" base "$stage"
