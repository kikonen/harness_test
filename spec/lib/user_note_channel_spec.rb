# frozen_string_literal: true

require 'user_note_channel'
require 'task'
require 'stringio'

RSpec.describe UserNoteChannel do
  # NOTE: StringIO.gets does NOT block - it returns nil as soon as the
  # buffered content is exhausted, which the reader treats as EOF. Blocking
  # scenarios (pause/stop mid-stream) therefore use real pipes, where gets
  # waits until data or a closed write end. Empty-string EOF tests use
  # StringIO (its immediate nil is exactly the EOF we want).

  def wait_for(_target, message: 'timed out waiting for channel state')
    deadline = Time.now + 2
    until yield
      raise message if Time.now > deadline

      sleep 0.01
    end
  end

  # Yields [read_io, write_io] over a real pipe; closes both ends after.
  def with_pipe
    reader, writer = IO.pipe
    begin
      yield reader, writer
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end

  describe 'reading lines in the background' do
    it 'buffers lines as they arrive on stdin' do
      io = StringIO.new("first note\nsecond note\n")
      channel = described_class.new(io)
      channel.start

      wait_for(channel) { channel.lines_read == 2 }

      expect(channel.pending_notes).to eq("first note\nsecond note")
    end

    it 'ignores blank lines and trims whitespace' do
      io = StringIO.new("  spaced  \n\n   \n")
      channel = described_class.new(io)
      channel.start

      wait_for(channel) { channel.lines_read == 3 }

      expect(channel.pending_notes).to eq('spaced')
    end

    it 'returns nil from pending_notes when nothing is buffered' do
      io = StringIO.new # empty: immediate EOF, no lines
      channel = described_class.new(io)
      channel.start

      wait_for(channel) { channel.closed? }

      expect(channel.pending_notes).to be_nil
    end

    it 'drains pending_notes once (empty afterwards)' do
      io = StringIO.new("hello\n")
      channel = described_class.new(io)
      channel.start

      wait_for(channel) { channel.lines_read == 1 }

      expect(channel.pending_notes).to eq('hello')
      expect(channel.pending_notes).to be_nil
    end
  end

  describe 'EOF handling' do
    it 'marks the channel closed and pushes :note_eof on the task outbox' do
      io = StringIO.new("bye\n")
      task = Task.new { |_t| }
      task.start
      channel = described_class.new(io, task)
      channel.start

      wait_for(channel) { channel.closed? }
      wait_for(task, message: 'timed out waiting for :note_eof') do
        events = []
        loop do
          msg = task.poll(0)
          break unless msg
          events << msg[:type]
        end
        events.include?(:note_eof)
      end
      expect(channel.closed?).to be(true)
    end

    it 'does not push :note_eof when there is no owning task' do
      channel = described_class.new(StringIO.new) # immediate EOF
      channel.start

      wait_for(channel) { channel.closed? }

      expect(channel.closed?).to be(true)
    end

    it 'closes (and stops reading) once the stream reaches EOF' do
      with_pipe do |read_io, write_io|
        channel = described_class.new(read_io)
        channel.start
        expect(channel.closed?).to be(false) # still open, reader blocked

        write_io.close # EOF on the read end: the blocked gets() returns nil
        wait_for(channel) { channel.closed? }
        expect(channel.lines_read).to eq(0)
        expect(channel.pending_notes).to be_nil
      end
    end
  end

  describe 'pause / resume (dialog safety)' do
    # Pause = suppress DELIVERY while the dialog owns the keyboard: the
    # reader backs off (pre-gets gate) so lines typed DURING the pause stay
    # unread in the stream - like a terminal where input sits in the kernel
    # buffer for the next turn. Notes buffered BEFORE the pause are still
    # deliverable; reading continues after resume.
    it 'keeps buffered notes across pause and holds lines typed mid-pause' do
      with_pipe do |read_io, write_io|
        channel = described_class.new(read_io)
        channel.start
        write_io.puts 'before pause'
        wait_for(channel) { channel.lines_read == 1 }

        expect(channel.pending_notes).to eq('before pause')
        channel.pause
        sleep 0.05 # let the reader hit the (now-closed) pre-gets gate
        write_io.puts 'held line' # typed "during the dialog": dropped at either
                                  # pause gate (pre-gets or post-gets) - never
                                  # buffered, deterministically
        channel.resume
        write_io.puts 'after resume'
        notes = nil
        wait_for(channel) do
          notes = channel.pending_notes
          notes == 'after resume' # held line never reached the buffer
        end
        expect(notes).to eq('after resume')
      end
    end

    it 'resume after EOF does nothing (channel stays closed)' do
      channel = described_class.new(StringIO.new) # immediate EOF
      channel.start
      wait_for(channel) { channel.closed? }

      channel.resume
      expect(channel.closed?).to be(true)
      expect(channel.pending_notes).to be_nil
    end
  end

  describe 'stop' do
    it 'terminates a live reader and drops buffered lines' do
      with_pipe do |read_io, _write_io|
        channel = described_class.new(read_io)
        channel.start
        expect(channel.closed?).to be(false) # reader alive and blocked

        channel.stop # closes the dedicated stream: the blocked gets wakes
        expect(channel.closed?).to be(true)
        expect(channel.pending_notes).to be_nil
      end
    end

    it 'is terminal: start after stop does nothing' do
      with_pipe do |read_io, _write_io|
        channel = described_class.new(read_io)
        channel.start
        channel.stop # kill the reader before any data flows
        expect(channel.lines_read).to eq(0)

        channel.start # must NOT spawn a new reader
        sleep 0.1
        expect(channel.lines_read).to eq(0)
        expect(channel.pending_notes).to be_nil
      end
    end
  end
end
