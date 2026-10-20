# frozen_string_literal: true

require "net/http"

require_relative "base_backend"

module LLM
  # OpenAI-compatible backend (default, issue #197): POST /v1/chat/completions.
  # The path is appended to the configured base URL as-is, so an
  # http://localhost:11434/v1 base (Ollama's /v1-compatible server) ends up
  # at the right place without any URL rewriting. NOTE: the OpenAI schema
  # num_ctx field - a server cannot be told the context window through this
  # endpoint, so the configured window only affects the client-side context
  # accounting (see issue #197). For real num_ctx control use an 'ollama'
  # profile (native /api/chat).
  class OpenAIBackend < BaseBackend
    def api_type = LLM::OPENAI

    # issue #217: public (like BaseBackend#endpoint_path) so the UI can
    # show the actual call target.
    def endpoint_path = "/chat/completions"

    private

    def build_body(messages, tools, stream: false)
      body = { model: @options[:model], messages: }

      # The OpenAI schema reads the flag at top level. Usage is NOT reported
      # on a streamed response unless asked for explicitly, and without it the
      # harness would lose its token accounting for every streamed turn.
      if stream
        body[:stream] = true
        body[:stream_options] = { include_usage: true }
      end

      # Config owns the sampling values: send each key ONLY when set
      # (issue #215), so the server default applies to anything omitted.
      body[:temperature]        = cfg(:temperature) if cfg(:temperature)
      body[:top_p]              = cfg(:top_p)       if cfg(:top_p)
      body[:top_k]              = cfg(:top_k)       if cfg(:top_k)
      body[:min_p]              = cfg(:min_p)       if cfg(:min_p)
      body[:presence_penalty]   = cfg(:presence_penalty) if cfg(:presence_penalty)
      body[:repeat_penalty]     = cfg(:repeat_penalty)   if cfg(:repeat_penalty)
      body[:max_tokens]         = cfg(:max_tokens)    if cfg(:max_tokens)
      # issue #215: the OpenAI endpoint reads reasoning_effort at TOP LEVEL
      # (openai.go ReasoningEffort -> Think); it is NOT an options key.
      body[:reasoning_effort]   = cfg(:reasoning_effort) if cfg(:reasoning_effort)

      body[:tools] = tools if tools && !tools.empty?
      body
    end

    def parse_response(json)
      message  = json.dig(:choices, 0, :message) || {}
      normalized = {
        choices: [{
          message: {
            role: message[:role] || "assistant",
            content: message[:content],
            reasoning: message[:reasoning] || message[:reasoning_content],
            tool_calls: normalize_tool_calls(message[:tool_calls])
          }
        }]
      }
      normalized[:usage] = normalized_usage(json[:usage]) if json[:usage]
      normalized
    end

    # OpenAI usage block: { prompt_tokens, completion_tokens, total_tokens }.
    def normalized_usage(usage)
      {
        prompt_tokens: usage[:prompt_tokens].to_i,
        completion_tokens: usage[:completion_tokens].to_i,
        total_tokens: (usage[:total_tokens] || 0).to_i
      }
    end
  end
end
