# frozen_string_literal: true

require_relative 'base_backend'

module LLM
  # Native Ollama backend (issue #197): POST /api/chat.
  # Unlike the OpenAI-compatible endpoint, this one accepts sampling and
  # generation parameters in a nested `options` map - INCLUDING num_ctx -
  # so the configured context window is actually applied by the server.
  class OllamaBackend < BaseBackend
    def api_type = LLM::OLLAMA

    # issue #217: public (like BaseBackend#endpoint_path) so the UI can
    # show the actual call target.
    def endpoint_path = '/api/chat'

    private

    # issue #215: the native /api/chat models tool-call arguments as JSON
    # OBJECTS (ToolCallFunctionArguments unmarshals into an ordered map),
    # not the OpenAI string form. Convert the session's string args on the
    # wire; the stored history keeps the canonical string shape.
    def serialize_messages(messages)
      messages.map { |m| m[:tool_calls] ? (m.merge(tool_calls: tool_call_args(m))) : m }
    end

    def serialize_args(args)
      args.is_a?(String) ? JSON.parse(args) : (args || {})
    rescue JSON::ParserError
      {}
    end

    def build_body(messages, tools)
      body = { model: @options[:model], messages: messages, stream: false,
               options: sampling_options }
      body[:tools] = tools if tools && !tools.empty?
      # issue #215: the native API has no 'reasoning_effort' option
      # (Options.FromMap warns and drops it); thinking is the top-level
      # 'think' field. An unknown level is tolerated server-side: it
      # resolves to the model's default.
      body[:think] = cfg(:reasoning_effort) if cfg(:reasoning_effort)
      body
    end

    # The native `options` map: sampling + generation limits, sent ONLY
    # when configured (issue #215). num_ctx is always sent - the built-in
    # window is its purpose here (the whole point of this backend).
    def sampling_options
      options = { num_ctx: ctx_window }
      options[:num_predict]        = cfg(:num_predict) if cfg(:num_predict)
      options[:temperature]        = cfg(:temperature) if cfg(:temperature)
      options[:top_p]              = cfg(:top_p)       if cfg(:top_p)
      options[:top_k]              = cfg(:top_k)       if cfg(:top_k)
      options[:min_p]              = cfg(:min_p)       if cfg(:min_p)
      options[:presence_penalty]   = cfg(:presence_penalty) if cfg(:presence_penalty)
      options[:repeat_penalty]     = cfg(:repeat_penalty)   if cfg(:repeat_penalty)
      options
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
