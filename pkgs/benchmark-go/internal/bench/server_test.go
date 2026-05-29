package bench

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestWaitReady_OK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	err := waitReady(srv.URL, 2*time.Second)
	if err != nil {
		t.Fatalf("waitReady returned error: %v", err)
	}
}

func TestWaitReady_Timeout(t *testing.T) {
	// Use a non-routable address (unreachable host) with a very short timeout.
	err := waitReady("http://192.0.2.1:9999", 300*time.Millisecond)
	if err == nil {
		t.Fatal("waitReady should have returned an error on unreachable host")
	}
}

func TestWaitReady_NonOKStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	err := waitReady(srv.URL, 400*time.Millisecond)
	if err == nil {
		t.Fatal("waitReady should return error when server returns non-200")
	}
}

// TestStart_EarlyExitDetected spawns a process that exits immediately and
// confirms Start() returns an early-exit error quickly — not after the full
// ReadyTimeout. Guards against the regression where ProcessState (nil until
// Wait) made the early-exit poll a no-op.
func TestStart_EarlyExitDetected(t *testing.T) {
	port, err := FindFreePort()
	if err != nil {
		t.Fatalf("FindFreePort: %v", err)
	}
	srv := NewLlamaServer([]string{"/bin/sh", "-c", "echo boom 1>&2; exit 3"}, port)
	// Long ready timeout: a regression would block here for the full duration.
	srv.ReadyTimeout = 30 * time.Second

	start := time.Now()
	err = srv.Start()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Start should fail when the process exits immediately")
	}
	if !strings.Contains(err.Error(), "exited early") {
		t.Errorf("expected early-exit error, got: %v", err)
	}
	if elapsed > 5*time.Second {
		t.Errorf("early exit took %v; should be detected well before ReadyTimeout", elapsed)
	}
}

// TestStartStop_WaitCalledOnce confirms a healthy server can be started and
// stopped without a double-Wait panic (race detector + clean Stop verify the
// single-Wait coordination between the readiness goroutine and Stop).
func TestStartStop_WaitCalledOnce(t *testing.T) {
	// A process that lives until killed, while a local HTTP server answers
	// /health so Start() sees readiness. We bind the HTTP server to the same
	// port the LlamaServer polls.
	port, err := FindFreePort()
	if err != nil {
		t.Fatalf("FindFreePort: %v", err)
	}
	health := &http.Server{
		Addr: addrForPort(port),
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
		}),
	}
	go func() { _ = health.ListenAndServe() }()
	defer health.Close()

	// Long-lived child process (sleep) — Stop must SIGTERM/SIGKILL it.
	srv := NewLlamaServer([]string{"/bin/sh", "-c", "sleep 60"}, port)
	srv.ReadyTimeout = 10 * time.Second
	srv.TermTimeout = 2 * time.Second

	if err := srv.Start(); err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	if err := srv.Stop(); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
	// Second Stop must be a safe no-op (cmd is nil'd out).
	if err := srv.Stop(); err != nil {
		t.Fatalf("second Stop returned error: %v", err)
	}
}

func addrForPort(port int) string {
	return "127.0.0.1:" + strconv.Itoa(port)
}

func TestFindFreePort(t *testing.T) {
	port, err := FindFreePort()
	if err != nil {
		t.Fatalf("FindFreePort returned error: %v", err)
	}
	if port <= 0 || port > 65535 {
		t.Fatalf("FindFreePort returned invalid port: %d", port)
	}
}
