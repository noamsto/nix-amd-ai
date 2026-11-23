#!/usr/bin/env bash
# One short LoRA started through Studio's HTTP API (the endpoint the web UI uses), polled to
# completion; prints the phase transitions and the loss history.
# Run under the gate:  ../unsloth-studio-trial-2026-11-23/gpu-gate.sh ui-train ./ui-train.sh <unsloth-studio> [port]
# Needs UNSLOTH_STUDIO_HOME set to a scratch install.
set -u -o pipefail
bin=$1
port=${2:-8897}
model=${MODEL:-unsloth/Llama-3.2-1B-Instruct}
steps=${STEPS:-20}
work=$(mktemp -d)
# shellcheck source=studio-session.sh
. "$(dirname "${BASH_SOURCE[0]}")/studio-session.sh"
trap 'session_cleanup; rm -rf -- "$work"' EXIT
studio_login || exit 1

jq -n --arg m "$model" --argjson s "$steps" '{
    model_name: $m, training_type: "LoRA/QLoRA", load_in_4bit: false,
    hf_dataset: "yahma/alpaca-cleaned", format_type: "alpaca", max_seq_length: 512,
    batch_size: 2, gradient_accumulation_steps: 4, max_steps: $s, warmup_steps: 5,
    learning_rate: "2e-4", lora_r: 16, lora_alpha: 16, packing: false, project_name: "ui-train-probe",
    target_modules: ["q_proj","k_proj","v_proj","o_proj","gate_proj","up_proj","down_proj"]
}' | api POST /api/train/start | jq -c .

last=
start=$(date +%s)
while :; do
    st=$(api GET /api/train/status </dev/null)
    phase=$(jq -r .phase <<<"$st")
    [ "$phase" != "$last" ] && { echo "phase=$phase t=$(($(date +%s) - start))s"; last=$phase; }
    case $phase in completed | error | stopped) break ;; esac
    [ $(($(date +%s) - start)) -gt 1500 ] && { echo "ui-train: timeout" >&2; break; }
    sleep 5
done
jq -c '{phase,message,error}' <<<"$st"
api GET /api/train/metrics </dev/null | jq -c '{n: (.loss_history|length), loss_history, step_history}'
