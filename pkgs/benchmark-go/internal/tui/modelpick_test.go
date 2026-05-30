package tui

import (
	"bytes"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/exp/teatest/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/advise"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/models"
)

// TestFormatModelRow_Glyphs verifies that formatModelRow produces the correct
// fit glyph, MoE tag, and estimation prefix.
func TestFormatModelRow_Glyphs(t *testing.T) {
	t.Run("fits dense no estimate", func(t *testing.T) {
		out := formatModelRow("MyModel-7B-GGUF", 4.5, true, advise.Fits, 12.3, false, false, false, true, false)
		if !strings.Contains(out, "✅") {
			t.Errorf("expected ✅ in %q", out)
		}
		if strings.Contains(out, "~") {
			t.Errorf("unexpected ~ in %q", out)
		}
		if strings.Contains(out, "(MoE)") {
			t.Errorf("unexpected (MoE) in %q", out)
		}
	})

	t.Run("spills with estimate and MoE", func(t *testing.T) {
		out := formatModelRow("Gemma-4-26B-A4B", 15.7, true, advise.Spills, 42.0, true, true, false, true, false)
		if !strings.Contains(out, "❌") {
			t.Errorf("expected ❌ in %q", out)
		}
		if !strings.Contains(out, "~") {
			t.Errorf("expected ~ in %q", out)
		}
		if !strings.Contains(out, "(MoE)") {
			t.Errorf("expected (MoE) in %q", out)
		}
	})

	t.Run("tight selected", func(t *testing.T) {
		out := formatModelRow("Model-14B", 8.0, true, advise.Tight, 5.0, false, false, true, true, false)
		if !strings.Contains(out, "⚠️") {
			t.Errorf("expected ⚠️ in %q", out)
		}
		if !strings.Contains(out, "[✓]") {
			t.Errorf("expected [✓] in %q", out)
		}
	})

	t.Run("unknown size shows ? glyph not cross", func(t *testing.T) {
		out := formatModelRow("UnknownModel", 0, false, advise.Fits, 0, false, false, false, true, false)
		if strings.Contains(out, "❌") {
			t.Errorf("unknown-size row must not show ❌ in %q", out)
		}
		if !strings.Contains(out, "?") {
			t.Errorf("unknown-size row should show ? in %q", out)
		}
	})

	t.Run("unknown size with fit=Spills still shows ? not cross", func(t *testing.T) {
		// Even if fit field is Spills (stale default), unknown size → neutral glyph.
		out := formatModelRow("UnknownModel", 0, false, advise.Spills, 0, false, false, false, true, false)
		if strings.Contains(out, "❌") {
			t.Errorf("unknown-size row must not show ❌ in %q", out)
		}
		if !strings.Contains(out, "?") {
			t.Errorf("unknown-size row should show ? in %q", out)
		}
	})
}

// TestFormatModelRow_Markers verifies ⬇ and ★ render correctly.
func TestFormatModelRow_Markers(t *testing.T) {
	t.Run("not-downloaded shows down arrow", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, false, false)
		if !strings.Contains(out, "⬇") {
			t.Errorf("not-downloaded row should contain ⬇ in %q", out)
		}
	})

	t.Run("downloaded does not show down arrow", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, false)
		if strings.Contains(out, "⬇") {
			t.Errorf("downloaded row must not show ⬇ in %q", out)
		}
	})

	t.Run("suggested shows star", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, true)
		if !strings.Contains(out, "★") {
			t.Errorf("suggested row should contain ★ in %q", out)
		}
	})

	t.Run("not suggested does not show star", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, false)
		if strings.Contains(out, "★") {
			t.Errorf("non-suggested row must not show ★ in %q", out)
		}
	})

	t.Run("both markers together", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, false, true)
		if !strings.Contains(out, "★") {
			t.Errorf("expected ★ in %q", out)
		}
		if !strings.Contains(out, "⬇") {
			t.Errorf("expected ⬇ in %q", out)
		}
	})
}

