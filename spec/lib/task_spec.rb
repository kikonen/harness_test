# frozen_string_literal: true

require 'task'
require 'harness'

RSpec.describe Task do
  describe 'emit (fire-and-forget)' do
    it 'delivers messages to the outbox in order' do
      task = described_class.new do |t|
        t.emit(:output, text: "hello")
        t.emit(:stats, iterations: 3)
      end
      task.start

      messages = []
      loop do
        msg = task.poll(2)
        break if msg.nil?
        messages << msg
        break if msg[:type] == :done
      end

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

  describe 'StdoutProxy (single-thread I/O, issue #40)' do
    it 'routes Task.puts / Task.print through the capture queue' do
      task = described_class.new do |_t|
        Task.puts "hello from task"
        Task.print "raw text"
      end
      task.start

      captured = []
      loop do
        msg = task.poll(2)
        break if msg.nil? || msg[:type] == :done
        captured << msg[:text] if msg[:type] == :output
      end

      expect(captured.join).to eq("hello from task\nraw text")
    end

    it 'never reassigns the shared global $stdout (the original StdoutProxy design did)' do
      require 'stringio'
      old_stdout = $stdout
      sentinel = $stdout = StringIO.new

      task = described_class.new do |_t|
        Task.puts "task output"
      end
      task.start

      # Drain the queue so the thread can finish.
      loop do
        msg = task.poll(2)
        break if msg.nil? || msg[:type] == :done
      end

      # $stdout must still be the sentinel - no proxy leaked in.
      expect($stdout.equal?(sentinel)).to be(true)
      $stdout = old_stdout
    end
  end

  describe 'Task.run (drain loop, issue #40)' do
    let(:fake_harness) { instance_double(Harness, spinner: nil) }

    it 'runs the block and drains all output' do
      error, _task = described_class.run(harness: fake_harness) do |_t|
        Task.puts "greeting"
      end

      expect(error).to be_nil
    end

    it 'captures an exception in the task as the return error' do
      error, _task = described_class.run(harness: fake_harness) do |_t|
        raise 'boom'
      end

      expect(error).to include('RuntimeError')
      expect(error).to include('boom')
    end

    it 'renders the spinner on the main thread during the task' do
      require 'ui'
      require 'stringio'

      spinner = UI::Spinner.new('Working')
      harness = instance_double(Harness, spinner: spinner)

      old_stdout = $stdout
      $stdout = StringIO.new

      described_class.run(harness: harness) do |_t|
        spinner.start
        sleep 0.3 # let the drain loop render a few frames
        spinner.stop
      end

      captured = $stdout.string
      $stdout = old_stdout

      expect(captured).to include('Working...')
    end

    it 'handles a dialog request from the task thread on the main thread' do
      require 'ui'
      require 'stringio'

      fake_harness2 = instance_double(Harness, spinner: nil)

      # Stub $stdin to return "1\n" (select first option)
      old_stdin = $stdin
      $stdin = StringIO.new("1\n")

      # Capture the dialog render output
      old_stdout = $stdout
      $stdout = StringIO.new

      choice = nil
      described_class.run(harness: fake_harness2) do |t|
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
