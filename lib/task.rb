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
require_relative "event_queue"
require_relative "queued_event"

class Task
  # Default spinner message; a :spinner_detail event may override it (and its
  # suffix) for the rest of the wait.
  DEFAULT_SPINNER_MESSAGE = "Working"

  # Raised INTO the worker thread to unwind a live turn (the :stop rule);
  # service_turn rescues it like an Interrupt. A parked worker whose pending
  # pop takes it ends its loop (see #start).
  StopSignal = Class.new(Interrupt)

  DEFAULT_POLL_TIMEOUT = 0.1

  # Grace #stop gives the task thread before killing it.
  DEFAULT_STOP_JOIN_TIMEOUT = 0.5

  # Raised by the drain loop when the note editor saw EOF (Ctrl-D inside it
  # while editing a mid-turn note): aborts the turn like Ctrl+C.
  class NoteAbort < StandardError; end

  # Event types the drain loop treats as control flow (never stored or rendered).
  CONTROL_EVENTS = %i[error_ctrl __request__].freeze

  attr_reader :thread, :buffer, :ui, :renderer, :job, :registry, :input_path
  # The job's event queue (QueuedEvent items); see #start.
  attr_reader :event_queue

  # Set by #run from the harness's configured palette; the constructor's own
  # renderer colors nothing, which is what a Task without a harness needs.
  attr_writer :renderer

  attr_accessor :note_editor
  attr_accessor :harness

  # A worker built with no block parks until a :prompt event hands it one; a
  # worker built WITH a block runs that turn first and then parks (the
  # per-turn form Task.run uses).
  attr_accessor :block

  # A task built for a job reads the registry's ONE outbox queue; its own
  # EventQueue is the worker's inbox (see #start).
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
    # The job's event queue: the worker loop admits QueuedEvents from it.
    @event_queue  = EventQueue.new
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

  # Spawn this job's worker thread (the worker EVENT LOOP, issue #286 step 3).
  # The task reference is published on Thread.current so nested code finds it
  # via `Task.current`. No buffer reference is exposed to task code - the buffer
  # is runner-side only.
  #
  # The loop admits QueuedEvents from the job's EventQueue and dispatches them
  # by kind: :prompt runs a turn (parked window), :note fills the mailbox (the
  # live turn folds it at its request boundary), :compact/:retry run as
  # mini-turns inside a live turn, :stop unwinds the live turn and PARKS the
  # worker (thread alive), :shutdown ends the loop. A turn ends with a :done
  # event; the thread ends only on :shutdown.
  def start
    raise HarnessError, "task for job #{@job.id} already has a worker" if @thread&.alive?

    # A worker built WITH a block has its turn in hand NOW, so the turn clock
    # starts here (synchronously) - the caller may read elapsed_label before the
    # worker thread reaches service_turn. A parked worker starts its clock in
    # service_turn, per turn.
    @started_at = Time.now if @block
    @job.worker = self
    # A revived Task (MainLoop#worker calls #start on the SAME object) must not
    # inherit the previous thread: its stale @thread would make the loop's
    # "@thread != Thread.current" revive guard read as a foreign :stop, and the
    # new worker would discard its own staged events and park forever.
    # The slot must be nil BEFORE Thread.new: the new thread reaches the loop
    # (and any :stop guard) before the main thread's assignment lands.
    @thread = nil
    @thread = Thread.new do
      Thread.current[:harness_task] = self
      Thread.current.name = "job-#{@job.id}"
      # A worker killed or StopSignal-raised out of its loop is the designed
      # end of a force-stop, not a bug to print.
      Thread.current.report_on_exception = false
      service_turn if @block
      loop do
        begin
          event = event_queue.admit_next
        rescue StopSignal
          break
        end
        # A :stop left staged by the PREVIOUS thread dies with that thread: only
        # the worker parked NOW acts on it, so reviving never self-kills.
        if event&.kind == :stop && @thread != Thread.current
          event_queue.discard_up_to(:stop)
        end
        break if dispatch(event) == :shutdown
      end
      @thread = nil
    end
    self
  end

  # Post the next turn's prompt as a :prompt event (main thread only; the
  # text is data the queue can reason about - the worker builds the block).
  def submit_prompt(text)
    event_queue.post(QueuedEvent.build(kind: :prompt, job_id: @job.id, payload: text))
    self
  end

  # Post a sender-owned behaviour block (:compact / :retry): the queue can
  # order and discard it; the worker decides WHEN it runs.
  def submit_block(kind:, block:)
    event_queue.post(QueuedEvent.build(kind:, job_id: @job.id, block:))
    self
  end

  # One admitted event, this worker's thread. Returns :shutdown when the worker
  # loop must end; anything else keeps the loop. A live turn's own boundary
  # drains :compact/:retry (service_pending_requests); a parked worker runs them
  # as its round: the EVENT'S block is the turn block (a command-built block
  # closes over the command's own harness, so it never reads this task's).
  def dispatch(event)
    return :park if event.nil?

    case event.kind
    when :shutdown
      :shutdown
    when :stop
      # Parked here: the staged work before it was already discarded by the
      # loop; nothing to unwind.
      :park
    when :prompt
      # The live turn owns the worker: a second :prompt stays staged until the
      # running turn's :done (the drain is following that turn's job).
      return :park if @job.running?

      @block = ->(_task) { harness.session_manager.run_prompt(event.payload) }
      service_turn
      :park
    when :note
      harness.user_note_text = event.payload
      :park
    when :compact, :retry
      # The EVENT'S block is the round (a command-built block closes over the
      # command's own harness, so it never reads this task's). A live turn runs
      # it as a mini-turn at its next boundary instead: the event stays staged
      # and service_pending_requests dispatches it from the live turn's thread.
      return :park if @job.running?

      @block = ->(_task) { event.block.call }
      service_turn
      :park
    end
  end

  # The live turn's request boundary drains the sender-owned block kinds staged
  # on the queue (the mini-turn-inside-the-live-turn rule from increment 4): the
  # event's own block runs, wrapped so a raise lands as :error_ctrl like a turn
  # error does. No :done of its own - the enclosing turn's :done ends the drain.
  def service_pending_requests
    event_queue.admit_arrived
    while (event = event_queue.peek_processable(accepted_kinds: QueuedEvent::BLOCK_KINDS))
      event_queue.dispatch(event)
      begin
        event.block.call
      rescue StandardError, Interrupt => e
        push_event(type: :error_ctrl, content: ErrorText.label(e))
        record_task_error(e)
      end
    end
  end

  # One turn: run the block, report an error, announce the turn's end. Called once
  # per :prompt event by the worker, and directly by a caller that wants exactly
  # one turn with @block already set. A block-kind event that arrives while the
  # block runs is serviced BEFORE the turn's :done: the :done finishes the JOB,
  # so a mini-turn pushed after it would land on a finished job.
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
    rescue StandardError, Interrupt => e
      # The event goes FIRST: a logger that cannot write must not swallow the
      # error the user is owed. Interrupt is caught here too: a Ctrl+C landing
      # on this thread must not end the worker WITHOUT the ensure pushing
      # :done, or the job stays :running and the drain waits forever.
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
    # An interrupted turn answers every request it still owes (a stop signal is
    # not an answer, so a blocked requester would raise on it).
    owed = @registry.jobs.select(&:awaiting?)
    had_live = !@pending_reply.nil?
    if had_live
      # A live request on THIS task blocks on the reply channel, not the queue.
      # Answer it so #request returns normally and the thread runs its
      # ensure/exit. The owning job was already counted in `owed`; drop it so
      # it is not ALSO answered into its queue.
      @pending_reply << Job::INTERRUPTED_ANSWER
      @pending_reply = nil
      @job.mark_awaiting(false)
      owed = owed.reject { |job| job.equal?(@job) }
    end
    owed.each { |job| job.respond(Job::INTERRUPTED_ANSWER) }
    event_queue.post(QueuedEvent.build(kind: :shutdown, job_id: @job.id))
    # A live turn is unwound by the signal into its own thread; a parked worker
    # is woken by the :shutdown posted above. Thread#raise ALSO re-raises into
    # the calling thread (measured), so the signal is absorbed here - the join
    # is what waits for the worker.
    thread = @thread
    if thread&.alive?
      begin
        thread.raise(StopSignal)
      rescue StopSignal
        # Thread#raise re-raises into THIS thread too (measured); the worker
        # got the signal either way.
      end
      # join re-raises the pending exception into the joiner EVERY call (no
      # once-per-thread flag), so the grace is a poll on alive? - a raised-out
      # worker is dead by the time the signal unwinds its turn.
      deadline = Time.now + timeout
      while thread.alive? && Time.now < deadline
        sleep(0.01)
      end
    end
    thread&.kill if thread&.alive?
    @thread = nil
    # The job keeps its (stopped) Task: alive? is false, so MainLoop#worker
    # REVIVES this same Task (its EventQueue survives) for the next turn.
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
    # on a channel SEPARATE from the event queue: a steering note already
    # staged there can never be mistaken for the answer.
    @pending_reply = Thread::Queue.new
    @job.mark_awaiting(true)
    push_event(type: :__request__, kind: type, **payload)
    reply = @pending_reply.pop
    @pending_reply = nil
    if reply.equal?(Job::INTERRUPTED_ANSWER)
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
  # Re-prepare (MainLoop#worker revives a stopped Task) refreshes the harness
  # reference too, so a job whose harness arrived after its first start is not
  # left with the nil from the first call.
  def prepare(harness: nil, ui:)
    # The input path is the ONE reader the main thread's loop shares with the idle
    # prompt: it only PEEKS stdin until typing starts, so nothing races for the
    # keyboard. Input needs a harness to land on (nil = unit test).
    @harness = harness if harness
    @ui      = ui
    settings = harness&.settings
    @renderer = UI::Renderer.new(
      palette: settings&.output_palette,
      markdown: settings&.markdown?,
      markdown_max_width: settings&.markdown_max_width)
    @note_editor = UI::Editor.new(ui.stdin) if ui.stdin && harness
    self
  end

  def start_parked
    @block = nil
    start
  end
end
