package tui

import "charm.land/lipgloss/v2"

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
}

func newStyles(isDark bool) styles {
	ld := lipgloss.LightDark(isDark)
	fg := func(light, dark string) lipgloss.Style {
		return lipgloss.NewStyle().Foreground(ld(lipgloss.Color(light), lipgloss.Color(dark)))
	}
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
	}
}
