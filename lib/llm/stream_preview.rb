# frozen_string_literal: true

require_relative "usage_stats"

module LLM
  # The live state of a streamed answer, for the spinner: its newest text and
  # the rate that text arrived at (issue #285).
  # Invariant: the writer is the task thread and the reader the main thread, so
  # #record publishes a FROZEN snapshot into one slot rather than appending to a
  # shared String. Threading, tail and rate rules: doc/streaming_design.md.
  class StreamPreview
    # How much of the answer the spinner can show. A spinner line is one
    # line: the tail is the newest part, so the oldest is what gets dropped.
    MAX_TAIL = 60

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
      @snapshot = nil
      @rate     = nil
      # Taken on the first delta: prefill (processing the prompt) produces no
      # text, so a rate measured from before the answer started is not a
      # generation rate.
      @started_at = nil
    end

    # Task thread: consume one delta ({ content:, reasoning: }).
    def record(delta)
      return self unless delta.is_a?(Hash)

      @full     << delta[:content].to_s   if delta.key?(:content)
      @thinking << delta[:reasoning].to_s if delta.key?(:reasoning)
      started_at
      publish
      self
    end

    # Main thread: the newest snapshot, or nil when nothing has arrived yet.
    def snapshot
      @snapshot
    end

    # The spinner segment: the newest text of the answer, with a leading
    # ellipsis when it is a tail. nil when the stream has said nothing yet.
    def tail_line
      text = @snapshot
      return nil if text.nil? || text.empty?

      (@full.length > @max_tail || @thinking.length > @max_tail) ? "...#{text}" : text
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
      @rate
    end

    # Everything received so far (for the log line, not the console).
    def received_chars
      @full.length + @thinking.length
    end

    def received_tokens
      (received_chars.to_f / @chars_per_token).ceil
    end

    private

    def started_at
      @started_at ||= @clock.call
    end

    def elapsed_seconds
      @clock.call - @started_at
    end

    # Publishes the newest tail and the rate measured over it as one snapshot
    # update. A spinner line is ONE line, so newlines in the answer collapse to
    # spaces. NOTE: source[-max..] returns nil when max exceeds the length, so
    # the whole source is used directly for a short answer.
    def publish
      source = @full.empty? ? @thinking : @full
      text = source.length > @max_tail ? source[-@max_tail..].to_s : source.dup
      @snapshot = text.gsub("\n", " ").freeze
      @rate     = UsageStats.measured_rate(received_tokens, elapsed_seconds)
    end
  end
end
