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

// --- parseCtxField (unit-aware) ---

func TestParseCtxField(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"2048", 2048},
		{"16k", 16384},
		{"16K", 16384},
		{"16kb", 16384},
		{"16KB", 16384},
		{"1m", 1024 * 1024},
		{"1MB", 1024 * 1024},
		{"", 999},       // fallback
		{"abc", 999},    // fallback
		{"0", 999},      // non-positive → fallback
		{"  8k ", 8192}, // trimmed
	}
	for _, tc := range cases {
		if got := parseCtxField(tc.in, 999); got != tc.want {
			t.Errorf("parseCtxField(%q) = %d; want %d", tc.in, got, tc.want)
		}
	}
}

// --- enterParamsScreen prefill ---

func TestEnterParamsScreen_Prefill(t *testing.T) {
	t.Run("recommended ctx snaps to the 2K preset", func(t *testing.T) {
		var f paramsForm
		enterParamsScreen(&f, 15.7) // advise → 2048 == ctxPresets[0]

		if f.ctxIdx != 0 {
			t.Errorf("ctxIdx = %d; want 0 (2K preset)", f.ctxIdx)
		}
		if f.ctxValue() != 2048 {
			t.Errorf("ctxValue = %d; want 2048", f.ctxValue())
		}
		if !f.ctxSuggested {
			t.Error("ctxSuggested should be true after enterParamsScreen")
		}
		if f.repeat != "3" || f.warmup != "1" {
			t.Errorf("repeat/warmup = %q/%q; want 3/1", f.repeat, f.warmup)
		}
		if len(f.backendSel) != 2 || !f.backendSel[0] || !f.backendSel[1] {
			t.Errorf("backendSel = %v; want both on", f.backendSel)
		}
		if f.focused != fieldCtx {
			t.Errorf("focused = %d; want fieldCtx (%d)", f.focused, fieldCtx)
		}
	})
}

// --- runParams ---

func TestRunParams(t *testing.T) {
	t.Run("preset ctx + both backends", func(t *testing.T) {
		f := paramsForm{
			ctxIdx:     3, // 16K
			repeat:     "5",
			warmup:     "2",
			backendSel: []bool{true, true},
		}
		rp := f.runParams()
		if rp.Ctx != 16384 {
			t.Errorf("Ctx = %d; want 16384", rp.Ctx)
		}
		if rp.Repeat != 5 || rp.Warmup != 2 {
			t.Errorf("Repeat/Warmup = %d/%d; want 5/2", rp.Repeat, rp.Warmup)
		}
		if len(rp.Backends) != 2 || rp.Backends[0] != "rocm" || rp.Backends[1] != "vulkan" {
			t.Errorf("Backends = %v; want [rocm vulkan]", rp.Backends)
		}
	})

	t.Run("custom ctx with unit + one backend off", func(t *testing.T) {
		f := paramsForm{
			ctxIdx:     ctxCustomIdx,
			ctxCustom:  "24k",
			repeat:     "3",
			warmup:     "1",
			backendSel: []bool{false, true},
		}
		rp := f.runParams()
		if rp.Ctx != 24*1024 {
			t.Errorf("Ctx = %d; want %d", rp.Ctx, 24*1024)
		}
		if len(rp.Backends) != 1 || rp.Backends[0] != "vulkan" {
			t.Errorf("Backends = %v; want [vulkan]", rp.Backends)
		}
	})
}

// --- model.Update on screenParams ---

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
	want := []paramField{fieldRepeat, fieldWarmup, fieldBackends, fieldCtx}
	for i, w := range want {
		m = send(m, tea.KeyPressMsg{Code: tea.KeyTab})
		if m.paramsForm.focused != w {
			t.Errorf("after %d Tab focused = %d; want %d", i+1, m.paramsForm.focused, w)
		}
	}
}

