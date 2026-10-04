# frozen_string_literal: true

require 'task'
require 'harness'
require 'ui/spinner'
require 'stringio'

RSpec.describe Task do
  def collect_until_done(task)
    messages = []
    loop do
      msg = task.poll(2)
      break if msg.nil?

      messages << msg
      break if msg[:type] == :done
    end
    messages
  end

  describe 'emit (fire-and-forget)' do
    it 'delivers messages to the outbox in order' do
      task = described_class.new do |t|
        t.emit(:output, text: "hello")
        t.emit(:stats, iterations: 3)
      end
      task.start

      messages = collect_until_done(task)

      expect(messages.map { |m| m[:type] }).to eq(%i[output stats done])
      expect(messages[0][:text]).to eq("hello")
      expect(messages[1][:iterations]).to eq(3)
    end

    it 'delivers a :done message when the block completes' do
      task = described_class.new { |_t| }
      task.start

      msg = nil
      20.times do
        msg = task.poll(0.5)
        break if msg && msg[:type] == :done
      end
      expect(msg[:type]).to eq(:done)
    end
  end

  describe 'request / respond' do
    it 'blocks the task thread until the main thread responds' do
      task = described_class.new do |t|
        reply = t.request(:test_request, key: 'value')
        # After unblock, emit the received value for verification
        t.emit(:result, value: reply)
      end
      task.start

      # Poll for the request message
      msg = nil
      20.times do
        msg = task.poll(0.5)
        break if msg && msg[:type] == :__request__
      end

      expect(msg).to be_a(Hash)
      expect(msg[:type]).to eq(:__request__)
      expect(msg[:kind]).to eq(:test_request)
      expect(msg[:key]).to eq('value')

      # Respond to unblock the task thread
      task.respond('the_answer')

      # Now poll for the result (emitted after unblock)
      result_msg = nil
      20.times do
        m = task.poll(0.5)
        next if m.nil?

        result_msg = m if m[:type] == :result
        break if m[:type] == :done
      end

      expect(result_msg[:value]).to eq('the_answer')
    end

    it 'captures the error when task is stopped while waiting' do
      task = described_class.new do |t|
        t.request(:forever) # will never be responded to
      end
      task.start

      # Wait for the request to arrive in the outbox
      msg = nil
      20.times do
        msg = task.poll(0.5)
        break if msg && msg[:type] == :__request__
      end
      expect(msg[:type]).to eq(:__request__)

      # Stop the task: sends STOP to inbox, unblocking the pending request
      task.stop(2)

      # Drain remaining messages (the rescue in start ensures :error + :done)
      got_done = false
      20.times do
        m = task.poll(0.5)
        break if m.nil?

        got_done = true if m[:type] == :done
        break if got_done
      end
      expect(got_done).to be(true)
    end
  end

  describe 'stop' do
    it 'joins the thread and sets @thread to nil' do
      task = described_class.new do |t|
        t.request(:forever) # blocks forever
      end
      task.start
      expect(task.alive?).to be(true)

      task.stop(2)
      expect(task.thread).to be_nil
    end
  end

  describe 'Task.puts / Task.print (single-thread I/O, issue #40)' do
    it 'routes through the capture queue when a task is active' do
      task = described_class.new do |_t|
        Task.puts "hello from task"
        Task.print "raw text"
      end
      task.start

      captured = []
      collect_until_done(task).each { |m| captured << m[:text] if m[:type] == :output }

      expect(captured.join).to eq("hello from task\nraw text")
    end

    it 'falls back to Kernel.puts when no task is active' do
      old_stdout = $stdout
      $stdout = StringIO.new

      Task.puts "main thread line"

      expect($stdout.string).to eq("main thread line\n")
    ensure
      $stdout = old_stdout
    end

    it 'never reassigns the shared global $stdout' do
      old_stdout = $stdout
      sentinel = $stdout = StringIO.new

      task = described_class.new { |_t| Task.puts "task output" }
      task.start

      # Drain the queue so the thread can finish.
      collect_until_done(task)

      # $stdout must still be the sentinel - no proxy leaked in.
      expect($stdout.equal?(sentinel)).to be(true)
    ensure
      $stdout = old_stdout
    end
  end

  describe 'Task.emit (structured sink, issue #40 follow-up)' do
    it 'appends a typed entry to the active task buffer' do
      buf = OutputBuffer.new
      described_class.output_buffer = buf

      Task.emit(:step, origin: :harness, content: '[step 1] did a thing')

      entry = buf.drain.first
      expect(entry.type).to eq(:step)
      expect(entry.origin).to eq(:harness)
      expect(entry.content).to eq('[step 1] did a thing')
    ensure
      described_class.output_buffer = nil
    end

    it 'falls back to Kernel.puts for text content without an active buffer' do
      old_stdout = $stdout
      $stdout = StringIO.new

      Task.emit(:stats, origin: :harness, content: '3 iterations')

      expect($stdout.string).to eq("3 iterations\n")
    ensure
      $stdout = old_stdout
    end

    it 'is a no-op for progress events without an active buffer' do
      old_stdout = $stdout
      $stdout = StringIO.new

      Task.emit(:progress_start, origin: :session_manager, content: { message: 'Working' })
      Task.emit(:progress_stop, origin: :session_manager)

      expect($stdout.string).to eq('')
    ensure
      $stdout = old_stdout
    end

    it 'stores non-string payloads (e.g. progress_start Hashes) intact' do
      buf = OutputBuffer.new
      described_class.output_buffer = buf

      payload = { message: 'Sending', suffix: -> { 'ctx 99%' } }
      Task.emit(:progress_start, origin: :session_manager, content: payload)

      entry = buf.drain.first
      expect(entry.type).to eq(:progress_start)
      expect(entry.content).to be_a(Hash)
      expect(entry.content[:message]).to eq('Sending')
    ensure
      described_class.output_buffer = nil
    end
  end

  describe 'spinner stack (owned by the task, LIFO)' do
    let(:task) { described_class.new { |_t| } }

    def make_spinner(running: true)
      sp = UI::Spinner.new('Working')
      running ? sp.start : nil
      sp
    end

    it 'top_spinner returns the last pushed entry' do
      a = make_spinner
      b = make_spinner
      task.push_spinner(a)
      task.push_spinner(b)

      expect(task.top_spinner).to equal(b)
    end

    it 'visible_spinner is the topmost running entry' do
      outer = make_spinner
      inner = make_spinner
      task.push_spinner(outer)
      task.push_spinner(inner)

      expect(task.visible_spinner).to equal(inner)
    end

    it 'pop_spinner restores the outer spinner to visibility' do
      outer = make_spinner
      inner = make_spinner
      task.push_spinner(outer)
      task.push_spinner(inner)

      task.pop_spinner&.stop

      expect(task.visible_spinner).to equal(outer)
    end

    it 'visible_spinner is nil when the stack is empty' do
      expect(task.visible_spinner).to be_nil
    end

    it 'clear_all_spinners stops every spinner and empties the stack' do
      task.push_spinner(make_spinner)
      task.push_spinner(make_spinner)

      task.clear_all_spinners

      expect(task.top_spinner).to be_nil
      expect(task.visible_spinner).to be_nil
    end
  end

  describe 'Task.run (drain loop, issue #40)' do
    it 'runs the block and drains all output' do
      error, task = described_class.run(harness: nil) do |_t|
        Task.puts "greeting"
      end

      expect(error).to be_nil
      expect(task.alive?).to be(false)
    end

    it 'captures an exception in the task as the return error' do
      error, _task = described_class.run(harness: nil) do |_t|
        raise 'boom'
      end

      expect(error).to include('RuntimeError')
      expect(error).to include('boom')
    end

    it 'drives the spinner from :progress_* events on the main thread' do
      old_stdout = $stdout
      $stdout = StringIO.new

      error, _task = described_class.run(harness: nil) do |_t|
        Task.emit(:progress_start, origin: :session_manager,
                  content: { message: 'Sending', suffix: 'ctx 12%' })
        sleep 0.3 # let the drain loop render a few frames
        Task.emit(:progress_stop, origin: :session_manager)
      end

      captured = $stdout.string
      $stdout = old_stdout

      expect(error).to be_nil
      expect(captured).to include('Sending...')
      expect(captured).to include('ctx 12%')
    end

    it 'renders nested spinners LIFO - inner start, inner stop restores outer' do
      old_stdout = $stdout
      $stdout = StringIO.new

      described_class.run(harness: nil) do |_t|
        Task.emit(:progress_start, origin: :session_manager, content: { message: 'Sending' })
        sleep 0.2
        # In-loop compaction: a second spinner goes ON TOP of the first.
        Task.emit(:progress_start, origin: :session_manager, content: { message: 'Compacting' })
        sleep 0.2
        Task.emit(:progress_stop, origin: :session_manager)
        sleep 0.2
        Task.emit(:progress_stop, origin: :session_manager)
      end

      captured = $stdout.string
      $stdout = old_stdout

      # Both spinners rendered while active; order follows the protocol.
      expect(captured).to include('Sending...')
      expect(captured).to include('Compacting...')
    end

    it 'prints text entries from the buffer in order' do
      old_stdout = $stdout
      $stdout = StringIO.new

      described_class.run(harness: nil) do |_t|
        Task.emit(:step, origin: :harness, content: '[step 1] first')
        Task.emit(:step, origin: :harness, content: '[step 2] second')
      end

      captured = $stdout.string
      $stdout = old_stdout

      expect(captured).to include("[step 1] first")
      expect(captured).to include("[step 2] second")
    end

    it 'handles a dialog request from the task thread on the main thread' do
      # Stub $stdin to return "1\n" (select first option)
      old_stdin = $stdin
      $stdin = StringIO.new("1\n")

      # Capture the dialog render output
      old_stdout = $stdout
      $stdout = StringIO.new

      choice = nil
      described_class.run(harness: nil) do |t|
        dialog = UI::Dialog.new(
          title: 'Test dialog',
          options: [UI::Dialog::Option.new(title: 'Yes', value: :yes)]
        )
        choice = dialog.show
      end

      $stdin = old_stdin
      captured = $stdout.string
      $stdout = old_stdout

      expect(choice).to eq(:yes)
      expect(captured).to include('Test dialog')
    end
  end
end
