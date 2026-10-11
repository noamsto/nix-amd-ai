# Unsloth fork vision and tool-call smoke test (#259)

`smoke-test.sh` checks that `llama-cpp-vulkan-unsloth`, serving Qwen3.8-Flash-Next with its vision projector, answers a known-answer image prompt and still returns tool calls. No results are recorded here: the script has not been run.

Run it on a Strix Halo (gfx1151) host with the model registered as in the [README example](../../README.md#opt-in-unsloth-llamacpp-fork-vulkan) and already loaded and served by an OpenAI-compatible endpoint:

```fish
MODEL=<model id> BASE_URL=http://localhost:13305/api/v1 ./smoke-test.sh
```

It generates a solid green 64x64 PNG at runtime, asks for its colour and requires `green` in the answer, then sends a text-only request with a `get_weather` tool and requires a tool call back. It exits non-zero with a `FAIL:` line on the first failure. `MODEL` is required (`/models` lists every registered model, and a request to the wrong one makes lemond load it); `API_KEY` is optional. It refuses to run while another bench holds the GPU signal file.

It does not measure speed, the projector's GTT cost, or the MTP gain.
