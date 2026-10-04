# frozen_string_literal: true

require 'task'
require 'harness'
require 'ui/spinner'
require 'stringio'

RSpec.describe Task do
  def drain_outbox(task)
    events = []
    loop do
      msg = task.poll(0)
      break unless msg
      events << msg
    end
    events
  end

  describe 'push_event (single event queue)' do
    it 'delivers messages to the outbox in order' do
      task = described_class.new do |t|
        t.push_event(type: :output, origin: :harness, content: 'hello')
        t.push_event(type: :stats, origin: :harness, content: '3 iterations')
      end
      task.start

      sleep 0.1 # let the thread start and push its events before draining
      messages = drain_outbox(task)

      expect(messages.map { |m| m[:type] }).to eq(%i[output stats done])
      expect(messages[0][:content]).to eq('hello')
      expect(messages[1][:content]).to eq('3 iterations')
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
        # After unblock, push the received value for verification
        t.push_event(type: :result, origin: :task, content: reply)
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

      # Now poll for the result (pushed after unblock)
      result_msg = nil
      20.times do
        m = task.poll(0.5)
        next if m.nil?

        result_msg = m if m[:type] == :result
        break if m[:type] == :done
      end

      expect(result_msg[:content]).to eq('the_answer')
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

      # Drain remaining messages (the rescue in start ensures :error_ctrl + :done)
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

  describe 'Task.puts / Task.print (single event queue)' do
    it 'pushes :text events onto the active task outbox' do
      task = described_class.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        Task.puts 'hello from task'
        Task.puts 'second line'
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events.map { |m| m[:type] }).to eq(%i[text text])
      expect(events[0][:content]).to eq('hello from task')
      expect(events[1][:content]).to eq('second line')
    end

    it 'Task.print pushes a single :text event with terminal: false' do
      task = described_class.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        Task.print 'raw text'
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events.map { |m| m[:type] }).to eq([:text])
      expect(events[0][:content]).to eq('raw text')
      expect(events[0][:terminal]).to be(false)
    end

    it 'falls back to Kernel.puts when no task is active' do
      old_stdout = $stdout
      $stdout = StringIO.new

      Task.puts 'no task around'

      expect($stdout.string).to eq("no task around\n")
    ensure
      $stdout = old_stdout
    end

    it 'falls back to Kernel.print when no task is active' do
      old_stdout = $stdout
      $stdout = StringIO.new

      Task.print 'no task around'

      expect($stdout.string).to eq('no task around')
    ensure
      $stdout = old_stdout
    end
  end

  describe 'Task.emit (structured events on the outbox)' do
    it 'pushes a typed event onto the active task outbox' do
      task = described_class.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        Task.emit(:step, origin: :harness, content: '[step 1] did a thing')
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events[0][:type]).to eq(:step)
      expect(events[0][:origin]).to eq(:harness)
      expect(events[0][:content]).to eq('[step 1] did a thing')
    end

    it 'is a no-op when no task is active' do
      old_stdout = $stdout
      $stdout = StringIO.new

      Task.emit(:stats, origin: :harness, content: '3 iterations')

      expect($stdout.string).to eq('')
    ensure
      $stdout = old_stdout
    end

    it 'stores non-string payloads (e.g. spinner_detail Hashes) intact' do
      task = described_class.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        payload = { message: 'Sending', suffix: 'ctx 99%' }
        Task.emit(:spinner_detail, origin: :session_manager, content: payload)
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events[0][:type]).to eq(:spinner_detail)
      expect(events[0][:content]).to be_a(Hash)
      expect(events[0][:content][:message]).to eq('Sending')
    end
  end

  describe 'the ONE spinner (owned by the drain loop)' do
    let(:task) { described_class.new { |_t| } }

    def make_spinner(running: true)
      sp = UI::Spinner.new('Working')
      running ? sp.start : nil
      sp
    end

    it 'spinner= replaces the spinner and visible_spinner tracks it' do
      a = make_spinner
      b = make_spinner

      task.spinner = a
      expect(task.visible_spinner).to equal(a)

      b.start
      task.spinner = b
      expect(task.visible_spinner).to equal(b)
    end

    it 'visible_spinner is nil when no spinner has been set yet' do
      expect(task.spinner).to be_nil
      expect(task.visible_spinner).to be_nil
    end

    it 'visible_spinner is nil once the spinner is stopped' do
      sp = make_spinner
      task.spinner = sp
      sp.stop

      expect(task.visible_spinner).to be_nil
    end

    it 'clear_all_spinners stops the spinner' do
      sp = make_spinner
      task.spinner = sp

      task.clear_all_spinners

      expect(sp.running?).to be(false)
      expect(task.visible_spinner).to be_nil
    end
  end

  describe 'Task.run (drain loop, issue #40)' do
    it 'runs the block and drains all output' do
      error, task = described_class.run(harness: nil) do |_t|
        Task.puts 'greeting'
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

    it 'shows a spinner automatically while waiting on the task thread' do
      old_stdout = $stdout
      $stdout = StringIO.new

      described_class.run(harness: nil) do |_t|
        sleep 0.3 # let the drain loop render a few default frames
      end

      captured = $stdout.string
      $stdout = old_stdout

      expect(captured).to include('Working...')
    end

    it 're-points the spinner from :spinner_detail events' do
      old_stdout = $stdout
      $stdout = StringIO.new

      described_class.run(harness: nil) do |_t|
        Task.emit(:spinner_detail, origin: :session_manager,
                  content: { message: 'Sending', suffix: 'ctx 12%' })
        sleep 0.3 # let the drain loop render the re-pointed frames
      end

      captured = $stdout.string
      $stdout = old_stdout

      expect(captured).to include('Sending...')
      expect(captured).to include('ctx 12%')
    end

    it 're-points suffix only when the detail provides one' do
      old_stdout = $stdout
      $stdout = StringIO.new

      described_class.run(harness: nil) do |_t|
        Task.emit(:spinner_detail, origin: :harness, content: { message: 'Running tool' })
        sleep 0.2
        # A later detail that only sets the suffix keeps the current message.
        Task.emit(:spinner_detail, origin: :harness, content: { suffix: 'file.read' })
        sleep 0.2
      end

      captured = $stdout.string
      $stdout = old_stdout

      expect(captured).to include('Running tool...')
      expect(captured).to include('file.read')
    end

    it 'prints text events from the outbox in order (and keeps the spinner going after)' do
      old_stdout = $stdout
      $stdout = StringIO.new

      described_class.run(harness: nil) do |_t|
        Task.puts '[step 1] first'
        sleep 0.1 # let the text line render and the spinner re-appear
        Task.puts '[step 2] second'
        sleep 0.2
      end

      captured = $stdout.string
      $stdout = old_stdout

      expect(captured).to include('[step 1] first')
      expect(captured).to include('[step 2] second')
      expect(captured).to include('Working...') # default spinner re-shown
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
        choice = t.request(:dialog, dialog: dialog)
      end

      $stdin = old_stdin
      captured = $stdout.string
      $stdout = old_stdout

      expect(choice).to eq(:yes)
      expect(captured).to include('Test dialog')
    end
  end
end
