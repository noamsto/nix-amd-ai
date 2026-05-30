package tui_test

import (
	"bytes"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/exp/teatest"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/tui"
)

func testInfo() hw.Info {
	return hw.Info{
		GfxArch:   "gfx1150",
		RAMGiB:    54.5,
		VRAMBytes: 8 << 30,
		GTTBytes:  27 << 30,
	}
}

// TestInitialScreen asserts that the first view is the Hardware panel.
func TestInitialScreen(t *testing.T) {
	tm := teatest.NewTestModel(t, tui.New(testInfo(), tui.Config{}),
		teatest.WithInitialTermSize(120, 40),
	)
	t.Cleanup(func() { _ = tm.Quit() })

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Hardware"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// TestEnterAdvancesScreen asserts that Enter moves to the Preflight panel.
func TestEnterAdvancesScreen(t *testing.T) {
	tm := teatest.NewTestModel(t, tui.New(testInfo(), tui.Config{}),
		teatest.WithInitialTermSize(120, 40),
	)
	t.Cleanup(func() { _ = tm.Quit() })

	// Wait for initial render.
	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Hardware"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))

	tm.Send(tea.KeyMsg{Type: tea.KeyEnter})

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Preflight"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// TestHWPanelShowsArch asserts that the hardware panel renders the GPU arch and GTT.
func TestHWPanelShowsArch(t *testing.T) {
	info := hw.Info{
		GfxArch:   "gfx1150",
		RAMGiB:    54.5,
		VRAMBytes: 8 << 30,
		GTTBytes:  27 << 30,
	}
	tm := teatest.NewTestModel(t, tui.New(info, tui.Config{}),
		teatest.WithInitialTermSize(120, 40),
	)
	t.Cleanup(func() { _ = tm.Quit() })

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("gfx1150")) && bytes.Contains(out, []byte("GTT"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// TestPreflightScreenHeader asserts that navigating to the preflight screen
// shows the "Preflight" heading. The checklist content depends on real
// systemctl/ss state, so we only assert the header is present.
func TestPreflightScreenHeader(t *testing.T) {
	tm := teatest.NewTestModel(t, tui.New(testInfo(), tui.Config{}),
		teatest.WithInitialTermSize(120, 40),
	)
	t.Cleanup(func() { _ = tm.Quit() })

	// Wait for HW screen then advance.
	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Hardware"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))

	tm.Send(tea.KeyMsg{Type: tea.KeyEnter})

	// The heading "Preflight" must appear; the loading indicator or results
	// may appear too — both are acceptable.
	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Preflight"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// TestQuitKey asserts that pressing q quits cleanly.
func TestQuitKey(t *testing.T) {
	tm := teatest.NewTestModel(t, tui.New(testInfo(), tui.Config{}),
		teatest.WithInitialTermSize(120, 40),
	)

	// Wait for initial render then quit.
	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Hardware"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))

	tm.Send(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})

	tm.WaitFinished(t, teatest.WithFinalTimeout(3*time.Second))
}
