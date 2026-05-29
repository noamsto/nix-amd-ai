package models

import (
	"testing"
)

func TestParseModels_envelope(t *testing.T) {
	raw := `{"data":[
		{"id":"Gemma-4-26B-A4B-it-GGUF","downloaded":true,"labels":["llamacpp"]},
		{"id":"Qwen3.6-27B-GGUF","downloaded":false,"labels":["llamacpp"]}
	]}`

	ms, err := ParseModels([]byte(raw))
	if err != nil {
		t.Fatalf("ParseModels error: %v", err)
	}
	if len(ms) != 2 {
		t.Fatalf("want 2 models, got %d", len(ms))
	}

	if ms[0].ID != "Gemma-4-26B-A4B-it-GGUF" {
		t.Errorf("ms[0].ID = %q, want Gemma-4-26B-A4B-it-GGUF", ms[0].ID)
	}
	if !ms[0].Downloaded {
		t.Errorf("ms[0].Downloaded = false, want true")
	}
	if len(ms[0].Labels) != 1 || ms[0].Labels[0] != "llamacpp" {
		t.Errorf("ms[0].Labels = %v, want [llamacpp]", ms[0].Labels)
	}

	if ms[1].ID != "Qwen3.6-27B-GGUF" {
		t.Errorf("ms[1].ID = %q, want Qwen3.6-27B-GGUF", ms[1].ID)
	}
	if ms[1].Downloaded {
		t.Errorf("ms[1].Downloaded = true, want false")
	}
}

func TestParseModels_bareArray(t *testing.T) {
	raw := `[{"id":"TestModel","downloaded":true,"labels":["llamacpp"]}]`
	ms, err := ParseModels([]byte(raw))
	if err != nil {
		t.Fatalf("ParseModels bare array error: %v", err)
	}
	if len(ms) != 1 {
		t.Fatalf("want 1 model, got %d", len(ms))
	}
	if ms[0].ID != "TestModel" {
		t.Errorf("ms[0].ID = %q, want TestModel", ms[0].ID)
	}
}

func TestParseModels_idFallback(t *testing.T) {
	// id absent → model_name used
	raw := `{"data":[{"model_name":"FallbackModel","downloaded":false}]}`
	ms, err := ParseModels([]byte(raw))
	if err != nil {
		t.Fatalf("ParseModels error: %v", err)
	}
	if len(ms) != 1 || ms[0].ID != "FallbackModel" {
		t.Errorf("got %v, want ID=FallbackModel", ms)
	}
}

func TestParseModels_recipeFallback(t *testing.T) {
	// recipe absent → backend used
	raw := `{"data":[{"id":"M","downloaded":true,"backend":"llamacpp"}]}`
	ms, err := ParseModels([]byte(raw))
	if err != nil {
		t.Fatalf("ParseModels error: %v", err)
	}
	if ms[0].Recipe != "llamacpp" {
		t.Errorf("ms[0].Recipe = %q, want llamacpp", ms[0].Recipe)
	}
}
