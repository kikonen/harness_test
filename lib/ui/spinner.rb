# frozen_string_literal: true

# -- UI::Spinner --------------------------------------------------------------
#
# Animated status indicator (issue #74 / #13). First primitive of the
# namespaced UI library. Public API is unchanged from the previous
# top-level Spinner: start / stop / running?.
#
# Single-thread I/O rule (issue #40): the spinner does NOT spawn a background
# thread. It is a pure state object + render method. The main thread calls
# `render!` on each drain tick to advance one animation frame. This guarantees
# that all console I/O (spinner frames, output, dialogs) happens on the same
# thread and can never interleave or race.
#
# Renderers:
#   * print  - the long-standing ANSI single-line spinner on stdout. Always
#              the safe default (CI, pipes, non-TTY). Forced by
#              HARNESS_SPINNER=print.
#   * tui    - an inline single-row RatatuiRuby viewport. Preserved for
#              headless testing via `draw_tui_frame`; NOT used in the live
#              render loop (would require blocking the main thread).
module UI
  class Spinner
    FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

    # Optional override / kill switch: HARNESS_SPINNER=print forces the ANSI
    # spinner (case-insensitive). Any other value leaves it in effect.
    ENV_OVERRIDE = 'HARNESS_SPINNER'

    # suffix is optional extra text appended after the message (issue #115,
    # e.g. the current context-usage estimate). It may be a plain string or a
    # callable (lambda/proc) that is re-evaluated on EVERY frame so it always
    # shows the CURRENT value, not the snapshot taken at construction time
    # (issue #126). nil/empty shows only the message, as before.
    # The Task drain loop re-points these via #update_detail while the wait
    # continues - no restart needed.
    def initialize(message = 'Working', suffix = nil)
      @message   = message
      @suffix    = suffix
      @active    = false  # between #start and #stop
      @resumable = false  # started and not yet stopped
      @frame     = 0
    end

    # Begin the spinner. Pure state change - no I/O, no thread spawn.
    # The main thread will start drawing frames on its next render! call.
    def start
      @active    = true
      @resumable = true
      @frame     = 0
    end

    # True while the spinner should be visible (between #start and the next
    # #stop). The drain loop uses this to decide what gets rendered.
    def running?
      @active
    end

    # End the spinner. Pure state change - the main thread clears the line
    # on its next tick when it sees running? is false.
    def stop
      @active    = false
      @resumable = false
    end

    # -- Main-thread render (issue #40 single-thread I/O rule) ---------------

    # Advance one animation frame and write it to stdout. Called by the
    # main thread on each drain tick (typically every 100ms). The output
    # stream is passed by the caller - there is deliberately no stdout
    # default, the stream must always be an explicit argument (Task.run
    # injects it; tests capture it with a StringIO).
    # No-op when not running (stopped).
    def render!(stdout)
      return unless running?

      text = "#{FRAMES[@frame % FRAMES.size]} #{@message}...#{render_suffix}"
      stdout.print("\r#{text}")
      stdout.flush
      @frame += 1
    end

    # Clear the spinner line with an ANSI erase-entire-line escape (issue #125).
    # Called by the main thread when transitioning from rendering to idle.
    # Same explicit-stream contract as #render! .
    def clear_line(stdout)
      stdout.print("\r\e[2K")
      stdout.flush
    end

    # Re-point the message and/or suffix without restarting the animation
    # (issue #40 follow-up - the drain loop uses this to apply a
    # :spinner_detail entry). Each argument is independent: pass nil to
    # keep the current value, pass a new one to replace it. The values
    # follow the constructor's contract (plain strings, or callables that
    # are re-evaluated every frame so they track live state). The spinner
    # keeps animating; the next frame simply shows the new content.
    def update_detail(message: nil, suffix: nil)
      @message = message unless message.nil?
      @suffix  = suffix  unless suffix.nil?
    end

    # One spinner frame as a plain string (no \r, no write). Public so tests
    # can assert the exact frame text without capturing stdout.
    def line(i)
      "#{FRAMES[i % FRAMES.size]} #{@message}...#{render_suffix}"
    end

    # Draw ONE TUI frame (index i) into the viewport, then drain the event
    # queue with a short timeout. Public so headless tests can drive a single
    # deterministic frame through ratatui's test terminal (issue #74).
    def draw_tui_frame(tui, i)
      tui.draw { |frame| frame.render_widget(tui.paragraph(text: line(i)), frame.area) }
      tui.poll_event(timeout: 0.05)
    end

    # -- Renderer selection (preserved for reference / future TUI path) -----

    # True when the user pinned the ANSI spinner via HARNESS_SPINNER=print
    # (case-insensitive).
    def forced_print?
      ENV[ENV_OVERRIDE].to_s.strip.casecmp('print').zero?
    end

    # True only when both stdin and stdout are real terminals.
    def interactive_tty?(stdout, stdin)
      return false unless stdin.respond_to?(:tty?) && stdin.tty?
      return true if stdout.nil?

      stdout.respond_to?(:tty?) && stdout.tty?
    end

    # True when the TUI renderer could be preferred over print (interactive
    # terminal AND not forced to print). Preserved for future use.
    def tui_preferred?(stdout, stdin)
      return false if forced_print?

      interactive_tty?(stdout, stdin)
    end

    private

    # Resolve the suffix to the text for this frame. A callable is invoked
    # fresh each frame so it tracks live state (issue #126); a plain string is
    # used as-is. Any failure resolves to no suffix - the spinner must never
    # abort because of a transient read error while the task thread mutates
    # the session (issue #40 single-thread I/O rule).
    def render_suffix
      value = @suffix.respond_to?(:call) ? @suffix.call : @suffix
      text  = value.to_s.strip
      text.empty? ? '' : " #{text}"
    rescue StandardError
      ''
    end
  end
end

# Backward-compatible top-level alias (issue #74): existing call sites that
# still reference the old flat `Spinner` keep working unchanged. New code
# should use UI::Spinner.
Spinner = UI::Spinner unless defined?(Spinner)
