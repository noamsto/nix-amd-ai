package tui

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

const (
	railTickInterval = time.Second
	gpuBusyThreshold = 5.0
	defaultRailWidth = 80
)

type railState struct {
	gpuPct    float64
	preflight railPreflightSummary
}

type railPreflightSummary struct {
	ran    bool
	issues int
}

// summarizePreflight converts a preflight result slice into a compact summary.
// Empty/nil slice → not-ran.
func summarizePreflight(results []preflight.Result) railPreflightSummary {
	if len(results) == 0 {
		return railPreflightSummary{}
	}
	s := railPreflightSummary{ran: true}
	for _, r := range results {
		if r.Status == preflight.Warn || r.Status == preflight.Fail {
			s.issues++
		}
	}
	return s
}

// railArch renders the GPU arch segment.
func railArch(info hw.Info) string {
	if info.GfxArch != "" {
		return info.GfxArch
	}
	return "gpu unknown"
}

// railBudget renders the GTT budget segment.
func railBudget(info hw.Info) string {
	if info.GTTBytes == 0 {
		return "? GTT"
	}
	return fmt.Sprintf("%.0fGB GTT", float64(info.GTTBytes)/(1<<30))
}

// railGPU renders the GPU busy-percent segment.
func railGPU(pct float64) string {
	glyph := "✓"
	if pct > gpuBusyThreshold {
		glyph = "⚠"
	}
	return fmt.Sprintf("GPU %.0f%% %s", pct, glyph)
}

// railPower renders the power segment.
func railPower(info hw.Info) string {
	if !info.OnAC {
		return "battery ⚠"
	}
	if info.Performance {
		return "AC perf ✓"
	}
	return "AC perf ✗"
}

// railPreflight renders the preflight summary segment.
func railPreflight(s railPreflightSummary) string {
	if !s.ran {
		return "preflight …"
	}
	if s.issues == 0 {
		return "preflight ✓ clean"
	}
	return fmt.Sprintf("preflight ⚠ %d", s.issues)
}

// joinFit greedily joins segments with sep, stopping before the result would
// exceed width. If any segments are dropped, " · …" is appended when it fits.
// width<=0 defaults to 80.
func joinFit(segs []string, sep string, width int) string {
	if width <= 0 {
		width = defaultRailWidth
	}
	result := ""
	dropped := false
	for i, seg := range segs {
		candidate := seg
		if i > 0 {
			candidate = sep + seg
		}
		if lipgloss.Width(result+candidate) > width {
			// Segments are priority-ordered left-to-right: stop at the first
			// overflow rather than gap-filling with later shorter segments.
			dropped = true
			break
		}
		result += candidate
	}
	if dropped {
		ell := "…"
		if lipgloss.Width(result) > 0 {
			ell = sep + "…"
		}
		if lipgloss.Width(result+ell) <= width {
			result += ell
		}
	}
	return result
}

// renderRail builds the status rail string for the given hw info and state.
// width<=0 defaults to 80.
func renderRail(info hw.Info, st railState, width int, styles styles) string {
	if width <= 0 {
		width = defaultRailWidth
	}
	segs := []string{
		railArch(info),
		railBudget(info),
		railGPU(st.gpuPct),
		railPower(info),
		railPreflight(st.preflight),
	}
	return styles.rail.Render(joinFit(segs, " · ", width))
}

// railTickMsg carries a fresh GPU busy-percent reading.
type railTickMsg struct{ pct float64 }

// defaultRailGRBM reads the real GPU busy percent.
func defaultRailGRBM() float64 { return hw.GRBMBusyPct() }

// railTickCmd returns a command that fires after railTickInterval with a fresh
// GPU reading. grbm==nil falls back to defaultRailGRBM.
func railTickCmd(grbm func() float64) tea.Cmd {
	read := grbm
	if read == nil {
		read = defaultRailGRBM
	}
	return tea.Tick(railTickInterval, func(time.Time) tea.Msg {
		return railTickMsg{pct: read()}
	})
}
