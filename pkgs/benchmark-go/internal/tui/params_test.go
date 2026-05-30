package tui

import (
	"bytes"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/exp/teatest/v2"
)

// --- parseIntField ---

func TestParseIntField(t *testing.T) {
	cases := []struct {
		name     string
		s        string
		fallback int
		want     int
	}{
		{"normal", "4096", 1, 4096},
		{"zero uses fallback", "0", 1, 1},
		{"empty uses fallback", "", 1, 1},
		{"non-digit uses fallback", "abc", 1, 1},
		{"single digit", "3", 1, 3},
		{"large number", "999999", 1, 999999},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseIntField(tc.s, tc.fallback)
			if got != tc.want {
				t.Errorf("parseIntField(%q, %d) = %d; want %d", tc.s, tc.fallback, got, tc.want)
			}
		})
	}
}

// TestParseIntField_BackspaceSimulation simulates building "4096" character by
// character, then backspacing once to get "409".
func TestParseIntField_BackspaceSimulation(t *testing.T) {
	buf := ""
	for _, ch := range "4096" {
		buf += string(ch)
	}
	if parseIntField(buf, 1) != 4096 {
		t.Fatalf("after typing 4096: got %d; want 4096", parseIntField(buf, 1))
	}

	// Backspace: remove last rune.
	buf = deleteLastChar(buf)
	if parseIntField(buf, 1) != 409 {
		t.Errorf("after backspace: got %d; want 409", parseIntField(buf, 1))
	}

	// Backspace everything.
	for len(buf) > 0 {
		buf = deleteLastChar(buf)
	}
	// Empty string → fallback (1).
	if parseIntField(buf, 1) != 1 {
		t.Errorf("after clearing: got %d; want 1 (fallback)", parseIntField(buf, 1))
	}
}

// --- renderParamsField ---

func TestRenderParamsField(t *testing.T) {
	t.Run("focused field has cursor", func(t *testing.T) {
		out := renderParamsField("Ctx:", "2048", true, false)
		if !stringContains(out, "> ") {
			t.Errorf("focused field should contain '> ', got %q", out)
		}
		if !stringContains(out, "Ctx:") {
			t.Errorf("field label missing in %q", out)
		}
		if !stringContains(out, "2048") {
			t.Errorf("field value missing in %q", out)
		}
	})

	t.Run("unfocused field has no cursor", func(t *testing.T) {
		out := renderParamsField("Repeat:", "3", false, false)
		if stringContains(out, "> ") {
			t.Errorf("unfocused field should not have '> ', got %q", out)
		}
	})

	t.Run("suggested field shows hint", func(t *testing.T) {
		out := renderParamsField("Ctx:", "2048", true, true)
		if !stringContains(out, "suggested") {
			t.Errorf("suggested field should show hint, got %q", out)
		}
	})

	t.Run("non-suggested field has no hint", func(t *testing.T) {
		out := renderParamsField("Repeat:", "3", false, false)
		if stringContains(out, "suggested") {
			t.Errorf("non-suggested field should not show hint, got %q", out)
		}
	})
}

// --- enterParamsScreen prefill ---

func TestEnterParamsScreen_Prefill(t *testing.T) {
	t.Run("known model size pre-fills ctx from advise", func(t *testing.T) {
		var f paramsForm
		// 15.7 GiB → advise.RecommendParams(15.7).Ctx == 2048
		enterParamsScreen(&f, 15.7)

		if f.ctx != "2048" {
			t.Errorf("ctx = %q; want 2048", f.ctx)
		}
		if !f.ctxSuggested {
			t.Error("ctxSuggested should be true after enterParamsScreen")
		}
		if f.repeat != "3" {
			t.Errorf("repeat = %q; want 3", f.repeat)
		}
		if f.warmup != "1" {
			t.Errorf("warmup = %q; want 1", f.warmup)
		}
		if f.backends != "rocm,vulkan" {
			t.Errorf("backends = %q; want rocm,vulkan", f.backends)
		}
		if f.focused != fieldCtx {
			t.Errorf("focused = %d; want fieldCtx (%d)", f.focused, fieldCtx)
		}
	})

	t.Run("zero size still prefills ctx (advise default 2048)", func(t *testing.T) {
		var f paramsForm
		enterParamsScreen(&f, 0)
		if f.ctx != "2048" {
			t.Errorf("ctx = %q; want 2048 for zero-size fallback", f.ctx)
		}
	})
}

// --- runParams ---

func TestRunParams(t *testing.T) {
	f := paramsForm{
		ctx:      "4096",
		repeat:   "5",
		warmup:   "2",
		backends: "rocm, vulkan",
	}
	rp := f.runParams()

	if rp.Ctx != 4096 {
		t.Errorf("Ctx = %d; want 4096", rp.Ctx)
	}
	if rp.Repeat != 5 {
		t.Errorf("Repeat = %d; want 5", rp.Repeat)
	}
	if rp.Warmup != 2 {
		t.Errorf("Warmup = %d; want 2", rp.Warmup)
	}
	if len(rp.Backends) != 2 || rp.Backends[0] != "rocm" || rp.Backends[1] != "vulkan" {
		t.Errorf("Backends = %v; want [rocm vulkan]", rp.Backends)
	}
}

// --- model.Update on screenParams ---

// makeParamsModel returns a model sitting on screenParams with a filled form.
func makeParamsModel() model {
	m := model{current: screenParams}
	enterParamsScreen(&m.paramsForm, 15.7)
	return m
}

