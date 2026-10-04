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
#   events (:text, :step, :spinner_detail, etc.) AND control events (:done,
#   :error, :__request__) travel on it. The drain loop pops one message at a
#   time and dispatches by type. This guarantees total ordering of all
#   visible output because every event flows through exactly one FIFO.
#
# Protocol:
#   Task thread -> Main thread: push_event(type, origin:, content:)  [outbox]
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
# Spinner ownership - the RUNNER decides, not the harness code:
#   The drain loop knows automatically when to show a spinner: as long as
#   it is still waiting for the task thread to finish, one is visible. It
#   is suppressed for the tick that prints text or services a dialog (so
#   that line shows cleanly), and re-appears on the next tick. The only
#   protocol entry that affects the spinner is :spinner_detail - it
#   describes what the current wait looks like (message + optional suffix).
#   Harness code never starts or stops spinners - it just emits
#   :spinner_detail (or nothing at all) and is done.
#
# Dialogs use the outbox as well: task.request(:dialog, dialog:) pushes a
# __request__ event; the drain loop performs the dialog on the main thread
# and calls task.respond(answer).

require_relative 'output_buffer'
require_relative 'ui/spinner'

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

  attr_reader :thread, :buffer

  def initialize(&block)
    @block         = block
    @inbox         = Thread::Queue.new   # main -> task (responses, stop)
    @outbox        = Thread::Queue.new   # task -> main (SINGLE event queue)
    @buffer        = OutputBuffer.new    # structured log (runner fills it)
    # The ONE spinner owned by the runner (nil until the drain loop creates
    # it). :spinner_detail events only re-point its message/suffix.
    @spinner       = nil
    # The drain loop sets this when it must hide the spinner to print text
    # or handle a dialog; cleared at the start of every tick.
    @spinner_hidden = false
    @thread        = nil
  end

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
  #
  # All of these find the current task via Thread.current and push events
  # onto ITS outbox (the single event queue). They NEVER write to $stdout,
  # NEVER write to the buffer directly. When no task is active (main-thread
  # CLI startup/shutdown), they fall back to Kernel since there is no drain
  # loop to render events for.

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
  # argument (like Kernel.puts). Falls back to Kernel.puts when no task is
  # active (main-thread code outside a Task has no drain loop).
  def self.puts(*args)
    task = current
    if task
      args = [''] if args.empty?
      args.each { |part| task.push_event(type: :text, origin: :task, content: part.to_s) }
    else
      Kernel.puts(*args)
    end
    nil
  end

  # Non-terminated variant of Task.puts. Single event with all parts joined
  # (no trailing newline). Falls back to Kernel.print when no task is active.
  def self.print(*args)
    task = current
    if task
      task.push_event(type: :text, origin: :task, content: args.map(&:to_s).join, terminal: false)
    else
      Kernel.print(*args)
    end
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

  # Stop the spinner - called by the drain loop when the wait ends
  # (:done/:error).
  def clear_all_spinners
    @spinner&.stop
    @spinner_hidden = false
  end

  # -- Drain loop (called from the MAIN thread) ------------------------------
  #
  # Spawns the task, then blocks in a poll loop that:
  #   1. Ensures a spinner is visible (the runner knows it is waiting by
  #      construction). Suppressed when text or a dialog was just rendered.
  #      Renders one animation frame.
  #   2. Polls the SINGLE event queue (the outbox) one message at a time.
  #      - Output events: stores into the OutputBuffer (structured log) AND
  #        renders to stdout in order.
  #      - Control events (:done, :error, :__request__): handled directly.
  #   3. Exits on :done or :error; the spinner is cleared.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(harness:, &block) # rubocop:disable Lint/UnusedMethodArgument
    task = Task.new(&block)
    real_stdout = $stdout
    last_rendered = nil
    error_msg     = nil

    begin
      task.start

      loop do
        task.clear_spinner_hidden

        # While this loop is still waiting on the task thread, a spinner is
        # visible - that is all there is to it. The first tick creates the
        # default one; subsequent :spinner_detail events re-point it.
        ensure_spinner_running(task)

        # 1. Spinner frame: draw the current one (main thread I/O).
        visible = task.visible_spinner
        if visible && !task.spinner_hidden?
          visible.render!
          last_rendered = visible
        elsif last_rendered
          last_rendered.clear_line
          last_rendered = nil
        end

        # 2. Wait for the next event on the SINGLE queue (blocks up to timeout).
        msg = task.poll
        next unless msg  # timeout expired, loop again (spinner re-renders)

        # 3. Process this event and any that arrived in the same window
        #    (batch-drain so we render one spinner frame per batch, not
        #    one per event).
        finished = false
        loop do
          case msg[:type]
          when :done
            finished = true
            break
          when :error_ctrl
            error_msg = msg[:content]
          when :__request__
            handle_request(task, msg)
          else
            store_and_render(task, msg, real_stdout)
          end

          msg = task.poll(0)  # non-blocking: grab next if available
          break unless msg
        end
        break if finished
      end

      # Final drain: one last pass so an event pushed in the same window
      # as :done is not lost. After :done the task block has finished, so
      # no more pushes occur - this is complete and idempotent.
      drain_remaining(task, real_stdout)
    ensure
      sp = last_rendered || task.visible_spinner
      sp&.clear_line if sp
      task.clear_all_spinners
    end

    [error_msg, task]
  end

  # While the drain loop is still waiting on the task thread, a spinner must
  # be visible - create the default one when none is running.
  def self.ensure_spinner_running(task)
    return if task.visible_spinner

    spinner = UI::Spinner.new(DEFAULT_SPINNER_MESSAGE)
    spinner.start
    task.spinner = spinner
  end

  # Handle a :__request__ control event on the main thread.
  def self.handle_request(task, msg)
    if msg[:kind] == :dialog
      dialog = msg[:dialog]
      task.suppress_spinner!
      answer = dialog.perform_direct
      task.respond(answer)
    else
      task.respond(nil)
    end
  end

  # Store one output event into the OutputBuffer (structured log) and render
  # it to stdout. The buffer is the durable record; stdout is what the user
  # sees right now. Both happen on the main thread, in outbox order.
  def self.store_and_render(task, msg, stdout)
    task.buffer.put(type: msg[:type], origin: msg[:origin] || :task, content: msg[:content])

    case msg[:type]
    when :spinner_detail
      payload = msg[:content].is_a?(Hash) ? msg[:content] : { message: msg[:content].to_s }
      # The drain loop always ensures the single spinner is running before
      # dispatching events - just re-point it.
      task.visible_spinner&.update_detail(**payload)
    when :text
      content = msg[:content].to_s
      if msg[:terminal] == false
        stdout.print(content)
      else
        stdout.puts(content)
      end
    else
      stdout.puts(msg[:content].to_s) if msg[:content]
    end
  end

  # After :done, drain any remaining events from the outbox and render them.
  def self.drain_remaining(task, stdout)
    loop do
      msg = task.poll(0)
      break unless msg
      next if msg[:type] == :done || msg[:type] == :error_ctrl

      store_and_render(task, msg, stdout)
    end
  end

  # -- Spinner visibility (drain loop only) ----------------------------------

  def suppress_spinner!
    @spinner_hidden = true
  end

  def clear_spinner_hidden
    @spinner_hidden = false
  end

  def spinner_hidden?
    @spinner_hidden
  end
end
