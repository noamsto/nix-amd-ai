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
	data, err := os.ReadFile(path) //nolint:gosec // test helper reading a path built by the test
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
	if err := os.WriteFile(cfgPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

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
	raw, _ := os.ReadFile(cfgPath) //nolint:gosec // test-created temp file
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

func TestRestoreLlamacppBackend_RoundTrip(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "config.json")

	// Pre-seed the file with vulkan, the value we expect to be restored.
	initial := map[string]any{
		"llamacpp": map[string]any{"backend": "vulkan"},
	}
	data, _ := json.MarshalIndent(initial, "", "  ")
	if err := os.WriteFile(cfgPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	// Set rocm, capturing the prior value for the restore.
	prev, err := SetLlamacppBackend(cfgPath, "rocm")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if prev != "vulkan" {
		t.Fatalf("prev = %q, want vulkan", prev)
	}

	// Restore using the captured prev — should put vulkan back.
	if err := RestoreLlamacppBackend(cfgPath, prev); err != nil {
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

// A config.json whose content is the JSON literal `null` unmarshals to a nil
// map. Both writers must replace it instead of panicking on a nil-map write.
func TestSetLlamacppBackend_NullConfig(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "config.json")
	if err := os.WriteFile(cfgPath, []byte("null"), 0o600); err != nil {
		t.Fatal(err)
	}

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

func TestRestoreLlamacppBackend_NullConfig(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "config.json")
	if err := os.WriteFile(cfgPath, []byte("null"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := RestoreLlamacppBackend(cfgPath, ""); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	m := readConfig(t, cfgPath)
	ll, ok := m["llamacpp"].(map[string]any)
	if !ok {
		t.Fatal("llamacpp key missing after restore")
	}
	if _, exists := ll["backend"]; exists {
		t.Fatal("backend key should not exist")
	}
}
