#!/usr/bin/env bash
# Markdown tables from a rows.jsonl (usage: tables.sh rows.jsonl [label-prefix]). Rows with an `error` print as such.
set -o pipefail
f=$1 pre=${2:-}
echo "### Speed (t/s)"
echo
echo "| row | loadavg start / end / max | prefill 4K | prefill 32K | prefill 128K | decode 512 (T=0) | decode 32K (T=0) | decode 128K (T=0) | acceptance 512 / 32K / 128K |"
echo "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
jq -r --arg pre "$pre" 'select(.label | startswith($pre)) |
  def m: if . == null then "-" else (. * 10 | round / 10 | tostring) end;
  def d(g): if g == null then "-" else "\(g.decode_tps.mean | m) ± \(g.decode_tps.stdev | m) (\(g.decode_tps_t0 | m))" end;
  def a(g): if g == null or g.acceptance == null then "-" else (g.acceptance * 100 | round / 100 | tostring) end;
  if .error then "| \(.label) | \(.loadavg_start) | error: \(.error[:80]) |||||||" else
  "| \(.label) | \(.loadavg_start) / \(.loadavg_end) / \(.loadavg_max) | \(.prefill4k.prefill_tps.mean | m) | \(.decode32k.prefill_tps.mean | m) | \(.decode128k.prefill_tps.mean | m) | \(d(.decode512)) | \(d(.decode32k)) | \(d(.decode128k)) | \(a(.decode512)) / \(a(.decode32k)) / \(a(.decode128k)) |" end' "$f"
echo
echo "### Replay, tool call, vision, memory"
echo
echo "| row | replay normalized / TTFT sum (s) | tool call | vision | GTT after load / peak (GiB) | RSS after load / engine peak / tree peak (GiB) | MemAvailable after load (GiB) | page cache before / after evict (GiB) | cores busy: system / engine |"
echo "| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |"
jq -r --arg pre "$pre" 'select(.label | startswith($pre)) | select(.error | not) |
  def g: if . == null then "-" else (. / 1073741824 * 10 | round / 10 | tostring) end;
  def k: if . == null then "-" else (. / 1048576 * 10 | round / 10 | tostring) end;
  "| \(.label) | \(if .replay then "\(.replay.normalized_total_s | . * 10 | round / 10) / \(.replay.ttft_total_s | . * 10 | round / 10)" else "-" end) | \(if .toolcall then (if .toolcall.tool_call_ok then "pass" else "FAIL" end) else "-" end) | \(if .vision then (if .vision.ok then "pass" else "FAIL" end) else "-" end) | \(.mem_after_load.gtt_delta_bytes | g) / \(.gtt_peak_delta_bytes | g) | \(.mem_after_load.rss_kb | k) / \(.hwm_kb | k) / \(.tree_hwm_kb | k) | \(.mem_after_load.mem_available_kb | k) | \(.cached_kb_before_evict | k) / \(.cached_kb_after_evict | k) | \(.cpu_cores_system // "-") / \(.cpu_cores_engine // "-") |"' "$f"
