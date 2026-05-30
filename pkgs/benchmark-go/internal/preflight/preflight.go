// Package preflight detects GPU/power/service interference before benchmarking.
// Classifiers are pure functions that accept injected inputs; live gatherers
// (systemctl, ss) are thin wrappers kept separate so unit tests never exec
// real commands.
package preflight

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

type Status int

const (
	Pass Status = iota
	Warn
	Fail
)

func (s Status) String() string {
	switch s {
	case Pass:
		return "Pass"
	case Warn:
		return "Warn"
	case Fail:
		return "Fail"
	default:
		return fmt.Sprintf("Status(%d)", int(s))
	}
}

type Result struct {
	Name   string
	Status Status
	Reason string
	// Fix is non-nil when the issue can be remediated automatically.
	// Headless mode NEVER calls Fix; it is reserved for the interactive TUI (Phase 5).
	Fix func() error
}

type Listener struct {
	Port int
	Proc string // best-effort process name; "" when unknown
}

// ---------------------------------------------------------------------------
// Pure classifiers — all accept injected inputs; no exec, no filesystem I/O.
// ---------------------------------------------------------------------------

// No fixer: cannot safely free someone else's GPU work.
func classifyGPU(grbmBusyPct float64) Result {
	if grbmBusyPct > 5 {
		return Result{
			Name:   "gpu-busy",
			Status: Fail,
			Reason: fmt.Sprintf("GPU busy: %.0f%%", grbmBusyPct),
		}
	}
	return Result{Name: "gpu-busy", Status: Pass}
}

// classifyPower returns Pass when on AC and in performance mode.
// Returns Warn for battery or non-performance mode; the performance fixer is
// attached when the fix is actionable (on AC but wrong power profile).
func classifyPower(onAC, performance bool) Result {
	if !onAC {
		return Result{
			Name:   "power",
			Status: Warn,
			Reason: "on battery; TLP throttles to powersave",
		}
	}
	if !performance {
		return Result{
			Name:   "power",
			Status: Warn,
			Reason: "not in performance mode",
			Fix:    setPerformance(),
		}
	}
	return Result{Name: "power", Status: Pass}
}

func classifyLemond(service, activeState string) Result {
	if activeState == "active" {
		return Result{
			Name:   "lemond",
			Status: Warn,
			Reason: "lemond is serving; may hold a model on the GPU",
			Fix:    stopLemond(service),
		}
	}
	return Result{Name: "lemond", Status: Pass}
}

// watchedPorts is the set of ports we consider "competing" (i.e. likely GPU
// inference servers). The lemond ports (13305, 9000) are excluded — lemond is
// handled separately by classifyLemond.
var watchedPorts = map[int]bool{
	8001:  true, // koko / other llama-server instances
	11434: true, // ollama
}

// classifyCompetingPorts returns Warn when any Listener is on a watched port
// and is NOT owned by lemond. No auto-fixer: we never kill user processes.
func classifyCompetingPorts(listeners []Listener) Result {
	for _, l := range listeners {
		if !watchedPorts[l.Port] {
			continue
		}
		if l.Proc == "lemond" {
			continue
		}
		proc := l.Proc
		if proc == "" {
			proc = "unknown"
		}
		return Result{
			Name:   "competing-port",
			Status: Warn,
			Reason: fmt.Sprintf("port %d held by %s", l.Port, proc),
		}
	}
	return Result{Name: "competing-port", Status: Pass}
}

// ---------------------------------------------------------------------------
// Pure parser — unit-tested against a captured ss -ltnp sample.
// ---------------------------------------------------------------------------

