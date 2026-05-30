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

func TestParseModels_nullData(t *testing.T) {
	// `{"data": null}` is an envelope with no models, not an error.
	ms, err := ParseModels([]byte(`{"data":null,"object":"list"}`))
	if err != nil {
		t.Fatalf("ParseModels null data error: %v", err)
	}
	if len(ms) != 0 {
		t.Errorf("want 0 models, got %d", len(ms))
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

func TestParseModels_checkpointCaptured(t *testing.T) {
	raw := `{"data":[
		{"id":"Gemma-4-26B-A4B-it-GGUF","downloaded":true,"recipe":"llamacpp","checkpoint":"unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M"},
		{"id":"Qwen3.6-27B-MTP-GGUF","downloaded":true,"recipe":"llamacpp","checkpoint":"unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-UD-Q4_K_XL.gguf"},
		{"id":"Flux-2-Klein-9B-GGUF","downloaded":true,"recipe":"sd-cpp","checkpoint":"unsloth/FLUX.2-klein-9B-GGUF:flux-2-klein-9b-Q8_0.gguf"}
	]}`

	ms, err := ParseModels([]byte(raw))
	if err != nil {
		t.Fatalf("ParseModels error: %v", err)
	}
	if len(ms) != 3 {
		t.Fatalf("want 3 models, got %d", len(ms))
	}

	cases := []struct{ id, want string }{
		{"Gemma-4-26B-A4B-it-GGUF", "unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M"},
		{"Qwen3.6-27B-MTP-GGUF", "unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-UD-Q4_K_XL.gguf"},
		{"Flux-2-Klein-9B-GGUF", "unsloth/FLUX.2-klein-9B-GGUF:flux-2-klein-9b-Q8_0.gguf"},
	}
	for i, c := range cases {
		if ms[i].ID != c.id {
			t.Errorf("ms[%d].ID = %q, want %q", i, ms[i].ID, c.id)
		}
		if ms[i].Checkpoint != c.want {
			t.Errorf("ms[%d].Checkpoint = %q, want %q", i, ms[i].Checkpoint, c.want)
		}
	}
}

func TestParseModels_checkpointEmptyWhenAbsent(t *testing.T) {
	raw := `{"data":[{"id":"NoCheckpoint","downloaded":true}]}`
	ms, err := ParseModels([]byte(raw))
	if err != nil {
		t.Fatalf("ParseModels error: %v", err)
	}
	if ms[0].Checkpoint != "" {
		t.Errorf("ms[0].Checkpoint = %q, want empty", ms[0].Checkpoint)
	}
}

func TestParseModels_sizeSuggestedLabels(t *testing.T) {
	// Mirrors real lemonade API response for Qwen3.6-27B-MTP-GGUF.
	raw := `{"data":[
		{"id":"Qwen3.6-27B-MTP-GGUF","downloaded":true,"recipe":"llamacpp","size":18.8,"suggested":true,"labels":["vision","tool-calling","mtp","hot"]},
		{"id":"Gemma-4-26B-A4B-it-GGUF","downloaded":false,"recipe":"llamacpp","size":15.2,"suggested":false,"labels":["llamacpp"]}
	]}`

	ms, err := ParseModels([]byte(raw))
	if err != nil {
		t.Fatalf("ParseModels error: %v", err)
	}
	if len(ms) != 2 {
		t.Fatalf("want 2 models, got %d", len(ms))
	}

	// First model: size, suggested=true, labels including "mtp"
	m0 := ms[0]
	if m0.Size != 18.8 {
		t.Errorf("ms[0].Size = %v, want 18.8", m0.Size)
	}
	if !m0.Suggested {
		t.Errorf("ms[0].Suggested = false, want true")
	}
	hasLabel := func(labels []string, want string) bool {
		for _, l := range labels {
			if l == want {
				return true
			}
		}
		return false
	}
	if !hasLabel(m0.Labels, "mtp") {
		t.Errorf("ms[0].Labels = %v, want to contain \"mtp\"", m0.Labels)
	}

	// Second model: size present even though not downloaded, suggested=false
	m1 := ms[1]
	if m1.Size != 15.2 {
		t.Errorf("ms[1].Size = %v, want 15.2", m1.Size)
	}
	if m1.Suggested {
		t.Errorf("ms[1].Suggested = true, want false")
	}
	if m1.Downloaded {
		t.Errorf("ms[1].Downloaded = true, want false")
	}
}
