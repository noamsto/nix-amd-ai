package tui

import (
	"image/color"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

func TestNewStylesLightDarkDiffer(t *testing.T) {
	light := newStyles(false)
	dark := newStyles(true)
	if light.value.Render("x") == dark.value.Render("x") {
		t.Fatal("value style should differ between light and dark")
	}
	if light.pass.Render("ok") == dark.pass.Render("ok") {
		t.Fatal("pass style should differ between light and dark")
	}
}

// TestBackgroundColorMsgSelectsStyles drives the Update handler with a dark and a
// light terminal background and asserts the model swaps to the matching style set.
func TestBackgroundColorMsgSelectsStyles(t *testing.T) {
	black := tea.BackgroundColorMsg{Color: color.RGBA{R: 0, G: 0, B: 0, A: 255}}
	white := tea.BackgroundColorMsg{Color: color.RGBA{R: 255, G: 255, B: 255, A: 255}}
	if !black.IsDark() {
		t.Fatal("black background should report IsDark()==true")
	}
	if white.IsDark() {
		t.Fatal("white background should report IsDark()==false")
	}

	m := New(hw.Info{}, Config{}).(model)

	dark, _ := m.Update(black)
	if dark.(model).st.value.Render("x") != newStyles(true).value.Render("x") {
		t.Fatal("dark background should select the dark style set")
	}

	light, _ := m.Update(white)
	if light.(model).st.value.Render("x") != newStyles(false).value.Render("x") {
		t.Fatal("light background should select the light style set")
	}
}
