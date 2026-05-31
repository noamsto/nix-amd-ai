package bench

import (
	"testing"
)

func TestBuildCompletionPayload(t *testing.T) {
	t.Run("base_keys", func(t *testing.T) {
		p := BuildCompletionPayload(CompletionOpts{
			Model:     "mymodel",
			Prompt:    "hello",
			GenTokens: 128,
			Stream:    true,
		})
		for _, key := range []string{"model", "prompt", "max_tokens", "stream"} {
			if _, ok := p[key]; !ok {
				t.Errorf("missing key %q", key)
			}
		}
		if _, ok := p["ignore_eos"]; ok {
			t.Errorf("unexpected key 'ignore_eos' when IgnoreEOS=false")
		}
		for _, key := range []string{"temperature", "cache_prompt", "n_predict"} {
			if _, ok := p[key]; ok {
				t.Errorf("unexpected key %q", key)
			}
		}
	})

	t.Run("values_correct", func(t *testing.T) {
		p := BuildCompletionPayload(CompletionOpts{
			Model:     "test-model",
			Prompt:    "test prompt",
			GenTokens: 256,
			Stream:    true,
		})
		if p["model"] != "test-model" {
			t.Errorf("model: got %v, want 'test-model'", p["model"])
		}
		if p["prompt"] != "test prompt" {
			t.Errorf("prompt: got %v, want 'test prompt'", p["prompt"])
		}
		if p["max_tokens"] != 256 {
			t.Errorf("max_tokens: got %v, want 256", p["max_tokens"])
		}
		if p["stream"] != true {
			t.Errorf("stream: got %v, want true", p["stream"])
		}
	})

	t.Run("ignore_eos_present_when_true", func(t *testing.T) {
		p := BuildCompletionPayload(CompletionOpts{
			Model:     "mtp-model",
			Prompt:    "prompt",
			GenTokens: 64,
			Stream:    true,
			IgnoreEOS: true,
		})
		val, ok := p["ignore_eos"]
		if !ok {
			t.Fatal("expected 'ignore_eos' key when IgnoreEOS=true")
		}
		if val != true {
			t.Errorf("ignore_eos: got %v, want true", val)
		}
	})

	t.Run("ignore_eos_absent_when_false", func(t *testing.T) {
		p := BuildCompletionPayload(CompletionOpts{
			Model:     "base-model",
			Prompt:    "prompt",
			GenTokens: 64,
			Stream:    true,
			IgnoreEOS: false,
		})
		if _, ok := p["ignore_eos"]; ok {
			t.Error("'ignore_eos' must be absent when IgnoreEOS=false")
		}
	})

	t.Run("exact_key_count_base", func(t *testing.T) {
		p := BuildCompletionPayload(CompletionOpts{
			Model: "m", Prompt: "p", GenTokens: 1, Stream: true,
		})
		if len(p) != 4 {
			t.Errorf("base payload: got %d keys, want 4 (model, prompt, max_tokens, stream)", len(p))
		}
	})

	t.Run("exact_key_count_with_ignore_eos", func(t *testing.T) {
		p := BuildCompletionPayload(CompletionOpts{
			Model: "m", Prompt: "p", GenTokens: 1, Stream: true, IgnoreEOS: true,
		})
		if len(p) != 5 {
			t.Errorf("ignore_eos payload: got %d keys, want 5", len(p))
		}
	})
}