func send(m model, msg tea.Msg) model {
	next, _ := m.Update(msg)
	return next.(model)
}

func TestParamsTabMovesFocus(t *testing.T) {
	m := makeParamsModel()
	if m.paramsForm.focused != fieldCtx {
		t.Fatalf("initial focused = %d; want fieldCtx", m.paramsForm.focused)
	}

	// Tab moves forward. Note: don't set Text for special keys — Text takes
	// priority in msg.String(), and "\t" would be returned as-is instead of "tab".
	m = send(m, tea.KeyPressMsg{Code: tea.KeyTab})
	if m.paramsForm.focused != fieldRepeat {
		t.Errorf("after Tab focused = %d; want fieldRepeat (%d)", m.paramsForm.focused, fieldRepeat)
	}

	m = send(m, tea.KeyPressMsg{Code: tea.KeyTab})
	if m.paramsForm.focused != fieldWarmup {
		t.Errorf("after 2x Tab focused = %d; want fieldWarmup (%d)", m.paramsForm.focused, fieldWarmup)
	}

	m = send(m, tea.KeyPressMsg{Code: tea.KeyTab})
	if m.paramsForm.focused != fieldBackends {
		t.Errorf("after 3x Tab focused = %d; want fieldBackends (%d)", m.paramsForm.focused, fieldBackends)
	}

	// Wraps around.
	m = send(m, tea.KeyPressMsg{Code: tea.KeyTab})
	if m.paramsForm.focused != fieldCtx {
		t.Errorf("after wrap Tab focused = %d; want fieldCtx (%d)", m.paramsForm.focused, fieldCtx)
	}
}

func TestParamsShiftTabMovesFocusBack(t *testing.T) {
	m := makeParamsModel()

	// Shift+Tab from fieldCtx wraps to last field.
	m = send(m, tea.KeyPressMsg{Mod: tea.ModShift, Code: tea.KeyTab})
	if m.paramsForm.focused != fieldBackends {
		t.Errorf("shift+tab from first field focused = %d; want fieldBackends (%d)", m.paramsForm.focused, fieldBackends)
	}

	m = send(m, tea.KeyPressMsg{Mod: tea.ModShift, Code: tea.KeyTab})
	if m.paramsForm.focused != fieldWarmup {
		t.Errorf("shift+tab focused = %d; want fieldWarmup (%d)", m.paramsForm.focused, fieldWarmup)
	}
}

func TestParamsTypingUpdatesCtx(t *testing.T) {
	m := makeParamsModel()
	// fieldCtx is focused; clear existing value first via backspaces.
	// Don't set Text for special keys — Text takes priority in msg.String().
	for range "2048" {
		m = send(m, tea.KeyPressMsg{Code: tea.KeyBackspace})
	}
	if m.paramsForm.ctx != "" {
		t.Fatalf("after clearing ctx = %q; want empty", m.paramsForm.ctx)
	}

	// Type "8192".
	for _, ch := range "8192" {
		m = send(m, tea.KeyPressMsg{Code: ch, Text: string(ch)})
	}
	if m.paramsForm.ctx != "8192" {
		t.Errorf("ctx = %q; want 8192", m.paramsForm.ctx)
	}
	if m.paramsForm.runParams().Ctx != 8192 {
		t.Errorf("runParams().Ctx = %d; want 8192", m.paramsForm.runParams().Ctx)
	}
}

func TestParamsIntFieldCapsLength(t *testing.T) {
	f := paramsForm{focused: fieldCtx} // empty ctx
	// Type more than maxIntFieldDigits digits; the field must cap.
	for range maxIntFieldDigits + 5 {
		updateParamsForm(&f, "9")
	}
	if len(f.ctx) != maxIntFieldDigits {
		t.Errorf("ctx length = %d; want capped at %d", len(f.ctx), maxIntFieldDigits)
	}
}

func TestParamsBackendsRejectsSlashAndDot(t *testing.T) {
	f := paramsForm{focused: fieldBackends, backends: ""}
	for _, ch := range "rocm/vulkan.x_y" {
		updateParamsForm(&f, string(ch))
	}
	// Slash, dot, underscore must be dropped; letters kept.
	if f.backends != "rocmvulkanxy" {
		t.Errorf("backends = %q; want rocmvulkanxy (/, ., _ rejected)", f.backends)
	}
	// Comma and hyphen are still accepted.
	updateParamsForm(&f, ",")
	updateParamsForm(&f, "-")
	if f.backends != "rocmvulkanxy,-" {
		t.Errorf("backends = %q; want rocmvulkanxy,- (comma+hyphen kept)", f.backends)
	}
}

func TestParamsEnterAdvancesToScreenRun(t *testing.T) {
	m := makeParamsModel()
	m = send(m, tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.current != screenRun {
		t.Errorf("after Enter current = %d; want screenRun (%d)", m.current, screenRun)
	}
}

func TestParamsEscBacksToScreenModel(t *testing.T) {
	m := makeParamsModel()
	m = send(m, tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.current != screenModel {
		t.Errorf("after Esc current = %d; want screenModel (%d)", m.current, screenModel)
	}
}

// --- teatest: labels visible in rendered output ---

func TestParamsScreenLabels(t *testing.T) {
	m := model{current: screenParams}
	enterParamsScreen(&m.paramsForm, 15.7)

	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(120, 40))
	t.Cleanup(func() { _ = tm.Quit() })

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Ctx")) &&
			bytes.Contains(out, []byte("Repeat")) &&
			bytes.Contains(out, []byte("Warmup"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}
