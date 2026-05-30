package tui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

// ---------------------------------------------------------------------------
// Pure unit tests for renderPreflightLine
// ---------------------------------------------------------------------------

func TestRenderPreflightLinePass(t *testing.T) {
	r := preflight.Result{Name: "gpu-busy", Status: preflight.Pass}
	out := renderPreflightLine(r)

	if !strings.Contains(out, "✓") {
		t.Errorf("Pass result: expected '✓'; got %q", out)
	}
	// No key hint on a passing result.
	if strings.Contains(out, "[") {
		t.Errorf("Pass result: unexpected key hint in %q", out)
	}
}

func TestRenderPreflightLineWarnLemond(t *testing.T) {
	r := preflight.Result{
		Name:   "lemond",
		Status: preflight.Warn,
		Reason: "lemond is serving; may hold a model on the GPU",
		Fix:    func() error { return nil },
	}
	out := renderPreflightLine(r)

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
		Fix:    func() error { return nil },
	}
	out := renderPreflightLine(r)

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
	out := renderPreflightLine(r)

	if !strings.Contains(out, "✗") {
		t.Errorf("Fail result: expected '✗'; got %q", out)
	}
}

func TestRenderPreflightLineWarnNoFix(t *testing.T) {
	// Warn without Fix → no key hint.
	r := preflight.Result{
		Name:   "competing-port",
		Status: preflight.Warn,
		Reason: "port 11434 held by ollama",
		Fix:    nil,
	}
	out := renderPreflightLine(r)

	if !strings.Contains(out, "⚠") {
		t.Errorf("Warn result: expected '⚠'; got %q", out)
	}
	if strings.Contains(out, "[") {
		t.Errorf("Warn without Fix: unexpected key hint in %q", out)
	}
}

// ---------------------------------------------------------------------------
// Fixer-only-on-keypress invariant test
//
// This is the critical correctness test: a Fix closure must NEVER be called
// during rendering, only when the user explicitly presses the fixer key.
// We verify this by:
//  1. Constructing a model with a preloaded preflight result that has a Fix
//     closure incrementing a counter.
//  2. Calling View() (render) — counter must remain 0.
//  3. Sending the fixer key via Update — counter still 0 (Cmd not yet run).
//  4. Invoking the returned tea.Cmd — counter becomes 1.
//  5. Calling View() again — counter still 1.
// ---------------------------------------------------------------------------

func TestFixerOnlyOnKeypress(t *testing.T) {
	fixCalled := 0
	fakeResult := preflight.Result{
		Name:   "lemond",
		Status: preflight.Warn,
		Reason: "lemond is serving",
		Fix: func() error {
			fixCalled++
			return nil
		},
	}

	// Build a model in the preflight screen with the result pre-loaded.
	m := model{
		current:          screenPreflight,
		preflightResults: []preflight.Result{fakeResult},
		preflightLoaded:  true,
	}

	// Render must NOT call Fix.
	_ = m.View()
	if fixCalled != 0 {
		t.Fatalf("Fix called %d time(s) during View(); must be 0", fixCalled)
	}

	// Send 's' key — must produce a non-nil Cmd without calling Fix inline.
	keyMsg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'s'}}
	newModel, cmd := m.Update(keyMsg)
	_ = newModel
	if fixCalled != 0 {
		t.Fatalf("Fix called %d time(s) during Update('s'); must be 0 (Cmd not yet invoked)", fixCalled)
	}
	if cmd == nil {
		t.Fatal("Update('s') returned nil Cmd; expected a Cmd that invokes Fix")
	}

	// Invoke the returned Cmd (simulates bubbletea runtime).
	msg := cmd()
	if fixCalled != 1 {
		t.Fatalf("Fix called %d time(s) after Cmd(); expected exactly 1", fixCalled)
	}

	// The Cmd should return a fixDoneMsg.
	if _, ok := msg.(fixDoneMsg); !ok {
		t.Errorf("Cmd returned %T; expected fixDoneMsg", msg)
	}

	// Render again — Fix must not have been called a second time.
	_ = m.View()
	if fixCalled != 1 {
		t.Fatalf("Fix called %d time(s) after second View(); expected still 1", fixCalled)
	}
}

// TestFixerPowerKeyOnlyOnKeypress mirrors the above for the 'p' (power) key.
func TestFixerPowerKeyOnlyOnKeypress(t *testing.T) {
	fixCalled := 0
	fakeResult := preflight.Result{
		Name:   "power",
		Status: preflight.Warn,
		Reason: "not in performance mode",
		Fix: func() error {
			fixCalled++
			return nil
		},
	}

	m := model{
		current:          screenPreflight,
		preflightResults: []preflight.Result{fakeResult},
		preflightLoaded:  true,
	}

	_ = m.View()
	if fixCalled != 0 {
		t.Fatalf("Fix called during View(); must be 0")
	}

	keyMsg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}}
	_, cmd := m.Update(keyMsg)
	if fixCalled != 0 {
		t.Fatalf("Fix called during Update('p'); must be 0")
	}
	if cmd == nil {
		t.Fatal("Update('p') returned nil Cmd")
	}

	_ = cmd()
	if fixCalled != 1 {
		t.Fatalf("Fix called %d time(s) after Cmd(); expected 1", fixCalled)
	}
}

// TestFixerKeyIgnoredOnOtherScreens asserts that pressing 's' on a non-preflight
// screen does NOT trigger any Fix.
func TestFixerKeyIgnoredOnOtherScreens(t *testing.T) {
	fixCalled := 0
	fakeResult := preflight.Result{
		Name:   "lemond",
		Status: preflight.Warn,
		Fix: func() error {
			fixCalled++
			return nil
		},
	}

	m := model{
		current:          screenHW, // NOT the preflight screen
		preflightResults: []preflight.Result{fakeResult},
		preflightLoaded:  true,
	}

	keyMsg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'s'}}
	_, cmd := m.Update(keyMsg)
	if cmd != nil {
		// Execute the cmd to confirm it doesn't call Fix.
		_ = cmd()
	}
	if fixCalled != 0 {
		t.Fatalf("Fix called on non-preflight screen; must be 0")
	}
}

// TestFixerNotCalledWhenNoFix ensures pressing 's' when the lemond result has
// no Fix (already stopped / passing) produces no Cmd.
func TestFixerNotCalledWhenNoFix(t *testing.T) {
	r := preflight.Result{
		Name:   "lemond",
		Status: preflight.Pass,
		Fix:    nil, // no fixer — already clean
	}

	m := model{
		current:          screenPreflight,
		preflightResults: []preflight.Result{r},
		preflightLoaded:  true,
	}

	keyMsg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'s'}}
	_, cmd := m.Update(keyMsg)
	if cmd != nil {
		t.Fatalf("Update('s') on result with nil Fix returned non-nil Cmd")
	}
}
