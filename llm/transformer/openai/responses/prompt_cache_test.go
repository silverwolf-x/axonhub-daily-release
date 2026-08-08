package responses

import (
	"encoding/json"
	"testing"

	"github.com/samber/lo"
	"github.com/stretchr/testify/require"

	"github.com/looplj/axonhub/llm"
)

func TestSupportsExplicitPromptCache(t *testing.T) {
	tests := []struct {
		model   string
		support bool
	}{
		{model: "gpt-5.5", support: false},
		{model: "gpt-5.6", support: true},
		{model: "gpt-5.6-sol", support: true},
		{model: "gpt-6", support: true},
		{model: "claude-sonnet-5", support: false},
		{model: "", support: false},
	}

	for _, tt := range tests {
		t.Run(tt.model, func(t *testing.T) {
			require.Equal(t, tt.support, supportsExplicitPromptCache(tt.model))
		})
	}
}

func TestConvertPromptCacheControlToResponsesBreakpoint(t *testing.T) {
	input := convertInputFromMessagesWithPromptCache(
		[]llm.Message{
			{
				Role: "user",
				Content: llm.MessageContent{
					Content: lo.ToPtr("stable context"),
				},
				CacheControl: &llm.CacheControl{Type: "ephemeral"},
			},
		},
		llm.TransformOptions{ArrayInputs: lo.ToPtr(true)},
		true,
	)

	require.Len(t, input.Items, 1)
	require.Len(t, input.Items[0].Content.Items, 1)
	require.Equal(t, "input_text", input.Items[0].Content.Items[0].Type)
	require.Equal(t, &PromptCacheBreakpoint{Mode: "explicit"}, input.Items[0].Content.Items[0].PromptCacheBreakpoint)
	require.Equal(t, &PromptCacheOptions{Mode: "explicit"}, promptCacheOptionsForInput(input))
}

func TestConvertToolCacheControlToResponsesBreakpoint(t *testing.T) {
	input := convertInputFromMessagesWithPromptCache(
		[]llm.Message{
			{
				Role:       "tool",
				ToolCallID: lo.ToPtr("call_1"),
				Content: llm.MessageContent{
					Content: lo.ToPtr("stable tool result"),
				},
				CacheControl: &llm.CacheControl{Type: "ephemeral"},
			},
		},
		llm.TransformOptions{ArrayInputs: lo.ToPtr(true)},
		true,
	)

	require.Len(t, input.Items, 1)
	require.Equal(t, "function_call_output", input.Items[0].Type)
	require.Len(t, input.Items[0].Output.Items, 1)
	require.Equal(t, "input_text", input.Items[0].Output.Items[0].Type)
	require.Equal(t, &PromptCacheBreakpoint{Mode: "explicit"}, input.Items[0].Output.Items[0].PromptCacheBreakpoint)
}

func TestPromptCacheBreakpointIsNotEmittedForUnsupportedModels(t *testing.T) {
	input := convertInputFromMessagesWithPromptCache(
		[]llm.Message{
			{
				Role: "user",
				Content: llm.MessageContent{
					Content: lo.ToPtr("stable context"),
				},
				CacheControl: &llm.CacheControl{Type: "ephemeral"},
			},
		},
		llm.TransformOptions{ArrayInputs: lo.ToPtr(true)},
		false,
	)

	require.Nil(t, input.Items[0].Content.Items[0].PromptCacheBreakpoint)
	require.Nil(t, promptCacheOptionsForInput(input))
}

func TestPromptCacheFieldsMarshalWithResponsesNames(t *testing.T) {
	body, err := json.Marshal(Request{
		Model: "gpt-5.6-sol",
		Input: Input{Items: []Item{{
			Type: "message",
			Role: "user",
			Content: &Input{Items: []Item{{
				Type:                  "input_text",
				Text:                  lo.ToPtr("stable context"),
				PromptCacheBreakpoint: &PromptCacheBreakpoint{Mode: "explicit"},
			}}},
		}}},
		PromptCacheOptions: &PromptCacheOptions{Mode: "explicit"},
	})
	require.NoError(t, err)
	require.JSONEq(t, `{
		"model":"gpt-5.6-sol",
		"instructions":"",
		"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"stable context","prompt_cache_breakpoint":{"mode":"explicit"}}]}],
		"prompt_cache_options":{"mode":"explicit"}
	}`, string(body))
}
