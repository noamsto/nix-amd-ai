package models

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Model holds the fields from lemonade's /api/v1/models endpoint.
// Labels is used as a set of recipe tags (e.g. ["llamacpp"]).
type Model struct {
	ID         string   `json:"id"`
	Downloaded bool     `json:"downloaded"`
	Labels     []string `json:"labels"`
	Recipe     string   `json:"recipe"`     // lemonade recipe (e.g. "llamacpp"); may be empty
	Checkpoint string   `json:"checkpoint"` // HF repo + optional variant (e.g. "owner/repo:variant")
}

// modelsEnvelope is the {"data":[...]} wrapper from /api/v1/models.
type modelsEnvelope struct {
	Data []rawModel `json:"data"`
}

// rawModel is the full JSON shape; we map to Model after parsing to apply
// the id-fallback logic that Python uses (id → model_name → name).
type rawModel struct {
	ID         string   `json:"id"`
	ModelName  string   `json:"model_name"`
	Name       string   `json:"name"`
	Downloaded bool     `json:"downloaded"`
	Labels     []string `json:"labels"`
	Recipe     string   `json:"recipe"`
	Backend    string   `json:"backend"`    // fallback for recipe
	Checkpoint string   `json:"checkpoint"` // HF repo + optional variant
}

// ParseModels decodes the /api/v1/models response body into a []Model.
// Handles both the {"data":[...]} envelope and a bare array, matching
// Python's check_models:
//
//	if isinstance(response, dict):
//	    models_list = response.get("data", [])
//	else:
//	    models_list = response
func ParseModels(data []byte) ([]Model, error) {
	// Disambiguate by the first non-space byte: '{' is the envelope (so
	// `"data": null` correctly yields an empty list), '[' is a bare array.
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) > 0 && trimmed[0] == '{' {
		var env modelsEnvelope
		if err := json.Unmarshal(data, &env); err != nil {
			return nil, fmt.Errorf("models.ParseModels: %w", err)
		}
		return convertModels(env.Data), nil
	}

	var raws []rawModel
	if err := json.Unmarshal(data, &raws); err != nil {
		return nil, fmt.Errorf("models.ParseModels: %w", err)
	}
	return convertModels(raws), nil
}

func convertModels(raws []rawModel) []Model {
	out := make([]Model, 0, len(raws))
	for _, r := range raws {
		// Python: name = m.get("id") or m.get("model_name") or m.get("name") or ""
		id := r.ID
		if id == "" {
			id = r.ModelName
		}
		if id == "" {
			id = r.Name
		}
		// recipe: "recipe" field, falling back to "backend" (Python's model_recipe).
		recipe := r.Recipe
		if recipe == "" {
			recipe = r.Backend
		}
		out = append(out, Model{
			ID:         id,
			Downloaded: r.Downloaded,
			Labels:     r.Labels,
			Recipe:     recipe,
			Checkpoint: r.Checkpoint,
		})
	}
	return out
}

const modelsHTTPTimeout = 10 * time.Second

// Fetch retrieves models from a lemonade server (baseURL = scheme+host+port).
func Fetch(baseURL string) ([]Model, error) {
	url := baseURL + "/api/v1/models"
	client := &http.Client{Timeout: modelsHTTPTimeout}
	resp, err := client.Get(url) //nolint:noctx
	if err != nil {
		return nil, fmt.Errorf("models.Fetch %s: %w", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("models.Fetch read body: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("models.Fetch: HTTP %d: %s", resp.StatusCode, body)
	}
	return ParseModels(body)
}
