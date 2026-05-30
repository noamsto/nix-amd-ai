package tui

import (
	"testing"
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

func TestModePickerCursorMovement(t *testing.T) {
	p := modePicker{cursor: 0}

	// Initial cursor is 0 (HTTP bench).
	if p.cursor != 0 {
		t.Fatalf("initial cursor = %d; want 0", p.cursor)
	}

	// Simulate down twice.
	if p.cursor < len(modeItems)-1 {
		p.cursor++
	}
	if p.cursor < len(modeItems)-1 {
		p.cursor++
	}
	if p.cursor != 2 {
		t.Errorf("after two downs cursor = %d; want 2", p.cursor)
	}

	// Cannot go past last item.
	if p.cursor < len(modeItems)-1 {
		p.cursor++
	}
	if p.cursor != 2 {
		t.Errorf("after third down cursor = %d; want 2 (clamped)", p.cursor)
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
