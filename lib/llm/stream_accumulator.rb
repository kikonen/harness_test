# frozen_string_literal: true

require "json"

require_relative "shared"
require_relative "usage_stats"

module LLM
  # Folds delta chunks into the SAME normalized response the buffered path
  # returns, reading both wire shapes (OpenAI's choices[0].delta, Ollama's
  # top-level message). Delta and usage rules: doc/streaming_design.md.
  class StreamAccumulator
    attr_reader :content, :reasoning, :finish_reason

    def initialize
      @content      = +""
      @reasoning    = +""
      @role         = nil
      @finish_reason = nil
      @usage         = nil
      @extended      = {}
      # Tool calls keyed by position: OpenAI streams them as fragments with an
      # `index`, Ollama sends complete calls keyed by `id`.
      @tool_calls = {}
    end

    # True once ANY part of the answer has arrived. The retry policy turns on
    # this: a request that produced nothing can be re-sent, one that produced
    # a partial answer cannot (re-sending would duplicate it).
    def started?
      !@content.empty? || !@reasoning.empty? || !@tool_calls.empty?
    end

    # Consumes one parsed chunk. Returns the deltas it added
    # ({ content:, reasoning:, tool_call_names: }, {} for a part with nothing)
    # so the caller can show them while the answer is still arriving.
    # tool_call_names is present for ANY chunk that carried tool-call fragments.
    def feed(json)
      return {} unless json.is_a?(Hash)

      delta = stream_delta(json)
      note_finish(json)
      note_usage(json)

      out = {}
      text = text_of(delta, :content)
      unless text.nil?
        @content << text
        out[:content] = text
      end
      think = text_of(delta, :reasoning) ||
        text_of(delta, :reasoning_content) ||
        text_of(delta, :thinking)
      unless think.nil?
        @reasoning << think
        out[:reasoning] = think
      end
      @role ||= delta[:role] if delta[:role]
      add_tool_calls(delta[:tool_calls])
      # Only the NAMES cross the callback boundary, never the arguments: a
      # file.write's arguments are a whole file, and the live consumer draws ONE
      # line (issue #368).
      out[:tool_call_names] = tool_call_names if delta[:tool_calls].is_a?(Array)
      out
    end

    # The answer in the normalized response shape (see BaseBackend).
    def to_response
      message = {
        role: @role || "assistant",
        content: @content.empty? ? nil : @content,
        reasoning: @reasoning.empty? ? nil : @reasoning,
        tool_calls: finished_tool_calls
      }
      response = { choices: [{ message: }] }
      response[:finish_reason] = @finish_reason if @finish_reason
      response[:usage] = @usage.merge(@extended) if @usage
      response
    end

    private

    # Where this chunk's answer lives: OpenAI nests a `delta` inside the
    # first choice, the native endpoint puts the `message` at the top level.
    def stream_delta(json)
      delta = json.dig(:choices, 0, :delta)
      return delta if delta.is_a?(Hash)
      return json[:message] if json[:message].is_a?(Hash)

      {}
    end

    def note_finish(json)
      reason = json.dig(:choices, 0, :finish_reason) || json[:done_reason]
      @finish_reason = reason if reason
      @finish_reason ||= "stop" if json[:done] == true
    end

    # Both wire shapes report counts differently (BaseBackend#usage_for has
    # the same check): the OpenAI `usage` object, or native top-level fields.
    # The native shape reports them on the final chunk only.
    def note_usage(json)
      core = core_usage(json)
      ext  = UsageStats.extended_usage(json)

      @usage = @usage ? @usage.merge(core) : core if core
      # A timings block may ride a chunk of its own; it describes the whole
      # answer, so it is kept until the usage is assembled.
      @extended.merge!(ext) unless ext.empty?
    end

    def core_usage(json)
      usage = json[:usage]
      if usage.is_a?(Hash) && !usage.empty?
        prompt     = usage[:prompt_tokens].to_i
        completion = usage[:completion_tokens].to_i
        # A streamed usage block often omits the total, and a zero total would
        # read as "no tokens" in the stats line, so it is derived here.
        reported   = usage[:total_tokens]
        total      = reported ? reported.to_i : prompt + completion
        return {
          prompt_tokens: prompt,
          completion_tokens: completion,
          total_tokens: total
        }
      end
      return nil unless json.key?(:prompt_eval_count) || json.key?(:eval_count)

      prompt     = json[:prompt_eval_count].to_i
      completion = json[:eval_count].to_i
      {
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: prompt + completion
      }
    end

    def text_of(delta, key)
      value = delta[key]
      return nil if value.nil?

      value.to_s
    end

    # One tool call, keyed so fragments of the same call land together.
    def call_key(call, position)
      call[:index] || call[:id] || position
    end

    def tool_call_names
      @tool_calls.values.filter_map { |call| call[:name] }.freeze
    end

    def add_tool_calls(calls)
      return unless calls.is_a?(Array)

      calls.each_with_index do |call, position|
        next unless call.is_a?(Hash)

        slot = (@tool_calls[call_key(call, position)] ||= new_call)
        slot[:id]   = call[:id].to_s if call[:id]
        function    = call[:function] || {}
        slot[:name] = function[:name] if function[:name]
        merge_arguments(slot, function[:arguments])
      end
    end

    def new_call
      { id: nil, name: nil, arguments: +"", arguments_object: nil }
    end

    # A String is a fragment of the JSON (OpenAI streams it piece by piece);
    # a Hash is the complete object (the native shape's form). Both end up as
    # the String execute_tool_call expects.
    def merge_arguments(slot, arguments)
      case arguments
      when String then slot[:arguments] << arguments
      when Hash   then slot[:arguments_object] = arguments
      end
    end

    def finished_tool_calls
      return nil if @tool_calls.empty?

      @tool_calls.values.filter_map do |call|
        next if call[:name].nil? && call[:id].nil?

        {
          id: call[:id].to_s,
          function: { name: call[:name], arguments: finished_arguments(call) }
        }
      end
    end

    def finished_arguments(call)
      return JSON.generate(call[:arguments_object]) if call[:arguments_object]
      return "{}" if call[:arguments].empty?

      call[:arguments]
    end
  end
end
