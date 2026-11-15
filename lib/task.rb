# frozen_string_literal: true

# Task: runs the turn block on a background thread and owns ALL console I/O
# for it (single-thread I/O rule); design and protocol: doc/task_design.md

require "io/console"
require_relative "job"
require_relative "input_path"
require_relative "output_buffer"
require_relative "ui/renderer"
require_relative "ui/editor"
require_relative "poller"
require_relative "ui/spinner"
require_relative "error_text"

class Task
  # Default spinner message while the runner waits for the task thread.
  # Any :spinner_detail event may override it (and its suffix) for the
  # rest of the wait.
  DEFAULT_SPINNER_MESSAGE = "Working"

  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  STOP = Object.new.freeze

  # Timeout (seconds) for polling the outbox in the drain loop.
  DEFAULT_POLL_TIMEOUT = 0.1

  # Grace the force-stop gives the task thread before killing it.
  DEFAULT_STOP_JOIN_TIMEOUT = 0.5

  # Raised by the drain loop when the note editor saw EOF (Ctrl-D pressed
  # inside it while editing a mid-turn note): aborts the running turn like
  # Ctrl+C (the drain loop stops the task and returns normally).
  class NoteAbort < StandardError; end

  # Event types handled by the drain loop as control flow (never stored or
  # rendered): the task finished ([:done]) and a pending user request
  # ([:__request__], answered on the main thread).
  CONTROL_EVENTS = %i[error_ctrl __request__].freeze

  attr_reader :thread, :buffer, :ui, :renderer, :job, :registry, :input_path

  # Set by #run from the harness's configured palette; the constructor's own
  # renderer colors nothing, which is what a Task without a harness needs.
  attr_writer :renderer

  attr_accessor :note_editor
  attr_accessor :harness

  # A task built for a job reads the registry's ONE queue instead of its own
  # outbox, and its inbox IS the job's inbox (the registry routes answers to it).
  def initialize(buffer:, registry: nil, job: nil, input_path: nil, &block)
    @block   = block
    # main -> task (the job's inbox). For a job this IS the job's inbox, where
    # the registry routes steering notes (and STOP for a task servicing no live
    # request). #request answers come back on the SEPARATE @pending_reply, so a
    # note can never be mistaken for a dialog answer (issue #424).
    @inbox         = job ? job.inbox : Thread::Queue.new
    @pending_reply = nil            # live request's reply channel (one at a time)
    # task -> main (SINGLE event queue). Under the registry (issue #286) this is
    # the registry's ONE fan-in queue: events carry the job id, so ordering holds.
    @outbox  = Thread::Queue.new
    @registry = registry
    @job      = job
    # The task USES the buffer it is given (issue #286): the registry's job
    # supplies its own buffer, otherwise the caller hands the run buffer. The
    # task never builds one - the buffer's own limits belong to the buffer. The
    # drain loop is the single writer; the task thread never touches it.
    @buffer       = job ? job.buffer : buffer
    # Patterns and colors are the renderer's decision, so the drain loop asks
    # it instead of printing content as the emitter wrote it. #run replaces it
    # with the harness's configured palette; this one colors nothing.
    @renderer  = UI::Renderer.new
    @spinner = nil
    @thread  = nil
    @ui = nil # set by Task.run before start
    @dialog_open = false           # true while perform_direct is on stdin
    @note_editor  = nil
    @input_path   = input_path
    @started_at   = nil            # turn clock (issue #277), set by #start
    @harness      = nil
  end

  attr_writer :ui

  # While true, store_and_render must not clear output lines: a Choice
  # prompt on stdin would vanish with them.
  def dialog_open?
    @dialog_open
  end

  # True while the poll loop is in the edit state (the user is typing); the
  # loop enters it when the shared input path's peek sees a keypress.
  def edit_state?
    input_path&.edit_state?
  end

  attr_accessor :note_draft

  # -- Lifecycle ---------------------------------------------------------------

  # Spawn the task thread and start running the block. The task reference is
  # published on Thread.current so nested code in the task can find it via
  # `Task.current` and push events onto its outbox. No buffer reference is
  # exposed to task code - the buffer is runner-side only.
  def start
    @started_at = Time.now
    @thread = Thread.new do
      Thread.current[:harness_task] = self

      begin
        value = @block.call(self)
      rescue => e
        # The event goes FIRST: a logger that cannot write must not swallow the
        # error the user is owed.
        push_event(type: :error_ctrl, content: ErrorText.label(e))
        record_task_error(e)
      ensure
        # The block's value IS the job's result, so the caller awaiting the job
        # gets it back on the :done event.
        push_event(type: :done, result: value)
        # Unblock any pending request so the thread can exit cleanly.
        @inbox << STOP
      end
    end
  end

  # The turn clock for the spinner's elapsed segment (issue #277): whole
  # seconds under a minute ("12s"), minutes beyond it ("2m 03s"). nil before
  # #start (a spinner built by a unit test that never started the task).
  def elapsed_label
    return nil if @started_at.nil?

    secs = (Time.now - @started_at).to_i
    return "#{secs}s" if secs < 60

    "#{(secs / 60)}m #{format('%02d', secs % 60)}s"
  end

  # Non-blocking poll: returns one message from the queue, or nil after the
  # timeout elapses with nothing available. Over the registry an event naming
  # ANOTHER job is recorded into that job's own buffer and skipped - the
  # foreground task never renders another job's lines.
  def poll(timeout = DEFAULT_POLL_TIMEOUT)
    return @outbox.pop(false, timeout:) unless @registry && @job

    event = @registry.poll(timeout)
    return nil if event.nil?
    return event if event[:job] == @job.id

    @registry.record(event)
    poll(0)
  rescue ThreadError
    nil
  end

  # True when no events are waiting (used by the drain loop to decide whether
  # to show the spinner).
  def outbox_empty?
    return @registry.queue_empty? if @registry && @job

    @outbox.empty?
  end

  # Reply to a pending request (called from the main thread). Unblocks the
  # task thread's #request call with the given value.
  def respond(value)
    @job&.mark_awaiting(false)
    if @pending_reply
      @pending_reply << value
    else
      @inbox << value
    end
  end

  # True when the task thread has been started and has not yet exited.
  def alive?
    !@thread.nil? && @thread.alive?
  end

  # Force-stop: answer what the turn owes, signal the inbox, and join with a
  # short grace. Kills the thread if it is still alive after the timeout.
  def stop(timeout = DEFAULT_STOP_JOIN_TIMEOUT)
    # An interrupted turn answers every request it still owes (STOP is not an
    # answer, so a blocked requester would raise on it). STOP then only breaks
    # this thread's own pending pop when no answer already hit that inbox.
    owed = (@registry&.jobs || []).select(&:awaiting?)
    had_live = !@pending_reply.nil?
    if had_live
      # A live request on THIS task blocks on the reply channel, not the inbox.
      # Answer it (not STOP) so #request returns normally and the thread runs
      # its ensure/exit. The owning job was already counted in `owed`; drop it
      # so it is not ALSO answered into its inbox.
      @pending_reply << Job::INTERRUPTED_ANSWER
      @pending_reply = nil
      @job&.mark_awaiting(false)
      owed = owed.reject { |job| job.equal?(@job) }
    end
    owed.each { |job| job.respond(Job::INTERRUPTED_ANSWER) }
    # No live request on this task: STOP the inbox only when the owed answers
    # did not already land in it (@inbox IS the foreground job's inbox).
    unless had_live || owed.any? { |job| job.inbox.equal?(@inbox) }
      @inbox << STOP
    end
    @thread&.join(timeout)
    @thread&.kill if @thread&.alive?
    @thread = nil
  end

  # -- Task-thread side (called from inside the block) -----------------------

  # The frames go to the session's harness.log: a task thread owns no console
  # (single-thread I/O rule) and the outbox carries ONE line, so without this
  # the trace dies with the thread.
  def record_task_error(error)
    logger = @harness.respond_to?(:logger) ? @harness.logger : nil
    return unless logger

    logger.error ErrorText.detailed(error, "task thread raised")
  end

  # Push a typed event onto the single event queue (the outbox). This is the
  # ONLY way task-thread code communicates output to the main thread.
  def push_event(type:, origin: nil, content: nil, **extra)
    event = { type: type.to_sym, origin:, content: }
    event.merge!(extra) unless extra.empty?
    event[:job] = @job.id if @job
    (@registry || @outbox) << event
    event
  end

  # Blocks until the main thread answers with #respond.
  def request(type, **payload)
    # While a request is unanswered, an input event must queue BEHIND the answer
    # it gets, so the job is marked awaiting (issue #198 FIFO rule). The answer
    # comes back on a channel SEPARATE from @inbox (issue #424): a steering note
    # already resident in the job inbox can no longer be mistaken for the answer.
    @pending_reply = Thread::Queue.new
    @job&.mark_awaiting(true)
    push_event(type: :__request__, kind: type, **payload)
    reply = @pending_reply.pop
    @pending_reply = nil
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

    task.push_event(type:, origin:, content:)
  end

  # Write lines as :text events on the active task's outbox. One event per
  # argument (like Kernel.puts). No-op when no task is active (the CLI owns
  # main-thread output through its UI::Console).
  def self.puts(*args)
    task = current
    return unless task

    args = [""] if args.empty?
    args.each { |part| task.push_event(type: :text, origin: :task, content: part.to_s) }
    nil
  end

  # -- The ONE spinner (held on the task, driven by the Poller) --------------
  # The spinner's storage lives here because the task is the single sink it
  # draws into; the Poller owns its creation, animation and clearing.

  # The task's single spinner (set by the drain loop; nil before first tick).
  attr_reader :spinner
  def spinner=(sp); @spinner = sp; end

  # The spinner while it is animating (nil when stopped).
  def visible_spinner
    @spinner if @spinner&.running?
  end

  def clear_all_spinners
    return unless @spinner
    if @ui && @spinner.running?
      @spinner.clear_line
    end
    @spinner.stop
    @spinner = nil
  end

  # -- Drain loop entry (main thread) ----------------------------------------
  #
  # Builds the task and hands it to a Poller, which runs the poll loop over the
  # single event queue, drives the spinner, serves dialogs and reads mid-turn
  # notes, and returns when the task finishes (issue #286: the loop is the
  # poller's, not the task's). The required `ui:` console is the single sink for
  # ALL output; tests can pass a StringIO-backed UI::Console to capture it.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(
    harness:,
    ui:,
    registry: nil,
    job: nil,
    input_path: nil,
    &block
  )
    # A task built for a job uses that job's buffer and inbox through the
    # registry; otherwise the harness' run buffer is the single record. The
    # drain loop is the single main-thread writer, so every put lands in the
    # same record a save reads.
    task = Task.new(buffer: harness.output_log, registry:, job:, input_path:, &block)
    task.ui = ui
    # The input path is the ONE reader the main thread's poll loop shares with
    # the idle prompt. It only PEEKS stdin until typing starts, so nothing races
    # for the keyboard. Input needs a harness to land on (nil = unit test).
    task.harness = harness
    # The palette is the harness's (issue #303). A harness double in a spec
    # may not answer #output_palette, and a Task without a harness colors
    # nothing, so the constructor's plain renderer stays unless one is given.
    palette = harness.respond_to?(:output_palette) ? harness.output_palette : nil
    # Markdown rendering of the assistant answer is opt-in (issue #106): the
    # posture is read here (a Task builds its renderer once per turn), so a
    # mid-run /markdown toggle lands on the next turn (the same as /palette).
    # A harness double in a spec may not answer #markdown?, so default off.
    markdown = harness.respond_to?(:markdown?) ? harness.markdown? : false
    # The table-width basis (issue #106): config-derived, read once per turn
    # like the palette. nil = the renderer's default (80% of the terminal).
    max_width = harness.respond_to?(:markdown_max_width) ? harness.markdown_max_width : nil
    task.renderer = UI::Renderer.new(palette:, markdown:, markdown_max_width: max_width)
    task.note_editor = UI::Editor.new(ui.stdin) if ui.stdin && harness
    # The Poller owns the main-thread loop, the spinner, stdin and dialog
    # serving - none of that is the Task's concern (issue #286).
    Poller.new(task).run
  end
end