func TestParamsShiftTabMovesFocusBack(t *testing.T) {
	m := makeParamsModel()
	m = send(m, tea.KeyPressMsg{Mod: tea.ModShift, Code: tea.KeyTab})
	if m.paramsForm.focused != fieldBackends {
		t.Errorf("shift+tab from first field focused = %d; want fieldBackends (%d)", m.paramsForm.focused, fieldBackends)
	}
}

func TestParamsCtxPresetCycling(t *testing.T) {
	m := makeParamsModel() // ctxIdx 0 (2K)
	m = send(m, tea.KeyPressMsg{Code: tea.KeyRight})
	if m.paramsForm.ctxIdx != 1 {
		t.Errorf("after → ctxIdx = %d; want 1", m.paramsForm.ctxIdx)
	}
	// Left from 0 wraps to the Custom slot.
	m = makeParamsModel()
	m = send(m, tea.KeyPressMsg{Code: tea.KeyLeft})
	if m.paramsForm.ctxIdx != ctxCustomIdx {
		t.Errorf("after ← from 0 ctxIdx = %d; want ctxCustomIdx (%d)", m.paramsForm.ctxIdx, ctxCustomIdx)
	}
}

func TestParamsTypingDigitJumpsToCustom(t *testing.T) {
	m := makeParamsModel() // focused fieldCtx, preset 2K
	for _, ch := range "8192" {
		m = send(m, tea.KeyPressMsg{Code: ch, Text: string(ch)})
	}
	if m.paramsForm.ctxIdx != ctxCustomIdx {
		t.Fatalf("typing a digit should jump to Custom; ctxIdx = %d", m.paramsForm.ctxIdx)
	}
	if m.paramsForm.ctxCustom != "8192" {
		t.Errorf("ctxCustom = %q; want 8192", m.paramsForm.ctxCustom)
	}
	if got := m.paramsForm.runParams().Ctx; got != 8192 {
		t.Errorf("runParams().Ctx = %d; want 8192", got)
	}
}

func TestParamsCustomAcceptsUnitSuffix(t *testing.T) {
	f := paramsForm{focused: fieldCtx}
	for _, ch := range "24k" {
		updateParamsForm(&f, string(ch))
	}
	if f.ctxCustom != "24k" {
		t.Fatalf("ctxCustom = %q; want 24k", f.ctxCustom)
	}
	if f.ctxValue() != 24*1024 {
		t.Errorf("ctxValue = %d; want %d", f.ctxValue(), 24*1024)
	}
}

func TestParamsCustomCapsDigits(t *testing.T) {
	f := paramsForm{focused: fieldCtx}
	for range maxIntFieldDigits + 5 {
		updateParamsForm(&f, "9")
	}
	if len(f.ctxCustom) != maxIntFieldDigits {
		t.Errorf("ctxCustom length = %d; want capped at %d", len(f.ctxCustom), maxIntFieldDigits)
	}
}

func TestParamsBackendToggle(t *testing.T) {
	m := makeParamsModel()
	// Move focus to backends.
	for m.paramsForm.focused != fieldBackends {
		m = send(m, tea.KeyPressMsg{Code: tea.KeyTab})
	}
	// Both start on; Space toggles rocm (cursor 0) off.
	m = send(m, tea.KeyPressMsg{Code: tea.KeySpace})
	if m.paramsForm.backendSel[0] {
		t.Errorf("after Space, rocm should be off; backendSel = %v", m.paramsForm.backendSel)
	}
	// → moves cursor to vulkan; Space toggles it off too.
	m = send(m, tea.KeyPressMsg{Code: tea.KeyRight})
	m = send(m, tea.KeyPressMsg{Code: tea.KeySpace})
	if m.paramsForm.backendSel[1] {
		t.Errorf("after →+Space, vulkan should be off; backendSel = %v", m.paramsForm.backendSel)
	}
	if len(m.paramsForm.runParams().Backends) != 0 {
		t.Errorf("both off → no backends; got %v", m.paramsForm.runParams().Backends)
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
		return bytes.Contains(out, []byte("Context")) &&
			bytes.Contains(out, []byte("Repeat")) &&
			bytes.Contains(out, []byte("Backends"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}
