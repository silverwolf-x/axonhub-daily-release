package responses

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/samber/lo"
	"github.com/stretchr/testify/require"

	"github.com/looplj/axonhub/llm"
	"github.com/looplj/axonhub/llm/auth"
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

func TestTransformRequestPromptCacheRequiresChannelOptIn(t *testing.T) {
	tests := []struct {
		name       string
		model      string
		enabled    bool
		breakpoint bool
	}{
		{name: "supported model disabled by default", model: "gpt-5.6-sol", enabled: false, breakpoint: false},
		{name: "supported model explicitly enabled", model: "gpt-5.6-sol", enabled: true, breakpoint: true},
		{name: "unsupported model explicitly enabled", model: "gpt-5.5", enabled: true, breakpoint: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			transformer, err := NewOutboundTransformerWithConfig(&Config{
				BaseURL:                   "https://api.openai.com",
				APIKeyProvider:            auth.NewStaticKeyProvider("test-api-key"),
				EnableExplicitPromptCache: tt.enabled,
			})
			require.NoError(t, err)

			httpReq, err := transformer.TransformRequest(context.Background(), &llm.Request{
				Model: tt.model,
				Messages: []llm.Message{{
					Role: "user",
					Content: llm.MessageContent{
						Content: lo.ToPtr("stable context"),
					},
					CacheControl: &llm.CacheControl{Type: "ephemeral"},
				}},
				TransformOptions: llm.TransformOptions{
					ArrayInputs: lo.ToPtr(true),
				},
			})
			require.NoError(t, err)

			var payload Request
			require.NoError(t, json.Unmarshal(httpReq.Body, &payload))
			require.Len(t, payload.Input.Items, 1)
			require.Len(t, payload.Input.Items[0].Content.Items, 1)

			if tt.breakpoint {
				require.Equal(t, &PromptCacheBreakpoint{Mode: "explicit"}, payload.Input.Items[0].Content.Items[0].PromptCacheBreakpoint)
				require.Equal(t, &PromptCacheOptions{Mode: "explicit"}, payload.PromptCacheOptions)
			} else {
				require.Nil(t, payload.Input.Items[0].Content.Items[0].PromptCacheBreakpoint)
				require.Nil(t, payload.PromptCacheOptions)
			}
		})
	}
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
