package bench

import (
	"strings"
	"testing"
)

func TestBuildPrompt(t *testing.T) {
	cases := []struct {
		n    int
		want string
	}{
		{0, ""},
		{1, "The "},
		{2, "The The "},
		{3, "The The The "},
		{4, "The The The The "},
		{5, "The The The The The "},
	}
	for _, c := range cases {
		if got := BuildPrompt(c.n); got != c.want {
			t.Errorf("BuildPrompt(%d): got %q, want %q", c.n, got, c.want)
		}
	}
}

func TestBuildMTPPrompt(t *testing.T) {
	t.Run("length_is_prompt_tokens_times_4", func(t *testing.T) {
		for _, n := range []int{1, 10, 100, 512} {
			p := BuildMTPPrompt(n)
			want := n * 4
			if len(p) != want {
				t.Errorf("n=%d: got len %d, want %d", n, len(p), want)
			}
		}
	})

	t.Run("content_is_prefix_of_repeated_base", func(t *testing.T) {
		// For small n, the result must be a prefix of MTPPromptBase repeated
		n := 10
		p := BuildMTPPrompt(n)
		target := n * 4 // 40 chars
		// Build expected by repeating base until >= target, then cut
		base := MTPPromptBase()
		full := ""
		for len(full) < target {
			full += base
		}
		expected := full[:target]
		if p != expected {
			t.Errorf("got %q, want %q", p, expected)
		}
	})

	t.Run("starts_with_known_prefix", func(t *testing.T) {
		p := BuildMTPPrompt(100)
		// The passage starts with "The quick brown fox..."
		if !strings.HasPrefix(p, "The quick brown fox") {
			t.Errorf("expected MTP prompt to start with 'The quick brown fox', got prefix: %q", p[:min(30, len(p))])
		}
	})
}
