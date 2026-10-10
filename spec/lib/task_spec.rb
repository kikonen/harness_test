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

  describe 'Task.puts (single event queue)' do
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

    it 'is a no-op when no task is active (CLI owns main-thread output)' do
      expect { Task.puts 'no task around' }.not_to raise_error
    end
  end

  describe 'Tool.puts (tools push onto the active task outbox)' do
    it 'pushes a :text event with origin :tool' do
      task = described_class.new { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        Tool.puts "  [test.tool] ok"
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events[0][:type]).to eq(:text)
      expect(events[0][:origin]).to eq(:tool)
      expect(events[0][:content]).to eq("  [test.tool] ok")
    end

    it 'is a no-op when no task is active (CLI owns main-thread output)' do
      expect { Tool.puts "  [test.tool] ok" }.not_to raise_error
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

    it 'is a no-op when no task is active (nothing to drain for)' do
      expect { Task.emit(:stats, origin: :harness, content: '3 iterations') }.not_to raise_error
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
      sp = UI::Spinner.new('Working', ui: UI::Console.new(stdout: StringIO.new))
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
      io_out = StringIO.new
      io_in = StringIO.new

      error, task = described_class.run(harness: nil,
                                       ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.puts 'greeting'
      end

      expect(error).to be_nil
      expect(task.alive?).to be(false)
    end

    it 'captures an exception in the task as the return error' do
      io_out = StringIO.new
      io_in = StringIO.new

      error, _task = described_class.run(harness: nil,
                                         ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        raise 'boom'
      end

      expect(error).to include('RuntimeError')
      expect(error).to include('boom')
    end

    it 'shows a spinner automatically while waiting on the task thread' do
      io_out = StringIO.new
      io_in = StringIO.new

      described_class.run(harness: nil,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        sleep 0.3 # let the drain loop render a few default frames
      end

      expect(io_out.string).to include('Working...')
    end

    it 're-points the spinner from :spinner_detail events' do
      io_out = StringIO.new
      io_in = StringIO.new

      described_class.run(harness: nil,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.emit(:spinner_detail, origin: :session_manager,
                  content: { message: 'Sending', suffix: 'ctx 12%' })
        sleep 0.3 # let the drain loop render the re-pointed frames
      end

      expect(io_out.string).to include('Sending...')
      expect(io_out.string).to include('ctx 12%')
    end

    it 'prints text events from the outbox in order (and keeps the spinner going after)' do
      io_out = StringIO.new
      io_in = StringIO.new

      described_class.run(harness: nil,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.puts '[step 1] first'
        sleep 0.1 # let the text line render and the spinner re-appear
        Task.puts '[step 2] second'
        sleep 0.2
      end

      captured = io_out.string

      expect(captured).to include('[step 1] first')
      expect(captured).to include('[step 2] second')
      expect(captured).to include('Working...') # default spinner re-shown
    end

    it 'handles a dialog request from the task thread on the main thread' do
      io_out = StringIO.new
      io_in = StringIO.new("1\n") # "1" selects the first option

      choice = nil
      described_class.run(harness: nil,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |t|
        dialog = UI::Dialog.new(
          title: 'Test dialog',
          options: [UI::Dialog::Option.new(title: 'Yes', value: :yes)]
        )
        choice = t.request(:dialog, dialog: dialog)
      end

      captured = io_out.string

      expect(choice).to eq(:yes)
      expect(captured).to include('Test dialog')
    end
  end

  # issue #36 / #198 phase 1: stdin fake exposing input_pending? alongside a
  # normal gets(). The drain loop only PEEKS (input_pending?) and then reads
  # on the main thread - there is no background reader thread anymore.
  class FakePendingStdin
    def initialize(io)
      @io = io
      @pending = false
    end

    attr_writer :pending

    def input_pending?
      @pending
    end

    def gets
      line = @io.gets
      @pending = false   # a line was consumed (canonical tty semantics)
      line
    end
  end

  describe 'Task.run mid-turn user notes (issue #36 / #198 phase 1)' do
    # Minimal harness double: stores the notes the drain loop hands over
    # (blank/nil ignored, like the real setter).
    let(:fake_harness) do
      Class.new do
        attr_reader :notes
        def initialize
          @notes = []
        end

        def user_note_text=(text)
          return if text.to_s.strip.empty?

          @notes << text
        end
      end.new
    end

    # Real pipe, not StringIO: gets() BLOCKS until data or a closed write
    # end (StringIO hits EOF the moment its content is exhausted).
    def with_stdin_pipe
      reader, writer = IO.pipe
      begin
        yield reader, writer
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
      end
    end

    it 'commits a note typed before the turn onto the harness with an ack' do
      io_out  = StringIO.new
      harness = fake_harness

      with_stdin_pipe do |io_in, writer|
        stdin = FakePendingStdin.new(io_in)
        writer.puts 'steer left' # typed before the turn even starts
        stdin.pending = true
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |_t|
          Task.puts 'working'
          sleep 0.3
        end
      end

      expect(harness.notes).to eq(['steer left'])
      expect(io_out.string).to include('[note] got it - steer left')
      expect(io_out.string).to include('working')
    end

    it 'drops a bare Enter (:empty) - no note, the turn continues' do
      io_out  = StringIO.new
      harness = fake_harness

      with_stdin_pipe do |io_in, writer|
        stdin = FakePendingStdin.new(io_in)
        writer.puts '' # bare Enter: nothing typed, no note (T3 design)
        stdin.pending = true
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |_t|
          sleep 0.2
        end
      end

      expect(harness.notes).to be_empty
      expect(io_out.string).not_to include('[note]')
    end

    it 'aborts the turn when the editor sees EOF (Ctrl-D) and no work survives' do
      io_out  = StringIO.new
      harness = fake_harness
      task    = nil

      reader, writer = IO.pipe
      stdin = FakePendingStdin.new(reader)
      stdin.pending = true
      begin
        writer.close # immediate EOF: the editor read returns :eof
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |t|
          task = t # captured so we can assert the thread was stopped
          sleep 5 # would hang forever if the EOF did not abort the turn
        end
      ensure
        reader.close unless reader.closed?
      end

      expect(task).not_to be_nil
      expect(task.alive?).to be(false) # thread stopped at EOF (no leak)
    end

    it 'does not open the editor when the harness is nil (stdin never polled)' do
      io_out = StringIO.new
      fake_in = Object.new
      def fake_in.input_pending?
        raise 'stdin must not be polled without a harness'
      end
      def fake_in.gets
        raise 'stdin must not be read without a harness'
      end

      described_class.run(harness: nil,
                          ui: UI::Console.new(stdout: io_out, stdin: fake_in)) do |_t|
        sleep 0.1
      end

      expect { fake_in.input_pending? }.to raise_error(/must not be polled/)
    end

    it 'keeps FIFO: a pre-typed line is a note; the dialog gets the next' do
      # The line already at the keyboard when the turn starts is a NOTE
      # (typed for steering); the dialog's answer must be the NEXT line.
      io_out  = StringIO.new
      harness = fake_harness
      choice  = nil

      with_stdin_pipe do |io_in, writer|
        stdin = FakePendingStdin.new(io_in)
        writer.puts '1'   # at the keyboard before anything starts -> note
        stdin.pending = true
        Thread.new do
          sleep 0.5
          writer.puts '1' # the real dialog answer (Allow), typed while open
        end
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |t|
          dialog = UI::Dialog.new(
            title: 'Grant test',
            options: [UI::Dialog::Option.new(title: 'Allow', value: :allow)]
          )
          choice = t.request(:dialog, dialog: dialog)
        end
      end

      expect(harness.notes).to eq(['1']) # pre-typed line went to steering
      expect(choice).to eq(:allow)       # the dialog got the NEXT line
    end

    it 'delivers lines typed WHILE a dialog is open to the dialog (no race)' do
      # The bug scenario from issue #198: user types, a dialog appears. No
      # reader thread exists during the turn (the drain loop only peeks),
      # so the dialog's gets() has the keyboard to itself.
      io_out  = StringIO.new
      harness = fake_harness
      choice  = nil

      with_stdin_pipe do |io_in, writer|
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |t|
          dialog = UI::Dialog.new(
            title: 'Grant test',
            options: [UI::Dialog::Option.new(title: 'Allow', value: :allow)]
          )
          # Simulate the user typing while the dialog is open.
          Thread.new { sleep 0.5; writer.puts '1' }
          choice = t.request(:dialog, dialog: dialog)
        end
      end

      expect(choice).to eq(:allow) # dialog received the typed line
    end
  end
end
