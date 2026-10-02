# frozen_string_literal: true

# -- UI::Spinner --------------------------------------------------------------
#
# Animated status indicator (issue #74 / #13). First primitive of the
# namespaced UI library. Public API is unchanged from the previous top-level
# Spinner: start / stop / pause / resume / running?.
#
# Two interchangeable renderers share that public surface:
#   * print  - the long-standing ANSI single-line spinner on $stdout. This is
#              always the safe default and is used whenever there is no
#              interactive terminal (CI, pipes) or when HARNESS_SPINNER=print.
#   * tui    - an inline single-row RatatuiRuby viewport that preserves
#              scrollback. Only activated on an interactive TTY, so it never
#              runs in headless environments; any failure degrades to print
#              rather than leaving the display half-initialized.
module UI
  class Spinner
    FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

    # Optional override / kill switch: HARNESS_SPINNER=print forces the ANSI
    # spinner even on an interactive terminal (useful when experimenting, or
    # when a terminal does not render the inline TUI well). Any other value
    # leaves the capability gate (interactive TTY) in place.
    ENV_OVERRIDE = 'HARNESS_SPINNER'

    # suffix is optional extra text appended after the message (issue #115,
    # e.g. the current context-usage estimate). It may be a plain string or a
    # callable (lambda/proc) that is re-evaluated on EVERY frame so it always
    # shows the CURRENT value, not the snapshot taken at construction time
    # (issue #126). nil/empty shows only the message, as before.
    def initialize(message = 'Working', suffix = nil)
      @message   = message
      @suffix    = suffix
      @running   = false # animation thread is live right now
      @resumable = false # started and not yet stopped (survives a pause)
      @thread    = nil
    end

    def start
      @running   = true
      @resumable = true
      @thread    = Thread.new do
        tui_preferred? ? run_tui_session : print_loop
      end
    end

    # True while the animation thread is live (between #start and the next
    # #pause/#stop). Callers use this to decide whether to resume after they
    # pause it (issue #116).
    def running?
      @running
    end

    # Pause the animation and clear the spinner line so that any
    # output (or input) from tools is not broken by the spinner.
    def pause
      return unless @running

      @running = false
      @thread&.join
      @thread = nil
      clear_line
    end

    # Resume the animation after a pause. No-op for a spinner that was never
    # started or was already stopped - only a paused spinner may be restarted,
    # so a caller can never resurrect a spinner it does not own (issue #116).
    def resume
      return unless @resumable && !@running

      start
    end

    def stop
      @running   = false
      @resumable = false
      @thread&.join
      @thread = nil
      clear_line
    end

    # -- Renderer selection ------------------------------------------------

    # Choose the rich inline-TUI renderer only when we are on an interactive
    # terminal AND the user has not forced the ANSI spinner (issue #74).
    # Everything else - CI, pipes, tests, HARNESS_SPINNER=print - uses the
    # proven print path, so the spinner is always safe in a headless context.
    def tui_preferred?
      return false if forced_print?

      interactive_tty?
    end

    # True when the user pinned the ANSI spinner via HARNESS_SPINNER=print
    # (case-insensitive). This only FORCES the print path; it does not force
    # the TUI - the gate still requires an interactive terminal otherwise.
    def forced_print?
      ENV[ENV_OVERRIDE].to_s.strip.casecmp('print').zero?
    end

    # True only when both stdin and stdout are real terminals - the case in
    # which an inline TUI can actually render for a human (not piped output).
    def interactive_tty?
      return false unless $stdin.respond_to?(:tty?) && $stdin.tty?
      return true if $stdout.nil?

      $stdout.respond_to?(:tty?) && $stdout.tty?
    end

    private

    # Rich renderer: an inline single-row viewport (preserves scrollback) run
    # in the animation thread so the main thread stays free to work. Any
    # failure - native extension missing, terminal init/draw error - degrades
    # to the print renderer rather than corrupting the display (issue #74).
    def run_tui_session
      require 'ratatui_ruby'
      RatatuiRuby.run(viewport: :inline, height: 1) do |tui|
        render_tui(tui)
      end
    rescue StandardError => e
      $stderr.puts tui_fallback_note(e)
      print_loop if @running
    end

    # A short stderr note explaining why we fell back to the ANSI spinner.
    def tui_fallback_note(err)
      "  [spinner] TUI unavailable (#{err.class.name}: #{err.message})" \
       ' - using ANSI fallback'
    end

    # Draw one frame per iteration; poll with a short timeout to pace the
    # animation (~20 fps) and keep the event queue drained. The loop ends as
    # soon as @running is cleared by #pause/#stop, and RatatuiRuby.run's own
    # teardown restores the terminal afterwards.
    def render_tui(tui)
      i = 0
      while @running
        tui.draw { |frame| frame.render_widget(tui.paragraph(text: line(i)), frame.area) }
        i += 1
        tui.poll_event(timeout: 0.05)
      end
    end

    # Proven renderer: the ANSI single-line spinner on $stdout. The clear on
    # #pause/#stop uses an erase-entire-line escape so double-width glyphs
    # (the 🧠 emoji) do not leave trailing trash (issue #125).
    def print_loop
      i = 0
      while @running
        print "\r#{line(i)}"
        $stdout.flush
        i += 1
        sleep 0.1
      end
    end

    # One spinner frame: frame glyph, message, and the (possibly live) suffix.
    def line(i)
      "#{FRAMES[i % FRAMES.size]} #{@message}...#{render_suffix}"
    end

    # Resolve the suffix to the text for this frame. A callable is invoked
    # fresh each frame so it tracks live state (issue #126); a plain string is
    # used as-is. Any failure resolves to no suffix - the spinner must never
    # abort because of a transient read error while the main thread mutates
    # the session.
    def render_suffix
      value = @suffix.respond_to?(:call) ? @suffix.call : @suffix
      text  = value.to_s.strip
      text.empty? ? '' : " #{text}"
    rescue StandardError
      ''
    end

    # Clear the spinner line with an ANSI erase-entire-line escape so the
    # clearing is independent of the rendered width. Blank-spaces computed
    # from string length under-clear when the suffix contains double-width
    # glyphs (the 🧠 emoji occupies 2 terminal columns but counts as 1 char),
    # leaving trailing trash such as a stray ")" on the next line (issue #125).
    def clear_line
      print "\r\e[2K"
      $stdout.flush
    end
  end
end

# Backward-compatible top-level alias (issue #74): existing call sites that
# still reference the old flat `Spinner` keep working unchanged. New code
# should use UI::Spinner.
Spinner = UI::Spinner unless defined?(Spinner)
