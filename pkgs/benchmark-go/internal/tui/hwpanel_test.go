package tui

import (
	"strings"
	"testing"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

func TestRenderHWPanelContainsArch(t *testing.T) {
	info := hw.Info{
		GfxArch:     "gfx1150",
		RAMGiB:      54.5,
		RAMType:     "DDR5",
		RAMSpeedMTs: 5600,
		VRAMBytes:   8 << 30,
		GTTBytes:    27 << 30,
		OnAC:        true,
		Performance: true,
	}
	out := renderHWPanel(info)

	if !strings.Contains(out, "gfx1150") {
		t.Errorf("expected arch 'gfx1150' in output; got:\n%s", out)
	}
	if !strings.Contains(out, "GTT") {
		t.Errorf("expected 'GTT' label in output; got:\n%s", out)
	}
	if !strings.Contains(out, "DDR5") {
		t.Errorf("expected RAM type 'DDR5' in output; got:\n%s", out)
	}
	if !strings.Contains(out, "5600") {
		t.Errorf("expected RAM speed '5600' in output; got:\n%s", out)
	}
}

func TestRenderHWPanelUnknownRAMType(t *testing.T) {
	info := hw.Info{
		GfxArch:   "gfx1150",
		RAMGiB:    54.5,
		RAMType:   "", // empty — run as root for RAM type
		VRAMBytes: 8 << 30,
		GTTBytes:  27 << 30,
	}
	out := renderHWPanel(info)

	if !strings.Contains(out, "unknown") {
		t.Errorf("expected 'unknown' RAM type hint in output; got:\n%s", out)
	}
}

func TestRenderHWPanelVRAMAndGTTValues(t *testing.T) {
	info := hw.Info{
		GfxArch:   "gfx1150",
		VRAMBytes: 8 << 30,  // 8 GiB
		GTTBytes:  27 << 30, // 27 GiB
	}
	out := renderHWPanel(info)

	if !strings.Contains(out, "8.0 GiB") {
		t.Errorf("expected VRAM '8.0 GiB' in output; got:\n%s", out)
	}
	if !strings.Contains(out, "27.0 GiB") {
		t.Errorf("expected GTT '27.0 GiB' in output; got:\n%s", out)
	}
}

func TestRenderHWPanelPowerStates(t *testing.T) {
	tests := []struct {
		name        string
		onAC        bool
		performance bool
		want        string
	}{
		{"ac-performance", true, true, "performance"},
		{"ac-not-perf", true, false, "AC"},
		{"battery", false, false, "battery"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			info := hw.Info{OnAC: tc.onAC, Performance: tc.performance}
			out := renderHWPanel(info)
			if !strings.Contains(out, tc.want) {
				t.Errorf("power state: expected %q in output; got:\n%s", tc.want, out)
			}
		})
	}
}
