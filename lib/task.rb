# frozen_string_literal: true

# Task: runs the turn block on a background thread and owns ALL console I/O
# for it (single-thread I/O rule); design and protocol: doc/task_design.md

require "io/console"
require_relative "job"
require_relative "input_path"
require_relative "output_buffer"
require_relative "ui/renderer"
require_relative "ui/editor"
require_relative "main_loop"
require_relative "ui/spinner"
require_relative "error_text"

class Task
  # Default spinner message; a :spinner_detail event may override it (and its
  # suffix) for the rest of the wait.
  DEFAULT_SPINNER_MESSAGE = "Working"

  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  STOP = Object.new.freeze

  DEFAULT_POLL_TIMEOUT = 0.1

  # Grace #stop gives the task thread before killing it.
  DEFAULT_STOP_JOIN_TIMEOUT = 0.5

  # Raised by the drain loop when the note editor saw EOF (Ctrl-D inside it
  # while editing a mid-turn note): aborts the turn like Ctrl+C.
  class NoteAbort < StandardError; end

  # Event types the drain loop treats as control flow (never stored or rendered).
  CONTROL_EVENTS = %i[error_ctrl __request__].freeze

  attr_reader :thread, :buffer, :ui, :renderer, :job, :registry, :input_path

  # Set by #run from the harness's configured palette; the constructor's own
  # renderer colors nothing, which is what a Task without a harness needs.
  attr_writer :renderer

  attr_accessor :note_editor
  attr_accessor :harness

  # A task built for a job reads the registry's ONE queue, and its inbox IS the
  # job's inbox (the registry routes answers to it).
  def initialize(registry:, job:, input_path: nil, &block)
    @block   = block
    # main -> task (the job's inbox), where the registry routes steering notes
    # (and STOP for a task servicing no live request). #request answers come back
    # on the SEPARATE @pending_reply, so a note can never be mistaken for a
    # dialog answer.
    @inbox         = job.inbox
    @pending_reply = nil            # live request's reply channel (one at a time)
    @registry = registry
    @job      = job
    # The task uses the job's buffer: the run record belongs to the job's
    # registry. The drain loop is the single writer; the task thread never touches it.
    @buffer       = job.buffer
    # The drain loop asks the renderer for patterns/colors; #run replaces it with
    # the harness's configured palette, so this one colors nothing.
    @renderer  = UI::Renderer.new
    @spinner = nil
    @thread  = nil
    @ui = nil # set by Task.run before start
    @dialog_open = false           # true while perform_direct is on stdin
    @note_editor  = nil
    @input_path   = input_path
    @started_at   = nil            # turn clock, set by #start
    @harness      = nil
  end

  attr_writer :ui

  # While true, store_and_render must not clear output lines: a Choice
  # prompt on stdin would vanish with them.
  def dialog_open?
    @dialog_open
  end

  # True while the poll loop is in the edit state (the user is typing).
  def edit_state?
    input_path&.edit_state?
  end

  attr_accessor :note_draft

  # -- Lifecycle ---------------------------------------------------------------

  # Spawn the task thread and run the block. The task reference is published on
  # Thread.current so nested code finds it via `Task.current`. No buffer
  # reference is exposed to task code - the buffer is runner-side only.
  def start
    @started_at = Time.now
    @thread = Thread.new do
      Thread.current[:harness_task] = self
      Thread.current.name = "job-#{@job.id}"
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

  # The turn clock for the spinner's elapsed segment: whole seconds under a
  # minute ("12s"), minutes beyond it ("2m 03s"). nil before #start.
  def elapsed_label
    return nil if @started_at.nil?

    secs = (Time.now - @started_at).to_i
    return "#{secs}s" if secs < 60

    "#{(secs / 60)}m #{format('%02d', secs % 60)}s"
  end

  # Non-blocking poll of the ONE queue: the next event, whatever job it belongs
  # to, or nil after the timeout. Deciding WHICH job's events a loop shows is the
  # loop's decision (MainLoop#next_shown_event), not this runner's - a Task is a
  # job's runner, not the queue's reader.
  def poll(timeout = DEFAULT_POLL_TIMEOUT)
    @registry.poll(timeout)
  rescue ThreadError
    nil
  end

  # True when no events are waiting (the drain loop uses it to decide
  # whether to show the spinner).
  def outbox_empty?
    @registry.queue_empty?
  end

  # Reply to a pending request (called from the main thread), unblocking the
  # task thread's #request call with the given value.
  def respond(value)
    @job.mark_awaiting(false)
    if @pending_reply
      @pending_reply << value
    else
      @inbox << value
    end
  end

  def alive?
    !@thread.nil? && @thread.alive?
  end

  # Force-stop: answer what the turn owes, signal the inbox, and join with a
  # short grace. Kills the thread if it is still alive after the timeout.
  def stop(timeout = DEFAULT_STOP_JOIN_TIMEOUT)
    # An interrupted turn answers every request it still owes (STOP is not an
    # answer, so a blocked requester would raise on it). STOP then only breaks
    # this thread's own pending pop when no answer already hit that inbox.
    owed = @registry.jobs.select(&:awaiting?)
    had_live = !@pending_reply.nil?
    if had_live
      # A live request on THIS task blocks on the reply channel, not the inbox.
      # Answer it (not STOP) so #request returns normally and the thread runs
      # its ensure/exit. The owning job was already counted in `owed`; drop it
      # so it is not ALSO answered into its inbox.
      @pending_reply << Job::INTERRUPTED_ANSWER
      @pending_reply = nil
      @job.mark_awaiting(false)
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
    logger = @harness&.logger
    return unless logger

    logger.error ErrorText.detailed(error, "task thread raised")
  end

  # Push a typed event onto the single event queue (the outbox). This is the
  # ONLY way task-thread code communicates output to the main thread.
  def push_event(type:, origin: nil, content: nil, **extra)
    event = { type: type.to_sym, origin:, content: }
    event.merge!(extra) unless extra.empty?
    event[:job] = @job.id
    @registry << event
    event
  end

  # Blocks until the main thread answers with #respond.
  def request(type, **payload)
    # While a request is unanswered, an input event must queue BEHIND the answer
    # it gets, so the job is marked awaiting (FIFO rule). The answer comes back
    # on a channel SEPARATE from @inbox: a steering note already resident in the
    # job inbox can no longer be mistaken for the answer.
    @pending_reply = Thread::Queue.new
    @job.mark_awaiting(true)
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
  # the CLI's UI::Console instead.

  # The Task running on the current thread (set by #start), or nil.
  def self.current
    Thread.current[:harness_task]
  end

  # Emit ONE typed event onto the active task's outbox. No-op when no task is active.
  def self.emit(type, origin:, content: nil)
    task = current
    return nil unless task

    task.push_event(type:, origin:, content:)
  end

  # Write lines as :text events on the active task's outbox. One event per
  # argument (like Kernel.puts). No-op when no task is active.
  def self.puts(*args)
    task = current
    return unless task

    args = [""] if args.empty?
    args.each { |part| task.push_event(type: :text, origin: :task, content: part.to_s) }
    nil
  end

  # -- The ONE spinner (held on the task, driven by the MainLoop) --------------
  # The spinner's storage lives here because the task is the single sink it
  # draws into; the MainLoop owns its creation, animation and clearing.

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
  # Builds the task and hands it to a MainLoop, which runs the poll loop over the
  # single event queue, drives the spinner, serves dialogs and reads mid-turn
  # notes, and returns when the task finishes. The required `ui:` console is the
  # single sink for ALL output; tests can pass a StringIO-backed UI::Console.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(
    harness:,
    ui:,
    registry:,
    job:,
    input_path: nil,
    &block
  )
    # The task runs on its job's registry, buffer and inbox. The drain loop is
    # the single main-thread writer, so every put lands in the same record a save reads.
    task = Task.new(registry:, job:, input_path:, &block)
    task.ui = ui
    # The input path is the ONE reader the main thread's poll loop shares with
    # the idle prompt. It only PEEKS stdin until typing starts, so nothing races
    # for the keyboard. Input needs a harness to land on (nil = unit test).
    task.harness = harness
    # The palette is the run's settings: a nil harness (a unit-test run) colors
    # nothing, so the plain renderer stays.
    palette = harness&.settings&.output_palette
    # Markdown rendering of the assistant answer is opt-in; the posture is read
    # here (a Task builds its renderer once per turn), so a mid-run /markdown
    # toggle lands on the next turn.
    markdown = harness&.settings&.markdown?
    # The table-width basis: config-derived, read once per turn like the
    # palette. nil = the renderer's default (80% of the terminal).
    max_width = harness&.settings&.markdown_max_width
    task.renderer = UI::Renderer.new(palette:, markdown:, markdown_max_width: max_width)
    task.note_editor = UI::Editor.new(ui.stdin) if ui.stdin && harness
    # The MainLoop owns the main-thread loop, the spinner, stdin and dialog serving.
    MainLoop.new(task).run
  end
end
