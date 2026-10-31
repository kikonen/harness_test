# frozen_string_literal: true

require "io/console"
require "kramdown/ansi"

# Animated status indicator. NO background thread: the main thread calls
# `render!` once per drain tick, so a spinner frame can never interleave
# with other console I/O.
module UI
  class Spinner
    FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

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

    attr_reader :ui

    # Elapsed-time segment drawn right after the frame glyph (issue #277),
    # e.g. "12s" or "2m 03s". It measures the TURN, not the wait, so the
    # runner - not the spinner - owns the clock (a spinner-built clock would
    # restart on every drain-loop rebuild). Callable or plain string.
    def elapsed=(value)
      @elapsed = value
    end

    attr_reader :elapsed

    # The terminal width a frame is fitted to (issue #401). A plain Integer, a
    # callable re-read every frame (so a resize lands on the next frame), or
    # nil to detect it per frame (see #detect_columns). nil is the default: the
    # harness never sets it, the spinner asks the terminal. A spec injects a
    # fixed Integer so a fit is deterministic without a real terminal.
    def columns=(value)
      @columns = value
    end

    attr_reader :columns

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
    def initialize(message = "Working", suffix = nil, ui: nil)
      @message   = message
      @suffix    = suffix
      @active    = false  # between #start and #stop
      @resumable = false  # started and not yet stopped
      @frame     = 0
      @badge     = nil
      @elapsed   = nil
      @columns   = nil
      raise ArgumentError, "Spinner requires a ui: console" if ui.nil?

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
    # No-op when not running. Each frame erases the line before drawing it:
    # "\r" alone returns the cursor to column 0 WITHOUT erasing, so any frame
    # SHORTER than the previous one left its tail on screen (issue #364).
    # The frame is first fitted to the terminal width (issue #401): a frame
    # wider than the terminal soft-wraps onto extra physical rows that the next
    # frame's "\r\e[2K" cannot reach (it clears only the row the cursor sits
    # on), so the overflow row survives as residue. Fitting keeps one frame on
    # one row.
    def render!
      return unless running?

      text = frame_line
      width = resolve_columns
      text = fit_line(@frame, width) if width
      ui.print("\r\e[2K#{text}")
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
    # :spinner_detail event). Each argument is independent: pass nil to
    # keep the current value, pass a new one to replace it. The values
    # follow the constructor's contract (plain strings, or callables that
    # are re-evaluated every frame so they track live state). The spinner
    # keeps animating; the next frame simply shows the new content.
    def update_detail(message: nil, suffix: nil)
      @message = message unless message.nil?
      @suffix  = suffix  unless suffix.nil?
    end

    # One spinner frame as a plain string (no \r, no write, NO fitting).
    # Public so tests can assert the exact frame text without capturing
    # stdout, and so the full frame is always available to the log.
    def line(i)
      "#{frame_glyph(i)}#{render_elapsed} #{@message}..." \
        "#{render_suffix}#{render_badge}"
    end

    def frame_line
      line(@frame)
    end

    # The frame for index i, fitted to `width` display columns. Deterministic
    # (no terminal probe) so a spec pins both the width and the result.
    #
    # Each segment carries a survival priority (PRIORITY_ORDER); a HIGHER one
    # is preserved, a LOWER one is truncated to the space left and finally
    # dropped - taking every still-lower segment with it. Glyph and message are
    # anchors: glyph is never dropped, message truncates only as a last resort.
    # The suffix (the streamed answer text, the context estimate, the rate) is
    # what runs past 100 columns, so it is sacrificed first; the posture badge
    # survives above it because a consent posture ([YOLO]) must stay visible.
    # A frame that already fits is returned unchanged (byte-identical to #line).
    SURVIVAL_PRIORITY = %i[glyph message elapsed badge suffix].freeze

    def fit_line(i, width)
      width = width.to_i
      return "" if width <= 0

      parts = frame_parts(i) # {prio => text}, already in visual form
      glyph_w = display_width(parts[:glyph])
      return "" if glyph_w > width

      budget = width - glyph_w
      out    = { glyph: parts[:glyph] }
      truncated = false

      # Allocate full widths highest-priority-first; the first segment that no
      # longer fits whole is truncated to the remaining budget, and once a
      # truncation has happened every lower-priority segment is dropped.
      SURVIVAL_PRIORITY.each do |prio|
        next if prio == :glyph

        text = parts[prio]
        need = display_width(text)
        if !truncated && need <= budget
          out[prio] = text
          budget -= need
          next
        end
        truncated = true
        out[prio] = budget >= 2 ? truncate_to(text, budget) : ""
        budget = 0
      end

      # Reassemble in VISUAL order, not priority order.
      parts.keys.map { |prio| out[prio] }.join
    end

    # Draw ONE TUI frame (index i) into the viewport, then drain the event
    # queue with a short timeout. Public so headless tests can drive a single
    # deterministic frame through ratatui's test terminal (issue #74).
    def draw_tui_frame(tui, i)
      tui.draw { |frame| frame.render_widget(tui.paragraph(text: line(i)), frame.area) }
      tui.poll_event(timeout: 0.05)
    end

    private

    # The frame's droppable segments, keyed by priority, in the order they are
    # drawn (glyph first, badge last). Each string already carries its own
    # leading separator space, so concatenating them in this key order rebuilds
    # the visual line. #line is the same composition - fit_line only decides
    # how much of each survives.
    def frame_parts(i)
      {
        glyph: frame_glyph(i),
        elapsed: render_elapsed,
        message: " #{@message}...",
        suffix: render_suffix,
        badge: render_badge
      }
    end

    # Terminal columns for this frame. A callable is re-read each frame (a
    # resize then lands on the next frame); an Integer is used as-is; nil
    # probes the console the frame is written to. No terminal (a spec's
    # StringIO console, a pipe, a closed descriptor) resolves to nil, which
    # means NO fitting - the raw frame is drawn exactly as before issue #401.
    def resolve_columns
      value = @columns.respond_to?(:call) ? @columns.call : @columns
      return value if value.is_a?(Integer) && value.positive?
      return detect_columns if @columns.nil?

      nil
    end

    # Width of the console the frame is actually written to (@ui.stdout), NOT
    # the process tty at large: a StringIO sink (every spec console) is not a
    # tty, so it answers nil and those frames stay UNFITTED - the byte-for-byte
    # behavior every render! example above relies on. Preference order: the
    # sink's own winsize (a real terminal File answers even when its isatty is
    # unreliable, as some MSYS2 setups report), then - only for a tty sink -
    # IO.console and $ENV['COLUMNS'].
    def detect_columns
      io = @ui.respond_to?(:stdout) ? @ui.stdout : nil
      sink_columns(io) || (tty_sink?(io) ? console_columns || env_columns : nil)
    end

    def tty_sink?(io)
      io.respond_to?(:tty?) && io.tty?
    end

    def sink_columns(io)
      return nil unless io.respond_to?(:winsize)

      positive_cols(io.winsize[0])
    rescue StandardError
      nil
    end

    def console_columns
      io = IO.console
      return nil unless io.respond_to?(:winsize)

      positive_cols(io.winsize[0])
    rescue StandardError
      nil
    end

    def env_columns
      env = ENV["COLUMNS"].to_s
      env.match?(/\A\d+\z/) ? positive_cols(env) : nil
    end

    def positive_cols(value)
      value = value.to_i
      value.positive? ? value : nil
    end

    def display_width(text)
      Kramdown::ANSI::Width.display_width(text)
    end

    # Cut text to `width` display columns with a "…" marker INSIDE the budget
    # (the result is exactly `width` wide). A width under 2 cannot hold a
    # marker, so it cuts the marker off rather than overflow the row again.
    def truncate_to(text, width)
      return text if display_width(text) <= width

      Kramdown::ANSI::Width.truncate(text, length: [width, 1].max, ellipsis: "…")
    end

    def frame_glyph(i)
      FRAMES[i % FRAMES.size]
    end

    # Resolve the elapsed segment for this frame. A callable is invoked fresh
    # each frame; a plain string is used as-is. Any failure (or a nil clock)
    # resolves to no segment, same contract as the badge and the suffix.
    def render_elapsed
      value = @elapsed.respond_to?(:call) ? @elapsed.call : @elapsed
      text  = value.to_s.strip
      text.empty? ? "" : " #{text}"
    rescue StandardError
      ""
    end

    # Resolve the badge to text for this frame. A callable is invoked fresh
    # each frame so it tracks live state (e.g. a mid-turn mode toggle); a
    # plain string is used as-is. Any failure resolves to no badge - the
    # spinner must never abort on a transient read error (issue #40).
    def render_badge
      value = @badge.respond_to?(:call) ? @badge.call : @badge
      text  = value.to_s.strip
      text.empty? ? "" : " #{text}"
    rescue StandardError
      ""
    end

    # Resolve the suffix to the text for this frame. A callable is invoked
    # fresh each frame so it tracks live state (issue #126); a plain string is
    # used as-is. Any failure resolves to no suffix - the spinner must never
    # abort because of a transient read error while the task thread mutates
    # the session (issue #40 single-thread I/O rule).
    # The text is drawn VERBATIM: every blank in it is the segment's own column -
    # a leading one reserves the rate number's tens column, a trailing one pads
    # the tail segment to its fixed width - and stripping either would move what
    # comes after it (issue #364). The spinner adds only its ONE separator space.
    def render_suffix
      value = @suffix.respond_to?(:call) ? @suffix.call : @suffix
      text  = value.to_s
      text.strip.empty? ? "" : " #{text}"
    rescue StandardError
      ""
    end
  end
end
