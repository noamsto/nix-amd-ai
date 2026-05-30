package bench

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
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
	result := MeasureSpec(context.Background(), srv.URL, "/v1/completions", "test-model", o)

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
	result := MeasureSpec(context.Background(), srv.URL, "/v1/completions", "m", o)

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
	result := MeasureSpec(context.Background(), srv.URL, "/v1/completions", "m", o)

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
	MeasureSpec(context.Background(), srv.URL, "/v1/completions", "m", o)

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
	MeasureSpec(context.Background(), srv.URL, "/v1/completions", "m", o)
	if calls != 0 {
		t.Errorf("expected 0 callbacks for no-token iterations, got %d", calls)
	}
}

func TestMeasureSpec_CtxCancelledBeforeStart(t *testing.T) {
	// An already-cancelled ctx must yield zero samples without hitting the
	// server (the loop guards break before runOneCompletion).
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, cannedSSE(4, 64, 42.0))
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel up-front

	o := MeasureOpts{PromptTokens: 8, GenTokens: 64, Warmup: 1, Repeat: 3}
	result := MeasureSpec(ctx, srv.URL, "/v1/completions", "m", o)

	if len(result.DecodeTPS) != 0 {
		t.Errorf("expected 0 samples on cancelled ctx, got %d", len(result.DecodeTPS))
	}
	if hits != 0 {
		t.Errorf("expected 0 server hits on cancelled ctx, got %d", hits)
	}
}

func TestMeasureSpec_CtxCancelInterruptsHTTP(t *testing.T) {
	// A ctx cancelled mid-flight interrupts the in-flight streaming HTTP call,
	// so the call returns promptly (well under the 300s completion timeout)
	// rather than blocking. The server hangs after the first chunk.
	ctx, cancel := context.WithCancel(context.Background())
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		// Cancel the client ctx, then block until the request context is done.
		cancel()
		<-r.Context().Done()
	}))
	defer srv.Close()

	o := MeasureOpts{PromptTokens: 8, GenTokens: 64, Warmup: 0, Repeat: 1}
	done := make(chan struct{})
	go func() {
		MeasureSpec(ctx, srv.URL, "/v1/completions", "m", o)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("MeasureSpec did not return after ctx cancel; HTTP call was not interrupted")
	}
}

// TestLogWriterNilIsStderr verifies the nil→os.Stderr default contract.
func TestLogWriterNilIsStderr(t *testing.T) {
	if got := logWriter(nil); got != os.Stderr {
		t.Errorf("logWriter(nil) = %v, want os.Stderr", got)
	}
}

// TestLogWriterNonNilPassthrough verifies a non-nil writer is returned as-is.
func TestLogWriterNonNilPassthrough(t *testing.T) {
	var buf bytes.Buffer
	if got := logWriter(&buf); got != &buf {
		t.Errorf("logWriter(&buf) returned a different writer")
	}
}

// TestMeasureSpec_LogWRoutesPhaseLog verifies that when LogW is set and PhaseLog
// is true, the "Warming up"/"Measuring" lines land in LogW and NOT on os.Stderr.
func TestMeasureSpec_LogWRoutesPhaseLog(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, cannedSSE(4, 64, 42.0))
	}))
	defer srv.Close()

	var buf bytes.Buffer
	o := MeasureOpts{
		PromptTokens: 8,
		GenTokens:    64,
		Warmup:       1,
		Repeat:       2,
		PhaseLog:     true,
		LogW:         &buf,
	}
	MeasureSpec(context.Background(), srv.URL, "/v1/completions", "m", o)

	got := buf.String()
	if !strings.Contains(got, "Warming up") {
		t.Errorf("LogW missing 'Warming up'; got: %q", got)
	}
	if !strings.Contains(got, "Measuring") {
		t.Errorf("LogW missing 'Measuring'; got: %q", got)
	}
}

// TestMeasureSpec_LogWNilDefaultsToStderr verifies nil LogW compiles and runs
// without panic (the default os.Stderr path is exercised implicitly by existing
// tests that pass nil LogW).
func TestMeasureSpec_LogWNilDefaultsToStderr(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, cannedSSE(4, 64, 42.0))
	}))
	defer srv.Close()

	// LogW deliberately omitted (nil) — must not panic and must return samples.
	o := MeasureOpts{PromptTokens: 8, GenTokens: 64, Warmup: 0, Repeat: 1}
	result := MeasureSpec(context.Background(), srv.URL, "/v1/completions", "m", o)
	if len(result.DecodeTPS) != 1 {
		t.Errorf("expected 1 sample with nil LogW, got %d", len(result.DecodeTPS))
	}
}

// TestMeasureSpec_LogWDiscard verifies io.Discard silences all output.
func TestMeasureSpec_LogWDiscard(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		// Return no tokens so the no-token warning fires.
		_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"text\":\"\"}]}\n\ndata: [DONE]\n\n")
	}))
	defer srv.Close()

	// Should complete without panic; io.Discard absorbs the WARNING lines.
	o := MeasureOpts{
		PromptTokens: 8,
		GenTokens:    64,
		Warmup:       0,
		Repeat:       2,
		PhaseLog:     true,
		LogW:         io.Discard,
	}
	result := MeasureSpec(context.Background(), srv.URL, "/v1/completions", "m", o)
	if len(result.DecodeTPS) != 0 {
		t.Errorf("expected 0 samples (no-token server), got %d", len(result.DecodeTPS))
	}
}
