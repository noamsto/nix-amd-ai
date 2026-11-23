#!/usr/bin/env bash
# One small 4-bit QLoRA fine-tune through the unsloth-studio wrapper, with GPU memory sampling.
# Studio only accepts an output dir under its own outputs/ root, so the adapter lands there,
# in a per-run directory. The run fails unless the log shows 4-bit loading and the adapter config
# records the qlora method.
# Run under gpu-gate.sh:  ./gpu-gate.sh unsloth-qlora ./qlora.sh <unsloth-studio> <outdir>
# Peak memory is the sampled maximum of amdgpu GTT+VRAM minus the idle baseline taken before the run,
# so a resident model server on the same GPU is excluded.
set -u
bin=$1
out=$2
model=${MODEL:-unsloth/Llama-3.2-1B-Instruct}
steps=${STEPS:-20}
mkdir -p "$out"
run_name=unsloth-studio-qlora-$(date +%Y%m%d-%H%M%S)
echo "output_name=$run_name"

dev=$(printf "%s\n" /sys/class/drm/card*/device | while read -r d; do [ -r "$d/mem_info_gtt_used" ] && echo "$d" && break; done)
[ -n "$dev" ] || { echo "qlora: no amdgpu mem_info device found" >&2; exit 1; }
used() { echo $(($(cat "$dev/mem_info_gtt_used") + $(cat "$dev/mem_info_vram_used"))); }
base=$(used)
case $base in '' | *[!0-9]*) echo "qlora: non-numeric baseline '$base'" >&2; exit 1 ;; esac
load_start=$(cut -d" " -f1 /proc/loadavg)
(
    peak=0
    while :; do
        u=$(used)
        [ "$u" -gt "$peak" ] && peak=$u
        echo "$peak" >"$out/peak.bytes.tmp" && mv "$out/peak.bytes.tmp" "$out/peak.bytes"
        sleep 1
    done
) &
sampler=$!
trap 'kill "$sampler" 2>/dev/null' EXIT

start=$(date +%s)
"$bin" train \
    --model "$model" \
    --dataset yahma/alpaca-cleaned \
    --format-type alpaca \
    --training-type lora \
    --load-in-4bit \
    --max-seq-length 512 \
    --batch-size 2 \
    --gradient-accumulation-steps 4 \
    --max-steps "$steps" \
    --warmup-steps 5 \
    --learning-rate 2e-4 \
    --lora-r 16 --lora-alpha 16 \
    --output-dir "$run_name" \
    >"$out/train.log" 2>&1
rc=$?
end=$(date +%s)
four_bit=no
adapter_cfg=$(find "${UNSLOTH_STUDIO_HOME:?}/outputs/$run_name" -name adapter_config.json 2>/dev/null | head -1)
if grep -q 'bnb-4bit' "$out/train.log" && [ -n "$adapter_cfg" ] &&
    jq -e '.unsloth_training_method == "qlora"' "$adapter_cfg" >/dev/null 2>&1; then
    four_bit=yes
fi
kill "$sampler" 2>/dev/null
wait "$sampler" 2>/dev/null
{
    echo "rc=$rc"
    echo "output_name=$run_name"
    echo "four_bit=$four_bit"
    echo "wall_s=$((end - start))"
    echo "load1_start=$load_start"
    echo "load1_end=$(cut -d" " -f1 /proc/loadavg)"
    echo "baseline_bytes=$base"
    echo "peak_bytes=$(cat "$out/peak.bytes")"
} >"$out/summary.txt"
[ "$four_bit" = yes ] || { echo "qlora: 4-bit not confirmed" >&2; [ "$rc" -ne 0 ] || rc=1; }
exit "$rc"
