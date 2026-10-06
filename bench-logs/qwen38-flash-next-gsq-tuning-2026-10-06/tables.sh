#!/usr/bin/env bash
# Summary table of the speed, replay and memory columns from a rows.jsonl (usage: tables.sh rows.jsonl).
set -o pipefail
jq -r '[.label, .loadavg_start, (.prefill4k.prefill_tps.mean // "-"), (.decode512.decode_tps.mean // "-"),
  (.decode32k.prefill_tps.mean // "-"), (.decode32k.decode_tps.mean // "-"), (.decode32k.decode_tps_t0 // "-"),
  (.decode128k.prefill_tps.mean // "-"), (.decode128k.decode_tps.mean // "-"), (.decode128k.decode_tps_t0 // "-"),
  (.replay.normalized_total_s // "-"), (.replay.ttft_total_s // "-"),
  (.mem_after_load.gtt_delta_bytes // null | if . then . / 1073741824 else "-" end),
  (.gtt_peak_delta_bytes // null | if . then . / 1073741824 else "-" end), (.error // "")] | @tsv' "$1" | column -t -s$'\t'
