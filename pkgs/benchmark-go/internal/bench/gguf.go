package bench

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ResolveLemonadeGGUF returns the absolute path to the GGUF file for a
// lemonade model id, using the HuggingFace hub cache layout:
//
//	<cacheRoot>/models--<owner>--<repo>/snapshots/<rev>/<file>.gguf
//
// The model id matches the trailing repo segment (everything after the second
// "--"). Returns "" if no matching directory exists or it contains no .gguf.
//
// cacheRoot defaults to ~/.cache/huggingface/hub when empty.
func ResolveLemonadeGGUF(modelID, cacheRoot string) string {
	if cacheRoot == "" {
		home, _ := os.UserHomeDir()
		cacheRoot = filepath.Join(home, ".cache", "huggingface", "hub")
	}

	entries, err := os.ReadDir(cacheRoot)
	if err != nil {
		return ""
	}

	// ReadDir already returns entries sorted, matching sorted(cache_dir.iterdir()).
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "models--") {
			continue
		}
		// split on "--" up to 3 parts: ["models", "<owner>", "<repo>"]
		parts := strings.SplitN(name, "--", 3)
		if len(parts) != 3 {
			continue
		}
		if parts[2] != modelID {
			continue
		}

		// Matched directory — find the lexicographically first .gguf.
		matchedDir := filepath.Join(cacheRoot, name)
		var ggufs []string
		_ = filepath.WalkDir(matchedDir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if strings.HasSuffix(d.Name(), ".gguf") {
				ggufs = append(ggufs, path)
			}
			return nil
		})
		if len(ggufs) == 0 {
			return ""
		}
		sort.Strings(ggufs)
		return ggufs[0]
	}
	return ""
}
