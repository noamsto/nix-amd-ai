package hw

import (
	"os"
	"testing"
)

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

// TestParseMemTotalGiB checks that the captured /proc/meminfo yields a value
// in the expected range for this 64 GiB machine.
func TestParseMemTotalGiB(t *testing.T) {
	data := readFixture(t, "meminfo")
	got := parseMemTotalGiB(data)
	if got < 50 || got > 70 {
		t.Errorf("parseMemTotalGiB = %.2f GiB; want 50..70", got)
	}
}

func TestParseMemTotalGiB_Synthetic(t *testing.T) {
	input := []byte("MemTotal:       57212812 kB\nMemFree:       1000000 kB\n")
	got := parseMemTotalGiB(input)
	// 57212812 kB / 1048576 ≈ 54.57
	if got < 54 || got > 55 {
		t.Errorf("parseMemTotalGiB = %.4f; want ~54.57", got)
	}
}

func TestParseMemTotalGiB_Empty(t *testing.T) {
	if got := parseMemTotalGiB([]byte("")); got != 0 {
		t.Errorf("empty input: got %.2f, want 0", got)
	}
}

// TestParseAmdgpuTop checks the captured amdgpu_top fixture. This is a stable
// real capture from the target box (Radeon 890M / Strix Point), so we pin the
// exact arch as a regression anchor.
func TestParseAmdgpuTop(t *testing.T) {
	data := readFixture(t, "amdgpu_top.json")
	grbm, arch := parseAmdgpuTop(data)
	if arch != "gfx1150" {
		t.Errorf("parseAmdgpuTop: arch = %q; want gfx1150", arch)
	}
	// GRBM may be 0 (GPU idle) — just check it's not negative.
	if grbm < 0 {
		t.Errorf("parseAmdgpuTop: grbm = %v; want >= 0", grbm)
	}
	t.Logf("arch=%q grbm=%.1f%%", arch, grbm)
}

func TestParseAmdgpuTop_Synthetic(t *testing.T) {
	// Minimal valid NDJSON record with a non-zero GRBM value.
	input := []byte(`{"devices":[{"GRBM":{"Graphics Pipe":{"unit":"%","value":42.5}},"Info":{"ASIC Name":"GFX1150/Strix Point"}}]}`)
	grbm, arch := parseAmdgpuTop(input)
	if arch != "gfx1150" {
		t.Errorf("arch = %q; want gfx1150", arch)
	}
	if grbm != 42.5 {
		t.Errorf("grbm = %v; want 42.5", grbm)
	}
}

func TestParseAmdgpuTop_Empty(t *testing.T) {
	grbm, arch := parseAmdgpuTop([]byte(""))
	if arch != "" || grbm != 0 {
		t.Errorf("empty input: got grbm=%v arch=%q; want 0/\"\"", grbm, arch)
	}
}

// TestParseBytesFile checks the captured VRAM and GTT sysfs values.
func TestParseBytesFile_VRAM(t *testing.T) {
	data := readFixture(t, "mem_info_vram_total")
	got := parseBytesFile(data)
	// Expect ~8 GiB = 8589934592
	if got < 8e9 || got > 9e9 {
		t.Errorf("VRAM = %d; want ~8589934592", got)
	}
	t.Logf("VRAM = %d bytes", got)
}

func TestParseBytesFile_GTT(t *testing.T) {
	data := readFixture(t, "mem_info_gtt_total")
	got := parseBytesFile(data)
	// Expect ~27 GiB = 29292957696
	if got < 28e9 || got > 31e9 {
		t.Errorf("GTT = %d; want ~29292957696", got)
	}
	t.Logf("GTT = %d bytes", got)
}

func TestParseBytesFile_Synthetic(t *testing.T) {
	if got := parseBytesFile([]byte("8589934592\n")); got != 8589934592 {
		t.Errorf("got %d; want 8589934592", got)
	}
}

func TestParseBytesFile_Empty(t *testing.T) {
	if got := parseBytesFile([]byte("")); got != 0 {
		t.Errorf("empty: got %d, want 0", got)
	}
}

