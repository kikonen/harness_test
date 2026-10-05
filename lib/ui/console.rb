# frozen_string_literal: true

# -- UI::Console ----------------------------------------------------------------
#
# Thin wrapper over an explicit stdout/stdin stream pair (issue #74 / TUI
# prep). This is the object handed to Command, CommandHandler, Dialog,
# Task.run, and Spinner instead of raw streams. It gives us a single place
# to later inject a TUI sink without touching any call site.
#
# Deliberately minimal: it does not parse or format anything - just exposes
# the low-level IO operations the callers already used (puts / print / flush
# / gets). Higher-level display methods (banner, prompt, spinner frame, etc.)
# can be added here as the TUI lands.
module UI
  class Console
    attr_reader :stdout, :stdin

    # stdout: an IO-like object with #puts/#print/#flush ($stdout, StringIO).
    # stdin:  an IO-like object with #gets ($stdin, StringIO). May be nil
    #         when the caller only needs to write (e.g. --list-sessions).
    def initialize(stdout:, stdin: nil)
      raise ArgumentError, 'UI::Console requires a non-nil stdout stream' \
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
