# frozen_string_literal: true

# Append-only structured record of everything shown to a user, split into the
# TAIL (durable history a renderer re-lays out) and HEAD (live arriving streams).
# Threading and ownership: doc/output_buffer_design.md

class OutputBuffer
  # One committed unit of output. IMMUTABLE BY CONSTRUCTION (no setters), so a
  # renderer cannot mutate an entry after it has been handed out of the tail.
  Entry = Data.define(:type, :origin, :content) do
    def to_s
      "#{type}:#{origin} #{content}"
    end

    # Data#to_h doubles as the serialization form, so no override needed.
  end

  # A live stream: the CURRENT state of one head cell, replaced as it grows.
  # Mutable on purpose - a refresh reads the whole stream at once. Immutability
  # holds for the tail only.
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

    # A stream cell GROWS (chunks append); a live-status cell is RE-POINTed
    # whole. Both mark the cell dirty so the poll sees the change.
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

  # Two independent tail limits: max_memory bounds the RAM window, max_saved is
  # the window a session save writes. max_saved <= max_memory.
  DEFAULT_MAX_MEMORY = 4_096
  DEFAULT_MAX_SAVED  = 30

  # Types that live in the HEAD, never in the tail: the live region is not part
  # of the durable record a replay redraws.
  HEAD_TYPES = %i[spinner_detail].freeze

  # A head cell is grown by the caller: :append means content arrives in chunks
  # (the cell is the whole stream so far), :replace means each write re-points
  # the live status. A call with no mode is a FINAL item committed to the tail.
  HEAD_MODES = %i[append replace].freeze

  # max_memory NEVER cuts a PENDING (unread) entry - the nothing-lost rule of the
  # drain loop - so it gates the consumed-front trim, not a plain "keep last N".
  def initialize(max_memory: DEFAULT_MAX_MEMORY, max_saved: DEFAULT_MAX_SAVED)
    @tail       = []
    @head       = {}
    @read_index = 0
    @max_memory = max_memory
    @max_saved  = max_saved
  end

  attr_reader :max_memory, :max_saved

  # A live update (a HEAD_MODE or a HEAD_TYPE) lands as a head cell - created,
  # or grown in place if that stream already has one. Anything else is a
  # committed tail entry, so a stream's final content is never only in the head.
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

  # Join any number of parts with a newline (like Kernel.puts), store ONE line
  # per part. Origin is the first argument (`buffer.puts(:harness, 'a')`) -
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

  # The live half: one cell per STREAM, a stream being (origin, type). One task
  # can hold several cells live at once (a spinner cell AND a streamed-response
  # cell), so the key is the pair, never the origin alone.
  def head
    @head.values
  end

  # The cell for one stream, keyed by (origin, type). The job is not a key field
  # here: each job's cells live in the job's own buffer, so the job is supplied
  # by WHICH buffer is read.
  def cell(origin, type)
    @head[head_key(origin, type)]
  end

  # Promote one live cell to the record as ONE immutable tail entry holding its
  # final content, removing it from the head. A stream that keeps going starts a
  # new cell, so the head never holds both history and live view of one stream.
  def commit(origin, type)
    live = @head[head_key(origin, type)]
    return nil if live.nil?

    @head.delete(head_key(origin, type))
    tail_entry(type: live.type, origin: live.origin, content: live.content)
  end

  # Tail waterline read: committed entries appended since the LAST call, advanced
  # past them. A head cell cannot be read this way, so the live half has its own
  # poll - #dirty_head.
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
  # shows when several streams of that type are live at once.
  def latest_head(type)
    @head.values.select { |cell| cell.type == type.to_sym }.max_by(&:version)
  end

  # True when a renderer has something new to show: pending tail entries, or a dirty head cell.
  def pending?
    @read_index < @tail.size || @head.values.any?(&:dirty?)
  end

  # Number of stored items in total (tail entries plus live head cells).
  def size
    @tail.size + @head.size
  end

  # The last N replayable entries for the resume replay redraw and saved tail.
  # Trimming only drops the consumed FRONT, so the tail is always intact.
  def replay_tail(count = nil)
    tail(count)
  end

  # Rehydrate saved entries (the JSON form of Entry#to_h) into the tail. Used
  # only at resume, before the drain loop first runs - a saved record is
  # committed history, so nothing of it is live.
  def restore(entries)
    Array(entries).each do |h|
      next unless h.is_a?(Hash)

      tail_entry(
        type: h[:type].to_sym,
        origin: normalize(h[:origin]),
        content: h[:content])
    end
  end

  # Keep only the last count TAIL entries. After dropping the front the read
  # waterline resets to 0 so a later drain still sees what remains. The head is
  # live state and is never windowed by this.
  def keep_tail(count)
    return if @tail.size <= count

    @tail = @tail.last(count)
    @read_index = 0
  end

  # Enforce this buffer's own max_saved on its tail. max_saved 0 (the disable)
  # keeps nothing, so the record stays empty. The head is never windowed.
  def keep_window
    keep_tail(@max_saved)
  end

  # Drop EVERYTHING (consumed tail, pending tail and live head) and reset the
  # waterline. Intended for explicit "new surface" boundaries.
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
    existing = @head[head_key(origin, type)]
    return existing.update(content) if existing

    @head[head_key(origin, type)] = HeadCell.new(
      type:,
      origin:,
      content:,
      mode:)
  end

  # The head-cell key is the stream: (origin, type). The job is NOT a key field -
  # each job has its own buffer, so the job is supplied by WHICH buffer is read.
  def head_key(origin, type)
    [normalize(origin), type.to_sym]
  end

  # Keep origins stable and short so entries are easy to group by a renderer. nil becomes :unknown.
  def normalize(origin)
    origin.nil? ? :unknown : origin.to_sym
  end

  # Drop the consumed prefix when the waterline is far enough along that it no
  # longer matters (it is at least half of what the tail holds).
  def trim_prefix
    return if @read_index < @max_memory
    return if @read_index * 2 < @tail.size

    @tail = @tail[@read_index..] || []
    @read_index = 0
  end
end
