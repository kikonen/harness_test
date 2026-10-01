# frozen_string_literal: true

# -- Spinner --------------------------------------------------------------

class Spinner
  FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

  # suffix is optional extra text appended after the message (issue #115,
  # e.g. the current context-usage estimate). nil/empty shows only the
  # message, as before.
  def initialize(message = 'Working', suffix = nil)
    @message   = message
    @suffix    = suffix.to_s.strip
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

  def render_suffix
    @suffix.empty? ? '' : " #{@suffix}"
  end

  def clear_line
    print "\r" + ' ' * (line_length) + "\r"
    $stdout.flush
  end

  # Length of one rendered spinner line (frame + message + optional
  # suffix), used to blank the line on pause/stop.
  def line_length
    @message.length + 5 + render_suffix.length
  end
end
