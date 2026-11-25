# frozen_string_literal: true

# Task: runs the turn block on a background thread and owns ALL console I/O
# for it (single-thread I/O rule); design and protocol: doc/task_design.md

require "io/console"
require_relative "job"
require_relative "input_path"
require_relative "output_buffer"
require_relative "ui/renderer"
require_relative "ui/editor"
require_relative "ui/spinner"
require_relative "error_text"
require_relative "harness_error"
require_relative "request_event"

class Task
  # Default spinner message; a :spinner_detail event may override it (and its
  # suffix) for the rest of the wait.
  DEFAULT_SPINNER_MESSAGE = "Working"

  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  STOP = Object.new.freeze

  # Inbox item naming one turn's work: a parked worker takes it, runs the block as
  # a turn, and parks again. A turn is a VALUE the registry hands the job, not a
  # thread a caller spawns.
  WORK = :__work__

  DEFAULT_POLL_TIMEOUT = 0.1

  # Grace #stop gives the task thread before killing it.
  DEFAULT_STOP_JOIN_TIMEOUT = 0.5

  # Raised by the drain loop when the note editor saw EOF (Ctrl-D inside it
  # while editing a mid-turn note): aborts the turn like Ctrl+C.
  class NoteAbort < StandardError; end

  # Event types the drain loop treats as control flow (never stored or rendered).
  CONTROL_EVENTS = %i[error_ctrl __request__].freeze

  attr_reader :thread, :buffer, :ui, :renderer, :job, :registry, :input_path
  # The worker's private queue (WORK items and STOP only); see #start.
  attr_reader :await_work

  # Set by #run from the harness's configured palette; the constructor's own
  # renderer colors nothing, which is what a Task without a harness needs.
  attr_writer :renderer

  attr_accessor :note_editor
  attr_accessor :harness

  # A worker built with no block parks until #submit_work hands it one; a worker
  # built WITH a block runs that turn first and then parks (the per-turn form
  # Task.run uses).
  attr_accessor :block

  # A task built for a job reads the registry's ONE queue. The job's inbox is the
  # drain loop's reader-side queue; the worker's deliveries arrive on @await_work.
  def initialize(registry:, job:, input_path: nil, &block)
    @block   = block
    # #request answers come back on the SEPARATE @pending_reply, so a steering
    # note (which the registry routes into the job's inbox) can never be mistaken
    # for a dialog answer.
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
    # The worker's own queue (WORK items and STOP only). #start parks the worker
    # on it; Job#deliver routes to it while a worker is live. It is separate from
    # the job inbox so a steering note can never be mistaken for work.
    @await_work   = Thread::Queue.new
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

  # Spawn this job's worker thread. The task reference is published on
  # Thread.current so nested code finds it via `Task.current`. No buffer reference
  # is exposed to task code - the buffer is runner-side only.
  #
  # The worker is PARKED, not per-turn: it takes a WORK item from its own
  # @await_work, runs that turn, and waits for the next. A turn ends with a :done
  # event (the turn's end); the THREAD ends only on a STOP - what an interrupt or
  # the run's shutdown sends. A worker built with a block runs that turn first, so
  # the per-turn form (Task.run) is the same body with one item already in hand.
  def start
    raise HarnessError, "task for job #{@job.id} already has a worker" if @thread&.alive?

    # A worker built WITH a block has its turn in hand NOW, so the turn clock
    # starts here (synchronously) - the caller may read elapsed_label before the
    # worker thread reaches service_turn. A parked worker starts its clock in
    # service_turn, per turn.
    @started_at = Time.now if @block
    @job.worker = self
    @thread = Thread.new do
      Thread.current[:harness_task] = self
      Thread.current.name = "job-#{@job.id}"
      # A worker built WITH a block runs that turn first: the block is the caller's
      # own, so it is never routed through the inbox (which also carries answers and
      # notes that must not be mistaken for work).
      service_turn if @block
      loop do
        # #await_work is the worker's own queue, not the job inbox: the drain loop
        # is the reader of the job inbox during a turn (steering notes stay there
        # for it), and Job#deliver routes the answer to the live worker.
        item = await_work.pop
        # A STOP left in the queue is the sentinel the PREVIOUS worker thread died
        # for: consume it and keep parking. Only the worker that is parked NOW may
        # end on a STOP, so reviving a stopped worker never self-kills it.
        next if item.equal?(STOP) && @thread != Thread.current
        break if item.equal?(STOP)
        # A command-side request event (:compact, ...): it becomes this worker's
        # next turn, so the requested work runs on the JOB's thread.
        if RequestEvent.deliver?(item)
          service_request(item)
          next
        end
        # A non-WORK item is a stray answer or note: the loop drains those, not the worker.
        next unless work_item?(item)

        @block = item[:block]
        service_turn
      end
      @thread = nil
    end
    self
  end

  # Hand this job's worker the next turn's block (main thread only). The worker
  # picks it up from its own queue (Job#deliver routes it there), so a caller never
  # touches the thread - and a job can be handed work whenever it is idle.
  def submit_work(&block)
    @job.deliver({ type: WORK, block: })
    self
  end

  # One turn: run the block, report an error, announce the turn's end. Called once
  # per WORK item by the worker, and directly by a caller that wants exactly one
  # turn with @block already set. A request event that arrives while the block
  # runs is serviced BEFORE the turn's :done: the :done finishes the JOB, so a
  # mini-turn pushed after it would land on a finished job (and a second :done
  # would be dropped by Job#finish's once-only guard).
  def service_turn
    # Live-ness is the JOB's status: the worker services a turn only while this
    # job has one, and the registry's :done record finishes the job again.
    @job.mark_running
    # The turn clock starts here (not at #start): a parked worker's thread exists
    # long before its first turn, and elapsed_label must stay nil until one runs.
    @started_at = Time.now
    begin
      value = @block.call(self)
      service_pending_requests
    rescue => e
      # The event goes FIRST: a logger that cannot write must not swallow the
      # error the user is owed.
      push_event(type: :error_ctrl, content: ErrorText.label(e))
      record_task_error(e)
    ensure
      # The block's value is the turn's result, on the :done event the caller
      # awaits. It is NOT the job's finish: a parked worker lives on after a turn,
      # and only an explicit Job#finish ends the JOB.
      push_event(type: :done, result: value)
    end
    self
  end

  # Drain the request events already on the worker's queue (non-blocking pop):
  # each becomes a mini-turn on this job, inside the live turn.
  def service_pending_requests
    loop do
      item = await_work.pop(true) rescue nil
      break unless item
      if RequestEvent.deliver?(item)
        service_request(item)
      elsif work_item?(item)
        @block = item[:block]
        service_turn
      end
    end
  end

  # One request event the loop handed to this worker: run the requested work on
  # the JOB's thread. A mini-turn pushes NO :done: the enclosing turn's :done is
  # what ends the turn and carries the turn's result, and a :done here would
  # finish the job mid-turn (Job#finish is once-only, so the real result would
  # be dropped). A raising mini-turn reports like a turn does.
  def service_request(item)
    @started_at = Time.now
    begin
      harness.session_manager.compact_session if RequestEvent.request?(item)
    rescue => e
      push_event(type: :error_ctrl, content: ErrorText.label(e))
      record_task_error(e)
    end
    self
  end

  def work_item?(item)
    item.is_a?(Hash) && item[:type] == WORK
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
      # No live request on this task: the value is a delivery for the job,
      # routed by Job#deliver (to the parked worker if one lives).
      @job.deliver(value)
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
    # The parked worker pops await_work, not the inbox, so the wake-up goes
    # there: STOP unblocks a pending pop and ends the worker loop.
    @await_work << STOP
    @thread&.join(timeout)
    @thread&.kill if @thread&.alive?
    @thread = nil
    # The job keeps its (stopped) Task: alive? is false, so Job#deliver falls
    # back to the inbox and MainLoop#worker REVIVES this same Task on its own
    # queue. Only a worker that exits on its own (its loop ended) clears the slot.
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
  # The per-turn presentation a drain loop reads ONCE per turn: the palette and the
  # markdown posture from the run's settings (so a mid-run /markdown toggle lands on
  # the NEXT turn) and the note editor for the mid-turn read. A nil harness (a
  # unit-test run) colors nothing, so the plain renderer stays.
  def prepare(harness:, ui:)
    # The input path is the ONE reader the main thread's loop shares with the idle
    # prompt: it only PEEKS stdin until typing starts, so nothing races for the
    # keyboard. Input needs a harness to land on (nil = unit test).
    @harness = harness
    @ui      = ui
    settings = harness&.settings
    @renderer = UI::Renderer.new(
      palette: settings&.output_palette,
      markdown: settings&.markdown?,
      markdown_max_width: settings&.markdown_max_width)
    @note_editor = UI::Editor.new(ui.stdin) if ui.stdin && harness
    self
  end

  # A worker parked on this task's inbox, ready for a turn it has not been given
  # yet: the block is delivered later by #submit_work.
  def start_parked
    @block = nil
    start
  end
end
