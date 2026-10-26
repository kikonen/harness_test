# frozen_string_literal: true

# Explicit stdout/stdin pair handed to every I/O caller instead of raw
# streams: the one place a TUI sink can later be injected without touching
# a call site. It parses and formats nothing - but it DOES carry the
# presentation (the palette, issue #388): the object that owns the streams
# is the object that knows how they should look, so a dialog or a status
# writer asks the console it was already given instead of being handed a
# renderer it has no reason to know about.
module UI
  class Console
    attr_reader :stdout, :stdin

    # stdout: an IO-like object with #puts/#print/#flush ($stdout, StringIO).
    # stdin:  an IO-like object with #gets ($stdin, StringIO). May be nil
    #         when the caller only needs to write (e.g. --list-sessions).
    # palette: how this sink paints (issue #388) - a UI::Palette, nil (no
    #   color), or a zero-arg callable answering one. The callable form is how
    #   a LIVE palette is wired (the same pattern FileList#posture uses for the
    #   YOLO coverage, issue #274): /palette and a mid-run Harness rebuild take
    #   effect on the next line, and a console built before the Harness exists
    #   still resolves it once the Harness does.
    def initialize(stdout:, stdin: nil, palette: nil)
      raise ArgumentError, "UI::Console requires a non-nil stdout stream" \
        if stdout.nil?

      @stdout = stdout
      @stdin  = stdin
      @palette = palette
    end

    # The palette to paint with, or nil when this sink paints nothing.
    def palette
      @palette.respond_to?(:call) ? @palette.call : @palette
    end

    # One colored RUN (issue #388): the caller states the ROLE of the text and
    # this sink decides whether it has a color at all. With no palette the text
    # comes back byte-for-byte unchanged, which is what --no-color, a plain
    # console in a spec and any console built before a Harness exists need.
    def paint(role, text)
      p = palette
      p ? p.paint(role, text) : text
    end

    # Write lines to the underlying stdout (like IO#puts).
    def puts(*args)
      @stdout.puts(*args)
    end

    # Write text without a trailing newline.
    def print(text)
      @stdout.print(text)
    end

    # Flush the underlying stdout.
    def flush
      @stdout.flush
    end

    # Read one line from stdin (nil on EOF or when stdin is not set).
    def gets
      @stdin&.gets
    end
  end
end
