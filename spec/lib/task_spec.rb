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

  describe 'Task.run mid-turn user notes (issue #36)' do
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
    # end, so EOF cannot fire before we close the writer (StringIO hits EOF
    # the moment its content is exhausted, which would end the turn early).
    def with_stdin_pipe
      reader, writer = IO.pipe
      begin
        yield reader, writer
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
      end
    end

    it 'flushes a note typed before the turn onto the harness with an ack' do
      io_out  = StringIO.new
      harness = fake_harness

      with_stdin_pipe do |io_in, writer|
        writer.puts 'steer left' # "typed" before the task even starts
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
          Task.puts 'working'
          sleep 0.3 # still running when the writer closes (EOF below)
        end
      end

      expect(harness.notes).to eq(['steer left'])
      # Both lines rendered: the ack (main thread) and the task output.
      expect(io_out.string).to include('[note] got it - steer left')
      expect(io_out.string).to include('working')
    end

    it 'ends the turn when stdin reaches EOF (:note_eof) and no work survives' do
      io_out  = StringIO.new
      harness = fake_harness
      task    = nil

      with_stdin_pipe do |io_in, writer|
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |t|
          Task.puts 'working'
          task = t # captured by the block so we can assert it was stopped
          sleep 5 # would hang forever if :note_eof never ended the turn
        end
      ensure
        writer.close unless writer.closed? # EOF: the channel reader sees nil
      end

      expect(task).not_to be_nil
      expect(task.alive?).to be(false) # thread stopped at EOF (no leak)
      expect(io_out.string).to include('working')
    end

    it 'does not start a channel when the harness is nil (unit-test mode)' do
      io_out = StringIO.new
      task   = nil

      described_class.run(harness: nil,
                          ui: UI::Console.new(stdout: io_out, stdin: StringIO.new('note\n'))) do |t|
        task = t
        sleep 0.1
      end

      expect(task.note_channel).to be_nil
    end

    it 'serves a dialog from the note channel FIFO (issue #198)' do
      # The line typed before the dialog opens is the dialog's answer: it
      # must go to the DIALOG first (FIFO order), not be flushed as a note.
      io_out  = StringIO.new
      harness = fake_harness
      choice  = nil

      with_stdin_pipe do |io_in, writer|
        writer.puts '1'   # typed before the dialog opens
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |t|
          dialog = UI::Dialog.new(
            title: 'Grant test',
            options: [UI::Dialog::Option.new(title: 'Allow', value: :allow)]
          )
          choice = t.request(:dialog, dialog: dialog)
        end
      end

      expect(choice).to eq(:allow) # the line reached the dialog, not a note
      expect(harness.notes).to be_empty # it must NOT double up as a note
    end

    it 'delivers lines typed WHILE a dialog is open to the dialog (no race)' do
      # The bug scenario: user types at the prompt, a dialog appears. With
      # two readers on the tty the line was stolen by one of them; now the
      # channel is the sole reader and hands the line to the dialog.
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
          # Simulate the user typing while the dialog is open: write to the
          # stdin pipe from a helper thread once the request is serviced.
          Thread.new { sleep 0.5; writer.puts '1' }
          choice = t.request(:dialog, dialog: dialog)
        end
      end

      expect(choice).to eq(:allow) # dialog received the typed line
    end
  end
end