// TestParseDmidecodeMemory checks the captured dmidecode fixture. This is a
// stable real capture (2x 32 GiB Samsung DDR5-5600 SO-DIMMs), so we pin the
// exact values as a regression anchor.
func TestParseDmidecodeMemory(t *testing.T) {
	data := readFixture(t, "dmidecode_memory.txt")
	ramType, speedMTs := parseDmidecodeMemory(data)
	if ramType != "DDR5" {
		t.Errorf("parseDmidecodeMemory: ramType = %q; want DDR5", ramType)
	}
	if speedMTs != 5600 {
		t.Errorf("parseDmidecodeMemory: speedMTs = %d; want 5600", speedMTs)
	}
	t.Logf("RAMType=%q SpeedMTs=%d", ramType, speedMTs)
}

func TestParseDmidecodeMemory_Synthetic(t *testing.T) {
	input := []byte(`# dmidecode 3.7
Handle 0x0058, DMI type 17, 92 bytes
Memory Device
	Type: LPDDR5
	Speed: 6400 MT/s
	Configured Memory Speed: 5600 MT/s
`)
	ramType, speedMTs := parseDmidecodeMemory(input)
	if ramType != "LPDDR5" {
		t.Errorf("ramType = %q; want LPDDR5", ramType)
	}
	// Configured Memory Speed wins over Speed
	if speedMTs != 5600 {
		t.Errorf("speedMTs = %d; want 5600", speedMTs)
	}
}

func TestParseDmidecodeMemory_Empty(t *testing.T) {
	ramType, speedMTs := parseDmidecodeMemory([]byte(""))
	if ramType != "" || speedMTs != 0 {
		t.Errorf("empty: got %q/%d; want \"\"/0", ramType, speedMTs)
	}
}

func TestParseDmidecodeMemory_Unknown(t *testing.T) {
	// "Unknown" should be skipped.
	input := []byte(`Handle 0x0058, DMI type 17, 92 bytes
Memory Device
	Type: Unknown
	Speed: Unknown
`)
	ramType, speedMTs := parseDmidecodeMemory(input)
	if ramType != "" {
		t.Errorf("Type Unknown should yield empty; got %q", ramType)
	}
	if speedMTs != 0 {
		t.Errorf("Speed Unknown should yield 0; got %d", speedMTs)
	}
}

// TestParseDmidecodeMemory_EmptySlot ensures an unpopulated DIMM slot ("No
// Module Installed") listed before a populated one is skipped, not reported.
func TestParseDmidecodeMemory_EmptySlot(t *testing.T) {
	input := []byte(`Handle 0x0009, DMI type 17, 92 bytes
Memory Device
	Type: No Module Installed
	Speed: Unknown
Handle 0x000C, DMI type 17, 92 bytes
Memory Device
	Type: DDR5
	Speed: 5600 MT/s
	Configured Memory Speed: 5600 MT/s
`)
	ramType, speedMTs := parseDmidecodeMemory(input)
	if ramType != "DDR5" {
		t.Errorf("ramType = %q; want DDR5 (empty slot must be skipped)", ramType)
	}
	if speedMTs != 5600 {
		t.Errorf("speedMTs = %d; want 5600", speedMTs)
	}
}

// TestGRBMBusyPct_NoError verifies that GRBMBusyPct returns without panic and
// never returns a negative value. It exercises the same amdgpu_top/parse path
// as parseAmdgpuTop (covered by the fixture tests above) but via the exported
// entry point used by the TUI's GRBM ticker.
func TestGRBMBusyPct_NoError(t *testing.T) {
	got := GRBMBusyPct()
	if got < 0 {
		t.Errorf("GRBMBusyPct() = %v; want >= 0", got)
	}
	t.Logf("GRBMBusyPct() = %.1f%%", got)
}

// TestDetect_Smoke calls Detect on the real box and asserts basic liveness.
// Run with -short to skip (but it should pass on the target machine).
func TestDetect_Smoke(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping Detect smoke test in short mode")
	}
	info := Detect()
	if info.RAMGiB <= 0 {
		t.Errorf("Detect: RAMGiB = %v; want > 0", info.RAMGiB)
	}
	if info.GfxArch == "" {
		t.Error("Detect: GfxArch is empty")
	}
	if info.VRAMBytes == 0 {
		t.Error("Detect: VRAMBytes is 0")
	}
	if info.GTTBytes == 0 {
		t.Error("Detect: GTTBytes is 0")
	}
	t.Logf("Detect: %+v", info)
}
