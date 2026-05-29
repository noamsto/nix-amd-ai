package bench

// CompletionOpts holds parameters for a streaming completion request.
type CompletionOpts struct {
	Model     string
	Prompt    string
	GenTokens int
	Stream    bool
	IgnoreEOS bool
}

// BuildCompletionPayload builds the JSON body for a streaming /completions
// request, matching Python's build_completion_payload exactly.
//
// Key set: model, prompt, max_tokens, stream (always present).
// ignore_eos is added only when IgnoreEOS=true — required for MTP A/B
// decode measurement to prevent stochastic immediate-EOS producing phantom
// 1-token completions.
func BuildCompletionPayload(o CompletionOpts) map[string]any {
	p := map[string]any{
		"model":      o.Model,
		"prompt":     o.Prompt,
		"max_tokens": o.GenTokens,
		"stream":     o.Stream,
	}
	if o.IgnoreEOS {
		p["ignore_eos"] = true
	}
	return p
}
