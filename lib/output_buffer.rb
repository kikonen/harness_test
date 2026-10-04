# frozen_string_literal: true

# -- OutputBuffer ------------------------------------------------------------
#
# A structured, append-only record of everything the harness wants to show
# the user (issue #40 - single-thread I/O rule, follow-up).
#
# The key idea: task-thread code NEVER writes to an IO stream. Instead it
# appends a typed, origin-tagged entry to this buffer. The main thread (the
# CLI drain loop, and later the TUI) advances a read waterline (#drain) and
# renders whatever is new. This replaces the fire-and-forget "puts to $stdout"
# model with a durable, inspectable log of {type, origin, content} blobs:
#
#   * type    - what KIND of output this is (:response, :stats, :step,
#               :system, :error, ...), so a renderer can style it distinctly.
#   * origin  - WHERE it came from (:session_manager, :harness, a tool name,
#               ...), so a renderer or future TUI can attribute it.
#   * content - the text itself (a single line; multi-part output is either
#               one blob or several entries, in order).
#
# The buffer is owned by the harness (Harness#output_buffer). Because the
# harness constructs its tools, those tools can reach the same instance and
# append to it too. Thread-safety is provided by a single Mutex: task threads
# append from many call sites at once while the main thread drains on its own
# tick, so both operations are synchronized.

class OutputBuffer
  # One unit of output. A Data instance - IMMUTABLE BY CONSTRUCTION: no
  # setters exist, so a renderer cannot mutate an entry after it has been
  # handed out of the buffer (type/origin are symbols; content is a string).
  Entry = Data.define(:type, :origin, :content) do
    def to_s
      "#{type}:#{origin} #{content}"
    end

    # Data#to_h already exists (symbol-keyed members) - it doubles as the
    # serialization form, so no override needed.
  end

  # When the read waterline has advanced this far and it is at least half of
  # the stored entries, drop the consumed prefix so long sessions do not
  # accumulate unbounded history in memory.
  TRIM_AT = 4_096

  def initialize
    @entries    = []
    @read_index = 0
    @mutex      = Mutex.new
  end

  # Append a structured entry (thread-safe). Returns the Entry that was
  # stored, so a caller can assert on it directly.
  def put(type:, origin:, content: nil)
    # Data is immutable; freezing the content string too stops a renderer
    # from mutating the payload text in place.
    entry = Entry.new(type: type.to_sym, origin: normalize(origin), content: content.to_s.freeze)
    @mutex.synchronize { @entries << entry }
    entry
  end

  # Convenience writer mirroring the old `puts` ergonomics: join any number
  # of parts with a newline (like Kernel.puts) and store ONE line per part.
  # The origin is passed as the first argument: `buffer.puts(:harness, 'a', 'b')`
  # - Ruby forbids a keyword before a splat, so this stays positional.
  # Returns the last entry written (or nil when nothing was passed).
  def puts(origin = :unknown, *parts)
    parts = [''] if parts.empty?
    origin = normalize(origin)
    last = nil
    parts.each do |part|
      last = put(type: :text, origin: origin, content: part.to_s)
    end
    last
  end

  # Waterline read (thread-safe): return the entries appended since the LAST
  # call and advance the read index past them. Subsequent calls see only new
  # entries - this is the "is there more output?" poll the CLI/renderer uses.
  # A trailing trim drops the already-consumed prefix to bound memory.
  def drain
    @mutex.synchronize do
      if @read_index >= @entries.size
        []
      else
        batch   = @entries[@read_index...@entries.size]
        @read_index += batch.size
        trim_prefix
        batch
      end
    end
  end

  # True when there are unread entries waiting for a renderer.
  def pending?
    @mutex.synchronize { @read_index < @entries.size }
  end

  # Number of entries stored in total (consumed or not). Useful for tests.
  def size
    @mutex.synchronize { @entries.size }
  end

  # Drop EVERYTHING (consumed and pending) and reset the waterline to zero.
  # Intended for explicit "new surface" boundaries if a renderer ever wants
  # a clean slate; the drain loop normally does not need it.
  def clear
    @mutex.synchronize do
      @entries.clear
      @read_index = 0
    end
  end

  private

  # normalize(origin) -> keep symbols/symbols-able values stable and short so
  # entries are easy to group by a renderer. nil becomes :unknown.
  def normalize(origin)
    origin.nil? ? :unknown : origin.to_sym
  end

  # Drop the consumed prefix when the waterline is far enough along that it
  # no longer matters (it is at least half of what we hold). Called with @mutex
  # held by the public methods.
  def trim_prefix
    return if @read_index < TRIM_AT
    return if @read_index * 2 < @entries.size

    @entries = @entries[@read_index..] || []
    @read_index = 0
  end
end
