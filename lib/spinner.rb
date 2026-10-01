# frozen_string_literal: true

# -- Spinner --------------------------------------------------------------

class Spinner
  FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

  # suffix is optional extra text appended after the message (issue #115,
  # e.g. the current context-usage estimate). It may be a plain string or a
  # callable (lambda/proc) that is re-evaluated on EVERY frame so it always
  # shows the CURRENT value, not the snapshot taken at construction time
  # (issue #126). nil/empty shows only the message, as before.
  def initialize(message = 'Working', suffix = nil)
    @message   = message
    @suffix  = suffix
    @running   = false # animation thread is live right now
    @resumable = false # started and not yet stopped (survives a pause)
    @thread    = nil
  end

  def start
    @running   = true
    @resumable = true
    @thread    = Thread.new do
      i = 0
      while @running
        frame = FRAMES[i % FRAMES.size]
        print "\r#{frame} #{@message}...#{render_suffix}"
        $stdout.flush
        i += 1
        sleep 0.1
      end
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

  private

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
