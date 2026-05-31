package tui

import (
	"fmt"
	"strings"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

// renderHWPanel renders a lipgloss-bordered box with detected hardware info.
func renderHWPanel(info hw.Info, st styles) string {
	var b strings.Builder

	// GPU arch
	arch := info.GfxArch
	if arch == "" {
		arch = "unknown"
	}
	b.WriteString(st.label.Render("GPU arch:  ") + st.value.Render(arch) + "\n")

	// RAM: total GiB + type/speed (or a note when type is unknown)
	ramLine := fmt.Sprintf("%.1f GiB", info.RAMGiB)
	if info.RAMType == "" {
		ramLine += "  " + st.warnValue.Render("(type: unknown — run as root for RAM type)")
	} else {
		typeStr := info.RAMType
		if info.RAMSpeedMTs > 0 {
			typeStr += fmt.Sprintf(" %d MT/s", info.RAMSpeedMTs)
		}
		ramLine += "  " + st.value.Render(typeStr)
	}
	b.WriteString(st.label.Render("RAM:       ") + ramLine + "\n")

	// VRAM (UMA carveout) in GiB
	vramGiB := float64(info.VRAMBytes) / (1 << 30)
	b.WriteString(st.label.Render("VRAM:      ") + st.value.Render(fmt.Sprintf("%.1f GiB  (UMA carveout)", vramGiB)) + "\n")

	// GTT (usable KV-cache budget) in GiB
	gttGiB := float64(info.GTTBytes) / (1 << 30)
	b.WriteString(st.label.Render("GTT:       ") + st.value.Render(fmt.Sprintf("%.1f GiB  (usable budget)", gttGiB)) + "\n")

	// Power state
	powerState := powerStateString(info.OnAC, info.Performance, st)
	b.WriteString(st.label.Render("Power:     ") + powerState + "\n")

	b.WriteString("\n" + keybar(st, [2]string{"Enter", "continue →"}))

	return titledPanel(st, "Hardware", b.String(), 0)
}

// powerStateString renders a human-readable power state from onAC + performance flags.
func powerStateString(onAC, performance bool, st styles) string {
	if !onAC {
		return st.warnValue.Render("battery  ⚠")
	}
	if performance {
		return st.value.Render("AC  performance")
	}
	return st.warnValue.Render("AC  (not performance mode)  ⚠")
}
