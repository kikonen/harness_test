# frozen_string_literal: true

# -- UserNoteChannel --------------------------------------------------------
#
# issue #36: capture user-typed lines while a prompt turn is running, so the
# model can be steered MID-TURN instead of Ctrl+C (abandon) or waiting for
# the next prompt. A background reader thread pulls lines from stdin and
# buffers them; the Task drain loop flushes the buffer on every tick - an
# ack line is rendered and the text is stored on the harness (Harness#
# user_note_text=), where Harness#call_llm injects it into the message chain
# before the next LLM call.
#
# Single-thread I/O rule (issue #40): the reader thread only ENQUEUES lines -
# it never touches a stream for output and never writes anywhere. All visible
# rendering happens on the main thread's drain loop, in outbox order.
#
# Dialog safety: a dialog (grant prompt, ui.dialog) reads stdin from the MAIN
# thread with Reline. While one is open the channel must not RACE it for the
# keyboard. #pause does this by SUPPRESSING DELIVERY, not by stopping the
# reader: a gets() parked on the shared tty cannot be woken (Ruby 4.x has no
# Thread#daemon, and Thread#kill only takes effect once the read returns -
# a tty never returns until EOF), and closing stdin would either kill every
# other reader of it or hand an EOF to the dialog (which the drain loop
# treats as end-of-turn). So while paused the reader keeps running: lines it
# READS are dropped, and buffered notes that predate the pause are delivered
# on resume. In practice a dialog blocks in Reline BEFORE new input arrives,
# so nothing is lost; a line already in flight at the pause moment (or typed
# while the dialog is open) is dropped rather than leaked into the notes.
#
# #stop (task teardown) kills the reader and drops the buffer; on a dedicated
# stream it also closes it to wake a blocked gets(). On the shared $stdin it
# leaves the stream open - stop only happens at turn teardown and no dialog
# is in flight. A zombie parked in an un-wakeable gets() cannot buffer: its
# next gets() wakes on close/EOF and ends it (read_loop drops late lines).
#
# EOF (Ctrl-D while no prompt is shown) ends the task: the reader pushes the
# :note_eof control event, which the drain loop treats like :done. The
# channel stops itself permanently afterwards - it never reads again from a
# closed stream (a later dialog simply gets nil from stdin too).

require 'thread'

class UserNoteChannel
  attr_reader :lines_read

  # io:   the stdin object to read from ($stdin in production, a StringIO
  #       or pipe in tests). Must respond to #gets.
  # task: the owning Task (the drain loop's owner), if any - the :note_eof
  #       event is pushed straight onto ITS outbox. The reader thread has no
  #       thread-local task context, so a bare Task.emit would silently
  #       drop the event. nil in unit tests.
  def initialize(io, task = nil)
    @io         = io
    @task       = task
    @mutex      = Mutex.new
    @pending    = []
    @eof        = false   # stream hit EOF: terminal, never reads again
    @stopped    = false   # stop() called: terminal, never restarts
    @paused     = false
    @thread     = nil
    @lines_read = 0
  end

  # Start reading lines in the background. No-op when already running or
  # closed (EOF / stopped). While paused, start does not spawn a reader -
  # the existing one keeps running (it drops lines until resume; see
  # #pause), and nothing new is needed because only ONE reader may own a
  # stream at a time.
  def start
    @mutex.synchronize { start_unlocked }
  end

  # Suspend DELIVERY (a dialog is taking over stdin from the main thread).
  # The reader keeps running but drops lines while paused - see the header
  # for why it does not stop or close the shared stream. resume re-enables.
  def pause
    @mutex.synchronize { @paused = true }
  end

  # Resume delivery after a dialog closed. Lines typed while paused are in
  # the kernel stdin buffer and are read now (or by the next prompt).
  def resume
    @mutex.synchronize do
      @paused = false
      start_unlocked # covers pause-before-start: spawn now
    end
  end

  # Drain buffered lines into one note text (nil when nothing pending or
  # paused). Consumes the buffer: a second call immediately after returns
  # nil, so the caller can only ever deliver each line once.
  def pending_notes
    @mutex.synchronize do
      return nil if @paused || @pending.empty?

      drained = @pending.join("\n")
      @pending.clear
      drained
    end
  end

  # True once stdin reached EOF or the channel was stopped: it never reads
  # again.
  def closed?
    @eof || @stopped
  end

  # Stop reading and drop any buffered lines (task teardown: a note typed on
  # the last line of a dying turn is lost, by design). Interrupts the reader
  # - kill plus a stream close on dedicated streams, so a blocked gets() is
  # woken. On $stdin the stream stays open for the next turn / dialogs.
  # Terminal - no restart.
  def stop
    @mutex.synchronize do
      return if closed?

      @stopped = true
      @pending.clear
      interrupt_reader
    end
  end

  private

  def start_unlocked
    return if closed? || @thread || @paused
    t = Thread.new { read_loop }
    # report_on_exception off: a kill from pause/stop surfacing as an
    # exception must not spam the console (and can't be handled anyway -
    # the read is interrupted mid-syscall on some platforms).
    t.report_on_exception = false
    @thread = t
  end

  # Pull lines until EOF or death. Only enqueues - no output I/O here
  # (issue #40 single-thread I/O rule). A line read while the channel is
  # PAUSED is dropped rather than delivered: it may have been typed for the
  # dialog (or at least raced it), and buffering it would leak dialog-time
  # input into the model's note slot. Lines read AFTER resume are normal -
  # which is where tty input held in the kernel buffer during a dialog
  # lands (at resume or the next prompt start). lines_read counts EVERY
  # line read (blanks included); dropped lines are not buffered.
  def read_loop
    until (line = safe_gets).nil?
      @mutex.synchronize { @lines_read += 1 }
      text = line.chomp.strip
      next if text.empty?

      # Paused: the line raced the dialog - drop it. A stopped channel
      # never buffers again (zombie hygiene).
      @mutex.synchronize do
        next if @paused || closed?

        @pending << text
      end
    end
    mark_eof
  rescue IOError, Errno::EBADF, Errno::EIO
    # close (from #stop) while gets() was blocked surfaces here: the
    # lifecycle flags (@stopped/@eof) own what follows - no eof mark.
  end

  def safe_gets
    return nil if @io.nil?

    return nil if @io.respond_to?(:closed?) && @io.closed?

    @io.gets
  rescue EOFError
    nil
  rescue Interrupt
    # Ctrl-D in raw mode can surface as an interrupt on the reader thread:
    # treat it as "stop reading" without killing the process.
    nil
  end

  def mark_eof
    @mutex.synchronize do
      return if closed?

      @eof = true
      @thread = nil
    end
    return if @task.nil?

    @task.push_event(type: :note_eof, origin: :user_note_channel)
  end

  # Kill the reader; on a dedicated stream also close it to wake a gets()
  # that Thread#kill cannot reach while the stream is still open. The shared
  # $stdin is never closed here (a turn may follow in this process).
  def interrupt_reader
    th = @thread
    @thread = nil
    close_io unless @io.equal?(STDIN)
    th&.kill
  end

  def close_io
    return unless @io.respond_to?(:close) && !@io.closed?

    @io.close
  rescue IOError, Errno::EBADF
    nil # already closed - fine
  end
end
