package tui

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestModePickerItems(t *testing.T) {
	// All three mode labels must appear in the rendered output.
	p := modePicker{cursor: 0}
	out := renderModeScreen(p)

	labels := []string{
		"HTTP bench (via lemonade)",
		"Backend A/B (rocm vs vulkan)",
		"MTP A/B (spec on/off)",
	}
	for _, label := range labels {
		// renderModeScreen wraps labels in lipgloss styles; strip control codes
		// by checking the raw label string still appears.
		if !containsStr(out, label) {
			t.Errorf("renderModeScreen: label %q not found in output:\n%s", label, out)
		}
	}
}

// TestModePickerCursorMovement drives down/up keys through model.Update so a
// `<` vs `<=` clamping regression in app.go is actually caught.
func TestModePickerCursorMovement(t *testing.T) {
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	up := tea.KeyPressMsg{Code: tea.KeyUp}

	send := func(m model, msg tea.Msg) model {
		next, _ := m.Update(msg)
		return next.(model)
	}

	m := model{current: screenMode}
	if m.modePicker.cursor != 0 {
		t.Fatalf("initial cursor = %d; want 0", m.modePicker.cursor)
	}

	// Down twice → cursor 2 (last item, len 3).
	m = send(m, down)
	m = send(m, down)
	if m.modePicker.cursor != 2 {
		t.Errorf("after two downs cursor = %d; want 2", m.modePicker.cursor)
	}

	// Down again must clamp at the last index, not overflow.
	m = send(m, down)
	if m.modePicker.cursor != len(modeItems)-1 {
		t.Errorf("after third down cursor = %d; want %d (clamped at bottom)", m.modePicker.cursor, len(modeItems)-1)
	}

	// Up back to top.
	m = send(m, up)
	m = send(m, up)
	if m.modePicker.cursor != 0 {
		t.Errorf("after two ups cursor = %d; want 0", m.modePicker.cursor)
	}

	// Up again must clamp at 0, not go negative.
	m = send(m, up)
	if m.modePicker.cursor != 0 {
		t.Errorf("after extra up cursor = %d; want 0 (clamped at top)", m.modePicker.cursor)
	}
}

func TestModeSelection(t *testing.T) {
	// Verify that selecting cursor 0 yields ModeHTTP, cursor 2 yields ModeMTP.
	cases := []struct {
		cursor int
		want   BenchMode
	}{
		{0, ModeHTTP},
		{1, ModeBackend},
		{2, ModeMTP},
	}
	for _, tc := range cases {
		got := modeItems[tc.cursor].mode
		if got != tc.want {
			t.Errorf("modeItems[%d].mode = %v; want %v", tc.cursor, got, tc.want)
		}
	}
}

// containsStr checks whether s contains sub (plain string, not style-aware).
func containsStr(s, sub string) bool {
	return len(s) > 0 && len(sub) > 0 && stringContains(s, sub)
}

func stringContains(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
