package tui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

var (
	panelStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("62")).
			Padding(0, 1)

	headingStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("212"))

	labelStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241"))

	valueStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("255"))

	warnValueStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("214"))
)

// renderHWPanel renders a lipgloss-bordered box with detected hardware info.
func renderHWPanel(info hw.Info) string {
	var b strings.Builder

	b.WriteString(headingStyle.Render("Hardware") + "\n\n")

	// GPU arch
	arch := info.GfxArch
	if arch == "" {
		arch = "unknown"
	}
	b.WriteString(labelStyle.Render("GPU arch:  ") + valueStyle.Render(arch) + "\n")

	// RAM: total GiB + type/speed (or a note when type is unknown)
	ramLine := fmt.Sprintf("%.1f GiB", info.RAMGiB)
	if info.RAMType == "" {
		ramLine += "  " + warnValueStyle.Render("(type: unknown — run as root for RAM type)")
	} else {
		typeStr := info.RAMType
		if info.RAMSpeedMTs > 0 {
			typeStr += fmt.Sprintf(" %d MT/s", info.RAMSpeedMTs)
		}
		ramLine += "  " + valueStyle.Render(typeStr)
	}
	b.WriteString(labelStyle.Render("RAM:       ") + ramLine + "\n")

	// VRAM (UMA carveout) in GiB
	vramGiB := float64(info.VRAMBytes) / (1 << 30)
	b.WriteString(labelStyle.Render("VRAM:      ") + valueStyle.Render(fmt.Sprintf("%.1f GiB  (UMA carveout)", vramGiB)) + "\n")

	// GTT (usable KV-cache budget) in GiB
	gttGiB := float64(info.GTTBytes) / (1 << 30)
	b.WriteString(labelStyle.Render("GTT:       ") + valueStyle.Render(fmt.Sprintf("%.1f GiB  (usable budget)", gttGiB)) + "\n")

	// Power state
	powerState := powerStateString(info.OnAC, info.Performance)
	b.WriteString(labelStyle.Render("Power:     ") + powerState + "\n")

	b.WriteString("\n" + labelStyle.Render("Press Enter to continue →"))

	return panelStyle.Render(b.String())
}

// powerStateString renders a human-readable power state from onAC + performance flags.
func powerStateString(onAC, performance bool) string {
	if !onAC {
		return warnValueStyle.Render("battery  ⚠")
	}
	if performance {
		return valueStyle.Render("AC  performance")
	}
	return warnValueStyle.Render("AC  (not performance mode)  ⚠")
}
