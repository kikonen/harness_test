# frozen_string_literal: true

require 'net/http'

require_relative 'base_backend'

module LLM
  # OpenAI-compatible backend (default, issue #197): POST /v1/chat/completions.
  # The request uses the standard OpenAI schema. NOTE: that schema has NO
  # num_ctx field - a server cannot be told the context window through this
  # endpoint, so the configured window only affects the client-side context
  # accounting (see issue #197). For real num_ctx control use an 'ollama'
  # profile (native /api/chat).
  class OpenAIBackend < BaseBackend
    def api_type = LLM::OPENAI

    private

    def endpoint_path = '/v1/chat/completions'

    def build_body(messages, tools)
      body = {
        model: @options[:model],
        messages: messages,
        temperature: sample(:temperature, LLM::TEMPERATURE),
        top_p: sample(:top_p, LLM::TOP_P),
        top_k: sample(:top_k, LLM::TOP_K),
        min_p: sample(:min_p, LLM::MIN_P),
        presence_penalty: sample(:presence_penalty, LLM::PRESENCE_PENALTY),
        repeat_penalty: sample(:repeat_penalty, LLM::REPEAT_PENALTY),
        max_tokens: LLM::NUM_PREDICT
      }
      body[:tools] = tools if tools && !tools.empty?
      body
    end

    def parse_response(json)
      message  = json.dig(:choices, 0, :message) || {}
      normalized = {
        choices: [{
          message: {
            role: message[:role] || 'assistant',
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
