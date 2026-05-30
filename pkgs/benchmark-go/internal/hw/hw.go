package hw

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Info holds detected host hardware properties. Fields are zero/empty when the
// source is unavailable (missing binary, permission denied, etc.).
type Info struct {
	GfxArch     string  // e.g. "gfx1150"; from amdgpu_top ASIC Name field
	RAMGiB      float64 // MemTotal from /proc/meminfo converted to GiB
	RAMType     string  // e.g. "DDR5"; from dmidecode (needs root); "" if unknown
	RAMSpeedMTs int     // e.g. 5600; from dmidecode; 0 if unknown
	VRAMBytes   uint64  // UMA carveout; from mem_info_vram_total sysfs
	GTTBytes    uint64  // GTT ceiling; from mem_info_gtt_total sysfs
	GRBMBusyPct float64 // GPU Graphics Pipe utilisation; from amdgpu_top GRBM
	Governor    string  // CPU scaling_governor for cpu0
	Performance bool    // true when platform_profile==performance AND EPP==performance
	OnAC        bool    // true when any A* power supply online==1
}

// amdgpuTopJSON is the minimal shape of one NDJSON line from `amdgpu_top --json`.
// Each invocation emits one or more newline-terminated JSON objects; we use the first.
type amdgpuTopJSON struct {
	Devices []struct {
		GRBM map[string]struct {
			Value float64 `json:"value"`
		} `json:"GRBM"`
		Info struct {
			ASICName string `json:"ASIC Name"`
		} `json:"Info"`
	} `json:"devices"`
}

// parseMemTotalGiB parses /proc/meminfo content and returns MemTotal in GiB.
// Returns 0 on parse failure.
func parseMemTotalGiB(data []byte) float64 {
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		// "MemTotal:       57212812 kB"
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return 0
		}
		kb, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			return 0
		}
		return kb / (1024 * 1024) // kB → GiB
	}
	return 0
}

// parseAmdgpuTop decodes the first NDJSON record from amdgpu_top --json output.
// grbmBusyPct is devices[0].GRBM["Graphics Pipe"].value.
// arch is extracted from devices[0].Info["ASIC Name"]: e.g. "GFX1150/Strix Point"
// → "gfx1150" (the part before "/" lowercased).
// Returns ("", 0) on decode failure.
func parseAmdgpuTop(data []byte) (grbmBusyPct float64, arch string) {
	// Use only the first newline-delimited record.
	line := data
	if idx := bytes.IndexByte(data, '\n'); idx >= 0 {
		line = data[:idx]
	}
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return 0, ""
	}

	var top amdgpuTopJSON
	if err := json.Unmarshal(line, &top); err != nil {
		return 0, ""
	}
	if len(top.Devices) == 0 {
		return 0, ""
	}
	dev := top.Devices[0]

	if gp, ok := dev.GRBM["Graphics Pipe"]; ok {
		grbmBusyPct = gp.Value
	}

	// ASIC Name is "GFX1150/Strix Point" → take part before "/" and lowercase.
	asic := dev.Info.ASICName
	if slash := strings.IndexByte(asic, '/'); slash > 0 {
		arch = strings.ToLower(asic[:slash])
	} else if asic != "" {
		arch = strings.ToLower(asic)
	}

	return grbmBusyPct, arch
}

// parseBytesFile parses a sysfs integer file (e.g. mem_info_vram_total).
// Returns 0 on parse failure.
func parseBytesFile(data []byte) uint64 {
	s := strings.TrimSpace(string(data))
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0
	}
	return v
}

// parseDmidecodeMemory extracts RAM type and configured speed from dmidecode
// -t memory output. It looks for the first populated (non-"Unknown", non-"No
// Module Installed") memory device block.
// Returns ("", 0) when the information is absent or unparseable.
//
// dmidecode format: a Handle line is followed by a type name line, then
// tab-indented fields. We enter a "Memory Device" block when we see the bare
// line "Memory Device" (not indented), and exit when we hit the next Handle.
func parseDmidecodeMemory(data []byte) (ramType string, speedMTs int) {
	sc := bufio.NewScanner(bytes.NewReader(data))
	inDevice := false
	var speedFallback int // from "Speed:" line; overridden by "Configured Memory Speed:"
	for sc.Scan() {
		line := sc.Text()
		trimmed := strings.TrimSpace(line)

		// "Memory Device" appears as an unindented line (no leading tab/space).
		if line == "Memory Device" {
			inDevice = true
			continue
		}
		// A new Handle line marks the start of the next section.
		if strings.HasPrefix(trimmed, "Handle ") {
			inDevice = false
			continue
		}
		if !inDevice {
			continue
		}

		// "Type: DDR5" — skip "Type Detail:" and "Error Correction Type:"
		if strings.HasPrefix(trimmed, "Type:") && !strings.HasPrefix(trimmed, "Type Detail:") {
			val := strings.TrimSpace(strings.TrimPrefix(trimmed, "Type:"))
			if val != "" && val != "Unknown" && val != "Other" && ramType == "" {
				ramType = val
			}
		}

		// "Configured Memory Speed:" is authoritative; "Speed:" is a fallback.
		if strings.HasPrefix(trimmed, "Configured Memory Speed:") {
			val := strings.TrimSpace(strings.TrimPrefix(trimmed, "Configured Memory Speed:"))
			if v := parseSpeedMTs(val); v != 0 {
				speedMTs = v
			}
		} else if strings.HasPrefix(trimmed, "Speed:") && speedFallback == 0 {
			val := strings.TrimSpace(strings.TrimPrefix(trimmed, "Speed:"))
			speedFallback = parseSpeedMTs(val)
		}

		if ramType != "" && speedMTs != 0 {
			return ramType, speedMTs
		}
	}
	// Use fallback speed if "Configured Memory Speed:" was absent.
	if speedMTs == 0 {
		speedMTs = speedFallback
	}
	return ramType, speedMTs
}