// TestFormatModelRow_Alignment verifies that rows with different id lengths
// produce the size column starting at the same display column.
// Also verifies that marked vs unmarked rows have the same size column offset.
func TestFormatModelRow_Alignment(t *testing.T) {
	short := formatModelRow("A", 4.5, true, advise.Fits, 10.0, false, false, false, true, false)
	long := formatModelRow("A-Very-Long-Model-Name-That-Gets-Truncated-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, false)

	// Find the display offset of the size string "4.5 GiB" in each row.
	findSizeOffset := func(row string) int {
		target := "4.5 GiB"
		idx := strings.Index(row, target)
		if idx < 0 {
			return -1
		}
		return lipgloss.Width(row[:idx])
	}

	shortOff := findSizeOffset(short)
	longOff := findSizeOffset(long)

	if shortOff < 0 || longOff < 0 {
		t.Fatalf("size string not found: short=%q long=%q", short, long)
	}
	if shortOff != longOff {
		t.Errorf("size column at display offset %d (short) vs %d (long); want equal\nshort: %s\n long: %s",
			shortOff, longOff, short, long)
	}

	// Marker vs no-marker: size column offset must be identical (markers are
	// fixed-width, so they don't affect the id or size columns).
	withMarkers := formatModelRow("SomeModel", 4.5, true, advise.Fits, 10.0, false, false, false, false, true)
	noMarkers := formatModelRow("SomeModel", 4.5, true, advise.Fits, 10.0, false, false, false, true, false)

	markedOff := findSizeOffset(withMarkers)
	plainOff := findSizeOffset(noMarkers)
	if markedOff < 0 || plainOff < 0 {
		t.Fatalf("size string not found in marker test: marked=%q plain=%q", withMarkers, noMarkers)
	}
	if markedOff != plainOff {
		t.Errorf("marker shifts size column: marked offset %d vs plain %d\nmarked: %s\nplain:  %s",
			markedOff, plainOff, withMarkers, noMarkers)
	}
}

// TestToggleSelection verifies space-bar selection logic.
func TestToggleSelection(t *testing.T) {
	p := modelPicker{
		rows: []modelRow{
			{id: "model-a"},
			{id: "model-b"},
		},
		cursor: 0,
	}

	// Toggle model-a on.
	p.toggleSelected()
	if !p.rows[0].selected {
		t.Error("rows[0] should be selected after first toggle")
	}

	// Move to model-b and toggle it on.
	p.cursor = 1
	p.toggleSelected()
	if !p.rows[1].selected {
		t.Error("rows[1] should be selected after toggle")
	}

	// Toggle model-a off.
	p.cursor = 0
	p.toggleSelected()
	if p.rows[0].selected {
		t.Error("rows[0] should be deselected after second toggle")
	}

	// selectedIDs should only return model-b.
	ids := p.selectedIDs()
	if len(ids) != 1 || ids[0] != "model-b" {
		t.Errorf("selectedIDs() = %v; want [model-b]", ids)
	}
}

// TestBuildModelRows_FitVsCeiling confirms that fit uses total size and ceiling
// uses active size (the core correctness invariant for MoE models).
func TestBuildModelRows_FitVsCeiling(t *testing.T) {
	info := hw.Info{
		RAMType:     "DDR5",
		RAMSpeedMTs: 5600,
		GTTBytes:    27 << 30, // 27 GiB budget
	}

	// 15.7 GB from API → ~14.63 GiB
	fakeList := []models.Model{
		{ID: "Gemma-4-26B-A4B-it-GGUF", Downloaded: true, Recipe: "llamacpp", Size: 15.7 * 1.073741824},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	r := rows[0]

	// Fit uses total size (15.7 GiB vs 27 GiB budget → Fits).
	if r.fit != advise.Fits {
		t.Errorf("fit = %v; want Fits (total 15.7 GiB < 27 GiB budget)", r.fit)
	}

	// MoE should be detected.
	if !r.isMoE {
		t.Error("isMoE should be true for Gemma-4-26B-A4B")
	}

	// Ceiling uses active size (~2.42 GiB for 4/26 of 15.7 GiB).
	// With 89.6 GB/s bandwidth: ceil ≈ 89.6 / (2.42 * 1.073741824) ≈ 34.4 t/s
	// Dense ceiling would be: 89.6 / (15.7 * 1.073741824) ≈ 5.3 t/s
	// Verify the MoE ceiling is significantly higher than a dense ceiling would be.
	denseCeiling := advise.DecodeCeilingTPS(89.6, 15.7)
	if r.ceilingTPS <= denseCeiling {
		t.Errorf("MoE ceiling %.2f t/s should exceed dense ceiling %.2f t/s (active < total)", r.ceilingTPS, denseCeiling)
	}
}

// TestBuildModelRows_SizeFromAPI verifies that size comes from m.Size (API, GB→GiB)
// and not from filesystem access.
func TestBuildModelRows_SizeFromAPI(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	// 18.8 GB from API → 18.8/1.073741824 ≈ 17.51 GiB
	fakeList := []models.Model{
		{ID: "Qwen3.6-27B-MTP-GGUF", Downloaded: true, Recipe: "llamacpp", Size: 18.8},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	r := rows[0]

	expected := 18.8 / 1.073741824
	if r.totalGiB < expected-0.01 || r.totalGiB > expected+0.01 {
		t.Errorf("totalGiB = %.4f, want ~%.4f (18.8 GB / 1.073741824)", r.totalGiB, expected)
	}
	if !r.sizeKnown {
		t.Error("sizeKnown should be true when m.Size > 0")
	}
}

// TestBuildModelRows_IncludesNotDownloaded verifies not-downloaded llamacpp models are included.
func TestBuildModelRows_IncludesNotDownloaded(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "downloaded-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
		{ID: "not-downloaded", Downloaded: false, Recipe: "llamacpp", Size: 8.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 2 {
		t.Errorf("expected 2 rows (including not-downloaded), got %d: %v", len(rows), rowIDs(rows))
	}

	// Verify downloaded field is propagated correctly.
	var foundNotDownloaded bool
	for _, r := range rows {
		if r.id == "not-downloaded" {
			foundNotDownloaded = true
			if r.downloaded {
				t.Errorf("not-downloaded row has downloaded=true")
			}
		}
	}
	if !foundNotDownloaded {
		t.Error("not-downloaded model was excluded from rows")
	}
}

// TestBuildModelRows_DownloadedSortedFirst verifies downloaded models appear before not-downloaded.
func TestBuildModelRows_DownloadedSortedFirst(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	// Deliberately put not-downloaded first in the input list.
	fakeList := []models.Model{
		{ID: "not-downloaded-A", Downloaded: false, Recipe: "llamacpp", Size: 5.0},
		{ID: "downloaded-B", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
		{ID: "not-downloaded-C", Downloaded: false, Recipe: "llamacpp", Size: 5.0},
		{ID: "downloaded-D", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 4 {
		t.Fatalf("expected 4 rows, got %d", len(rows))
	}
	// First two should be downloaded.
	if !rows[0].downloaded || !rows[1].downloaded {
		t.Errorf("first two rows should be downloaded: %v %v", rows[0].id, rows[1].id)
	}
	// Last two should be not-downloaded.
	if rows[2].downloaded || rows[3].downloaded {
		t.Errorf("last two rows should be not-downloaded: %v %v", rows[2].id, rows[3].id)
	}
	// Order within each group should be stable (preserved from input).
	if rows[0].id != "downloaded-B" || rows[1].id != "downloaded-D" {
		t.Errorf("downloaded group order: got %v %v, want downloaded-B downloaded-D", rows[0].id, rows[1].id)
	}
	if rows[2].id != "not-downloaded-A" || rows[3].id != "not-downloaded-C" {
		t.Errorf("not-downloaded group order: got %v %v, want not-downloaded-A not-downloaded-C", rows[2].id, rows[3].id)
	}
}

// TestBuildModelRows_SuggestedField verifies the suggested field is propagated.
func TestBuildModelRows_SuggestedField(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "suggested-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Suggested: true},
		{ID: "plain-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Suggested: false},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
	for _, r := range rows {
		switch r.id {
		case "suggested-model":
			if !r.suggested {
				t.Errorf("suggested-model: suggested = false, want true")
			}
		case "plain-model":
			if r.suggested {
				t.Errorf("plain-model: suggested = true, want false")
			}
		}
	}
}

// TestBuildModelRows_FiltersNonLlamacpp verifies that non-llamacpp models are excluded.
func TestBuildModelRows_FiltersNonLlamacpp(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "llama-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
		{ID: "flux-model", Downloaded: true, Recipe: "sd-cpp", Size: 5.0},
		{ID: "whisper-model", Downloaded: true, Recipe: "whispercpp", Size: 5.0},
		{ID: "vllm-model", Downloaded: true, Recipe: "vllm", Size: 5.0},
		{ID: "flm-model", Downloaded: true, Recipe: "flm", Size: 5.0},
		{ID: "kokoro-model", Downloaded: true, Recipe: "kokoro", Size: 5.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Errorf("expected 1 row (llamacpp only), got %d; ids: %v", len(rows), rowIDs(rows))
	}
	if len(rows) > 0 && rows[0].id != "llama-model" {
		t.Errorf("unexpected row id %q, want llama-model", rows[0].id)
	}
}

// TestBuildModelRows_UnknownSizeIsNeutral verifies that a model with unknown size
// (m.Size == 0) gets a neutral fit (not Spills) and renders "?" not "❌".
func TestBuildModelRows_UnknownSizeIsNeutral(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "mystery-model", Downloaded: true, Recipe: "llamacpp", Size: 0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	r := rows[0]

	if r.fit == advise.Spills {
		t.Error("unknown-size row should not have fit=Spills")
	}
	if r.sizeKnown {
		t.Error("sizeKnown should be false")
	}

	rendered := formatModelRow(r.id, r.totalGiB, r.sizeKnown, r.fit, r.ceilingTPS, r.isMoE, r.estimated, r.selected, r.downloaded, r.suggested)
	if strings.Contains(rendered, "❌") {
		t.Errorf("unknown-size row rendered ❌, want ?: %q", rendered)
	}
	if !strings.Contains(rendered, "?") {
		t.Errorf("unknown-size row should render ?, got: %q", rendered)
	}
}

// TestBuildModelRows_MTPModeFilter verifies MTP mode filtering by label.
func TestBuildModelRows_MTPModeFilter(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "mtp-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Labels: []string{"mtp", "llamacpp"}},
		{ID: "plain-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Labels: []string{"llamacpp"}},
		{ID: "not-downloaded-mtp", Downloaded: false, Recipe: "llamacpp", Size: 5.0, Labels: []string{"mtp"}},
	}

	t.Run("MTP mode keeps only mtp-labeled", func(t *testing.T) {
		rows := buildModelRows(fakeList, info, ModeMTP)
		ids := rowIDs(rows)
		for _, r := range rows {
			if r.id == "plain-model" {
				t.Errorf("plain-model (no mtp label) should be excluded in MTP mode; got: %v", ids)
			}
		}
		if len(rows) != 2 {
			t.Errorf("expected 2 rows in MTP mode (mtp-model + not-downloaded-mtp), got %d: %v", len(rows), ids)
		}
	})

	t.Run("HTTP mode keeps all llamacpp regardless of mtp label", func(t *testing.T) {
		rows := buildModelRows(fakeList, info, ModeHTTP)
		if len(rows) != 3 {
			t.Errorf("expected 3 rows in HTTP mode, got %d: %v", len(rows), rowIDs(rows))
		}
	})

	t.Run("Backend mode keeps all llamacpp regardless of mtp label", func(t *testing.T) {
		rows := buildModelRows(fakeList, info, ModeBackend)
		if len(rows) != 3 {
			t.Errorf("expected 3 rows in Backend mode, got %d: %v", len(rows), rowIDs(rows))
		}
	})
}

func rowIDs(rows []modelRow) []string {
	ids := make([]string, len(rows))
	for i, r := range rows {
		ids[i] = r.id
	}
	return ids
}

// TestModelScreenHeader is a teatest integration test that asserts the model
// screen header appears. Uses the fake fetch seam — no real lemonade needed.
func TestModelScreenHeader(t *testing.T) {
	info := hw.Info{
		GfxArch:  "gfx1150",
		RAMGiB:   54.5,
		GTTBytes: 27 << 30,
	}
	cfg := Config{BaseURL: "http://fake-host"}

	// Use the internal model struct directly (same package) so we can inject seams.
	m := model{
		current: screenModel,
		info:    info,
		cfg:     cfg,
	}
	// Inject fake fetch that returns an empty list immediately.
	m.modelPicker.fetchModels = func(baseURL string) ([]models.Model, error) {
		return []models.Model{}, nil
	}
	m.modelPicker.loading = true // simulate loading state

	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(120, 40))
	t.Cleanup(func() { _ = tm.Quit() })

	// Send the loaded message directly.
	tm.Send(modelsLoadedMsg{models: []models.Model{}, err: nil})

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Select Models"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// TestModelPickerSpaceAndEnter verifies space toggles selection and Enter
// carries selected IDs using only pure unit logic (no teatest).
func TestModelPickerSpaceAndEnter(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "model-alpha", Downloaded: true, Recipe: "llamacpp", Size: 4.0},
		{ID: "model-beta", Downloaded: true, Recipe: "llamacpp", Size: 4.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)

	p := modelPicker{rows: rows, cursor: 0}

	// Space on first model.
	p.toggleSelected()
	if !p.rows[0].selected {
		t.Error("model-alpha should be selected")
	}

	// Move to second and select.
	p.cursor = 1
	p.toggleSelected()

	// Enter: collect selected IDs.
	ids := p.selectedIDs()
	if len(ids) != 2 {
		t.Errorf("selectedIDs() = %v; want 2 items", ids)
	}
}

// TestModelEnterGuardsEmptySelection verifies that Enter with no models
// selected stays on screenModel (and flags needSelection), while Enter with
// at least one selected advances to screenParams carrying the selected IDs.
func TestModelEnterGuardsEmptySelection(t *testing.T) {
	rows := []modelRow{
		{id: "model-alpha"},
		{id: "model-beta"},
	}

	t.Run("empty selection stays on screenModel", func(t *testing.T) {
		m := model{current: screenModel}
		m.modelPicker.rows = append([]modelRow(nil), rows...)

		next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
		nm := next.(model)

		if nm.current != screenModel {
			t.Errorf("current = %v; want screenModel (no advance on empty selection)", nm.current)
		}
		if !nm.modelPicker.needSelection {
			t.Error("needSelection should be set after Enter with empty selection")
		}
		if len(nm.selectedModels) != 0 {
			t.Errorf("selectedModels = %v; want empty", nm.selectedModels)
		}
	})

	t.Run("non-empty selection advances to screenParams", func(t *testing.T) {
		m := model{current: screenModel}
		m.modelPicker.rows = append([]modelRow(nil), rows...)
		m.modelPicker.rows[1].selected = true

		next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
		nm := next.(model)

		if nm.current != screenParams {
			t.Errorf("current = %v; want screenParams", nm.current)
		}
		if len(nm.selectedModels) != 1 || nm.selectedModels[0] != "model-beta" {
			t.Errorf("selectedModels = %v; want [model-beta]", nm.selectedModels)
		}
	})
}

// Compile-time check: model implements tea.Model.
var _ tea.Model = model{}
