package tui

import (
	"os/exec"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

// trueCmd is a harmless fix-command builder for tests.
func trueCmd() func() *exec.Cmd { return func() *exec.Cmd { return exec.Command("true") } }

// ---------------------------------------------------------------------------
// Pure unit tests for renderPreflightLine
// ---------------------------------------------------------------------------

func TestRenderPreflightLinePass(t *testing.T) {
	r := preflight.Result{Name: "gpu-busy", Status: preflight.Pass}
	out := renderPreflightLine(r, newStyles(true))

	if !strings.Contains(out, "✓") {
		t.Errorf("Pass result: expected '✓'; got %q", out)
	}
	if strings.Contains(out, "[s]") || strings.Contains(out, "[p]") {
		t.Errorf("Pass result: unexpected key hint in %q", out)
	}
}

func TestRenderPreflightLineWarnLemond(t *testing.T) {
	r := preflight.Result{
		Name:   "lemond",
		Status: preflight.Warn,
		Reason: "lemond not running — needed to list models",
		FixCmd: trueCmd(),
	}
	out := renderPreflightLine(r, newStyles(true))

	if !strings.Contains(out, "⚠") {
		t.Errorf("Warn result: expected '⚠'; got %q", out)
	}
	if !strings.Contains(out, "[s]") {
		t.Errorf("lemond Warn: expected '[s]' key hint; got %q", out)
	}
}

func TestRenderPreflightLineWarnPower(t *testing.T) {
	r := preflight.Result{
		Name:   "power",
		Status: preflight.Warn,
		Reason: "not in performance mode",
		FixCmd: trueCmd(),
	}
	out := renderPreflightLine(r, newStyles(true))

	if !strings.Contains(out, "⚠") {
		t.Errorf("Warn result: expected '⚠'; got %q", out)
	}
	if !strings.Contains(out, "[p]") {
		t.Errorf("power Warn: expected '[p]' key hint; got %q", out)
	}
}

func TestRenderPreflightLineFail(t *testing.T) {
	r := preflight.Result{
		Name:   "gpu-busy",
		Status: preflight.Fail,
		Reason: "GPU busy: 80%",
	}
	out := renderPreflightLine(r, newStyles(true))

	if !strings.Contains(out, "✗") {
		t.Errorf("Fail result: expected '✗'; got %q", out)
	}
}

func TestRenderPreflightLineWarnNoFix(t *testing.T) {
	// Warn without a fix command → no key hint.
	r := preflight.Result{
		Name:   "competing-port",
		Status: preflight.Warn,
		Reason: "port 11434 held by ollama",
		FixCmd: nil,
	}
	out := renderPreflightLine(r, newStyles(true))

	if !strings.Contains(out, "⚠") {
		t.Errorf("Warn result: expected '⚠'; got %q", out)
	}
	if strings.Contains(out, "[s]") || strings.Contains(out, "[p]") {
		t.Errorf("Warn without fix: unexpected key hint in %q", out)
	}
}

// ---------------------------------------------------------------------------
// Fixer-only-on-keypress invariant
//
// The fix command must NEVER be built during rendering — only when the user
// presses the fixer key (and even then it is handed to tea.ExecProcess, not run
// in-process). We verify by counting builder invocations.
// ---------------------------------------------------------------------------

func TestFixerOnlyOnKeypress(t *testing.T) {
	built := 0
	fakeResult := preflight.Result{
		Name:   "lemond",
		Status: preflight.Warn,
		Reason: "lemond not running",
		FixCmd: func() *exec.Cmd { built++; return exec.Command("true") },
	}

	m := model{
		current:          screenPreflight,
		preflightResults: []preflight.Result{fakeResult},
		preflightLoaded:  true,
	}

	_ = m.View()
	if built != 0 {
		t.Fatalf("FixCmd built %d time(s) during View(); must be 0", built)
	}

	_, cmd := m.Update(tea.KeyPressMsg{Code: 's', Text: "s"})
	if cmd == nil {
		t.Fatal("Update('s') returned nil Cmd; expected a tea.ExecProcess Cmd")
	}
	// Building the command to hand to tea.ExecProcess is expected; the command
	// itself is not executed here (only the bubbletea runtime runs it).
	if built != 1 {
		t.Fatalf("FixCmd built %d time(s) on keypress; want 1", built)
	}

	_ = m.View()
	if built != 1 {
		t.Fatalf("FixCmd built again during second View(); want still 1, got %d", built)
	}
}

func TestFixerPowerKeyOnlyOnKeypress(t *testing.T) {
	built := 0
	fakeResult := preflight.Result{
		Name:   "power",
		Status: preflight.Warn,
		Reason: "not in performance mode",
		FixCmd: func() *exec.Cmd { built++; return exec.Command("true") },
	}

	m := model{
		current:          screenPreflight,
		preflightResults: []preflight.Result{fakeResult},
		preflightLoaded:  true,
	}

	_ = m.View()
	if built != 0 {
		t.Fatalf("FixCmd built during View(); must be 0")
	}

	_, cmd := m.Update(tea.KeyPressMsg{Code: 'p', Text: "p"})
	if cmd == nil {
		t.Fatal("Update('p') returned nil Cmd")
	}
	if built != 1 {
		t.Fatalf("FixCmd built %d time(s) on keypress; want 1", built)
	}
}

// TestFixerKeyIgnoredOnOtherScreens asserts pressing 's' off the preflight
// screen triggers nothing.
func TestFixerKeyIgnoredOnOtherScreens(t *testing.T) {
	built := 0
	fakeResult := preflight.Result{
		Name:   "lemond",
		Status: preflight.Warn,
		FixCmd: func() *exec.Cmd { built++; return exec.Command("true") },
	}

	m := model{
		current:          screenHW, // NOT the preflight screen
		preflightResults: []preflight.Result{fakeResult},
		preflightLoaded:  true,
	}

	_, cmd := m.Update(tea.KeyPressMsg{Code: 's', Text: "s"})
	if cmd != nil {
		t.Fatalf("Update('s') on non-preflight screen returned non-nil Cmd")
	}
	if built != 0 {
		t.Fatalf("FixCmd built on non-preflight screen; must be 0")
	}
}

// TestFixerNotCalledWhenNoFix ensures pressing 's' with no fix command produces
// no Cmd.
func TestFixerNotCalledWhenNoFix(t *testing.T) {
	r := preflight.Result{
		Name:   "lemond",
		Status: preflight.Pass,
		FixCmd: nil, // up and serving — nothing to fix
	}

	m := model{
		current:          screenPreflight,
		preflightResults: []preflight.Result{r},
		preflightLoaded:  true,
	}

	_, cmd := m.Update(tea.KeyPressMsg{Code: 's', Text: "s"})
	if cmd != nil {
		t.Fatalf("Update('s') on result with nil FixCmd returned non-nil Cmd")
	}
}
