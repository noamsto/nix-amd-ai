package bench

import "fmt"

type ServerArgs struct {
	BinPath   string // absolute path to the backend-specific llama-server binary
	ModelPath string // absolute path to the GGUF file
	Port      int
	Device    string // e.g. "ROCm0" or "Vulkan0"
	SpecType  string // "none" or "draft-mtp"
	NGL       int    // --n-gpu-layers
	Ctx       int    // --ctx-size
}

// BuildLlamaServerArgs returns the argv slice to spawn llama-server.
// Always includes --flash-attn on; appends --spec-draft-n-max 6 when SpecType != "none";
// --parallel 1 for KV-cache budget control.
func BuildLlamaServerArgs(sa ServerArgs) []string {
	args := []string{
		sa.BinPath,
		"--model", sa.ModelPath,
		"--port", fmt.Sprintf("%d", sa.Port),
		"--host", "127.0.0.1",
		"--device", sa.Device,
		"--spec-type", sa.SpecType,
		"--n-gpu-layers", fmt.Sprintf("%d", sa.NGL),
		"--ctx-size", fmt.Sprintf("%d", sa.Ctx),
		"--parallel", "1",
		"--flash-attn", "on",
	}
	if sa.SpecType != "none" {
		args = append(args, "--spec-draft-n-max", "6")
	}
	return args
}
