# frozen_string_literal: true

# Explicit stdout/stdin pair handed to every I/O caller instead of raw
# streams: the one place a TUI sink can later be injected without touching
# a call site. It parses and formats nothing.
module UI
  class Console
    attr_reader :stdout, :stdin

    # stdout: an IO-like object with #puts/#print/#flush ($stdout, StringIO).
    # stdin:  an IO-like object with #gets ($stdin, StringIO). May be nil
    #         when the caller only needs to write (e.g. --list-sessions).
    def initialize(stdout:, stdin: nil)
      raise ArgumentError, "UI::Console requires a non-nil stdout stream" \
        if stdout.nil?

      @stdout = stdout
      @stdin  = stdin
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
