package bench

import (
	"strings"
	"testing"
)

func TestParseSSE(t *testing.T) {
	t.Run("multi_chunk_concatenates_text", func(t *testing.T) {
		// Simulates a streaming response: two text chunks + final usage chunk + DONE
		stream := strings.Join([]string{
			`data: {"choices":[{"text":"Hello"}]}`,
			`data: {"choices":[{"text":" world"}],"usage":{"completion_tokens":2}}`,
			`data: [DONE]`,
			``,
		}, "\n")

		res, err := ParseSSE(strings.NewReader(stream))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if res.Text != "Hello world" {
			t.Errorf("Text: got %q, want %q", res.Text, "Hello world")
		}
		if res.CompletionTokens != 2 {
			t.Errorf("CompletionTokens: got %d, want 2", res.CompletionTokens)
		}
	})

	t.Run("mtp_failure_mode_empty_text_single_token", func(t *testing.T) {
		// MTP failure mode: single chunk with empty text but completion_tokens=1
		stream := strings.Join([]string{
			`data: {"choices":[{"text":""}],"usage":{"completion_tokens":1}}`,
			`data: [DONE]`,
			``,
		}, "\n")

		res, err := ParseSSE(strings.NewReader(stream))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if res.Text != "" {
			t.Errorf("Text: got %q, want empty", res.Text)
		}
		if res.CompletionTokens != 1 {
			t.Errorf("CompletionTokens: got %d, want 1", res.CompletionTokens)
		}
	})

	t.Run("non_json_keepalive_lines_ignored", func(t *testing.T) {
		// Non-JSON data lines and non-data lines should be silently skipped
		stream := strings.Join([]string{
			`: keep-alive`,
			`data: not-json`,
			`data: {"choices":[{"text":"hi"}]}`,
			`data: [DONE]`,
			``,
		}, "\n")

		res, err := ParseSSE(strings.NewReader(stream))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if res.Text != "hi" {
			t.Errorf("Text: got %q, want %q", res.Text, "hi")
		}
	})

	t.Run("done_sentinel_stops_reading", func(t *testing.T) {
		// Data after [DONE] should be ignored
		stream := strings.Join([]string{
			`data: {"choices":[{"text":"stop"}]}`,
			`data: [DONE]`,
			`data: {"choices":[{"text":"ignored"}]}`,
			``,
		}, "\n")

		res, err := ParseSSE(strings.NewReader(stream))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if res.Text != "stop" {
			t.Errorf("Text: got %q, want %q", res.Text, "stop")
		}
	})
}
