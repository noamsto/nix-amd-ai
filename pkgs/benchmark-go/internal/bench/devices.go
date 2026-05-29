package bench

import (
	"fmt"
	"regexp"
	"strings"
)

// backendPrefix maps backend keys to the device-string prefix used by llama-server.
var backendPrefix = map[string]string{
	"rocm":   "ROCm",
	"vulkan": "Vulkan",
}

var deviceRe = regexp.MustCompile(`^\s*([A-Za-z][A-Za-z0-9]*)\s*:`)

// ParseLlamaDevices parses the output of `llama-server --list-devices` and
// returns the device identifier strings (e.g. ["ROCm0", "Vulkan0"]).
//
// Returns an error if the output is non-empty but no known-backend devices
// are found — this indicates a format change in llama-server.
func ParseLlamaDevices(output string) ([]string, error) {
	knownPrefixes := make([]string, 0, len(backendPrefix))
	for _, p := range backendPrefix {
		knownPrefixes = append(knownPrefixes, p)
	}

	var devices []string
	for _, line := range strings.Split(output, "\n") {
		m := deviceRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		token := m[1]
		for _, pfx := range knownPrefixes {
			if strings.HasPrefix(token, pfx) {
				devices = append(devices, token)
				break
			}
		}
	}

	if strings.TrimSpace(output) != "" && len(devices) == 0 {
		return nil, fmt.Errorf(
			"parse_llama_devices: no devices parsed from non-empty output"+
				" (format change?). Raw output:\n%q", output,
		)
	}
	return devices, nil
}

// PickDevice returns the first device string whose prefix matches the given
// backend key (e.g. "rocm", "vulkan"). Returns ("", false) when the backend is
// unknown or no matching device is present.
//
// Python's pick_device raises on both of these miss cases; the Go equivalent
// is the bool. Callers MUST check it and treat ("", false) as a hard error in
// BOTH cases (unknown backend AND no matching device) — never pass the empty
// string on as a --device flag.
func PickDevice(devs []string, backend string) (string, bool) {
	prefix, ok := backendPrefix[backend]
	if !ok {
		return "", false
	}
	for _, d := range devs {
		if strings.HasPrefix(d, prefix) {
			return d, true
		}
	}
	return "", false
}
