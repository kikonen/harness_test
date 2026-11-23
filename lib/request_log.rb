# frozen_string_literal: true

require_relative "llm/stream_preview"
require_relative "session"

# The per-request plumbing of a turn (issue #582): the chain request, the
# stream preview the spinner reads, and this request's own clock. It holds the
# live client and tools payload so a model switch or a mid-run tool change is
# seen by the NEXT request, and it publishes the preview so the spinner's
# reader and the turn's request see the same object.
class RequestLog
  # Cleared in the ensure, not after the call: a request that died mid-stream
  # must not leave its partial tail for the next request. doc/streaming_design.md.
  def initialize(client_source:, tools_source:, settings:, context_lines:)
    @client_source  = client_source
    @tools_source   = tools_source
    @settings       = settings
    @context_lines  = context_lines
    @preview        = nil
    @seconds        = 0.0
  end

  attr_reader :preview, :seconds

  def chat(messages)
    streaming = @settings.stream?
    # Session owns the ratio the spinner's rate and context indicator need.
    preview = streaming ? LLM::StreamPreview.new(
      chars_per_token: Session::EST_CHARS_PER_TOKEN) : nil
    @preview = preview
    # The callback holds THIS request's object, not the ivar the ensure clears:
    # a late delta would call record on nil.
    on_delta = preview ? ->(delta) { preview.record(delta) } : nil

    # stats[:elapsed_seconds] is the TURN's, so this request needs its own clock.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      @client_source.call.chat(
        messages,
        tools: @tools_source.call,
        stream: streaming,
        on_delta:)
    ensure
      @seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      @preview = nil
    end
  end

  # A live rate is '~' (estimated from stream chars); a "(last)" rate is the
  # previous request's own measurement, never the in-flight request's number.
  # nil when neither part has anything: the spinner's contract is "no suffix",
  # not an empty segment.
  def wait_line(rate_segment)
    parts = []
    parts << (@context_lines.streaming_line(preview) || @context_lines.live)
    parts << rate_segment.call(pad: true) if rate_segment
    parts.compact!
    return nil if parts.empty?

    parts.join(" ")
  end

  # A tool wait carries NO rate: nothing is in flight, so there is no speed.
  def tool_wait_line
    @context_lines.live
  end
end
