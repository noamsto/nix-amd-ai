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
		// Two non-empty text chunks -> client-side fallback count of 2.
		if res.TextTokenCount != 2 {
			t.Errorf("TextTokenCount: got %d, want 2", res.TextTokenCount)
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

	t.Run("captures_server_timings_predicted_per_second", func(t *testing.T) {
		// llama.cpp sends timings.predicted_per_second in the final chunk;
		// it takes precedence over client-side wall-clock TPS.
		stream := strings.Join([]string{
			`data: {"choices":[{"text":"a"}]}`,
			`data: {"choices":[{"text":"b"}],"usage":{"completion_tokens":2},"timings":{"predicted_per_second":42.5}}`,
			`data: [DONE]`,
			``,
		}, "\n")

		res, err := ParseSSE(strings.NewReader(stream))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if res.PredictedPerSecond != 42.5 {
			t.Errorf("PredictedPerSecond: got %v, want 42.5", res.PredictedPerSecond)
		}
	})

	t.Run("text_token_count_fallback_when_no_usage", func(t *testing.T) {
		// No usage block: caller must fall back to counting non-empty text
		// chunks. CompletionTokens stays 0 (server reported nothing);
		// TextTokenCount provides the fallback.
		stream := strings.Join([]string{
			`data: {"choices":[{"text":"one"}]}`,
			`data: {"choices":[{"text":""}]}`,
			`data: {"choices":[{"text":"two"}]}`,
			`data: {"choices":[{"text":"three"}]}`,
			`data: [DONE]`,
			``,
		}, "\n")

		res, err := ParseSSE(strings.NewReader(stream))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if res.CompletionTokens != 0 {
			t.Errorf("CompletionTokens: got %d, want 0 (no usage reported)", res.CompletionTokens)
		}
		// Three non-empty text chunks; the empty one is not counted.
		if res.TextTokenCount != 3 {
			t.Errorf("TextTokenCount: got %d, want 3", res.TextTokenCount)
		}
		if res.Text != "onetwothree" {
			t.Errorf("Text: got %q, want %q", res.Text, "onetwothree")
		}
	})
}
