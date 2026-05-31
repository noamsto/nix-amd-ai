package tui

import (
	"strings"

	"charm.land/lipgloss/v2"
)

type styles struct {
	panel     lipgloss.Style
	heading   lipgloss.Style
	label     lipgloss.Style
	value     lipgloss.Style
	warnValue lipgloss.Style
	pass      lipgloss.Style
	warn      lipgloss.Style
	fail      lipgloss.Style
	hint      lipgloss.Style
	rail      lipgloss.Style

	// Fancy additions.
	accent    lipgloss.Style // primary accent (focus bullet, selection, keys)
	title     lipgloss.Style // panel title line
	rule      lipgloss.Style // thin separator rule under a title
	selected  lipgloss.Style // highlighted (cursor) row in a list
	chipOn    lipgloss.Style // a toggled-on chip
	chipOff   lipgloss.Style // a toggled-off chip
	stepOn    lipgloss.Style // active wizard step
	stepDone  lipgloss.Style // completed wizard step
	stepTodo  lipgloss.Style // not-yet-reached wizard step
	cursorStr string         // text-entry cursor glyph
}

func newStyles(isDark bool) styles {
	ld := lipgloss.LightDark(isDark)
	fg := func(light, dark string) lipgloss.Style {
		return lipgloss.NewStyle().Foreground(ld(lipgloss.Color(light), lipgloss.Color(dark)))
	}
	accentColor := ld(lipgloss.Color("63"), lipgloss.Color("212"))
	return styles{
		panel: lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(ld(lipgloss.Color("61"), lipgloss.Color("62"))).
			Padding(0, 1),
		heading:   lipgloss.NewStyle().Bold(true).Foreground(ld(lipgloss.Color("90"), lipgloss.Color("212"))),
		label:     fg("240", "241"),
		value:     fg("236", "255"),
		warnValue: fg("130", "214"),
		pass:      fg("28", "46"),
		warn:      fg("130", "214"),
		fail:      fg("160", "196"),
		hint:      fg("244", "245"),
		rail:      lipgloss.NewStyle().Faint(true),

		accent: lipgloss.NewStyle().Bold(true).Foreground(accentColor),
		title:  lipgloss.NewStyle().Bold(true).Foreground(accentColor),
		rule:   fg("250", "238"),
		selected: lipgloss.NewStyle().Bold(true).
			Foreground(ld(lipgloss.Color("17"), lipgloss.Color("231"))).
			Background(ld(lipgloss.Color("189"), lipgloss.Color("57"))),
		chipOn: lipgloss.NewStyle().Bold(true).
			Foreground(ld(lipgloss.Color("231"), lipgloss.Color("231"))).
			Background(ld(lipgloss.Color("35"), lipgloss.Color("28"))).
			Padding(0, 1),
		chipOff: lipgloss.NewStyle().
			Foreground(ld(lipgloss.Color("244"), lipgloss.Color("245"))).
			Background(ld(lipgloss.Color("254"), lipgloss.Color("236"))).
			Padding(0, 1),
		stepOn:    lipgloss.NewStyle().Bold(true).Foreground(accentColor),
		stepDone:  fg("28", "42"),
		stepTodo:  lipgloss.NewStyle().Faint(true).Foreground(ld(lipgloss.Color("250"), lipgloss.Color("240"))),
		cursorStr: "▏",
	}
}

// focusBullet returns the leading marker for a list/form row: an accent "▸ "
// when focused, two spaces otherwise (keeps columns aligned).
func (st styles) focusBullet(focused bool) string {
	if focused {
		return st.accent.Render("▸") + " "
	}
	return "  "
}

// titledPanel renders body inside the rounded panel with an accent title line
// and a thin rule beneath it. width<=0 lets the panel size to its content.
func titledPanel(st styles, title, body string, width int) string {
	rule := st.rule.Render(strings.Repeat("─", panelRuleWidth(title, body, width)))
	inner := st.title.Render(title) + "\n" + rule + "\n" + body
	p := st.panel
	if width > 0 {
		p = p.Width(width)
	}
	return p.Render(inner)
}

// panelRuleWidth picks a separator-rule width: the widest content line, capped.
func panelRuleWidth(title, body string, width int) int {
	w := lipgloss.Width(title)
	for _, line := range strings.Split(body, "\n") {
		if lw := lipgloss.Width(line); lw > w {
			w = lw
		}
	}
	if width > 0 && width-2 < w {
		w = width - 2
	}
	if w < 1 {
		w = 1
	}
	if w > maxRuleWidth {
		w = maxRuleWidth
	}
	return w
}

const maxRuleWidth = 100

// keybar renders a footer hint line: each pair is {key, description}; keys are
// accent-colored, descriptions dim, joined with " · ".
func keybar(st styles, pairs ...[2]string) string {
	parts := make([]string, 0, len(pairs))
	for _, p := range pairs {
		parts = append(parts, st.accent.Render(p[0])+" "+st.hint.Render(p[1]))
	}
	return strings.Join(parts, st.hint.Render("  ·  "))
}

// chip renders a toggle chip: filled when on, outlined when off. A focused chip
// is underlined so the keyboard cursor is visible within a row of chips.
func chip(st styles, label string, on, focused bool) string {
	style := st.chipOff
	text := "○ " + label
	if on {
		style = st.chipOn
		text = "◉ " + label
	}
	if focused {
		style = style.Underline(true)
	}
	return style.Render(text)
}
