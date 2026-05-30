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

	for i, item := range modeItems {
		focused := i == p.cursor
		label := item.label
		if focused {
			label = st.selected.Render(" " + label + " ")
		} else {
			label = st.label.Render(label)
		}
		b.WriteString(st.focusBullet(focused) + label + "\n")
		b.WriteString(fmt.Sprintf("    %s\n", st.hint.Render(item.desc)))
	}

	b.WriteString("\n" + keybar(st,
		[2]string{"↑/↓", "move"},
		[2]string{"Enter", "select →"},
		[2]string{"Esc", "← back"},
	))

	return titledPanel(st, "Select Benchmark Mode", b.String(), 0)
}
