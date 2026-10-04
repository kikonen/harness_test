# frozen_string_literal: true

# -- Task --------------------------------------------------------------------
#
# Runs a block on a background thread and exposes a message-passing protocol
# (two Thread::Queues, no mutexes) so that ALL console I/O stays on the main
# thread (issue #40 - single-thread I/O rule).
#
# Protocol:
#   Task thread  -> Main thread: emit(type, **payload)      [fire-and-forget]
#   Task thread  -> Main thread: request(type, **payload)   [blocking]
#   Main thread  -> Task thread: respond(value)             [unblocks request]
#   Main thread  -> Main thread: poll(timeout:)             [reads outbox]
#
# Single-thread I/O enforcement (issue #40):
#   Ruby's `$stdout` is a SHARED GLOBAL - reassigning it in the task thread
#   would corrupt the main thread's stream, so we do NOT use it for capture.
#   Instead the task publishes a restricted Capture object on
#   `Thread.current[:harness_task_capture]`; any code executing in the task
#   thread (session flow, tools) writes via `Task.puts` / `Task.print` /
#   `Task.capture.puts`, which route through the Capture's outbox queue. The
#   main thread's drain loop reads the queue and writes to the REAL stdout
#   in order. When no Task is active (tests, direct CLI commands), the same
#   helpers fall back to the real `$stdout` so existing bare `puts` call-
#   sites in main-thread-only code keep working.
#
#   Structured sink (issue #40 follow-up): harness-owned code (Harness itself,
#   SessionManager, and soon the tools) no longer writes to the Capture at
#   all - it appends typed {type, origin, content} entries to the harness's
#   OutputBuffer instead. The drain loop (#drain_output_buffer below) is the
#   single place that turns those entries into screen output: each tick it
#   advances the buffer's read waterline and renders whatever is new. This is
#   the "waterline" the CLI/renderer polls to know there is more output, and
#   the same loop will hand entries to a TUI later - no puts anywhere.
#
#   Dialogs use a different mechanism: UI::Dialog#show checks
#   `Thread.current[:harness_task]` and routes via request/response, so
#   $stdin reads happen on the main thread as well.

