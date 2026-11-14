# frozen_string_literal: true

require "tins"

module UI
  # ONE width rule for every layer that lays text out to a column count (issue
  # #474, increment 24). A width is stated as a CHAR COUNT or as a PERCENTAGE of
  # the terminal ("85%"), and the two mean different things:
  #
  # - a count is a TERMINAL fact. It is clamped to the terminal (never padded), so
  #   a paragraph is never wider than the console it is written to.
  # - a percentage is the only form that travels to a sink with no column count of
  #   its own (a browser page in a variable-width font, where "120 chars" means
  #   nothing). It is applied to the terminal, and capped so a wide terminal does
  #   not produce a paragraph nobody can read.
  #
  # The RAW basis is kept as data (UI::Renderer#max_width, the record, and a
  # remote sink) and the RESOLVED number is what a terminal render uses.
  module Width
    DEFAULT_PERCENT = 80
    # The reading cap for a resolved paragraph width: 80% of a 200-column terminal
    # is a line no one reads, so the cap is the point. Around 120 is the reasonable
    # maximum for prose; a caller may cap lower but never higher.
    MAX_PARAGRAPH_WIDTH = 120
    # A line written into EVERY column makes the terminal wrap it itself, which
    # lands the next control sequence on the wrong row. Only a DETECTED width is
    # reserved - an explicit count is exactly what a caller asked for.
    RESERVED_COLUMNS = 1

    # value: an Integer (chars), a String percentage ("85%"), or nil.
    # cap: nil means no cap (a table basis the caller sized itself); a resolved
    # percentage is capped so a wide terminal does not produce unreadable prose.
    def self.resolve(
      value:,
      terminal: nil,
      fallback: nil,
      percent: DEFAULT_PERCENT,
      cap: MAX_PARAGRAPH_WIDTH,
      reserve: 0
    )
      chars, value_percent = parse(value)

      if chars
        # An explicit count is exactly what the caller asked for: clamp to the
        # terminal, never shrink it to the cap.
        clamp(chars, terminal, reserve)
      elsif value_percent
        # A percentage needs a terminal to apply to. With none, the caller's
        # fallback is all there is.
        return fallback if terminal.nil?

        capped((terminal * value_percent / 100.0).floor, reserve, cap)
      elsif terminal
        capped((terminal * percent / 100.0).floor, reserve, cap)
      else
        fallback
      end
    end

    def self.parse(value)
      return [nil, nil] if value.nil?

      text = value.to_s
      return [nil, text.to_i] if text.match?(/\A\d+%\z/)

      [value.is_a?(Integer) ? value : text.to_i, nil]
    end

    # Columns of the console the text is written to, NOT the process tty at large:
    # a StringIO (every spec console) is not a tty and answers nil, so a spec that
    # pins a wrapped width must state an explicit count or the fallback applies.
    def self.detect_columns(io)
      sink_columns(io) || (tty_sink?(io) ? console_columns || env_columns : nil)
    end

    # A UI::Console is not the stream itself, so a caller holding the SINK gets the
    # stream's columns through this: a Console answers its stdout, anything else
    # answers its own winsize.
    def self.columns_for(ui_or_io)
      io = ui_or_io.respond_to?(:stdout) ? ui_or_io.stdout : ui_or_io
      detect_columns(io)
    end

    # The gem's basis: the sink first, then Tins (which answers a fallback number
    # when no terminal is detected at all).
    def self.terminal_columns(io)
      columns_for(io) || Tins::Terminal.columns
    end

    def self.tty_sink?(io)
      io.respond_to?(:tty?) && io.tty?
    end

    def self.sink_columns(io)
      return nil unless io.respond_to?(:winsize)

      positive_cols(io.winsize[1])
    rescue StandardError
      nil
    end

    def self.console_columns
      io = IO.console
      return nil unless io.respond_to?(:winsize)

      positive_cols(io.winsize[1])
    rescue StandardError
      nil
    end

    def self.env_columns
      env = ENV["COLUMNS"].to_s
      env.match?(/\A\d+\z/) ? positive_cols(env) : nil
    end

    def self.clamp(chars, terminal, reserve)
      width = terminal ? [terminal, chars].min : chars
      reserve_amount(width, reserve)
    end

    def self.capped(chars, reserve, cap)
      chars = [chars, cap].min if cap
      reserve_amount(chars, reserve)
    end

    def self.reserve_amount(width, reserve)
      return nil if width.nil?

      [width - reserve, 1].max
    end

    def self.positive_cols(value)
      value = value.to_i
      value.positive? ? value : nil
    end
  end
end
