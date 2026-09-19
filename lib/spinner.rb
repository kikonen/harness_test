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

  def stop
    @running = false
    @thread&.join
    print "\r" + ' ' * (@message.length + 5) + "\r"
    $stdout.flush
  end
end
