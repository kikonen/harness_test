# frozen_string_literal: true

require "io/console"
require "kramdown/ansi"
require_relative "width"

# Animated status indicator. NO background thread: the main thread calls render! once per drain
# tick, so a spinner frame can never interleave with other console I/O.
module UI
  class Spinner
    FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    # A DETECTED width keeps this many columns free: writing a frame into every column makes the
    # terminal wrap the line, which lands the next frame's "\r\e[2K" on the wrong row and leaves
    # residue. Detection lives in UI::Width, not a second copy here.
    RESERVED_COLUMNS = UI::Width::RESERVED_COLUMNS

    # A live status badge at the END of the frame (e.g. the consent MODE "[YOLO]"): a plain string
    # or a callable re-evaluated every frame so it shows the CURRENT state. nil/blank renders nothing.
    # It trails the progress message rather than interrupting it.
    def badge=(value)
      @badge = value
    end

    attr_reader :badge

    attr_reader :ui

    # Elapsed-time segment drawn right after the glyph ("12s", "2m 03s"). It measures the TURN, not
    # the wait, so the runner owns the clock (a spinner-built clock would restart on every rebuild).
    # Callable or plain string.
    def elapsed=(value)
      @elapsed = value
    end

    attr_reader :elapsed

    # The terminal width a frame is fitted to: a plain Integer, a callable re-read every frame (so a
    # resize lands on the next frame), or nil to detect it per frame. nil is the default. A detected
    # width is reserved by RESERVED_COLUMNS; an injected Integer is used exactly as given.
    def columns=(value)
      @columns = value
    end

    attr_reader :columns

    # suffix is optional extra text after the message (e.g. the context-usage estimate): a plain
    # string or a callable re-evaluated every frame so it tracks live state, not the construction-time
    # snapshot. The drain loop re-points these via #update_detail while the wait continues.
    # ui: the output console, injected ONCE and used by every per-frame write - deliberately no
    # per-call stream argument and no global fallback.
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

    # Begin the spinner. Pure state change - no I/O, no thread spawn. The main thread starts drawing
    # frames on its next render! call.
    def start
      @active    = true
      @resumable = true
      @frame     = 0
    end

    # True while the spinner should be visible (between #start and the next #stop). The drain loop
    # uses this to decide what gets rendered.
    def running?
      @active
    end

    # End the spinner. Pure state change - the main thread clears the line on its next tick when it
    # sees running? is false.
    def stop
      @active    = false
      @resumable = false
    end

    # -- Main-thread render (single-thread I/O rule) -------------------------

    # Advance one frame and write it to the injected console (ui: passed at construction), called on
    # each drain tick. Each frame erases the line before drawing it: "\r" alone returns to column 0
    # WITHOUT erasing, so a frame shorter than the previous left its tail. The frame is fitted to the
    # terminal width first: a frame wider than the terminal soft-wraps onto rows the next frame's
    # "\r\e[2K" cannot reach (it clears only the cursor's row), so the overflow survives as residue.
    def render!
      return unless running?

      # ONE snapshot of this frame's segments: a live suffix/clock/badge is resolved once per frame,
      # never once per composing step.
      parts = frame_parts(@frame)
      width = resolve_columns
      text = width ? fit_parts(parts, width) : parts.values.join
      ui.print("\r\e[2K#{text}")
      ui.flush
      @frame += 1
    end

    # Clear the spinner line with an ANSI erase-entire-line escape on the injected console. Called by
    # the main thread transitioning from rendering to idle. Same injected-console contract as #render!.
    def clear_line
      ui.print("\r\e[2K")
      ui.flush
    end

    # Re-point the message and/or suffix without restarting the animation (used to apply a
    # :spinner_detail event). Each argument is independent: pass nil to keep the current value. The
    # values follow the constructor's contract. The spinner keeps animating; the next frame shows the new content.
    def update_detail(message: nil, suffix: nil)
      @message = message unless message.nil?
      @suffix  = suffix  unless suffix.nil?
    end

    # One frame as a plain string (no \r, no write, NO fitting). Public so tests assert the exact
    # frame text without capturing stdout, and so the full frame is always available to the log.
    def line(i)
      "#{frame_glyph(i)}#{render_elapsed} #{@message}..." \
        "#{render_suffix}#{render_badge}"
    end

    def frame_line
      line(@frame)
    end

    # The frame for index i, fitted to `width` display columns. Deterministic (no terminal probe) so a
    # spec pins both the width and the result. Each segment carries a survival priority: a higher one
    # is preserved, a lower one truncated to the space left and finally dropped - taking every lower
    # segment with it. Glyph and message are anchors (glyph never dropped). The suffix is what runs
    # past 100 columns, so it is sacrificed first; the badge survives above it because a consent
    # posture ([YOLO]) must stay visible. A frame that already fits is returned unchanged.
    SURVIVAL_PRIORITY = %i[glyph message elapsed badge suffix].freeze

    def fit_line(i, width)
      fit_parts(frame_parts(i), width)
    end

    # Draw ONE TUI frame (index i) into the viewport, then drain the event queue with a short timeout.
    # Public so headless tests can drive a single deterministic frame through ratatui's test terminal.
    def draw_tui_frame(tui, i)
      tui.draw { |frame| frame.render_widget(tui.paragraph(text: line(i)), frame.area) }
      tui.poll_event(timeout: 0.05)
    end

    private

    # Fit one already-resolved frame (the {prio => text} hash #frame_parts builds) to `width` columns.
    # #fit_line resolves the frame first; #render! passes its own single snapshot so a live segment is
    # never evaluated twice for one drawn frame.
    def fit_parts(parts, width)
      width = width.to_i
      return "" if width <= 0

      glyph_w = display_width(parts[:glyph])
      return "" if glyph_w > width

      budget = width - glyph_w
      out    = { glyph: parts[:glyph] }
      truncated = false

      # Allocate full widths highest-priority-first; the first segment that no longer fits whole is
      # truncated to the remaining budget, and once a truncation happens every lower segment is dropped.
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

    # The frame's droppable segments, keyed by priority, in the order they are drawn (glyph first,
    # badge last). Each string already carries its own leading separator space, so concatenating them
    # in this key order rebuilds the visual line. #line is the same composition - fit_line only decides
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

    # Terminal columns for this frame. A callable is re-read each frame (a resize lands on the next);
    # an Integer is used as-is; nil probes the console the frame is written to. No terminal (a spec
    # StringIO, a pipe) resolves to nil, which means NO fitting - the raw frame is drawn as before.
    def resolve_columns
      value = @columns.respond_to?(:call) ? @columns.call : @columns
      return value if value.is_a?(Integer) && value.positive?
      return reserve_columns(detect_columns) if @columns.nil?

      nil
    end

    # Width of the console the frame is actually written to (@ui.stdout), NOT the process tty at large:
    # a StringIO sink (every spec console) is not a tty, so it answers nil and those frames stay
    # UNFITTED - the byte-for-byte behaviour every render! example relies on. Detection is UI::Width's.
    def detect_columns
      io = @ui.respond_to?(:stdout) ? @ui.stdout : nil
      UI::Width.detect_columns(io)
    end

    def reserve_columns(width)
      return nil if width.nil?

      UI::Width.reserve_amount(width, RESERVED_COLUMNS)
    end

    def display_width(text)
      Kramdown::ANSI::Width.display_width(text)
    end

    # Cut text to `width` display columns with a "…" marker INSIDE the budget (the result is exactly
    # `width` wide). A width under 2 cannot hold a marker, so it cuts the marker off rather than overflow.
    def truncate_to(text, width)
      return text if display_width(text) <= width

      Kramdown::ANSI::Width.truncate(text, length: [width, 1].max, ellipsis: "…")
    end

    def frame_glyph(i)
      FRAMES[i % FRAMES.size]
    end

    # Resolve the elapsed segment for this frame. A callable is invoked fresh each frame; a plain
    # string is used as-is. Any failure (or a nil clock) resolves to no segment.
    def render_elapsed
      value = @elapsed.respond_to?(:call) ? @elapsed.call : @elapsed
      text  = value.to_s.strip
      text.empty? ? "" : " #{text}"
    rescue StandardError
      ""
    end

    # Resolve the badge to text for this frame. A callable is invoked fresh each frame so it tracks
    # live state (e.g. a mid-turn mode toggle); a plain string is used as-is. Any failure resolves to
    # no badge - the spinner must never abort on a transient read error.
    def render_badge
      value = @badge.respond_to?(:call) ? @badge.call : @badge
      text  = value.to_s.strip
      text.empty? ? "" : " #{text}"
    rescue StandardError
      ""
    end

    # Resolve the suffix for this frame. A callable is invoked fresh each frame so it tracks live
    # state; a plain string is used as-is. Any failure resolves to no suffix - the spinner must never
    # abort on a transient read error while the task thread mutates the session.
    # The text is drawn VERBATIM: every blank in it is the segment's own column (a leading one reserves
    # a number's tens column, a trailing one pads the tail to its fixed width) - stripping either would
    # move what comes after it. The spinner adds only its ONE separator space.
    def render_suffix
      value = @suffix.respond_to?(:call) ? @suffix.call : @suffix
      text  = value.to_s
      text.strip.empty? ? "" : " #{text}"
    rescue StandardError
      ""
    end
  end
end
