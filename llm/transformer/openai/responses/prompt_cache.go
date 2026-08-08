package responses

import (
	"strconv"
	"strings"

	"github.com/looplj/axonhub/llm"
)

const explicitPromptCacheMode = "explicit"

// PromptCacheOptions controls GPT-5.6+ prompt-cache breakpoint behavior.
// The field is only emitted when an Anthropic cache-control marker was mapped
// to at least one Responses input content block.
type PromptCacheOptions struct {
	Mode string `json:"mode,omitempty"`
}

// PromptCacheBreakpoint marks the end of a cacheable Responses input prefix.
type PromptCacheBreakpoint struct {
	Mode string `json:"mode"`
}

func explicitPromptCacheBreakpoint() *PromptCacheBreakpoint {
	return &PromptCacheBreakpoint{Mode: explicitPromptCacheMode}
}

func isEphemeralCacheControl(cacheControl *llm.CacheControl) bool {
	return cacheControl != nil && cacheControl.Type == "ephemeral"
}

// supportsExplicitPromptCache reports whether a model is eligible for the GPT-5.6
// prompt cache breakpoint contract after its channel has explicitly opted in.
// Older models reject these request fields.
func supportsExplicitPromptCache(model string) bool {
	model = strings.ToLower(strings.TrimSpace(model))
	if !strings.HasPrefix(model, "gpt-") {
		return false
	}

	version := strings.TrimPrefix(model, "gpt-")
	if separator := strings.IndexByte(version, '-'); separator >= 0 {
		version = version[:separator]
	}

	versionParts := strings.SplitN(version, ".", 2)
	major, err := strconv.Atoi(versionParts[0])
	if err != nil {
		return false
	}

	minor := 0
	if len(versionParts) == 2 {
		minor, err = strconv.Atoi(versionParts[1])
		if err != nil {
			return false
		}
	}

	return major > 5 || major == 5 && minor >= 6
}

func hasPromptCacheBreakpoint(input Input) bool {
	for _, item := range input.Items {
		if item.PromptCacheBreakpoint != nil {
			return true
		}
		if item.Content != nil && hasPromptCacheBreakpoint(*item.Content) {
			return true
		}
		if item.Output != nil && hasPromptCacheBreakpoint(*item.Output) {
			return true
		}
	}

	return false
}

func promptCacheOptionsForInput(input Input) *PromptCacheOptions {
	if !hasPromptCacheBreakpoint(input) {
		return nil
	}

	return &PromptCacheOptions{Mode: explicitPromptCacheMode}
}

type promptCacheBreakpointMode struct {
	enabled bool
}

func (m promptCacheBreakpointMode) forCacheControl(cacheControl *llm.CacheControl) *PromptCacheBreakpoint {
	if !m.enabled || !isEphemeralCacheControl(cacheControl) {
		return nil
	}

	return explicitPromptCacheBreakpoint()
}

func (m promptCacheBreakpointMode) forMessageContentPart(part llm.MessageContentPart) *PromptCacheBreakpoint {
	return m.forCacheControl(part.CacheControl)
}
