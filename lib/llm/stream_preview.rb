# frozen_string_literal: true

module LLM
  # The live tail of a streamed answer, for the spinner.
  # Invariant: the writer is the task thread and the reader the main thread, so
  # #record publishes a FROZEN snapshot into one slot rather than appending to a
  # shared String. Threading and tail rules: doc/streaming_design.md.
  class StreamPreview
    # How much of the answer the spinner can show. A spinner line is one
    # line: the tail is the newest part, so the oldest is what gets dropped.
    MAX_TAIL = 60

    def initialize(max_tail: MAX_TAIL)
      @max_tail = max_tail
      @full     = +""
      @thinking = +""
      @snapshot = nil
    end

    # Task thread: consume one delta ({ content:, reasoning: }).
    def record(delta)
      return self unless delta.is_a?(Hash)

      @full     << delta[:content].to_s   if delta.key?(:content)
      @thinking << delta[:reasoning].to_s if delta.key?(:reasoning)
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

    # Everything received so far (for the log line, not the console).
    def received_chars
      @full.length + @thinking.length
    end

    private

    # Publishes the newest tail as an immutable snapshot for the main thread.
    # A spinner line is ONE line, so newlines in the answer collapse to spaces.
    # NOTE: source[-max..] returns nil when max exceeds the length, so the
    # whole source is used directly for a short answer.
    def publish
      source = @full.empty? ? @thinking : @full
      text = source.length > @max_tail ? source[-@max_tail..].to_s : source.dup
      @snapshot = text.gsub("\n", " ").freeze
    end
  end
end
