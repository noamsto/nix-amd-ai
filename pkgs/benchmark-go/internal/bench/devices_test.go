package bench

import (
	"testing"
)

// Real llama-server --list-devices output samples (verbatim).
const rocmOutput = "Available devices:\n" +
	"  ROCm0: AMD Radeon 890M Graphics (27935 MiB, 49248 MiB free)\n"

const vulkanOutput = "Available devices:\n" +
	"  Vulkan0: AMD Radeon 890M Graphics (RADV STRIX1)" +
	" (36127 MiB, 35117 MiB free)\n"

func TestParseLlamaDevices_ROCm(t *testing.T) {
	devs, err := ParseLlamaDevices(rocmOutput)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devs) != 1 || devs[0] != "ROCm0" {
		t.Fatalf("got %v, want [ROCm0]", devs)
	}
}

func TestParseLlamaDevices_Vulkan(t *testing.T) {
	devs, err := ParseLlamaDevices(vulkanOutput)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devs) != 1 || devs[0] != "Vulkan0" {
		t.Fatalf("got %v, want [Vulkan0]", devs)
	}
}

func TestParseLlamaDevices_Empty(t *testing.T) {
	devs, err := ParseLlamaDevices("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(devs) != 0 {
		t.Fatalf("got %v, want []", devs)
	}
}

func TestParseLlamaDevices_NonEmptyNoDevices_Errors(t *testing.T) {
	_, err := ParseLlamaDevices("Some unrelated diagnostic output: foo bar\n")
	if err == nil {
		t.Fatal("expected error for non-empty output with no devices")
	}
}

func TestParseLlamaDevices_HeaderOnly_Errors(t *testing.T) {
	_, err := ParseLlamaDevices("Available devices:\n")
	if err == nil {
		t.Fatal("expected error for header-only output with no devices")
	}
}

func TestPickDevice_ROCm(t *testing.T) {
	devs := []string{"Vulkan0", "ROCm0"}
	got, ok := PickDevice(devs, "rocm")
	if !ok || got != "ROCm0" {
		t.Fatalf("got %q %v, want ROCm0 true", got, ok)
	}
}

func TestPickDevice_Vulkan(t *testing.T) {
	devs := []string{"Vulkan0", "ROCm0"}
	got, ok := PickDevice(devs, "vulkan")
	if !ok || got != "Vulkan0" {
		t.Fatalf("got %q %v, want Vulkan0 true", got, ok)
	}
}

func TestPickDevice_UnknownBackend_ReturnsFalse(t *testing.T) {
	devs := []string{"Vulkan0", "ROCm0"}
	_, ok := PickDevice(devs, "cuda")
	if ok {
		t.Fatal("expected false for unknown backend cuda")
	}
}

func TestPickDevice_MissingDevice_ReturnsFalse(t *testing.T) {
	devs := []string{"Vulkan0"}
	_, ok := PickDevice(devs, "rocm")
	if ok {
		t.Fatal("expected false when rocm device not in list")
	}
}
