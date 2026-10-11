#!/usr/bin/env bash
# Smoke test for llama-cpp-vulkan-unsloth (#259) against a running
# OpenAI-compatible endpoint that serves a vision-capable Qwen3.8-Flash-Next.
# Checks a known-answer image prompt, then a text-only tool call.
#   BASE_URL  endpoint root (default: lemond's)
#   MODEL     model id to request (required: /models lists every registered
#             model, and a request to the wrong one makes lemond load it)
#   API_KEY   bearer token, if the endpoint wants one
set -euo pipefail

BASE_URL=${BASE_URL:-http://localhost:13305/api/v1}
API_KEY=${API_KEY:-}
MODEL=${MODEL:?set MODEL to the Flash-Next model id served by the Unsloth fork}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for tool in curl jq python3; do
  command -v "$tool" >/dev/null || fail "missing required tool: $tool"
done

gpu_signal=${XDG_RUNTIME_DIR:-/run/user/$UID}/halo-gpu-bench.active
[ ! -e "$gpu_signal" ] || fail "another bench holds $gpu_signal; not sending requests"

auth=()
[ -z "$API_KEY" ] || auth=(-H "Authorization: Bearer $API_KEY")

post() {
  curl -sS --fail-with-body --max-time 300 ${auth[@]+"${auth[@]}"} \
    -H 'Content-Type: application/json' -d @- "$BASE_URL/chat/completions"
}

echo "endpoint: $BASE_URL  model: $MODEL"

png_b64=$(python3 - <<'PY'
import base64, struct, zlib

w = h = 64
row = b"\x00" + b"\x00\xc0\x00" * w
raw = row * h


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw))
    + chunk(b"IEND", b"")
)
print(base64.b64encode(png).decode())
PY
) || fail "could not generate the test image"

echo "== vision: solid green square =="
vision=$(jq -n --arg model "$MODEL" --arg img "data:image/png;base64,$png_b64" '{
  model: $model,
  max_tokens: 8192,
  messages: [{role: "user", content: [
    {type: "text", text: "What colour is this image? Answer with one word."},
    {type: "image_url", image_url: {url: $img}}
  ]}]
}' | post) || fail "vision request errored: ${vision:-no response}"
# A backend that leaves <think> blocks in content would match the colour from
# the reasoning rather than the answer.
answer=$(jq -r '.choices[0].message.content // empty' <<<"$vision" | sed '/<think>/,/<\/think>/d')
echo "answer: $answer"
grep -qiw 'green' <<<"$answer" ||
  fail "vision answer is not 'green' (finish_reason: $(jq -r '.choices[0].finish_reason' <<<"$vision"))"

echo "== tool call: text only =="
tools=$(jq -n --arg model "$MODEL" '{
  model: $model,
  max_tokens: 8192,
  messages: [{role: "user", content: "What is the weather in Paris right now? Use the tool."}],
  tools: [{type: "function", function: {
    name: "get_weather",
    description: "Current weather for a city",
    parameters: {type: "object", properties: {city: {type: "string"}}, required: ["city"]}
  }}]
}' | post) || fail "tool request errored: ${tools:-no response}"
name=$(jq -r '.choices[0].message.tool_calls[0].function.name // empty' <<<"$tools")
[ -n "$name" ] || fail "no tool call returned (finish_reason: $(jq -r '.choices[0].finish_reason' <<<"$tools")): $(jq -c '.choices[0].message' <<<"$tools")"
echo "tool call: $name $(jq -c '.choices[0].message.tool_calls[0].function.arguments' <<<"$tools")"
[ "$name" = get_weather ] || fail "unexpected tool '$name', expected get_weather"
jq -e '.choices[0].message.tool_calls[0].function.arguments | fromjson | .city | test("paris"; "i")' <<<"$tools" >/dev/null ||
  fail "tool arguments do not name Paris"

echo "PASS"
