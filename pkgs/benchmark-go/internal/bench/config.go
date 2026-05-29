package bench

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// SetLlamacppBackend writes llamacpp.backend into lemonade's config.json.
// Returns the previous value (or "" if the key was absent), so the caller can
// restore state on exit. Creates the file (and parent dirs) if missing.
func SetLlamacppBackend(path, backend string) (prev string, err error) {
	var config map[string]any
	if _, statErr := os.Stat(path); os.IsNotExist(statErr) {
		config = map[string]any{}
		if mkErr := os.MkdirAll(filepath.Dir(path), 0o755); mkErr != nil {
			return "", mkErr
		}
	} else {
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return "", readErr
		}
		if unmarshalErr := json.Unmarshal(data, &config); unmarshalErr != nil {
			return "", unmarshalErr
		}
	}

	llamacpp := configSection(config, "llamacpp")
	prev, _ = llamacpp["backend"].(string)
	llamacpp["backend"] = backend

	return prev, writeJSON(path, config)
}

// RestoreLlamacppBackend restores a previously captured llamacpp.backend value.
// If prev is "" the backend key is removed. If the file is missing, returns nil.
func RestoreLlamacppBackend(path, prev string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		return err
	}

	llamacpp := configSection(config, "llamacpp")
	if prev == "" {
		delete(llamacpp, "backend")
	} else {
		llamacpp["backend"] = prev
	}

	return writeJSON(path, config)
}

// configSection returns config[key] as a map, creating it if absent.
func configSection(config map[string]any, key string) map[string]any {
	if v, ok := config[key]; ok {
		if m, ok := v.(map[string]any); ok {
			return m
		}
	}
	m := map[string]any{}
	config[key] = m
	return m
}

func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
