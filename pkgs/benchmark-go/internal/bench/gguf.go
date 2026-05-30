package bench

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ResolveGGUFByCheckpoint resolves a lemonade checkpoint ("owner/repo" or
// "owner/repo:variant") to a local GGUF path using the HuggingFace hub cache.
//
// variant may be a full filename ("...gguf") or a quant tag ("UD-Q4_K_M").
// mmproj-*.gguf projection files are never returned. Returns "" if not found.
//
// cacheRoot defaults to ~/.cache/huggingface/hub when empty.
func ResolveGGUFByCheckpoint(checkpoint, cacheRoot string) string {
	if checkpoint == "" {
		return ""
	}
	if cacheRoot == "" {
		home, _ := os.UserHomeDir()
		cacheRoot = filepath.Join(home, ".cache", "huggingface", "hub")
	}

	// Split "owner/repo[:variant]"
	repoStr, variant, _ := strings.Cut(checkpoint, ":")
	parts := strings.SplitN(repoStr, "/", 2)
	if len(parts) != 2 {
		return ""
	}
	owner, repo := parts[0], parts[1]
	// A repo containing a further "/" would build a path that descends into a
	// subdir (models--a--b/c); reject it.
	if strings.Contains(repo, "/") {
		return ""
	}

	// Cache dir name is exact: models--<owner>--<repo>
	dirName := "models--" + owner + "--" + repo
	matchedDir := filepath.Join(cacheRoot, dirName)
	if _, err := os.Stat(matchedDir); err != nil {
		return ""
	}

	// Collect all .gguf files, excluding mmproj-*.gguf
	var ggufs []string
	_ = filepath.WalkDir(matchedDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		base := d.Name()
		if !strings.HasSuffix(base, ".gguf") {
			return nil
		}
		if strings.HasPrefix(strings.ToLower(base), "mmproj") {
			return nil
		}
		ggufs = append(ggufs, path)
		return nil
	})
	if len(ggufs) == 0 {
		return ""
	}
	sort.Strings(ggufs)

	if variant == "" {
		return ggufs[0]
	}

	variantLower := strings.ToLower(variant)
	if strings.HasSuffix(variantLower, ".gguf") {
		// Full filename match: basename == variant (case-insensitive)
		for _, p := range ggufs {
			if strings.EqualFold(filepath.Base(p), variant) {
				return p
			}
		}
		return ""
	}

	// Quant tag: pick the first .gguf whose basename contains the variant (case-insensitive)
	for _, p := range ggufs {
		if strings.Contains(strings.ToLower(filepath.Base(p)), variantLower) {
			return p
		}
	}
	return ""
}

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
