package preflight

import (
	"os"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Status.String
// ---------------------------------------------------------------------------

func TestStatusString(t *testing.T) {
	cases := map[Status]string{
		Pass: "Pass",
		Warn: "Warn",
		Fail: "Fail",
	}
	for s, want := range cases {
		if got := s.String(); got != want {
			t.Errorf("Status(%d).String() = %q, want %q", int(s), got, want)
		}
	}
}

// ---------------------------------------------------------------------------
// classifyGPU
// ---------------------------------------------------------------------------

func TestClassifyGPU_pass(t *testing.T) {
	r := classifyGPU(0)
	if r.Status != Pass {
		t.Errorf("classifyGPU(0).Status = %v, want Pass", r.Status)
	}
}

func TestClassifyGPU_passAtThreshold(t *testing.T) {
	// 5% is the boundary — not strictly greater, so still passes.
	r := classifyGPU(5)
	if r.Status != Pass {
		t.Errorf("classifyGPU(5).Status = %v, want Pass", r.Status)
	}
}

func TestClassifyGPU_fail(t *testing.T) {
	r := classifyGPU(42)
	if r.Status != Fail {
		t.Errorf("classifyGPU(42).Status = %v, want Fail", r.Status)
	}
	if r.FixCmd != nil {
		t.Error("classifyGPU should have no fixer (can't free someone else's GPU work)")
	}
	if r.Reason == "" {
		t.Error("classifyGPU Fail should have a non-empty Reason")
	}
}

func TestClassifyGPU_failJustAboveThreshold(t *testing.T) {
	r := classifyGPU(5.1)
	if r.Status != Fail {
		t.Errorf("classifyGPU(5.1).Status = %v, want Fail", r.Status)
	}
}

// ---------------------------------------------------------------------------
// classifyPower
// ---------------------------------------------------------------------------

func TestClassifyPower_pass(t *testing.T) {
	r := classifyPower(true, true)
	if r.Status != Pass {
		t.Errorf("classifyPower(AC=true, perf=true).Status = %v, want Pass", r.Status)
	}
	if r.FixCmd != nil {
		t.Error("Pass result should not have a Fix")
	}
}

func TestClassifyPower_warnBattery(t *testing.T) {
	r := classifyPower(false, false)
	if r.Status != Warn {
		t.Errorf("classifyPower(AC=false, perf=false).Status = %v, want Warn", r.Status)
	}
	// No fixer: can't plug in the cable automatically.
	if r.FixCmd != nil {
		t.Error("battery warning should have no fixer")
	}
}

func TestClassifyPower_warnNotPerformance(t *testing.T) {
	r := classifyPower(true, false)
	if r.Status != Warn {
		t.Errorf("classifyPower(AC=true, perf=false).Status = %v, want Warn", r.Status)
	}
	if r.FixCmd == nil {
		t.Error("AC + non-performance should provide a Fix")
	}
}

func TestClassifyPower_warnBatteryPerformance(t *testing.T) {
	// On battery even if performance flag claims true: still Warn, no fixer.
	r := classifyPower(false, true)
	if r.Status != Warn {
		t.Errorf("classifyPower(AC=false, perf=true).Status = %v, want Warn", r.Status)
	}
}

// ---------------------------------------------------------------------------
// classifyLemond
// ---------------------------------------------------------------------------

// Flipped semantics: lemond UP is good (Pass, no fixer); lemond DOWN is the
// actionable problem (Warn + a start fixer).
func TestClassifyLemond_passWhenActive(t *testing.T) {
	r := classifyLemond("lemond.service", "active")
	if r.Status != Pass {
		t.Errorf("classifyLemond(active).Status = %v, want Pass", r.Status)
	}
	if r.FixCmd != nil {
		t.Error("classifyLemond(active) should have no fixer")
	}
}

func TestClassifyLemond_warnWhenDown(t *testing.T) {
	for _, state := range []string{"inactive", "failed", "unknown", ""} {
		r := classifyLemond("lemond.service", state)
		if r.Status != Warn {
			t.Errorf("classifyLemond(%q).Status = %v, want Warn", state, r.Status)
		}
		if r.FixCmd == nil {
			t.Errorf("classifyLemond(%q).FixCmd should be non-nil (start fixer)", state)
		}
		if r.Reason == "" {
			t.Errorf("classifyLemond(%q).Reason should be non-empty", state)
		}
	}
}

// ---------------------------------------------------------------------------
// classifyCompetingPorts
// ---------------------------------------------------------------------------

func TestClassifyCompetingPorts_empty(t *testing.T) {
	r := classifyCompetingPorts(nil)
	if r.Status != Pass {
		t.Errorf("no listeners: Status = %v, want Pass", r.Status)
	}
}

func TestClassifyCompetingPorts_lemondOnly(t *testing.T) {
	listeners := []Listener{
		{Port: 13305, Proc: "lemond"},
		{Port: 9000, Proc: "lemond"},
	}
	r := classifyCompetingPorts(listeners)
	// lemond ports are not in watchedPorts; should pass cleanly.
	if r.Status != Pass {
		t.Errorf("lemond-only listeners: Status = %v, want Pass", r.Status)
	}
}

func TestClassifyCompetingPorts_kokoOnWatchedPort(t *testing.T) {
	listeners := []Listener{
		{Port: 8001, Proc: "llama-server"},
	}
	r := classifyCompetingPorts(listeners)
	if r.Status != Warn {
		t.Errorf("llama-server on :8001: Status = %v, want Warn", r.Status)
	}
	if r.FixCmd != nil {
		t.Error("competing port should have no fixer (don't kill user processes)")
	}
	if r.Reason == "" {
		t.Error("competing port Warn should have a non-empty Reason")
	}
}

func TestClassifyCompetingPorts_lemondOnWatchedPortIsNotCompeting(t *testing.T) {
	// If lemond itself were somehow on :8001, it would NOT be flagged.
	listeners := []Listener{
		{Port: 8001, Proc: "lemond"},
	}
	r := classifyCompetingPorts(listeners)
	if r.Status != Pass {
		t.Errorf("lemond on watched port should not be flagged: Status = %v", r.Status)
	}
}

func TestClassifyCompetingPorts_unwatchedPort(t *testing.T) {
	// Port not in watchedPorts should not trigger a warning.
	listeners := []Listener{
		{Port: 22, Proc: "sshd"},
	}
	r := classifyCompetingPorts(listeners)
	if r.Status != Pass {
		t.Errorf("sshd on :22 should not be competing: Status = %v", r.Status)
	}
}

func TestClassifyCompetingPorts_ollamaWatched(t *testing.T) {
	listeners := []Listener{
		{Port: 11434, Proc: "ollama"},
	}
	r := classifyCompetingPorts(listeners)
	if r.Status != Warn {
		t.Errorf("ollama on :11434: Status = %v, want Warn", r.Status)
	}
}

// ---------------------------------------------------------------------------
// parseSSOutput — against the captured fixture and synthetic inputs
// ---------------------------------------------------------------------------

func TestParseSSOutput_fixture(t *testing.T) {
	data, err := os.ReadFile("testdata/ss_ltnp.txt")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	listeners := parseSSOutput(string(data))

	// We expect lemond on 13305 (both IPv4 and IPv6) and lemond on 9000,
	// plus llama-server on 8001. Lines without users:((...)) are skipped.
	findListener := func(port int, proc string) bool {
		for _, l := range listeners {
			if l.Port == port && l.Proc == proc {
				return true
			}
		}
		return false
	}

	if !findListener(13305, "lemond") {
		t.Errorf("expected lemond on port 13305; got %v", listeners)
	}
	if !findListener(9000, "lemond") {
		t.Errorf("expected lemond on port 9000; got %v", listeners)
	}
	if !findListener(8001, "llama-server") {
		t.Errorf("expected llama-server on port 8001; got %v", listeners)
	}

	// Verify koko (llama-server) on :8001 is flagged as competing.
	r := classifyCompetingPorts(listeners)
	if r.Status != Warn {
		t.Errorf("fixture listeners: expected Warn for llama-server on :8001, got %v", r.Status)
	}
}

func TestParseSSOutput_empty(t *testing.T) {
	listeners := parseSSOutput("")
	if len(listeners) != 0 {
		t.Errorf("empty input: got %d listeners, want 0", len(listeners))
	}
}

func TestParseSSOutput_headerOnly(t *testing.T) {
	input := "State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process\n"
	listeners := parseSSOutput(input)
	if len(listeners) != 0 {
		t.Errorf("header-only: got %d listeners, want 0", len(listeners))
	}
}

func TestParseSSOutput_noProcessColumn(t *testing.T) {
	// Lines without users:((…)) are still emitted, with Proc=="" (ss without
	// sudo hides PIDs). classifyCompetingPorts filters unwatched ports, so this
	// adds no noise for ordinary services like cups on :631.
	input := "LISTEN 0 4096 127.0.0.1:631 0.0.0.0:*\n"
	listeners := parseSSOutput(input)
	if len(listeners) != 1 {
		t.Fatalf("no process column: got %v, want 1 listener with empty Proc", listeners)
	}
	if listeners[0].Port != 631 || listeners[0].Proc != "" {
		t.Errorf("listeners[0] = %+v, want {631, \"\"}", listeners[0])
	}
}

// TestParseSSOutput_watchedPortNoOwner is the key regression for issue #2: a
// process-less LISTEN line on a watched port (8001) must still warn.
func TestParseSSOutput_watchedPortNoOwner(t *testing.T) {
	input := "LISTEN 0 512 127.0.0.1:8001 0.0.0.0:*\n"
	listeners := parseSSOutput(input)
	if len(listeners) != 1 {
		t.Fatalf("got %v, want 1 listener", listeners)
	}
	r := classifyCompetingPorts(listeners)
	if r.Status != Warn {
		t.Errorf("unknown owner on :8001: Status = %v, want Warn", r.Status)
	}
	if !strings.Contains(r.Reason, "unknown") {
		t.Errorf("reason should mention 'unknown', got %q", r.Reason)
	}
}

// TestParseSSOutput_ipv6Bracket pins port extraction from the IPv6 bracket
// form so a fixture regen can't silently drop coverage.
func TestParseSSOutput_ipv6Bracket(t *testing.T) {
	input := `LISTEN 0 5 [::1]:13305 [::]:* users:(("lemond",pid=3988,fd=9))`
	listeners := parseSSOutput(input)
	if len(listeners) != 1 {
		t.Fatalf("got %v, want 1 listener", listeners)
	}
	if listeners[0].Port != 13305 || listeners[0].Proc != "lemond" {
		t.Errorf("listeners[0] = %+v, want {13305, lemond}", listeners[0])
	}
}

// TestParseSSOutput_wildcard pins port extraction from the wildcard form *:PORT.
func TestParseSSOutput_wildcard(t *testing.T) {
	input := `LISTEN 0 10 *:1716 *:* users:((".valent-wrapped",pid=8731,fd=11))`
	listeners := parseSSOutput(input)
	if len(listeners) != 1 {
		t.Fatalf("got %v, want 1 listener", listeners)
	}
	if listeners[0].Port != 1716 || listeners[0].Proc != ".valent-wrapped" {
		t.Errorf("listeners[0] = %+v, want {1716, .valent-wrapped}", listeners[0])
	}
}

func TestParseSSOutput_minimal(t *testing.T) {
	input := `State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process
LISTEN 0      512     127.0.0.1:8001      0.0.0.0:*          users:(("llama-server",pid=1823914,fd=12))
LISTEN 0      5       127.0.0.1:13305     0.0.0.0:*          users:(("lemond",pid=3988,fd=8))
`
	listeners := parseSSOutput(input)
	if len(listeners) != 2 {
		t.Fatalf("got %d listeners, want 2: %v", len(listeners), listeners)
	}
	if listeners[0].Port != 8001 || listeners[0].Proc != "llama-server" {
		t.Errorf("listeners[0] = %+v, want {8001, llama-server}", listeners[0])
	}
	if listeners[1].Port != 13305 || listeners[1].Proc != "lemond" {
		t.Errorf("listeners[1] = %+v, want {13305, lemond}", listeners[1])
	}
}
