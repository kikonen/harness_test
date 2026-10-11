# frozen_string_literal: true

require_relative 'base_backend'

module LLM
  # Native Ollama backend (issue #197): POST /api/chat.
  # Unlike the OpenAI-compatible endpoint, this one accepts sampling and
  # generation parameters in a nested `options` map - INCLUDING num_ctx -
  # so the configured context window is actually applied by the server.
  class OllamaBackend < BaseBackend
    def api_type = LLM::OLLAMA

    private

    def endpoint_path = '/api/chat'

    def build_body(messages, tools)
      body = {
        model: @options[:model],
        messages: messages,
        stream: false,
        options: {
          num_ctx: sample(:num_ctx, LLM::NUM_CTX),
          num_predict: sample(:num_predict, LLM::NUM_PREDICT),
          temperature: sample(:temperature, LLM::TEMPERATURE),
          top_p: sample(:top_p, LLM::TOP_P),
          top_k: sample(:top_k, LLM::TOP_K),
          min_p: sample(:min_p, LLM::MIN_P),
          presence_penalty: sample(:presence_penalty, LLM::PRESENCE_PENALTY),
          repeat_penalty: sample(:repeat_penalty, LLM::REPEAT_PENALTY),
          reasoning_effort: sample(:reasoning_effort, LLM::REASONING_EFFORT)
        }
      }
      body[:tools] = tools if tools && !tools.empty?
      body
    end

    # Native /api/chat returns the assistant message at the top level:
    #   { message: { role:, content:, thinking:, tool_calls: },
    #     prompt_eval_count: <int>, eval_count: <int> }
    # There is no `usage` object; token counts are top-level fields.
    def parse_response(json)
      message  = json[:message] || {}
      normalized = {
        choices: [{
          message: {
            role: message[:role] || 'assistant',
            content: message[:content],
            reasoning: message[:thinking] || message[:reasoning],
            tool_calls: normalize_tool_calls(message[:tool_calls])
          }
        }]
      }

      if json.key?(:prompt_eval_count) || json.key?(:eval_count)
        prompt     = json[:prompt_eval_count].to_i
        completion = json[:eval_count].to_i
        normalized[:usage] = { prompt_tokens: prompt,
                               completion_tokens: completion,
                               total_tokens: prompt + completion }
      end

      normalized
    end
  end
end