class Task
  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  STOP = Object.new.freeze

  # Timeout (seconds) for polling the outbox in the drain loop.
  DEFAULT_POLL_TIMEOUT = 0.1

  attr_reader :thread

  def initialize(&block)
    @block    = block
    @inbox    = Thread::Queue.new   # main -> task (responses to requests, stop)
    @outbox   = Thread::Queue.new   # task -> main (events: output, dialog, done, error)
    @capture  = Capture.new(self)
    @thread   = nil
  end

  # Spawn the task thread and start running the block. The capture object
  # is published on Thread.current so nested code in the task can find it
  # without re-binding $stdout (which is a shared global - see module docs).
  def start
    @thread = Thread.new do
      Thread.current[:harness_task]         = self
      Thread.current[:harness_task_capture] = @capture

      begin
        @block.call(self)
      rescue => e
        @outbox << { type: :error, error: "#{e.class.name}: #{e.message}" }
      ensure
        @outbox << { type: :done }
        # Unblock any pending request so the thread can exit cleanly.
        @inbox << STOP
      end
    end
  end

  # Non-blocking poll: returns one message hash from the outbox, or nil
  # after the timeout elapses with no message available.
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

  # Fire-and-forget event to the main thread. Never blocks.
  def emit(type, **payload)
    @outbox << { type: type, **payload }
  end

  # Blocking request: posts a message to the outbox for the main thread to
  # process, then blocks until the main thread calls #respond with a value.
  # Returns that value. Raises if the task is stopped while waiting.
  def request(type, **payload)
    @outbox << { type: :__request__, kind: type, **payload }
    reply = @inbox.pop
    if reply.equal?(STOP)
      raise "task was stopped while waiting for response to '#{type}'"
    end
    reply
  end

  # -- Restricted capture (issue #40 single-thread I/O rule) -----------------
  #
  # A minimal IO-like surface that carries ONLY the methods task code is
  # expected to call for console output: puts / print / write / flush. It
  # does NOT model a full stream (no fileno, no seek, no binary mode); it
  # just funnels text into the task's outbox queue so the drain loop can
  # order and serialize writes on the main thread. This is the LEGACY path
  # still used by tools that have not been migrated to the OutputBuffer yet.
  class Capture
    def initialize(task)
      @task = task
    end

    def write(str)
      text = str.to_s
      @task.emit(:output, text: text)
      text.bytesize
    end

    def puts(*args)
      if args.empty?
        write("\n")
      else
        args.each { |a| write(a.to_s + "\n") }
      end
      nil
    end

    def print(*args)
      args.each { |a| write(a.to_s) }
      nil
    end

    def flush
      # Real flush happens on the main thread after it drains :output.
      nil
    end

    def sync
      true
    end

    def sync=(val) # rubocop:disable Lint/UnusedMethodArgument
      nil
    end

    def closed?
      false
    end
  end

  # -- Output helpers (used from task-thread code and tools) -----------------

  # The capture object for the current thread's Task, or nil when no task
  # is active (main thread / tests / direct CLI commands). Callers are
  # encouraged to use `Task.puts` / `Task.print`, which pick the right path.
  def self.capture
    Thread.current[:harness_task_capture]
  end

  # Write a line, respecting the task's capture when active (routes via the
  # outbox so the drain loop can order it with spinner frames and dialog
  # I/O on the main thread). Falls back to the real $stdout when no task
  # is running - this keeps bare main-thread call-sites (CLI banner, /help)
  # working without them knowing about the Task.
  def self.puts(*args)
    cap = capture
    if cap
      cap.puts(*args)
      nil
    else
      Kernel.puts(*args)
    end
  end

  # Non-terminated variant of `Task.puts`.
  def self.print(*args)
    cap = capture
    if cap
      cap.print(*args)
      nil
    else
      Kernel.print(*args)
    end
  end

  # -- Structured sink rendering (issue #40 follow-up) ----------------------

  # Render ONE structured OutputBuffer::Entry to the given stream. For now
  # every type is printed as a plain line; this is the extension point where
  # a future TUI will style entries by `type`/`origin` instead of dumping raw
  # text. Kept dumb and main-thread-only so it can never race task writes.
  def self.render_entry(entry, stdout)
    stdout.puts(entry.content)
  end

  # Drain the harness's OutputBuffer (the structured output sink owned by
  # the harness) and render whatever is new onto `stdout`. This is the
  # "waterline" read: each tick the main thread advances the buffer's read
  # index and dumps the new entries to the screen, in order. No-op when the
  # harness exposes no buffer (e.g. a bare double in tests). Runs on the
  # MAIN thread only - the single-thread I/O rule (issue #40).
  def self.drain_output_buffer(harness, stdout)
    buffer = harness.respond_to?(:output_buffer) ? harness.output_buffer : nil
    return unless buffer

    entries = buffer.drain
    return if entries.empty?

    entries.each { |entry| render_entry(entry, stdout) }
    stdout.flush
  end

  # -- Drain loop (called from the MAIN thread) ------------------------------
  #
  # Spawns the task, then blocks in a poll loop that:
  #   1. Renders the spinner frame (if active) - main thread I/O.
  #   2. Drains the harness OutputBuffer and renders new entries (waterline).
  #   3. Reads the next message from the outbox (or times out) - the legacy
  #      :output channel and :dialog requests still work as before.
  #   4. Exits on :done or :error.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(harness:, &block)
    task = Task.new(&block)
    real_stdout = $stdout  # main thread's real stdout (never re-bound)
    spinner_was_rendering = false
    error_msg = nil

    begin
      task.start

      loop do
        # 1. Render spinner frame (main thread only - single-thread I/O rule).
        spinner = harness.spinner
        if spinner&.running?
          spinner.render!
          spinner_was_rendering = true
        elsif spinner_was_rendering
          spinner&.clear_line
          spinner_was_rendering = false
        end

        # 2. Drain + render the harness OutputBuffer (structured sink).
        drain_output_buffer(harness, real_stdout)

        # 3. Poll the outbox (non-blocking, DEFAULT_POLL_TIMEOUT).
        msg = task.poll

        if msg
          case msg[:type]
          when :output
            real_stdout.write(msg[:text])
            real_stdout.flush
          when :__request__
            if msg[:kind] == :dialog
              dialog = msg[:dialog]
              answer = dialog.perform_direct
              task.respond(answer)
            else
              task.respond(nil)
            end
          when :error
            error_msg = msg[:error]
          when :done
            break
          end
        end
      end

      # Final drain: the in-loop order is drain-then-poll, so one window
      # remains where an entry appended just before :done was enqueued could
      # slip past the last in-loop drain. After :done no more appends occur
      # (the task block has finished), so one more drain here is complete and
      # idempotent (returns [] when nothing is pending).
      drain_output_buffer(harness, real_stdout)
    ensure
      sp = harness.spinner
      sp.clear_line if spinner_was_rendering && sp
    end

    [error_msg, task]
  end
end
