# frozen_string_literal: true

# -- Task --------------------------------------------------------------------
#
# Runs a block on a background thread and owns ALL console I/O for that turn
# (issue #40 - single-thread I/O rule). The task thread NEVER writes to an
# IO stream. Instead it emits typed entries into the Task-owned OutputBuffer
# (or, for legacy unmigrated tools, into the Capture outbox); the main
# thread's drain loop advances the buffer's waterline and renders whatever
# is new - including spinner frames.
#
# Protocol:
#   Task thread -> Main thread: emit(type, origin:, content:)  [fire-and-forget]
#   Task thread -> Main thread: request(type, **payload)       [blocking]
#   Main thread -> Task thread: respond(value)                 [unblocks request]
#   Main thread -> Main thread: poll(timeout:)                 [reads outbox]
#
# Single-thread I/O enforcement (issue #40):
#   Ruby's `$stdout` is a SHARED GLOBAL - reassigning it in the task thread
#   would corrupt the main thread's stream, so we do NOT use it for capture.
#   Legacy code still runs in the task thread uses a restricted Capture object
#   published on `Thread.current[:harness_task_capture]`; writes route through
#   the outbox queue and are rendered by the drain loop on the main thread.
#   Newly migrated code calls `Task.emit(...)` which appends typed entries to
#   the Task's OutputBuffer; the same drain loop renders them. Both paths are
#   ordered by construction (single writer, single reader).
#
# Structured sink (issue #40 follow-up):
#   The OutputBuffer is owned by THIS task instance (not the harness), so the
#   code that renders it and the code that appends to it live in the same
#   object - no shared mutable state across components. Harness-side code
#   (Harness itself, SessionManager, tools) reaches the buffer through
#   `Task.output_buffer` (a thread-local accessor set inside #start). When
#   no task is active (main-thread-only code, tests), `Task.emit` falls back
#   to a bare Kernel.puts so call-sites stay safe everywhere.
#
# Spinner visibility is OWNED BY THE TASK: the drain loop suppresses the
# spinner whenever it prints text or handles a dialog (the user must see the
# line cleanly), and re-shows it on the next tick if the topmost spinner is
# still running. Harness-side code never touches the spinner - it just emits
# :progress_start / :progress_stop to start/stop one, and :spinner_detail to
# change the visible spinner's extra label (e.g. "file.read" while a tool is
# running). Nested progress is handled by a LIFO stack: a second
# :progress_start pushes on top of the first, and its :progress_stop pops it
# off, exposing the outer one again.
#
# Dialogs use a different mechanism: UI::Dialog#show checks
# `Thread.current[:harness_task]` and routes via request/response, so
# $stdin reads happen on the main thread as well.

require_relative 'output_buffer'
require_relative 'ui/spinner'

