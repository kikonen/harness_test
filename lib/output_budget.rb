# frozen_string_literal: true

# Byte budget for text that reaches the conversation chain (issue #551).
# Design: doc/tool_output_budget_design.md.
#
# A line count is not a size limit. Output with few newlines and huge lines (a
# base64 dump, minified JSON, a one-line blob) passes any line gate whole,
# becomes one giant message in the chain, and the backend then refuses the WHOLE
# request ("requests are never truncated") - including the auto-compact request
# that would have repaired it. So size is bounded in BYTES as well as lines, and
# a single oversized line is clipped within itself: that is the shape no
# line-shaped rule can catch.
module OutputBudget
  DEFAULT_RESULT_BYTES = 100_000
  # A line is clipped only when it is grossly oversized - an ordinary diff or
  # log line must survive intact. It stays BELOW DEFAULT_RESULT_BYTES on
  # purpose: a huge SINGLE-line file (minified JSON, a one-line blob) read whole
  # is caught by this clip too, because clamp_bytes drops WHOLE lines and would
  # keep nothing at all when every line is longer than the byte budget.
  OVERSIZED_LINE_BYTES = 20_000
  # Head-biased split, the same shape the line budget uses (issue #537): the
  # header of a run is at the head, its failure block at the tail.
  HEAD_RATIO           = 0.6
  # A tool result as it goes to harness.log. The same overflow, in the log
  # instead of the chain.
  LOG_RESULT_BYTES     = 2_000
  NO_LINE_LIMIT        = Float::INFINITY

  Result = Struct.new(:text, :lines_dropped, :lines_clipped, :bytes_dropped) do
    def truncated?
      lines_dropped.positive? || lines_clipped.positive? || bytes_dropped.positive?
    end
  end

  # Clips ONE line to `line_bytes`, keeping both ends of it.
  def self.clip_line(line, line_bytes = OVERSIZED_LINE_BYTES)
    return line if line.bytesize <= line_bytes

    tail_bytes = (line_bytes * (1 - HEAD_RATIO)).floor
    head_bytes = line_bytes - tail_bytes
    head, tail = split_bytes(line, head_bytes, tail_bytes)
    "#{head} ...#{line.bytesize - line_bytes} bytes of this line omitted... #{tail}"
  end

  # Bounds `text` to `limit` bytes and `limit_lines` lines, clipping any single
  # line over `line_bytes`. Returns an OutputBudget::Result.
  def self.fit(text, limit:, limit_lines: NO_LINE_LIMIT,
               line_bytes: OVERSIZED_LINE_BYTES)
    source  = text.to_s
    lines   = source.split("\n")
    clipped = 0

    if lines.size > limit_lines
      tail_n  = limit_lines / 2
      head_n  = limit_lines - tail_n
      picked  = lines.first(head_n) + lines.last(tail_n)
      dropped = lines.size - picked.size
    else
      picked  = lines
      dropped = 0
    end

    kept = picked.map do |line|
      next line if line.bytesize <= line_bytes

      clipped += 1
      clip_line(line, line_bytes)
    end

    kept          = clamp_bytes(kept.join("\n"), limit)
    dropped_bytes = [source.bytesize - kept.bytesize, 0].max
    Result.new(kept, dropped, clipped, dropped_bytes)
  end

  # Drops WHOLE lines from the tail so `text` fits `limit` bytes, naming how
  # many bytes went. Only reached when line clipping was not enough.
  def self.clamp_bytes(text, limit)
    return text if text.bytesize <= limit

    lines  = text.split("\n")
    kept   = []
    budget = limit
    lines.each do |line|
      cost = line.bytesize + 1
      break if cost > budget

      kept << line
      budget -= cost
    end

    dropped = text.bytesize - kept.sum { |l| l.bytesize } - (kept.size - 1)
    kept.join("\n") + notice(dropped)
  end

  # A tool result as it goes to a log line: the head, with the size named. A
  # full dump in harness.log is the same overflow in a different place.
  def self.log_excerpt(result, limit: LOG_RESULT_BYTES)
    text = result.to_s
    return text if text.bytesize <= limit

    "#{text[0, limit]} ...#{text.bytesize - limit} bytes not logged..."
  end

  # Read a file WITHOUT loading it whole: the head half and the tail half of its
  # BYTES, with the middle named. Used by the file readers so an oversized file
  # never becomes a huge string in the tool, in harness.log, or in the chain.
  # Returns [text, total_bytes]; total_bytes is nil when the file is absent.
  def self.read_capped(path, limit:)
    total = File.size(path)
    return [File.read(path), total] if total <= limit

    tail_bytes = (limit * (1 - HEAD_RATIO)).floor
    head_bytes = limit - tail_bytes
    File.open(path, "rb") do |io|
      head = io.read(head_bytes).to_s
      io.seek(total - tail_bytes)
      tail = io.read(tail_bytes).to_s
      # A head slice that ends mid-character is repaired by the read boundary
      # normalizer downstream; the byte counts stay exact.
      dropped = total - head.bytesize - tail.bytesize
      [
        "#{head}\n... (file too large: #{dropped} bytes omitted from the " \
          "middle of #{total} - read it in slices, or search it for the part " \
          "you need) ...\n#{tail}",
        total
      ]
    end
  end

  # The line a capped result ends with: what went, and what to do about it.
  # `spill` is the workdir-relative path of the full text when it was saved.
  def self.notice(bytes_dropped, spill: nil)
    head = "... (output too large: #{bytes_dropped} bytes omitted - pipe the " \
      "command through head or tail to see more"
    head += ", or read the full text saved to #{spill}" if spill
    "#{head})"
  end

  # Byte-slices a line on CHARACTER boundaries (never mid-character).
  def self.split_bytes(line, head_bytes, tail_bytes)
    chars   = line.each_char.to_a
    head    = +""
    size    = 0
    index   = 0
    while index < chars.size && size + chars[index].bytesize <= head_bytes
      head << chars[index]
      size += chars[index].bytesize
      index += 1
    end
    tail   = +""
    size   = 0
    cursor = chars.size - 1
    while cursor > index && size + chars[cursor].bytesize <= tail_bytes
      tail = chars[cursor] + tail
      size += chars[cursor].bytesize
      cursor -= 1
    end
    [head, tail]
  end
end
