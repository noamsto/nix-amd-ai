package bench

import (
	"bufio"
	"encoding/json"
	"io"
	"strings"
)

// SSEResult holds everything run_completion extracts from a completion stream,
// so the caller can reproduce its (ttft, decode_tps, completion_tokens) return:
//
//   - Text: all choices[].text concatenated.
//   - CompletionTokens: server-reported usage.completion_tokens from the final
//     chunk that carries it (0 if never reported). Python prefers this when
//     truthy.
//   - TextTokenCount: client-side count of non-empty text chunks. Python's
//     fallback for completion_tokens when usage is absent/zero.
//   - PredictedPerSecond: server-reported timings.predicted_per_second. Python
//     prefers this as decode TPS over client-side wall-clock measurement.
//
// TTFT and wall-clock decode timing are measured by the caller around the
// stream (not derivable from chunk content), so they are not part of SSEResult.
type SSEResult struct {
	Text               string
	CompletionTokens   int
	TextTokenCount     int
	PredictedPerSecond float64
}

type sseChunk struct {
	Choices []struct {
		Text string `json:"text"`
	} `json:"choices"`
	Usage *struct {
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
	Timings *struct {
		PredictedPerSecond float64 `json:"predicted_per_second"`
	} `json:"timings"`
}

// scanSSE performs the low-level SSE scan shared by ParseSSE and
// runOneCompletion: bufio-scans lines, strips the "data: " prefix, breaks on
// "[DONE]", JSON-decodes each chunk (silently skipping non-JSON and non-data
// lines), and invokes onChunk per decoded chunk. Returns the scanner error.
//
// Matches Python's run_completion loop: non-data lines skipped, "[DONE]"
// terminates, json.loads wrapped in try/except JSONDecodeError.
func scanSSE(r io.Reader, onChunk func(c sseChunk)) error {
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
		onChunk(c)
	}
	return sc.Err()
}

// ParseSSE reads an OpenAI-style completion SSE stream, replicating what
// run_completion extracts: concatenated text, server usage/timings, and a
// client-side non-empty-text token count for fallback.
//
// The last chunk carrying a truthy usage / timings wins, matching Python's
// final_usage / final_timings overwrite-on-each-truthy behavior.
func ParseSSE(r io.Reader) (SSEResult, error) {
	var out SSEResult
	var text strings.Builder
	err := scanSSE(r, func(c sseChunk) {
		// Python: `if usage:` / `if timings:` — only truthy blocks overwrite.
		if c.Usage != nil && c.Usage.CompletionTokens != 0 {
			out.CompletionTokens = c.Usage.CompletionTokens
		}
		if c.Timings != nil && c.Timings.PredictedPerSecond != 0 {
			out.PredictedPerSecond = c.Timings.PredictedPerSecond
		}
		// Python iterates all choices and counts only non-empty text.
		for _, ch := range c.Choices {
			text.WriteString(ch.Text)
			if ch.Text != "" {
				out.TextTokenCount++
			}
		}
	})
	out.Text = text.String()
	return out, err
}
