package bench

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"syscall"
	"time"
)

const (
	// defaultReadyTimeout is how long to wait for llama-server to become
	// ready — matches Python's LlamaServer default of 300 s.
	defaultReadyTimeout = 300 * time.Second

	// defaultTermTimeout is how long to wait after SIGTERM before SIGKILL —
	// matches Python's LlamaServer default of 10 s.
	defaultTermTimeout = 10 * time.Second

	// pollInterval is how often waitReady polls /health.
	// Polls faster than Python's 0.5s; no behavioral downside.
	pollInterval = 250 * time.Millisecond
)

// FindFreePort binds to :0, reads the kernel-assigned port, and closes.
// The port is briefly racy until the caller binds again, which is fine for
// our subprocess spawn flow — mirrors Python's find_free_port.
func FindFreePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("find free port: %w", err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return port, nil
}

// waitReady polls GET {baseURL}/health every pollInterval until it receives
// HTTP 200 or the deadline expires.
//
// Unlike Python's _wait_ready, the process-exited-early check is the
// responsibility of LlamaServer.Start (it wraps waitReady and can inspect
// cmd.ProcessState). Here we only poll the HTTP endpoint.
func waitReady(baseURL string, timeout time.Duration) error {
	url := baseURL + "/health"
	// Cap each per-attempt HTTP timeout to min(2s, remaining) so callers
	// with short deadlines (tests) don't get stuck inside one dial attempt.
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		remaining := time.Until(deadline)
		perAttempt := 2 * time.Second
		if remaining < perAttempt {
			perAttempt = remaining
		}
		client := &http.Client{Timeout: perAttempt}
		resp, err := client.Get(url) //nolint:noctx
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
			lastErr = fmt.Errorf("HTTP %d", resp.StatusCode)
		} else {
			lastErr = err
		}
		if time.Now().Before(deadline) {
			time.Sleep(pollInterval)
		}
	}
	return fmt.Errorf(
		"llama-server at %s did not become ready within %s (last error: %v)",
		baseURL, timeout, lastErr,
	)
}

// LlamaServer spawns and manages a llama-server subprocess.
// Use Start/Stop (not a context manager as in Python, but equivalent).
type LlamaServer struct {
	Argv         []string
	Port         int
	BaseURL      string
	ReadyTimeout time.Duration
	TermTimeout  time.Duration

	cmd    *exec.Cmd
	stderr *bytes.Buffer
	// waitDone receives the single cmd.Wait() result. The goroutine started
	// in Start() is the sole owner of cmd.Wait(); both waitReadyWithEarlyExit
	// and Stop() drain this channel rather than calling Wait() again, so
	// cmd.Wait() runs exactly once over the server's lifetime.
	waitDone chan error
}

// NewLlamaServer constructs a LlamaServer with the given argv and port,
// using the default ready/term timeouts — mirrors Python's LlamaServer.__init__.
func NewLlamaServer(argv []string, port int) *LlamaServer {
	return &LlamaServer{
		Argv:         argv,
		Port:         port,
		BaseURL:      fmt.Sprintf("http://127.0.0.1:%d", port),
		ReadyTimeout: defaultReadyTimeout,
		TermTimeout:  defaultTermTimeout,
	}
}

// Start spawns the server and waits for it to become ready.
// On failure it calls Stop to clean up.
func (s *LlamaServer) Start() error {
	s.stderr = new(bytes.Buffer)
	s.cmd = exec.Command(s.Argv[0], s.Argv[1:]...) //nolint:gosec
	s.cmd.Stdout = nil                             // DEVNULL
	s.cmd.Stderr = s.stderr

	if err := s.cmd.Start(); err != nil {
		return fmt.Errorf("spawn llama-server: %w", err)
	}

	// Single owner of cmd.Wait(): this goroutine. ProcessState is guaranteed
	// set once a value lands on waitDone, so the early-exit check can read it.
	s.waitDone = make(chan error, 1)
	go func() { s.waitDone <- s.cmd.Wait() }()

	if err := s.waitReadyWithEarlyExit(); err != nil {
		_ = s.Stop()
		return err
	}
	return nil
}

// waitReadyWithEarlyExit polls /health but also detects early process exit via
// the waitDone channel, matching Python's _wait_ready which reads stderr and
// raises on returncode. Reading from waitDone (instead of cmd.ProcessState,
// which is nil until Wait returns) guarantees a fast crash is caught instead
// of burning the full ReadyTimeout.
func (s *LlamaServer) waitReadyWithEarlyExit() error {
	url := s.BaseURL + "/health"
	deadline := time.Now().Add(s.ReadyTimeout)
	var lastErr error
	for time.Now().Before(deadline) {
		// Detect early exit without blocking. Once a value is on waitDone,
		// cmd.Wait() has returned and cmd.ProcessState is populated.
		select {
		case <-s.waitDone:
			return fmt.Errorf(
				"llama-server exited early (code %d) before becoming ready. stderr:\n%s",
				s.cmd.ProcessState.ExitCode(),
				lastN(s.stderr.String(), 2000),
			)
		default:
		}

		remaining := time.Until(deadline)
		perAttempt := 2 * time.Second
		if remaining < perAttempt {
			perAttempt = remaining
		}
		client := &http.Client{Timeout: perAttempt}
		resp, err := client.Get(url) //nolint:noctx
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
			lastErr = fmt.Errorf("HTTP %d", resp.StatusCode)
		} else {
			lastErr = err
		}
		if time.Now().Before(deadline) {
			time.Sleep(pollInterval)
		}
	}
	return fmt.Errorf(
		"llama-server at %s did not become ready within %s (last error: %v)",
		s.BaseURL, s.ReadyTimeout, lastErr,
	)
}

// Stop sends SIGTERM and waits up to TermTimeout, then SIGKILLs if still alive.
// Mirrors Python's LlamaServer.__exit__.
//
// Stop drains the same waitDone channel the readiness goroutine feeds, so
// cmd.Wait() is never called a second time. If the process already exited
// (waitReadyWithEarlyExit consumed the value), ProcessState is set and Stop
// returns without signaling.
func (s *LlamaServer) Stop() error {
	if s.cmd == nil || s.cmd.Process == nil {
		return nil
	}
	defer func() { s.cmd = nil }()

	// If cmd.Wait() already returned (ProcessState set), the process is gone
	// and waitDone has already been drained — nothing to signal or wait on.
	if s.cmd.ProcessState != nil {
		return nil
	}

	_ = s.cmd.Process.Signal(syscall.SIGTERM)

	select {
	case <-s.waitDone:
		// Exited cleanly after SIGTERM.
	case <-time.After(s.TermTimeout):
		fmt.Fprintln(os.Stderr, "WARNING: llama-server did not exit on SIGTERM; sending SIGKILL")
		_ = s.cmd.Process.Kill()
		<-s.waitDone
	}
	return nil
}

// lastN returns the last n bytes of s as a string.
func lastN(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
