# frozen_string_literal: true

require_relative "usage_stats"

module LLM
  # The live state of a streamed answer, for the spinner: its newest text and
  # the rate that text arrived at (issue #285).
  # Invariant: the writer is the task thread and the reader the main thread, so
  # #record publishes ONE frozen group into one slot rather than appending to a
  # shared String - a reader can never pair a newer truncation decision with an
  # older tail. Threading, tail and rate rules: doc/streaming_design.md.
  class StreamPreview
    # The width of the tail segment the spinner shows: the newest part of the
    # answer, with the truncation marker counted INSIDE that width. A fixed width
    # is the point - the tail is redrawn every frame, and a segment that changes
    # width shifts the rate segment and the posture badges drawn after it.
    MAX_TAIL = 60

    # Prepended when older text was dropped. One character, because a three-dot
    # marker in front of a kept tail that BEGINS with the dots of an ellipsis the
    # ANSWER wrote read as ".... The bottom" - dots that look like content and
    # are none. It is always the segment's first character.
    TAIL_MARKER = "…"

    # What the cut can leave at the seam: the tail of an ellipsis the answer
    # itself wrote, and the blanks after it (a collapsed newline counts). The
    # marker replaces this run; dots FURTHER inside the tail are the answer's own
    # text and are left exactly as it wrote them.
    CUT_SEAM = /\A[.…]*\s*/

    # The segment shown while the model is writing a tool call (issue #368). The
    # names follow it; a fragment that arrived before the name shows the bare
    # phase, which is still better than a line that looks frozen.
    TOOL_PHASE = "writing tool call"

    # The rate converts the stream's CHARACTERS to tokens; the caller injects
    # the ratio it uses everywhere else for estimates (Session#estimate_tokens),
    # so the spinner's rate and its context estimate agree instead of each
    # carrying its own magic number.
    def initialize(max_tail: MAX_TAIL, chars_per_token:, clock: nil)
      @max_tail        = max_tail
      @chars_per_token = chars_per_token
      @clock           = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @full     = +""
      @thinking = +""
      @tail     = nil # [newest text, older text was dropped?, rate]
      # Taken on the first delta: prefill (processing the prompt) produces no
      # text, so a rate measured from before the answer started is not a
      # generation rate.
      @started_at = nil
      # Frozen Array of the tool-call names seen so far, or nil while no tool
      # call has started. One reference assignment, same contract as @tail.
      @tool_call  = nil
    end

    # Task thread: consume one delta ({ content:, reasoning:, tool_call_names: }).
    def record(delta)
      return self unless delta.is_a?(Hash)

      @full     << delta[:content].to_s   if delta.key?(:content)
      @thinking << delta[:reasoning].to_s if delta.key?(:reasoning)
      # Sticky for the request: a tool call that started arriving stays known
      # even while its later fragments carry no name, which is the whole point -
      # the phase is what the spinner must show, not the last fragment.
      note_tool_calls(delta[:tool_call_names]) if delta.key?(:tool_call_names)
      started_at
      publish
      self
    end

    # Main thread: the newest tail text, or nil when nothing has arrived yet.
    def snapshot
      @tail&.first
    end

    # The spinner segment: the newest text of the answer, with a leading marker
    # when older text was dropped. A truncated segment is always exactly
    # MAX_TAIL characters. nil when the stream has said nothing yet.
    def tail_line
      text, dropped = @tail
      return nil if text.nil? || text.empty?

      return text unless dropped

      TAIL_MARKER + text.sub(CUT_SEAM, "").ljust(text_budget)
    end

    # The live generation rate in tokens/second: the value PUBLISHED with the
    # tail, so the reader never recomputes from counters the writer is mutating
    # (same invariant as #snapshot). nil while there is nothing to measure -
    # prefill produces no text, and the first deltas are too short a window to
    # be a rate.
    #
    # This is the spinner's answer to #285: a server reports its own timings
    # only on the LAST chunk of a stream, and a buffered or unsupported server
    # reports none at all, so a live speed has to be measured HERE. Tokens are
    # estimated from characters (see #initialize), which is why the caller
    # labels the number as not the server's.
    def live_rate
      @tail&.last
    end

    # Main thread: the tool-call phase segment, or nil while the answer has
    # produced no tool call. NO rate is shown with it: no text is arriving to
    # measure, and a rate recomputed while nothing arrives DECAYS frame by frame
    # (9.0 -> 4.5 -> 2.2), which reads as a connection dying (measured in
    # issue #368's probe).
    def tool_call_line
      names = @tool_call
      return nil if names.nil?
      return TOOL_PHASE if names.empty?

      "#{TOOL_PHASE}: #{names.join(', ')}"
    end

    # Everything received so far (for the log line, not the console).
    def received_chars
      @full.length + @thinking.length
    end

    def received_tokens
      (received_chars.to_f / @chars_per_token).ceil
    end

    private

    # The marker is part of the segment's width, so the text gets the rest of it.
    def text_budget
      @max_tail - TAIL_MARKER.length
    end

    # The names known so far, frozen as one Array. A fragment may add a name;
    # fragments that add none keep the names already published.
    def note_tool_calls(names)
      return unless names.is_a?(Array)

      @tool_call = (@tool_call.to_a | names).freeze
    end

    def started_at
      @started_at ||= @clock.call
    end

    def elapsed_seconds
      @clock.call - @started_at
    end

    # Publishes the newest tail, whether anything was dropped, and the rate
    # measured over them as ONE frozen update. The truncation decision is made
    # against the source ACTUALLY shown: text that was never dropped is never
    # marked as if it were.
    def publish
      source = @full.empty? ? @thinking : @full
      dropped = source.length > text_budget
      text = dropped ? source[-text_budget..].to_s : source.dup
      @tail = [
        text.gsub("\n", " ").freeze, dropped,
        UsageStats.measured_rate(received_tokens, elapsed_seconds)
      ].freeze
    end
  end
end
