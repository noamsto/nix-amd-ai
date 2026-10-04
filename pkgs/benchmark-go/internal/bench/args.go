package bench

import "fmt"

type ServerArgs struct {
	BinPath        string // absolute path to the backend-specific llama-server binary
	ModelPath      string // absolute path to the GGUF file
	DraftModelPath string // optional external MTP draft head -> --model-draft
	Port           int
	Device         string // e.g. "ROCm0" or "Vulkan0"
	SpecType       string // "none" or "draft-mtp"
	NGL            int    // --n-gpu-layers
	Ctx            int    // --ctx-size
	DraftNMax      int    // --spec-draft-n-max for SpecType != "none"; <=0 defaults to 6
}

// BuildLlamaServerArgs returns the argv slice to spawn llama-server.
// --flash-attn on and --parallel 1 always; on the MTP arm (SpecType != "none")
// an external --model-draft is appended if set, plus --spec-draft-n-max
// (default 6).
func BuildLlamaServerArgs(sa ServerArgs) []string {
	args := []string{
		sa.BinPath,
		"--model", sa.ModelPath,
	}
	if sa.SpecType != "none" && sa.DraftModelPath != "" {
		args = append(args, "--model-draft", sa.DraftModelPath)
	}
	args = append(args,
		"--port", fmt.Sprintf("%d", sa.Port),
		"--host", "127.0.0.1",
		"--device", sa.Device,
		"--spec-type", sa.SpecType,
		"--n-gpu-layers", fmt.Sprintf("%d", sa.NGL),
		"--ctx-size", fmt.Sprintf("%d", sa.Ctx),
		"--parallel", "1",
		"--flash-attn", "on",
	)
	if sa.SpecType != "none" {
		nmax := sa.DraftNMax
		if nmax <= 0 {
			nmax = 6
		}
		args = append(args, "--spec-draft-n-max", fmt.Sprintf("%d", nmax))
	}
	return args
}