// parseSSOutput parses the stdout of `ss -ltnp` and returns every listening TCP
// socket. The owning process name is extracted from the users:((...)) column
// when present; when absent (e.g. ss run without sudo cannot see the PID) the
// Listener is still emitted with Proc=="" so a watched port held by an
// unknown owner is not silently dropped. classifyCompetingPorts filters to the
// watched-port set, so unknown-owner sockets on unwatched ports add no noise.
//
// Expected format (header line is skipped):
//
//	State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port  Process
//	LISTEN 0      512     127.0.0.1:8001      0.0.0.0:*          users:(("llama-server",pid=1823914,fd=12))
//
// The process name is extracted from users:(("<name>",…)).
func parseSSOutput(output string) []Listener {
	var out []Listener
	sc := bufio.NewScanner(strings.NewReader(output))
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "LISTEN") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		addrPort := fields[3]
		portStr := addrPort
		if idx := strings.LastIndex(addrPort, ":"); idx >= 0 {
			portStr = addrPort[idx+1:]
		}
		port, err := strconv.Atoi(portStr)
		if err != nil {
			continue
		}

		procName := ""
		rest := strings.Join(fields[5:], " ")
		if idx := strings.Index(rest, `users:((`); idx >= 0 {
			after := rest[idx+len(`users:(("`):]
			if end := strings.IndexByte(after, '"'); end >= 0 {
				procName = after[:end]
			}
		}

		// Emit even when procName=="" (ss without sudo hides the PID): a
		// watched port with an unknown owner must still be flagged.
		out = append(out, Listener{Port: port, Proc: procName})
	}
	return out
}

// ---------------------------------------------------------------------------
// Live gatherers — thin wrappers; not unit-tested directly.
// ---------------------------------------------------------------------------

func lemondActiveState(service string) string {
	out, _ := exec.Command("systemctl", "is-active", service).Output()
	return strings.TrimSpace(string(out))
}

func listListeners() []Listener {
	out, err := exec.Command("ss", "-ltnp").Output()
	if err != nil {
		return nil
	}
	return parseSSOutput(string(out))
}

// ---------------------------------------------------------------------------
// Fixers — return a func() error; called only from the interactive TUI (Phase 5).
// ---------------------------------------------------------------------------

// stopLemond returns a fixer that stops the given systemd service via sudo.
// Stdout/Stderr are not wired to os.Stdout: the interactive TUI invokes this
// fixer while bubbletea owns the terminal, so any child output would corrupt
// the render. systemctl stop is quiet on success; stderr is captured into the
// returned error.
func stopLemond(service string) func() error {
	return func() error {
		cmd := exec.Command("sudo", "systemctl", "stop", service)
		var stderr bytes.Buffer
		cmd.Stdout = io.Discard
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			if msg := strings.TrimSpace(stderr.String()); msg != "" {
				return fmt.Errorf("stopping %s: %w: %s", service, err, msg)
			}
			return fmt.Errorf("stopping %s: %w", service, err)
		}
		return nil
	}
}

// setPerformance returns a fixer that switches the CPU to performance mode.
// Writes "performance" to:
//   - /sys/firmware/acpi/platform_profile (single system-wide knob)
//   - every core's energy_performance_preference
//     (/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference)
//
// EPP is per-core: writing only cpu0 leaves the other cores at their old EPP,
// which is fragile and may not reflect as a real performance switch. We write
// every core. All writes use sudo tee so no special binary capability is
// required.
func setPerformance() func() error {
	return func() error {
		if err := writeSysfsPerformance("/sys/firmware/acpi/platform_profile"); err != nil {
			return err
		}
		eppKnobs, _ := filepath.Glob("/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference")
		for _, path := range eppKnobs {
			if err := writeSysfsPerformance(path); err != nil {
				return err
			}
		}
		return nil
	}
}

// writeSysfsPerformance writes "performance" to a sysfs path via sudo tee.
// Stdout is discarded (NOT os.Stdout): tee echoes its input, which would
// scribble over the bubbletea render when the TUI invokes this fixer. Stderr
// is captured and folded into the returned error.
func writeSysfsPerformance(path string) error {
	cmd := exec.Command("sudo", "tee", path)
	cmd.Stdin = strings.NewReader("performance")
	cmd.Stdout = io.Discard
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return fmt.Errorf("writing %s: %w: %s", path, err, msg)
		}
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Public entrypoint
// ---------------------------------------------------------------------------

// Run performs all preflight checks and returns the ordered results.
// Fix fields are populated but NEVER called here — callers decide whether to invoke.
func Run(info hw.Info, service string) []Result {
	return []Result{
		classifyGPU(info.GRBMBusyPct),
		classifyPower(info.OnAC, info.Performance),
		classifyLemond(service, lemondActiveState(service)),
		classifyCompetingPorts(listListeners()),
	}
}
