package bench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// readConfig decodes the JSON file at path into a map.
func readConfig(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readConfig: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("readConfig unmarshal: %v", err)
	}
	return m
}

// llamacppBackend extracts config["llamacpp"]["backend"] from a decoded map.
func llamacppBackend(t *testing.T, m map[string]any) string {
	t.Helper()
	ll, ok := m["llamacpp"].(map[string]any)
	if !ok {
		t.Fatal("llamacpp key missing or wrong type")
	}
	v, ok := ll["backend"].(string)
	if !ok {
		t.Fatal("backend key missing or wrong type")
	}
	return v
}

func TestSetLlamacppBackend_OverExistingVulkan(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "config.json")

	// Existing config: vulkan backend + unrelated key
	initial := map[string]any{
		"llamacpp": map[string]any{
			"backend": "vulkan",
		},
		"unrelated": "preserved",
	}
	data, _ := json.MarshalIndent(initial, "", "  ")
	os.WriteFile(cfgPath, data, 0o644)

	prev, err := SetLlamacppBackend(cfgPath, "rocm")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if prev != "vulkan" {
		t.Fatalf("prev = %q, want vulkan", prev)
	}

	m := readConfig(t, cfgPath)

	// backend changed to rocm
	if got := llamacppBackend(t, m); got != "rocm" {
		t.Fatalf("backend = %q, want rocm", got)
	}

	// unrelated key preserved
	if m["unrelated"] != "preserved" {
		t.Fatalf("unrelated key lost: %v", m["unrelated"])
	}

	// file uses indent (contains newlines)
	raw, _ := os.ReadFile(cfgPath)
	if !strings.Contains(string(raw), "\n") {
		t.Fatal("expected indented JSON (newlines present)")
	}
}

func TestSetLlamacppBackend_MissingFile_CreatesIt(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "subdir", "config.json")

	prev, err := SetLlamacppBackend(cfgPath, "rocm")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if prev != "" {
		t.Fatalf("prev = %q, want empty string (key was absent)", prev)
	}

	m := readConfig(t, cfgPath)
	if got := llamacppBackend(t, m); got != "rocm" {
		t.Fatalf("backend = %q, want rocm", got)
	}
}

func TestRestoreLlamacppBackend_RestoresToVulkan(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "config.json")

	// Set up rocm config
	prev, _ := SetLlamacppBackend(cfgPath, "rocm")
	_ = prev

	// Restore to vulkan
	if err := RestoreLlamacppBackend(cfgPath, "vulkan"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	m := readConfig(t, cfgPath)
	if got := llamacppBackend(t, m); got != "vulkan" {
		t.Fatalf("backend = %q, want vulkan", got)
	}
}

func TestRestoreLlamacppBackend_NoPrev_RemovesKey(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "config.json")

	_, _ = SetLlamacppBackend(cfgPath, "rocm")

	// prev="" means the backend key was absent before; restore should remove it
	if err := RestoreLlamacppBackend(cfgPath, ""); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	m := readConfig(t, cfgPath)
	ll, ok := m["llamacpp"].(map[string]any)
	if !ok {
		// llamacpp key itself missing is fine — key absent
		return
	}
	if _, exists := ll["backend"]; exists {
		t.Fatal("backend key should have been removed")
	}
}

func TestRestoreLlamacppBackend_MissingFile_NoOp(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "config.json")
	// File doesn't exist — should not error
	if err := RestoreLlamacppBackend(cfgPath, "vulkan"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
