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
# SOLE STDIN OWNER (issue #198 minimal fix): the reader thread is the ONLY
# consumer of the stdin stream - dialogs must never open a second gets() on
# it, or every submitted line becomes a coin flip between two live readers
# on one tty (the observed stuck-dialog bug). A dialog therefore claims the
# channel as EXCLUSIVE (#claim_exclusive) and pulls its lines one at a time
# (#exclusive_line): the reader keeps feeding the same FIFO queue, so lines
# pre-buffered before the dialog drain to it first (issue #40 total-order
# rule intact), and nothing races for the keyboard. After the dialog closes
# (#release_exclusive) the line stream resumes serving steering notes.
# There is deliberately NO pause/drop mode: the reader never stops, never
# closes the shared stream mid-turn, and never throws lines away.
#
# Single-thread I/O rule (issue #40): the reader thread only ENQUEUES lines -
# it never touches a stream for output and never writes anywhere. All visible
# rendering happens on the main thread's drain loop, in outbox order.
#
# #stop (task teardown) kills the reader and drops the buffer; on a dedicated
# stream it also closes it to wake a blocked gets(). On the shared $stdin it
# leaves the stream open - stop only happens at turn teardown and no dialog
# is in flight. A zombie parked in an un-wakeable gets() cannot buffer: its
# next gets() wakes on close/EOF and ends it (read_loop drops late lines).
#
# EOF (Ctrl-D while no prompt is shown) ends the task: the reader pushes the
# :note_eof control event, which the drain loop treats like :done. A dialog
# served from a closed channel gets nil from #exclusive_line (dismiss/cancel
# - same as its direct-stdin EOF path). The channel stops itself permanently
# afterwards - it never reads again from a closed stream.

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
    @io      = io
    @task    = task
    @mutex   = Mutex.new
    @lines   = []
    @eof     = false   # stream hit EOF: terminal, never reads again
    @stopped = false   # stop() called: terminal, never restarts
    @thread  = nil
    @woken   = ConditionVariable.new
    @exclusive = false
    @lines_read = 0
  end

  # Start reading lines in the background. No-op when already running or
  # closed (EOF / stopped). Only ONE reader may own a stream at a time.
  def start
    @mutex.synchronize { start_unlocked }
  end

  # Claim the channel for a DIALOG (issue #198 minimal fix): while claimed,
  # #pending_notes returns nil - steering flushes see nothing to deliver -
  # and the dialog pulls its own lines via #exclusive_line in FIFO order.
  # Re-claiming is harmless (nested servicing of one claim). Must be paired
  # with a #release_exclusive when the dialog closes.
  def claim_exclusive
    @mutex.synchronize { @exclusive = true }
  end

  # Release an exclusive claim so the line stream serves steering notes
  # again. Lines left in the queue stay - they are delivered on the next
  # drain tick as a normal note (they were typed for the keyboard, not lost).
  def release_exclusive
    @mutex.synchronize { @exclusive = false }
  end

  # BLOCKING exclusive read for a dialog: returns the next line ("line\n")
  # from the shared FIFO - including lines buffered BEFORE the claim (FIFO)
  # - or nil once the channel is closed. Wakes on every reader enqueue via
  # the condition variable, so nothing is lost and nothing races for stdin.
  # IO-compatible alias: a dialog receives a console whose stdin IS this
  # channel, so its usual `ui.gets` pulls from the shared FIFO instead of
  # opening a second gets() on the real stream (issue #198 minimal fix).
  def gets
    exclusive_line
  end

  # Blocking read used by the dialog path (see #gets for why).
  def exclusive_line
    @mutex.synchronize do
      until closed? || (line = @lines.shift)
        # No line yet: wait for the reader's signal (or EOF/stop). wait
        # releases and re-acquires the mutex, so no race with enqueue.
        @woken.wait(@mutex)
      end
      return nil if line.nil?

      line + "\n"
    rescue ThreadError
      nil # mutex already gone (channel stopped): closed path wins
    end
  end

  # Drain buffered lines into one note text (nil when nothing pending or
  # while a dialog owns the channel exclusively). Consumes the buffer: a
  # second call immediately after returns nil, so the caller can only ever
  # deliver each line once.
  def pending_notes
    @mutex.synchronize do
      return nil if @exclusive || @lines.empty?

      drained = @lines.join("\n")
      @lines.clear
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
      @lines.clear
      interrupt_reader
      @woken.broadcast
    end
  end

  private

  def start_unlocked
    return if closed? || @thread

    t = Thread.new { read_loop }
    # report_on_exception off: a kill from stop surfacing as an exception
    # must not spam the console (and can't be handled anyway - the read is
    # interrupted mid-syscall on some platforms).
    t.report_on_exception = false
    @thread = t
  end

  # Pull lines until EOF or death. Only enqueues - no output I/O here
  # (issue #40 single-thread I/O rule). Every non-blank line lands in the
  # shared FIFO regardless of who will consume it (drain loop or dialog);
  # order is what matters. lines_read counts EVERY line read (blanks
  # included); blank lines are not buffered.
  def read_loop
    until (line = safe_gets).nil?
      @mutex.synchronize { @lines_read += 1 }
      text = line.chomp.strip
      next if text.empty?

      @mutex.synchronize do
        break if closed?   # stop raced the read: drop late lines

        @lines << text
        @woken.signal      # wake an exclusive waiter (dialog) if any
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
      @woken.broadcast   # wake any exclusive waiter: it sees closed? -> nil
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
