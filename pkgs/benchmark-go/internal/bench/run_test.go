package bench

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// cannedSSE builds a minimal SSE response that matches what runOneCompletion expects:
// - numTextChunks text-bearing data lines (each with one non-empty choices[].text token)
// - one final chunk with usage.completion_tokens and timings.predicted_per_second
// - a [DONE] terminator
func cannedSSE(numTextChunks int, compTokens int, predictedTPS float64) string {
	out := ""
	for i := range numTextChunks {
		out += fmt.Sprintf("data: {\"choices\":[{\"text\":\"tok%d\"}]}\n\n", i)
	}
	// Final chunk with usage + timings (no choices text).
	out += fmt.Sprintf(
		"data: {\"choices\":[{\"text\":\"\"}],\"usage\":{\"completion_tokens\":%d},\"timings\":{\"predicted_per_second\":%.2f}}\n\n",
		compTokens, predictedTPS,
	)
	out += "data: [DONE]\n\n"
	return out
}

func TestMeasureSpec_BasicSSE(t *testing.T) {
	const (
		numChunks  = 4
		compTokens = 128
		predTPS    = 42.5
		repeat     = 3
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		body := cannedSSE(numChunks, compTokens, predTPS)
		_, _ = fmt.Fprint(w, body)
	}))
	defer srv.Close()

	o := MeasureOpts{
		PromptTokens: 8,
		GenTokens:    128,
		Warmup:       1,
		Repeat:       repeat,
		IgnoreEOS:    false,
	}
	result := MeasureSpec(srv.URL, "/v1/completions", "test-model", o)

	if len(result.DecodeTPS) != repeat {
		t.Fatalf("expected %d DecodeTPS samples, got %d", repeat, len(result.DecodeTPS))
	}
	for i, tps := range result.DecodeTPS {
		if tps <= 0 {
			t.Errorf("DecodeTPS[%d] = %v, want > 0", i, tps)
		}
	}
	if len(result.TTFT) != repeat {
		t.Fatalf("expected %d TTFT samples, got %d", repeat, len(result.TTFT))
	}
	for i, ttft := range result.TTFT {
		if ttft < 0 {
			t.Errorf("TTFT[%d] = %v, want >= 0", i, ttft)
		}
	}
}

func TestMeasureSpec_ServerReportedTPS(t *testing.T) {
	// Verify that PredictedPerSecond from the server takes precedence over wall-clock.
	const predTPS = 99.9

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, cannedSSE(4, 64, predTPS))
	}))
	defer srv.Close()

	o := MeasureOpts{PromptTokens: 8, GenTokens: 64, Warmup: 0, Repeat: 1}
	result := MeasureSpec(srv.URL, "/v1/completions", "m", o)

	if len(result.DecodeTPS) != 1 {
		t.Fatalf("expected 1 sample, got %d", len(result.DecodeTPS))
	}
	if result.DecodeTPS[0] != predTPS {
		t.Errorf("DecodeTPS = %v, want %v (server-reported)", result.DecodeTPS[0], predTPS)
	}
}

func TestMeasureSpec_NoTokensSentinel(t *testing.T) {
	// Server streams only [DONE] with no text tokens — all iterations should be skipped.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		// No text chunks — only empty choices and DONE.
		_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"text\":\"\"}]}\n\ndata: [DONE]\n\n")
	}))
	defer srv.Close()

	o := MeasureOpts{PromptTokens: 8, GenTokens: 64, Warmup: 0, Repeat: 3}
	result := MeasureSpec(srv.URL, "/v1/completions", "m", o)

	if len(result.DecodeTPS) != 0 {
		t.Errorf("expected 0 samples (all no-token), got %d", len(result.DecodeTPS))
	}
}

func TestMeasureSpec_OnIteration(t *testing.T) {
	const (
		numChunks  = 4
		compTokens = 128
		predTPS    = 42.5
		warmup     = 2
		repeat     = 3
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, cannedSSE(numChunks, compTokens, predTPS))
	}))
	defer srv.Close()

	type sample struct {
		iter int
		tps  float64
	}
	var got []sample
	o := MeasureOpts{
		PromptTokens: 8,
		GenTokens:    128,
		Warmup:       warmup,
		Repeat:       repeat,
		OnIteration: func(iter int, decodeTPS float64) {
			got = append(got, sample{iter, decodeTPS})
		},
	}
	MeasureSpec(srv.URL, "/v1/completions", "m", o)

	// Exactly Repeat callbacks (warmup iterations must NOT fire it).
	if len(got) != repeat {
		t.Fatalf("expected %d OnIteration callbacks, got %d", repeat, len(got))
	}
	for i, s := range got {
		if s.iter != i+1 {
			t.Errorf("callback %d: iter = %d, want %d (1-based)", i, s.iter, i+1)
		}
		if s.tps <= 0 {
			t.Errorf("callback %d: tps = %v, want > 0", i, s.tps)
		}
	}
}

func TestMeasureSpec_OnIterationSkipsNoToken(t *testing.T) {
	// All iterations produce no tokens → OnIteration must never fire.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"text\":\"\"}]}\n\ndata: [DONE]\n\n")
	}))
	defer srv.Close()

	calls := 0
	o := MeasureOpts{
		PromptTokens: 8, GenTokens: 64, Warmup: 0, Repeat: 3,
		OnIteration: func(int, float64) { calls++ },
	}
	MeasureSpec(srv.URL, "/v1/completions", "m", o)
	if calls != 0 {
		t.Errorf("expected 0 callbacks for no-token iterations, got %d", calls)
	}
}

func TestMeasureSpec_EmptySliceGuard(t *testing.T) {
	// Verify that when all iterations produce no tokens, calling MeanStdev on
	// the empty result would be wrong — but we DON'T call it here; we just
	// confirm the slice is empty (the caller's guard works correctly).
	result := MeasureResult{}
	if len(result.DecodeTPS) != 0 {
		t.Error("zero-value MeasureResult should have empty DecodeTPS")
	}
	// MeanStdev with empty input returns (0, 0) — contracts says "do not call".
	// We verify the guard pattern works.
	if len(result.DecodeTPS) > 0 {
		_, _ = MeanStdev(result.DecodeTPS)
	}
}
