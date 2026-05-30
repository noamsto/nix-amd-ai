// Package preflight detects GPU/power/service interference before benchmarking.
// Classifiers are pure functions that accept injected inputs; live gatherers
// (systemctl, ss) are thin wrappers kept separate so unit tests never exec
// real commands.
package preflight

import (
	"bufio"
	"fmt"
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
	// FixCmd builds the command that remediates the issue, or nil when there is
	// none. The TUI runs it via tea.ExecProcess so any sudo auth prompt
	// (password / fingerprint) gets the real terminal instead of corrupting the
	// alt-screen. Headless mode never invokes it. It is a builder (not a built
	// *exec.Cmd) because an exec.Cmd is single-use.
	FixCmd func() *exec.Cmd
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
			FixCmd: setPerformanceCmd(),
		}
	}
	return Result{Name: "power", Status: Pass}
}

// classifyLemond: lemond being UP is what we want — the model picker and HTTP
// bench both need its API, and a loaded model on the GPU is freed automatically
// by the run's evacuation guardrail (gentle unload, no sudo). So the actionable
// problem is lemond being DOWN, which is what we warn on (with a start fixer).
func classifyLemond(service, activeState string) Result {
	if activeState == "active" {
		return Result{Name: "lemond", Status: Pass, Reason: "lemond serving"}
	}
	return Result{
		Name:   "lemond",
		Status: Warn,
		Reason: "lemond not running — needed to list models and serve HTTP bench",
		FixCmd: startLemondCmd(service),
	}
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
// Fixers — build the *exec.Cmd to remediate. The TUI runs them via
// tea.ExecProcess (terminal handed over), so a sudo prompt works cleanly.
// ---------------------------------------------------------------------------

// startLemondCmd builds the command to (re)start the lemond service. `restart`
// (not `start`) so it also recovers a failed unit. Needs sudo for the system
// unit.
func startLemondCmd(service string) func() *exec.Cmd {
	return func() *exec.Cmd {
		return exec.Command("sudo", "systemctl", "restart", service) //nolint:gosec
	}
}

// setPerformanceCmd builds one command that switches the CPU to performance
// mode: writes "performance" to the ACPI platform profile and EVERY core's EPP
// knob. EPP is per-core, so writing only cpu0 is fragile — we write them all.
// Bundled into a single `sudo sh -c` so there is exactly one auth prompt.
func setPerformanceCmd() func() *exec.Cmd {
	return func() *exec.Cmd {
		var sb strings.Builder
		sb.WriteString("echo performance > /sys/firmware/acpi/platform_profile")
		eppKnobs, _ := filepath.Glob("/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference")
		for _, p := range eppKnobs {
			fmt.Fprintf(&sb, "; echo performance > %s", p)
		}
		return exec.Command("sudo", "sh", "-c", sb.String()) //nolint:gosec
	}
}

// ---------------------------------------------------------------------------
// Public entrypoint
// ---------------------------------------------------------------------------

// Run performs all preflight checks and returns the ordered results.
// FixCmd builders are populated but NEVER run here — callers decide whether to invoke.
func Run(info hw.Info, service string) []Result {
	return []Result{
		classifyGPU(info.GRBMBusyPct),
		classifyPower(info.OnAC, info.Performance),
		classifyLemond(service, lemondActiveState(service)),
		classifyCompetingPorts(listListeners()),
	}
}
