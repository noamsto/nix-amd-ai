package bench

import (
	"bufio"
	"encoding/json"
	"io"
	"strings"
)

// SSEResult holds the accumulated text and token count from a completion stream.
type SSEResult struct {
	Text             string
	CompletionTokens int
}

type sseChunk struct {
	Choices []struct {
		Text string `json:"text"`
	} `json:"choices"`
	Usage *struct {
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

// ParseSSE reads an OpenAI-style completion SSE stream, concatenating
// choices[0].text and capturing the final usage.completion_tokens.
// Non-JSON lines and non-data lines are silently skipped, matching Python's
// run_completion which wraps json.loads in a try/except JSONDecodeError.
func ParseSSE(r io.Reader) (SSEResult, error) {
	var out SSEResult
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := line[len("data: "):]
		if strings.TrimSpace(payload) == "[DONE]" {
			break
		}
		var c sseChunk
		if err := json.Unmarshal([]byte(payload), &c); err != nil {
			continue
		}
		if len(c.Choices) > 0 {
			out.Text += c.Choices[0].Text
		}
		if c.Usage != nil {
			out.CompletionTokens = c.Usage.CompletionTokens
		}
	}
	return out, sc.Err()
}
