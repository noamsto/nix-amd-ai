package models

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Model holds the fields lemonade's /api/v1/models endpoint returns that
// benchmark.py uses: id, downloaded, and the labels slice (used as a set
// of recipe tags, e.g. ["llamacpp"]). The recipe field, when present, is
// included so run_benchmarks can look it up from the returned map.
type Model struct {
	ID         string   `json:"id"`
	Downloaded bool     `json:"downloaded"`
	Labels     []string `json:"labels"`
	// Recipe is the lemonade recipe string (e.g. "llamacpp"). Python reads
	// model_map[mid].get("recipe") in model_recipe(). May be empty.
	Recipe string `json:"recipe"`
}

// modelsEnvelope matches the {"data":[...], "object":"list"} wrapper that
// /api/v1/models returns.
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
	Backend    string   `json:"backend"` // fallback for recipe
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

// convertModels applies the id-fallback logic and builds the public slice.
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
		})
	}
	return out
}

// modelsHTTPTimeout bounds the GET /api/v1/models request.
const modelsHTTPTimeout = 10 * time.Second

// Fetch retrieves the model list from a running lemonade server.
// baseURL is the scheme+host+port, e.g. "http://localhost:13305".
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