// parseSpeedMTs parses a dmidecode speed string like "5600 MT/s" → 5600.
func parseSpeedMTs(s string) int {
	s = strings.TrimSuffix(s, " MT/s")
	s = strings.TrimSpace(s)
	v, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return v
}

// findAMDGPUCard returns the sysfs device path for the first DRM card that has
// a mem_info_vram_total file (i.e. an amdgpu card).
func findAMDGPUCard() (string, error) {
	matches, err := filepath.Glob("/sys/class/drm/card*/device/mem_info_vram_total")
	if err != nil || len(matches) == 0 {
		return "", fmt.Errorf("no amdgpu card found")
	}
	// Return the device directory for the first match.
	return filepath.Dir(matches[0]), nil
}

// readFile reads a file and returns its contents. Returns nil on error.
func readFile(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return data
}

// readSysfsString reads a sysfs file and returns trimmed string. Returns "" on error.
func readSysfsString(path string) string {
	return strings.TrimSpace(string(readFile(path)))
}

// runAmdgpuTop spawns amdgpu_top --json, reads only the first NDJSON line,
// then kills the process. amdgpu_top streams continuously so we must not use
// cmd.Output() which waits for EOF.
func runAmdgpuTop() (grbmBusyPct float64, arch string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "amdgpu_top", "--json")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 0, ""
	}
	if err := cmd.Start(); err != nil {
		return 0, ""
	}
	// Read the first non-empty line.
	sc := bufio.NewScanner(stdout)
	var line []byte
	for sc.Scan() {
		l := bytes.TrimSpace(sc.Bytes())
		if len(l) > 0 {
			line = make([]byte, len(l))
			copy(line, l)
			break
		}
	}
	// Kill the process — ignore any wait error (context deadline or signal).
	_ = cmd.Process.Kill()
	_ = cmd.Wait()

	if len(line) == 0 {
		return 0, ""
	}
	return parseAmdgpuTop(line)
}

// Detect reads host hardware and returns an Info struct.
// It never panics and degrades gracefully when any source is unavailable.
func Detect() Info {
	var info Info

	// RAM total from /proc/meminfo
	if data := readFile("/proc/meminfo"); data != nil {
		info.RAMGiB = parseMemTotalGiB(data)
	}

	// VRAM and GTT from amdgpu sysfs
	if cardDev, err := findAMDGPUCard(); err == nil {
		if data := readFile(filepath.Join(cardDev, "mem_info_vram_total")); data != nil {
			info.VRAMBytes = parseBytesFile(data)
		}
		if data := readFile(filepath.Join(cardDev, "mem_info_gtt_total")); data != nil {
			info.GTTBytes = parseBytesFile(data)
		}
	}

	// GPU utilisation and arch from amdgpu_top.
	// amdgpu_top --json streams NDJSON forever; use a 5-second context so we
	// kill the process after capturing the first sample line.
	info.GRBMBusyPct, info.GfxArch = runAmdgpuTop()

	// CPU governor
	govPath := "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
	info.Governor = readSysfsString(govPath)

	// Platform performance: profile + EPP must both be "performance"
	profile := readSysfsString("/sys/firmware/acpi/platform_profile")
	eppPath := "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"
	epp := readSysfsString(eppPath)
	info.Performance = profile == "performance" && epp == "performance"

	// AC power: any power supply named A* with online==1
	acMatches, _ := filepath.Glob("/sys/class/power_supply/A*/online")
	for _, p := range acMatches {
		if readSysfsString(p) == "1" {
			info.OnAC = true
			break
		}
	}

	// RAM type and speed from dmidecode (needs root; tolerate failure)
	if out, err := exec.Command("dmidecode", "-t", "memory").Output(); err == nil {
		info.RAMType, info.RAMSpeedMTs = parseDmidecodeMemory(out)
	}

	return info
}