class Task
  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  STOP = Object.new.freeze

  # Timeout (seconds) for polling the outbox in the drain loop.
  DEFAULT_POLL_TIMEOUT = 0.1

  attr_reader :thread, :buffer

  def initialize(&block)
    @block           = block
    @inbox           = Thread::Queue.new   # main -> task (responses, stop)
    @outbox          = Thread::Queue.new   # task -> main (output, dialog, done, error)
    @capture         = Capture.new(self)
    @buffer          = OutputBuffer.new
    # LIFO spinner stack: the topmost entry is what gets rendered. Nested
    # progress (send_session -> in-loop compaction -> back to send) is
    # modeled as push/pop, so a :progress_stop of the inner one restores the
    # outer spinner's visibility without the caller knowing about it.
    @spinner_stack   = []
    # The drain loop sets this when it must hide the spinner to print text
    # or handle a dialog; cleared at the start of every tick. Harness code
    # does NOT touch this - the runner owns spinner visibility entirely.
    @spinner_hidden  = false
    @thread          = nil
  end

  # Spawn the task thread and start running the block. The capture object
  # and the output buffer are published on Thread.current so nested code in
  # the task can find them without re-binding $stdout (which is a shared
  # global - see module docs).
  def start
    @thread = Thread.new do
      Thread.current[:harness_task]          = self
      Thread.current[:harness_task_capture]  = @capture
      Thread.current[:harness_output_buffer] = @buffer

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
  # still used by tools that have not been migrated to Task.emit yet.
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

  # The Task running on the current thread (set by #start), or nil. Exposed
  # so task-thread code can introspect the runner's own state (e.g. the
  # spinner stack) without going through the harness - the runner owns
  # that state.
  def self.current
    Thread.current[:harness_task]
  end

  # The OutputBuffer for the current thread's Task, or nil when no task is
  # active. Main-thread code (e.g. specs) may set this directly to capture
  # entries without spinning up a real Task.
  def self.output_buffer
    Thread.current[:harness_output_buffer]
  end

  def self.output_buffer=(buf)
    Thread.current[:harness_output_buffer] = buf
  end

  # Emit ONE typed entry to the active task's buffer. Falls back to a bare
  # Kernel.puts for text content when no task is active, so call-sites in
  # main-thread-only code keep working (e.g. CLI banner, direct specs).
  # Progress events are ignored in fallback mode - a main thread has no
  # drain loop to drive animation for.
  def self.emit(type, origin:, content: nil)
    buf = output_buffer
    if buf
      buf.put(type: type, origin: origin, content: content)
    elsif %i[progress_start progress_stop spinner_detail].include?(type.to_sym)
      nil
    elsif content
      Kernel.puts(content.to_s)
    end
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

  # -- Spinner stack (main-thread-only mutation via drain loop) --------------
  #
  # The Task OWNS the spinner: harness/session_manager code never touches it
  # directly. Instead it emits :progress_start / :progress_stop /
  # :spinner_detail entries; the drain loop interprets them against this
  # LIFO stack. Topmost entry is what gets drawn (suppression handled by
  # @spinner_hidden).

  def push_spinner(spinner)
    @spinner_stack.push(spinner)
  end

  def pop_spinner
    @spinner_stack.pop
  end

  def top_spinner
    @spinner_stack.last
  end

  # Topmost running spinner (nil when the stack is empty or the top entry
  # is not running). Paused entries are not supported anymore: the drain
  # loop hides and re-shows the spinner itself via @spinner_hidden.
  def visible_spinner
    sp = @spinner_stack.last
    sp if sp && sp.running?
  end

  def clear_all_spinners
    @spinner_stack.each { |sp| sp.stop }
    @spinner_stack.clear
    @spinner_hidden = false
  end

  # -- Drain loop (called from the MAIN thread) ------------------------------
  #
  # Spawns the task, then blocks in a poll loop that:
  #   1. Renders the active spinner frame (topmost running in the stack),
  #      UNLESS it is suppressed (a text line or dialog was just printed).
  #   2. Drains the Task-owned OutputBuffer and renders new entries -
  #      :progress_start/:progress_stop mutate the spinner stack,
  #      :spinner_detail updates the topmost suffix, other types print.
  #   3. Reads the next message from the outbox (or times out) - the legacy
  #      :output channel and :dialog requests still work as before. Printing
  #      a text line or servicing a dialog suppresses the spinner for that
  #      tick so it does not interleave with the content; on the next tick
  #      (with no new suppression) the spinner re-appears automatically if
  #      the topmost entry is still running.
  #   4. Exits on :done or :error.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(harness:, &block) # rubocop:disable Lint/UnusedMethodArgument
    task = Task.new(&block)
    real_stdout = $stdout  # main thread's real stdout (never re-bound)
    last_rendered = nil
    error_msg     = nil

    begin
      task.start

      loop do
        task.clear_spinner_hidden

        # 1. Spinner frame: draw the topmost running one (main thread I/O).
        visible = task.visible_spinner
        if visible && !task.spinner_hidden?
          visible.render!
          last_rendered = visible
        elsif last_rendered
          last_rendered.clear_line
          last_rendered = nil
        end

        # 2. Drain + render the Task-owned OutputBuffer (structured sink).
        task.buffer.drain.each { |entry| render_entry(task, entry, real_stdout) }

        # 3. Poll the outbox (non-blocking, DEFAULT_POLL_TIMEOUT).
        msg = task.poll

        if msg
          case msg[:type]
          when :output
            # Text output: suppress the spinner for this tick so the line
            # prints cleanly on its own; the next tick re-shows it if the
            # topmost spinner is still running.
            task.suppress_spinner!
            real_stdout.write(msg[:text])
            real_stdout.flush
          when :__request__
            if msg[:kind] == :dialog
              dialog = msg[:dialog]
              # Same suppression rule: a dialog needs its own lines.
              task.suppress_spinner!
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

      # Final drain: one last pass so an entry appended in the same window
      # as the :done message is not lost. After :done the task block has
      # finished, so no more appends occur - this is complete and idempotent.
      task.buffer.drain.each { |entry| render_entry(task, entry, real_stdout) }
    ensure
      sp = last_rendered || task.visible_spinner
      sp&.clear_line if sp
      task.clear_all_spinners
    end

    [error_msg, task]
  end

  # Render ONE structured OutputBuffer::Entry on the MAIN thread. Progress
  # events mutate the task's spinner stack; :spinner_detail updates the
  # visible spinner's suffix; everything else is printed to the given stream
  # in order. Kept main-thread-only so it can never race the task thread's
  # appends.
  def self.render_entry(task, entry, stdout)
    case entry.type
    when :progress_start
      payload = entry.content.is_a?(Hash) ? entry.content : { message: entry.content.to_s }
      spinner = UI::Spinner.new(payload[:message].to_s, payload[:suffix])
      spinner.start
      task.push_spinner(spinner)
    when :progress_stop
      popped = task.pop_spinner
      popped&.stop
      # If the stack is now empty, the drain loop's next tick will clear the
      # line itself; nothing to do here (render! is a no-op on a stopped
      # spinner).
    when :spinner_detail
      # Update the extra label on the currently visible spinner. The value
      # may be a String (plain) or a callable (re-evaluated each frame,
      # matching UI::Spinner's suffix contract). No visible spinner: ignore.
      sp = task.visible_spinner
      sp&.update_suffix(entry.content)
    else
      stdout.puts(entry.content.to_s) if entry.content
    end
  end

  # -- Spinner visibility (drain loop only) ----------------------------------
  #
  # The runner hides the spinner whenever it prints text or services a
  # dialog, so that line is not broken by an animation frame; the next tick
  # re-shows the spinner if its topmost entry is still running. Harness
  # code does NOT use these - they are internal to the drain loop.

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
