# frozen_string_literal: true

# Animated status indicator. NO background thread: the main thread calls
# `render!` once per drain tick, so a spinner frame can never interleave
# with other console I/O.
module UI
  class Spinner
    FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

    attr_reader :ui

    # A live status badge rendered at the END of the frame line (issue #224
    # follow-up: the command consent MODE, e.g. "[YOLO]"). It may be a plain
    # string or a callable re-evaluated on EVERY frame so it always
    # shows the CURRENT state (the mode can be toggled live mid-turn).
    # nil/blank renders nothing. The Task drain loop installs it once; it is
    # shared by every frame of the turn. Placement matters: the progress
    # message ("Sending to model...") is what the user reads first, so the
    # posture tag trails it instead of interrupting it (issue #221 review,
    # bug 3 - the tag between the glyph and the message read as incoherent).
    def badge=(value)
      @badge = value
    end

    attr_reader :badge

    # suffix is optional extra text appended after the message (issue #115,
    # e.g. the current context-usage estimate). It may be a plain string or a
    # callable (lambda/proc) that is re-evaluated on EVERY frame so it always
    # shows the CURRENT value, not the snapshot taken at construction time
    # (issue #126). nil/empty shows only the message, as before.
    # The Task drain loop re-points these via #update_detail while the wait
    # continues - no restart needed.
    # ui: the output console (UI::Console), injected ONCE at construction and
    # used by every per-frame write (render!, clear_line) - there is
    # deliberately no per-call stream argument and no global fallback.
    def initialize(message = 'Working', suffix = nil, ui: nil)
      @message   = message
      @suffix    = suffix
      @active    = false  # between #start and #stop
      @resumable = false  # started and not yet stopped
      @frame     = 0
      @badge     = nil
      raise ArgumentError, 'Spinner requires a ui: console' if ui.nil?

      @ui = ui
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

    # Advance one animation frame and write it to the injected console
    # (ui: passed at construction). Called by the main thread on each
    # drain tick (typically every 100ms). No per-call stream argument: the
    # console is fixed for the spinner's lifetime.
    # No-op when not running (stopped).
    def render!
      return unless running?

      text = frame_line
      ui.print("\r#{text}")
      ui.flush
      @frame += 1
    end

    # Clear the spinner line with an ANSI erase-entire-line escape
    # (issue #125) on the injected console. Called by the main thread when
    # transitioning from rendering to idle. Same constructor-injected
    # contract as #render! .
    def clear_line
      ui.print("\r\e[2K")
      ui.flush
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
      "#{FRAMES[i % FRAMES.size]} #{@message}...#{render_suffix}#{render_badge}"
    end

    def frame_line
      line(@frame)
    end

    # Draw ONE TUI frame (index i) into the viewport, then drain the event
    # queue with a short timeout. Public so headless tests can drive a single
    # deterministic frame through ratatui's test terminal (issue #74).
    def draw_tui_frame(tui, i)
      tui.draw { |frame| frame.render_widget(tui.paragraph(text: line(i)), frame.area) }
      tui.poll_event(timeout: 0.05)
    end

    private

    # Resolve the badge to text for this frame. A callable is invoked fresh
    # each frame so it tracks live state (e.g. a mid-turn mode toggle); a
    # plain string is used as-is. Any failure resolves to no badge - the
    # spinner must never abort on a transient read error (issue #40).
    def render_badge
      value = @badge.respond_to?(:call) ? @badge.call : @badge
      text  = value.to_s.strip
      text.empty? ? '' : " #{text}"
    rescue StandardError
      ''
    end

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
