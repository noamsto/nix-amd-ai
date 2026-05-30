package tui

import (
	"fmt"
	"strings"
)

// BenchMode identifies which benchmark workflow the user selected.
type BenchMode int

const (
	ModeHTTP    BenchMode = iota // HTTP bench via lemonade
	ModeBackend                  // Backend A/B (rocm vs vulkan)
	ModeMTP                      // MTP A/B (spec decode on/off)
)

// modeItem is a single entry shown in the mode picker.
type modeItem struct {
	mode  BenchMode
	label string
	desc  string
}

var modeItems = []modeItem{
	{ModeHTTP, "HTTP bench (via lemonade)", "Measure throughput against a running lemonade server"},
	{ModeBackend, "Backend A/B (rocm vs vulkan)", "Compare ROCm and Vulkan backends head-to-head"},
	{ModeMTP, "MTP A/B (spec on/off)", "Measure speculative-decode gain (MTP on vs off)"},
}

// modePicker holds the transient state for the mode selection screen.
type modePicker struct {
	cursor int
}

// renderModeScreen renders the mode selection panel.
func renderModeScreen(p modePicker, st styles) string {
	var b strings.Builder

	b.WriteString(st.heading.Render("Select Benchmark Mode") + "\n\n")

	for i, item := range modeItems {
		prefix := "  "
		label := item.label
		if i == p.cursor {
			prefix = "> "
			label = st.value.Render(label)
		} else {
			label = st.label.Render(label)
		}
		b.WriteString(fmt.Sprintf("%s%s\n", prefix, label))
		b.WriteString(fmt.Sprintf("    %s\n", st.hint.Render(item.desc)))
	}

	b.WriteString("\n" + st.label.Render("↑/↓ move   Enter → select   Esc ← back"))

	return st.panel.Render(b.String())
}
