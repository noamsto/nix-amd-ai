package bench

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

const (
	defaultReadyTimeout = 300 * time.Second
	defaultTermTimeout  = 10 * time.Second
	pollInterval        = 250 * time.Millisecond
)

// FindFreePort binds to :0, reads the kernel-assigned port, and closes.
// The port is briefly racy until the caller binds again — fine for subprocess spawn.
func FindFreePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("find free port: %w", err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return port, nil
}

// waitReady polls GET {baseURL}/health every pollInterval until HTTP 200 or deadline.
// Process-exited-early detection is the caller's responsibility (see waitReadyWithEarlyExit).
func waitReady(baseURL string, timeout time.Duration) error {
	url := baseURL + "/health"
	// Cap each per-attempt HTTP timeout to min(2s, remaining) so callers
	// with short deadlines (tests) don't get stuck inside one dial attempt.
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		remaining := time.Until(deadline)
		perAttempt := min(remaining, 2*time.Second)
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
		"llama-server at %s did not become ready within %s (last error: %w)",
		baseURL, timeout, lastErr,
	)
}

// LlamaServer spawns and manages a llama-server subprocess.
type LlamaServer struct {
	Argv         []string
	Port         int
	BaseURL      string
	ReadyTimeout time.Duration
	TermTimeout  time.Duration
	// LogW is the destination for Stop's SIGKILL warning. nil → os.Stderr.
	LogW io.Writer

	cmd    *exec.Cmd
	stderr *syncBuffer
	// waitDone receives the single cmd.Wait() result. The goroutine started
	// in Start() is the sole owner of cmd.Wait(); both waitReadyWithEarlyExit
	// and Stop() drain this channel rather than calling Wait() again, so
	// cmd.Wait() runs exactly once over the server's lifetime.
	waitDone chan error
	// waitFinished is closed once cmd.Wait() has returned. Stop() selects on it
	// instead of reading cmd.ProcessState, which Wait() writes concurrently.
	waitFinished chan struct{}
}

// syncBuffer is a bytes.Buffer that outlives the Wait() goroutine's writes:
// os/exec copies the child's stderr into it from its own goroutine while
// waitReadyWithEarlyExit may read it from the polling goroutine.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

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
	s.stderr = new(syncBuffer)
	s.cmd = exec.Command(s.Argv[0], s.Argv[1:]...) //nolint:gosec
	s.cmd.Stdout = nil                             // DEVNULL
	s.cmd.Stderr = s.stderr

	if err := s.cmd.Start(); err != nil {
		return fmt.Errorf("spawn llama-server: %w", err)
	}

	// Single owner of cmd.Wait(): this goroutine. It closes waitFinished before
	// publishing the result, so Stop() can tell that Wait() returned without
	// reading cmd.ProcessState while Wait() is still writing it.
	s.waitDone = make(chan error, 1)
	s.waitFinished = make(chan struct{})
	go func() {
		err := s.cmd.Wait()
		close(s.waitFinished)
		s.waitDone <- err
	}()

	if err := s.waitReadyWithEarlyExit(); err != nil {
		_ = s.Stop()
		return err
	}
	return nil
}

// waitReadyWithEarlyExit polls /health but also detects early process exit via
// waitDone. Reading from waitDone (instead of cmd.ProcessState, which is nil until
// Wait returns) guarantees a fast crash is caught instead of burning the full ReadyTimeout.
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
		perAttempt := min(remaining, 2*time.Second)
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
	// Server is still alive but never went ready (e.g. GPU starved by another
	// process, stuck fitting params). Include its stderr tail so the failure is
	// diagnosable instead of a bare "HTTP 503".
	return fmt.Errorf(
		"llama-server at %s did not become ready within %s (last error: %w). stderr:\n%s",
		s.BaseURL, s.ReadyTimeout, lastErr, lastN(s.stderr.String(), 2000),
	)
}

// Stop sends SIGTERM and waits up to TermTimeout, then SIGKILLs if still alive.
// Drains the same waitDone channel the goroutine feeds, so cmd.Wait() is called exactly once.
func (s *LlamaServer) Stop() error {
	if s.cmd == nil || s.cmd.Process == nil {
		return nil
	}
	defer func() { s.cmd = nil }()

	// If cmd.Wait() already returned, the process is gone and waitDone has
	// already been drained — nothing to signal or wait on. Selecting on the
	// closed waitFinished channel is the race-free equivalent of reading
	// cmd.ProcessState, which Wait() may be writing concurrently.
	select {
	case <-s.waitFinished:
		return nil
	default:
	}

	_ = s.cmd.Process.Signal(syscall.SIGTERM)

	select {
	case <-s.waitDone:
		// Exited cleanly after SIGTERM.
	case <-time.After(s.TermTimeout):
		_, _ = fmt.Fprintln(logWriter(s.LogW), "WARNING: llama-server did not exit on SIGTERM; sending SIGKILL")
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
