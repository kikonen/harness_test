# frozen_string_literal: true

# -- Task --------------------------------------------------------------------
#
# Runs a block on a background thread and owns ALL console I/O for that turn
# (issue #40 - single-thread I/O rule). The task thread NEVER writes to an
# IO stream. It pushes typed events onto the SINGLE event queue (the outbox);
# the main thread's drain loop reads from that queue, stores each output
# event into the OutputBuffer (structured log), and renders to stdout in
# order. There is no second channel - one queue guarantees total ordering.
#
# SINGLE EVENT QUEUE (issue #40 follow-up):
#   The outbox (Thread::Queue) is the ONLY task→main channel. Both output
#   events (:text, :spinner_detail, etc.) AND control events (:done,
#   :error_ctrl, :__request__) travel on it. The drain loop pops one message
#   at a time and dispatches by type. This guarantees total ordering of all
#   visible output because every event flows through exactly one FIFO.
#
# Protocol:
#   Task thread -> Main thread: push_event(type:, origin:, content:) [outbox]
#   Task thread -> Main thread: request(type, **payload)             [outbox, blocking]
#   Main thread -> Task thread: task.respond(value)                  [inbox]
#   Main thread (drain loop):    poll outbox, dispatch by type
#
# Structured log:
#   The OutputBuffer is owned by the Task instance. The DRAIN LOOP fills it
#   (one put per output event it reads from the outbox). Task code NEVER
#   touches the buffer directly. A future TUI can read the buffer as a
#   durable, inspectable record of everything shown to the user.
#
# Spinner ownership - the RUNNER decides, trivially:
#   The drain loop shows the spinner while the outbox is EMPTY (the task is
#   silently working - i.e. while we wait for a slow operation such as an
#   LLM request). A :spinner_detail event re-points what the current wait
#   looks like (message + optional suffix) and keeps the spinner alive after
#   that batch. Any OTHER data clears the spinner line BEFORE it is rendered
#   (output lines must never land under a stale spin frame). It comes back on
#   the next tick only if the outbox is empty again. Harness code never
#   starts or stops spinners - it just emits :spinner_detail (or nothing at
#   all) and is done. Tool execution renders output, it does not wait, so it
#   never re-points the spinner.
#
# Console injection:
#   Task.run REQUIRES a `ui:` (a UI::Console wrapping an explicit stdout/
#   stdin pair). The same console is used for spinner frames, text output,
#   and dialog prompts so tests can capture everything through a single
#   StringIO-backed console. It is published on the task instance and passed
#   explicitly to every I/O call.
#
# Ctrl+C:
#   While Task.run is draining, SIGINT is trapped so an interrupt targets
#   the drain loop, not a random thread. The task thread is force-stopped
#   (no background work survives the turn) and the Interrupt is re-raised
#   for the CLI's cleanup path.

# Mid-turn user notes (issue #36): when stdin is available (a TTY in
# production, any stream in tests), Task.run starts a UserNoteChannel that
# reads typed lines in the background while the task runs. The drain loop
# flushes the buffer on every tick: the note is rendered as an ack line and
# stored on the harness (Harness#user_note_text=), where Harness#call_llm
# injects it into the chain before the next LLM call. A dialog PAUSES the
# channel for its duration (the dialog owns stdin on the main thread, so a
# second reader would race it); EOF ends the task (like :done).

require_relative 'output_buffer'
require_relative 'ui/spinner'
require_relative 'user_note_channel'

