package tui

import "testing"

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
