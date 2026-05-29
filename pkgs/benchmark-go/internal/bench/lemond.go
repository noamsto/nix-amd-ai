package bench

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"time"
)

// lemonadeCompletionsPath is the OpenAI-compatible completions endpoint on
// the lemonade HTTP server.
const lemonadeCompletionsPath = "/api/v1/completions"

// RestartLemond restarts lemond via sudo systemctl, matching Python's
// restart_lemond. Raises on failure.
func RestartLemond(service string) error {
	cmd := exec.Command("sudo", "systemctl", "restart", service) //nolint:gosec
	cmd.Stderr = nil
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("restart %s: %w", service, err)
	}
	return nil
}

// WaitForLemond polls /api/v1/models until lemond answers or timeout expires,
// matching Python's wait_for_lemond (polls every 1s).
func WaitForLemond(baseURL string, timeout time.Duration) error {
	url := baseURL + "/api/v1/models"
	// Per-attempt timeout so a hung connection can't run past the deadline,
	// matching waitReady's bounded client.
	client := &http.Client{Timeout: 5 * time.Second}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := client.Get(url) //nolint:noctx
		if err == nil {
			status := resp.StatusCode
			_ = resp.Body.Close()
			// Python's urlopen raises on non-2xx, so it retries through
			// startup 503s; only a 2xx response counts as ready here.
			if status >= 200 && status < 300 {
				return nil
			}
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("lemond did not become reachable at %s within %s", baseURL, timeout)
}

// LoadModel loads a model into lemonade via POST /api/v1/load.
// Matches Python's load_model.
func LoadModel(baseURL, modelID string) error {
	payload, err := json.Marshal(map[string]string{"model_name": modelID})
	if err != nil {
		return err
	}
	url := baseURL + "/api/v1/load"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: completionHTTPTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("load model %q: %w", modelID, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("load model %q: HTTP %d: %s", modelID, resp.StatusCode, body)
	}
	return nil
}
