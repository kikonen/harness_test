# frozen_string_literal: true

# Append-only structured record of everything shown to a user, split into the
# two parts a per-task buffer needs (issue #286): the TAIL is the durable
# history a renderer can re-lay out, the HEAD is the live state of the streams
# that are still arriving. Threading and ownership: doc/output_buffer_design.md

class OutputBuffer
  # One committed unit of output. A Data instance - IMMUTABLE BY CONSTRUCTION:
  # no setters exist, so a renderer cannot mutate an entry after it has been
  # handed out of the tail (type/origin are symbols; content is a string).
  Entry = Data.define(:type, :origin, :content) do
    def to_s
      "#{type}:#{origin} #{content}"
    end

    # Data#to_h already exists (symbol-keyed members) - it doubles as the
    # serialization form, so no override needed.
  end

  # A live stream: the CURRENT state of one head cell, replaced as it grows.
  # Mutable on purpose - the head is the snapshot a renderer shows now, and a
  # refresh must be able to read the whole stream at once instead of rebuilding
  # it from a pile of chunks. Immutability holds for the tail only.
  class HeadCell
    attr_reader :type, :origin, :mode, :version

    def initialize(type:, origin:, content: nil, mode: :replace)
      @type    = type
      @origin  = origin
      @mode    = mode
      @content = content
      @version = 0
      @dirty   = true
    end

    attr_reader :content

    # A stream cell GROWS (chunks append); a live-status cell is a RE-POINT and
    # is replaced whole. Both mark the cell dirty so the poll sees the change.
    def update(value)
      @content = mode == :append ? [content, value].compact.join("") : value
      @version += 1
      @dirty   = true
      self
    end

    def dirty?
      @dirty
    end

    def clear_dirty
      @dirty = false
    end

    def to_h
      { type:, origin:, content: }
    end
  end

  # When the tail read waterline has advanced this far and it is at least half of
  # what the tail holds, drop the consumed prefix so long sessions do not
  # accumulate unbounded history in memory.
  TRIM_AT = 4_096

  # Types that live in the HEAD, never in the tail: they are the live region and
  # are not part of the durable record a replay redraws.
  HEAD_TYPES = %i[spinner_detail].freeze

  # A head cell is grown by the caller: :append means the content arrives in
  # chunks and the cell is the WHOLE stream so far, :replace means each write is
  # a re-point of the live status. A call with no mode states a FINAL item and
  # is committed to the tail - the head must never be the only copy of an answer.
  HEAD_MODES = %i[append replace].freeze

  def initialize
    @tail       = []
    @head       = {}
    @read_index = 0
  end

  # Append one item. A live update (mode: :append or :replace, or a type that is
  # transient by nature) lands as a head cell - created, or grown in place if
  # that stream already has one. Anything else is a committed tail entry, so the
  # final content of a stream is always in the record and never only in the head.
  def put(type:, origin:, content: nil, mode: nil)
    type   = type.to_sym
    mode   = mode&.to_sym
    origin = normalize(origin)

    if HEAD_MODES.include?(mode) || (mode.nil? && HEAD_TYPES.include?(type))
      head_cell(type:, origin:, content:, mode: mode || :replace)
    else
      tail_entry(type:, origin:, content:)
    end
  end

  # Convenience writer mirroring the old `puts` ergonomics: join any number of
  # parts with a newline (like Kernel.puts) and store ONE line per part. The
  # origin is passed as the first argument: `buffer.puts(:harness, 'a', 'b')` -
  # Ruby forbids a keyword before a splat, so this stays positional.
  def puts(origin = :unknown, *parts)
    parts = [""] if parts.empty?
    origin = normalize(origin)
    last = nil
    parts.each do |part|
      last = put(type: :text, origin:, content: part.to_s)
    end
    last
  end

  # The durable half: committed entries in append order, oldest first.
  def tail(count = nil)
    return @tail if count.nil? || count >= @tail.size

    @tail.last(count)
  end

  # The live half: one cell per STREAM, a stream being (origin, type). A single
  # task can have several cells live at once - the spinner cell AND the LLM
  # streamed-response cell, both from :session_manager - so the key is the pair,
  # never the origin alone (which would collapse them into one cell). In
  # first-seen order.
  def head
    @head.values
  end

  # The cell for one stream, keyed by (origin, type); nil when nothing is live
  # for that pair. A single task can hold several cells at once (spinner + LLM
  # response, both from :session_manager), so the key is the pair.
  def cell(origin, type)
    @head[[normalize(origin), type.to_sym]]
  end

  # Promote one live cell to the record as ONE immutable tail entry holding its
  # final content, and remove it from the head. A stream that keeps going after
  # a commit starts a new cell, so the head never holds both the history and the
  # live view of the same stream. Keyed by (origin, type).
  def commit(origin, type)
    live = @head[[normalize(origin), type.to_sym]]
    return nil if live.nil?

    @head.delete([normalize(origin), type.to_sym])
    tail_entry(type: live.type, origin: live.origin, content: live.content)
  end

  # Tail waterline read: the committed entries appended since the LAST call,
  # advanced past them. A head cell cannot be read this way (a replaced cell is
  # not an append), so the live half has its own poll - #dirty_head.
  def drain
    return [] if @read_index >= @tail.size

    batch = @tail[@read_index...@tail.size]
    @read_index += batch.size
    trim_prefix
    batch
  end

  # Head cells changed since the last poll, in first-seen order.
  def dirty_head
    changed = @head.values.select(&:dirty?)

    changed.each(&:clear_dirty)
    changed
  end

  # The most recently UPDATED head cell of a type - the live state a renderer
  # shows when several streams of that type are live at once (a new wait
  # announces itself instead of inheriting a finished wait's line).
  def latest_head(type)
    @head.values.select { |cell| cell.type == type.to_sym }.max_by(&:version)
  end

  # True when a renderer has something new to show: pending tail entries, or a
  # dirty head cell.
  def pending?
    @read_index < @tail.size || @head.values.any?(&:dirty?)
  end

  # Number of stored items in total (tail entries plus live head cells).
  def size
    @tail.size + @head.size
  end

  # The last N replayable entries for the resume replay redraw and its saved
  # tail. The head is never part of the record, so this is the tail as stored:
  # trimming only drops the consumed FRONT, so the tail is always intact.
  def replay_tail(count = nil)
    tail(count)
  end

  # Rehydrate saved entries (the JSON form of Entry#to_h: type/origin come back
  # as strings, content as whatever it was) into the tail. Used only at resume,
  # before the drain loop first runs - a saved record is committed history, so
  # nothing of it is live.
  def restore(entries)
    Array(entries).each do |h|
      next unless h.is_a?(Hash)

      tail_entry(
        type: h[:type].to_sym,
        origin: normalize(h[:origin]),
        content: h[:content])
    end
  end

  # Keep only the last count TAIL entries - the run's durable record is a
  # window, not the whole session. The read waterline is kept consistent: after
  # dropping the front it resets to 0 so a later drain still sees what remains.
  # The head is live state and is never windowed by this.
  def keep_tail(count)
    return if @tail.size <= count

    @tail = @tail.last(count)
    @read_index = 0
  end

  # Drop EVERYTHING (consumed tail, pending tail and live head) and reset the
  # waterline to zero. Intended for explicit "new surface" boundaries.
  def clear
    @tail.clear
    @head.clear
    @read_index = 0
  end

  private

  def tail_entry(type:, origin:, content:)
    stored = content.is_a?(String) ? content.freeze : content
    entry  = Entry.new(type: type.to_sym, origin:, content: stored)
    @tail << entry
    entry
  end

  def head_cell(type:, origin:, content:, mode: :replace)
    existing = @head[[origin, type]]
    return existing.update(content) if existing

    @head[[origin, type]] = HeadCell.new(
      type:,
      origin:,
      content:,
      mode:)
  end

  # normalize(origin) -> keep symbols/symbols-able values stable and short so
  # entries are easy to group by a renderer. nil becomes :unknown.
  def normalize(origin)
    origin.nil? ? :unknown : origin.to_sym
  end

  # Drop the consumed prefix when the waterline is far enough along that it
  # no longer matters (it is at least half of what the tail holds).
  def trim_prefix
    return if @read_index < TRIM_AT
    return if @read_index * 2 < @tail.size

    @tail = @tail[@read_index..] || []
    @read_index = 0
  end
end
