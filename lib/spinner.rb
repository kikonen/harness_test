# frozen_string_literal: true

# -- Spinner --------------------------------------------------------------

class Spinner
  FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

  def initialize(message = 'Working')
    @message = message
    @running = false
    @thread  = nil
  end

  def start
    @running = true
    @thread = Thread.new do
      i = 0
      while @running
        frame = FRAMES[i % FRAMES.size]
        print "\r#{frame} #{@message}..."
        $stdout.flush
        i += 1
        sleep 0.1
      end
    end
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

  # Resume the animation after a pause (no-op if not started).
  def resume
    return if @thread

    start
  end

  def stop
    @running = false
    @thread&.join
    @thread = nil
    clear_line
  end

  private

  def clear_line
    print "\r" + ' ' * (@message.length + 5) + "\r"
    $stdout.flush
  end
end