class Task
  # Default spinner message while the runner waits for the task thread.
  # Any :spinner_detail event may override it (and its suffix) for the
  # rest of the wait.
  DEFAULT_SPINNER_MESSAGE = 'Working'

  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  STOP = Object.new.freeze

  # Timeout (seconds) for polling the outbox in the drain loop.
  DEFAULT_POLL_TIMEOUT = 0.1

  # Event types handled by the drain loop as control flow (never stored or
  # rendered): the task finished ([:done]), stdin hit EOF while reading
  # mid-turn notes ([:note_eof], issue #36), and a pending user request
  # ([:__request__], answered on the main thread).
  CONTROL_EVENTS = %i[error_ctrl note_eof __request__].freeze

  attr_reader :thread, :buffer, :ui

  # The mid-turn note channel (issue #36) and its owner harness: the channel
  # is read-only (created by Task.run), the harness is assigned by Task.run
  # so the drain loop's #flush_user_notes can store notes on it.
  attr_accessor :note_channel
  attr_accessor :harness

  def initialize(&block)
    @block   = block
    @inbox   = Thread::Queue.new   # main -> task (responses, stop)
    @outbox  = Thread::Queue.new   # task -> main (SINGLE event queue)
    @buffer  = OutputBuffer.new    # structured log (runner fills it)
    @spinner = nil
    @thread  = nil
    @ui      = nil                 # set by Task.run before start
    @dialog_open = false           # true while perform_direct is on stdin
    @note_channel = nil            # issue #36: mid-turn user notes
    @harness      = nil
  end

  attr_writer :ui

  # True while the main thread is inside a dialog's perform_direct
  # (stdin read + prompt print) - store_and_render must not clear any
  # output line in that window, so the Choice prompt survives.
  def dialog_open?
    @dialog_open
  end

  # -- Lifecycle ---------------------------------------------------------------

  # Spawn the task thread and start running the block. The task reference is
  # published on Thread.current so nested code in the task can find it via
  # `Task.current` and push events onto its outbox. No buffer reference is
  # exposed to task code - the buffer is runner-side only.
  def start
    @thread = Thread.new do
      Thread.current[:harness_task] = self

      begin
        @block.call(self)
      rescue => e
        push_event(type: :error_ctrl, content: "#{e.class.name}: #{e.message}")
      ensure
        push_event(type: :done)
        # Unblock any pending request so the thread can exit cleanly.
        @inbox << STOP
      end
    end
  end

  # Non-blocking poll: returns one message from the outbox, or nil after
  # the timeout elapses with no message available.
  def poll(timeout = DEFAULT_POLL_TIMEOUT)
    @outbox.pop(false, timeout: timeout)
  rescue ThreadError
    nil
  end

  # True when no events are waiting in the outbox (used by the drain loop
  # to decide whether to show the spinner).
  def outbox_empty?
    @outbox.empty?
  end

  # Reply to a pending request (called from the main thread). Unblocks the
  # task thread's #request call with the given value.
  def respond(value)
    @inbox << value
  end

  # True when the task thread has been started and has not yet exited.
  def alive?
    @thread && @thread.alive?
  end

  # Force-stop: signal the inbox (unblocking any pending request) and join
  # with a timeout. Kills the thread if it is still alive after the timeout.
  def stop(timeout = 5)
    @inbox << STOP
    @thread&.join(timeout)
    @thread&.kill if @thread&.alive?
    @thread = nil
  end

  # -- Task-thread side (called from inside the block) -----------------------

  # Push a typed event onto the single event queue (the outbox). This is
  # the ONLY way task-thread code communicates output to the main thread.
  def push_event(type:, origin: nil, content: nil, **extra)
    event = { type: type.to_sym, origin: origin, content: content }
    event.merge!(extra) unless extra.empty?
    @outbox << event
  end

  # Blocking request: posts a dialog/event message to the outbox for the
  # main thread to process, then blocks until the main thread calls
  # #respond with a value. Returns that value. Raises if the task is
  # stopped while waiting.
  def request(type, **payload)
    @outbox << { type: :__request__, kind: type, **payload }
    reply = @inbox.pop
    if reply.equal?(STOP)
      raise "task was stopped while waiting for response to '#{type}'"
    end
    reply
  end

  # -- Task-thread output helpers --------------------------------------------
  # These find the current task via Thread.current and push events onto
  # ITS outbox (the single event queue). They NEVER write to a stream and
  # NEVER touch the buffer. Main-thread startup/shutdown output goes through
  # the CLI's UI::Console instead - there is no Kernel fallback, and none
  # should ever be needed (production callers run on a task thread).

  # The Task running on the current thread (set by #start), or nil.
  def self.current
    Thread.current[:harness_task]
  end

  # Emit ONE typed event onto the active task's outbox (the single event
  # queue). No-op when no task is active (nothing to drain for).
  def self.emit(type, origin:, content: nil)
    task = current
    return nil unless task

    task.push_event(type: type, origin: origin, content: content)
  end

  # Write lines as :text events on the active task's outbox. One event per
  # argument (like Kernel.puts). No-op when no task is active (the CLI owns
  # main-thread output through its UI::Console).
  def self.puts(*args)
    task = current
    return unless task

    args = [''] if args.empty?
    args.each { |part| task.push_event(type: :text, origin: :task, content: part.to_s) }
    nil
  end

  # -- The ONE spinner (main-thread-only access via the drain loop) ----------

  # The task's single spinner (set by the drain loop; nil before first tick).
  attr_reader :spinner
  def spinner=(sp); @spinner = sp; end

  # The spinner while it is animating (nil when stopped).
  def visible_spinner
    @spinner if @spinner&.running?
  end

  # Stop the spinner and clear its line on the task's stdout stream.
  # Called by the drain loop when data arrives, when the wait ends
  # (:done/:error), or on Ctrl+C (ensure).
  def clear_all_spinners
    return unless @spinner
    # In production the console is always set by Task.run; in unit tests it
    # may be nil - just stop without clearing.
    if @ui && @spinner.running?
      @spinner.clear_line
    end
    @spinner.stop
    @spinner = nil
  end

  # -- Drain loop (called from the MAIN thread) ------------------------------
  #
  # Spawns the task, then blocks in a poll loop that:
  #   1. Shows the spinner ONLY while the outbox is empty (the task is
  #      silently working - i.e. waiting on something slow such as an LLM).
  #   2. Polls the SINGLE event queue (the outbox) one message at a time.
  #      - Output events: the stale spinner line is cleared FIRST (a spin
  #        frame must never survive above real output), then the event is
  #        stored into the OutputBuffer and rendered to stdout in order.
  #      - Control events (:done, :error_ctrl, :__request__): handled directly.
  #   3. A :spinner_detail batch keeps the spinner alive with its new
  #      message (the wait continues); every other batch has already
  #      cleared the spinner line inside store_and_render before printing.
  #
  # The required `ui:` console is the single sink used for
  # ALL output - spinner frames, text lines, dialog prompts. Tests can pass
  # a StringIO-backed UI::Console to capture everything deterministically.
  #
  # Ctrl+C: SIGINT is trapped for the duration of this call, so an interrupt
  # always hits the drain loop (which then force-stops the task thread - a
  # task must NEVER keep working in the background) and re-raises Interrupt
  # for the caller's cleanup path.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(
    harness:,
    ui:,
    &block
  )
    task = Task.new(&block)
    task.ui = ui
    # Mid-turn user notes (issue #36): start the stdin reader when a stdin
    # stream is available; the drain loop flushes its buffer every tick.
    task.harness = harness
    # Notes need a harness to land on; Task.run is called with harness: nil
    # only from unit tests, so gate both the reader and the EOF shortcut.
    start_note_channel(task) if ui.stdin && harness
    error_msg   = nil
    old_trap    = trap('INT') { raise Interrupt }

    begin
      task.start

      # issue #36: a note may have been typed before the first outbox event;
      # flush once so it is not lost on an immediate :done.
      flush_user_notes(task)

      loop do
        # Spinner visible only while waiting on an EMPTY outbox. No data
        # means the task is silently working => animate.
        show_spinner_if_waiting(task)

        # issue #36: lines typed mid-turn are flushed into the harness here,
        # where Harness#call_llm injects them before the next LLM call.
        flush_user_notes(task)

        # Wait for the next event on the SINGLE queue (blocks up to timeout).
        msg = task.poll
        next unless msg  # timeout expired, loop again (spinner re-renders)

        # Clear the spinner line BEFORE rendering any output so a stale
        # spin frame never survives above real text.
        task.clear_all_spinners if task.visible_spinner

        # Process this event and any that arrived in the same window
        # (batch-drain so we render one spinner frame per batch, not
        # one per event).
        finished = false
        loop do
          case msg[:type]
          when :done
            finished = true
            break
          when :note_eof
            # issue #36: stdin reached EOF (Ctrl-D) - abandon the turn.
            # Flush first: a note typed just before Ctrl-D sits in the channel
            # buffer and would be dropped by the stop below. The task thread
            # must NOT keep working in the background (same rule as Ctrl+C).
            flush_user_notes(task)
            task.stop
            finished = true
            break
          when :error_ctrl
            error_msg = msg[:content]
          when :__request__
            handle_request(task, msg)
          when :spinner_detail
            # Re-points the spinner (keeps it alive for the next tick).
          end

          # Control events are handled above and must not be rendered; only
          # output events (text, spinner_detail, ...) go to buffer + stdout.
          unless CONTROL_EVENTS.include?(msg[:type])
            store_and_render(task, msg)
          end

          msg = task.poll(0)  # non-blocking: grab next if available
          break unless msg
        end

        break if finished
      end

      # Final drain: one last pass so an event pushed in the same window
      # as :done is not lost. After :done the task block has finished, so
      # no more pushes occur - this is complete and idempotent.
      drain_remaining(task)
      [error_msg, task]
    rescue Interrupt
      # Ctrl+C: kill the task thread (it must NOT keep working in the
      # background) and hand the interrupt back to the caller (CLI cleanup).
      task.stop
      raise
    ensure
      # Clean up the spinner and restore the pre-existing SIGINT handler.
      task.clear_all_spinners
      task.note_channel&.stop  # issue #36: no reader survives the turn
      trap('INT', old_trap)
    end
  end

  # Create the runner's single spinner when none is running.
  def self.ensure_spinner_running(task)
    return if task.visible_spinner

    spinner = UI::Spinner.new(DEFAULT_SPINNER_MESSAGE, ui: task.ui)
    spinner.start
    task.spinner = spinner
  end

  # Spinner frame for this tick: visible only while waiting on an EMPTY
  # outbox. No data => the task is silently working => animate.
  def self.show_spinner_if_waiting(task)
    return unless task.outbox_empty?

    ensure_spinner_running(task)
    task.visible_spinner&.render!
  end

  #
  # issue #36: start the mid-turn note channel (stdin reader) for this turn
  # when a stdin stream is available. The reader enqueues lines in the
  # background; the drain loop flushes them via #flush_user_notes.
  def self.start_note_channel(task)
    task.note_channel = UserNoteChannel.new(task.ui.stdin, task).tap(&:start)
  end

  # issue #36: flush buffered mid-turn notes onto the harness (one per
  # tick). Harness#call_llm injects the stored note into the chain before
  # the next LLM call; an ack line confirms receipt to the user. Rendered
  # here on the main thread - the single-thread I/O rule (issue #40).
  def self.flush_user_notes(task)
    channel = task.note_channel
    return unless channel && !channel.closed?
    return unless task.harness

    note = channel.pending_notes
    return if note.nil?

    task.harness.user_note_text = note
    ui = task.ui
    ui.puts("  [note] got it - #{note}")
    task.buffer.put(type: :text, origin: :user_note, content: "note received: #{note}")
  end

  def self.handle_request(task, msg)
    if msg[:kind] == :dialog
      dialog = msg[:dialog]
      task.instance_variable_set(:@dialog_open, true)
      begin
        task.note_channel&.pause  # issue #36: dialog owns stdin on this thread
        answer = dialog.perform_direct(ui: task.ui)
        task.respond(answer)
      ensure
        task.instance_variable_set(:@dialog_open, false)
        task.note_channel&.resume unless task.note_channel&.closed?
      end
    else
      task.respond(nil)
    end
  end

  # Store one output event into the OutputBuffer (structured log) and render
  # it to the task's console. The buffer is the durable record; the console
  # is what the user sees right now. Both happen on the main thread, in
  # outbox order.
  def self.store_and_render(task, msg)
    ui = task.ui

    case msg[:type]
    when :spinner_detail
      payload = msg[:content].is_a?(Hash) ? msg[:content] : { message: msg[:content].to_s }
      # Ensure the spinner is alive for this re-point (it may have been
      # cleared if the previous batch was non-spinner output).
      ensure_spinner_running(task) unless task.visible_spinner
      task.visible_spinner&.update_detail(**payload)
      task.buffer.put(type: :spinner_detail, origin: msg[:origin] || :task, content: msg[:content])
    when :text
      ui.puts(msg[:content].to_s)
      task.buffer.put(type: :text, origin: msg[:origin] || :task, content: msg[:content])
    else
      ui.puts(msg[:content].to_s) if msg[:content]
      task.buffer.put(type: msg[:type], origin: msg[:origin] || :task, content: msg[:content])
    end
  end

  # After :done, drain any remaining events from the outbox and render them.
  def self.drain_remaining(task)
    loop do
      msg = task.poll(0)
      break unless msg
      next if msg[:type] == :done || msg[:type] == :error_ctrl

      store_and_render(task, msg)
    end
  end
end
