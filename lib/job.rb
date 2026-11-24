# frozen_string_literal: true

# A graph node with its own buffer and inbox, and NO outbox: its events go to the
# registry's ONE queue tagged with its id. Design: doc/task_model_design.md.
class Job
  # A timed job's dependency is a clock predicate, not a job, so a plain
  # job-to-job DAG is not enough.
  KINDS = %i[main sub_agent command timed].freeze

  STATUSES = %i[pending running finished].freeze

  # Types the executor handles as control flow: they are never stored as
  # output, so the registry's single writer must skip them.
  CONTROL_TYPES = %i[error_ctrl __request__].freeze

  # A background job cannot be shown a dialog, so its request is answered with a
  # value the tool can return to the model. Grant dialogs are never denied -
  # denying one would stop the job from working at all.
  DENIED_ANSWER = "error: dialog denied (background job)"

  # What an interrupted turn delivers to a request it still owes: STOP is not an
  # answer, so a blocked requester needs a value a tool can hand back.
  INTERRUPTED_ANSWER = "cancelled: the turn was interrupted"

  # A reply equal to STOP is not an answer, so a job must stop rather than read
  # it as a dialog result.
  STOP = Object.new.freeze

  # Same timeout as the drain loop, so a poll costs the same everywhere.
  DEFAULT_POLL_TIMEOUT = 0.1

  # The Harness that lives INSIDE this job (#286): a Harness is one LLM
  # tool-loop, so it belongs to a job rather than to a global. A job the run
  # never drives (a bare registry in a spec, a not-yet-serviced job) carries nil.
  attr_reader :id, :kind, :status, :result, :registry, :buffer, :inbox
  attr_reader :dependencies, :requested_by, :harness

  # The Task whose worker is parked on this job's deliveries (#286). A parked
  # worker reads the job's deliveries from its OWN queue (await_work), so a
  # steering note resident in the inbox stays the drain loop's to read.
  attr_accessor :worker

  # The buffer comes from the registry: its limits belong to the buffer, and the
  # fan-in queue is shared by all jobs.
  def initialize(
    id:,
    kind:,
    registry:,
    buffer:,
    dependencies: [],
    requested_by: nil,
    harness: nil
  )
    raise ArgumentError, "unknown job kind: #{kind}" unless Job::KINDS.include?(kind)

    @id           = id
    @kind         = kind
    @registry     = registry
    @buffer       = buffer
    @inbox        = Thread::Queue.new
    @dependencies = dependencies
    @requested_by = requested_by
    @harness      = harness
    @status       = :pending
    @awaiting     = false
  end

  # Attach the Harness that drives this job, once. A job is created before its
  # agent exists (a registry job, a job being restored) and the agent is attached
  # when the system builds or restores it; attaching twice would hand one job two
  # LLM loops, so the second attempt raises rather than replacing the first.
  def attach_harness(harness)
    raise HarnessError, "job #{@id} already has a harness" if @harness

    @harness = harness
    harness
  end

  def pending?
    @status == :pending
  end

  def running?
    @status == :running
  end

  def finished?
    @status == :finished
  end

  def mark_running
    @status = :running
  end

  # Ask this job's agent to persist its OWN conversation at its next safe point
  # (issue #548 F). The main thread only flips a flag on the harness; the job's own
  # thread does the save, so a running chain is never read across threads. No-op
  # for a job with no agent (a job kind with no LLM round has nothing to save).
  def request_save
    @harness&.request_save
  end

  # Restore the status a save recorded (issue #548). A resumed job was already
  # finished or interrupted in the run that saved it; without this every restored
  # job reads as :pending, so the retention rule (only finished jobs drop) would
  # never see it. A result is NOT restored: Job#finish delivers it live to a live
  # requester, and a requester this run does not have cannot be answered.
  def restore_status(status)
    symbol = status.to_sym
    return nil unless Job::STATUSES.include?(symbol)

    @status = symbol
  end

  # True while the executor is waiting for an ANSWER to a request it posted. An
  # input event that arrives meanwhile must queue BEHIND that answer, so the
  # registry does not deliver it to the inbox (FIFO, issue #198).
  def awaiting?
    @awaiting
  end

  def mark_awaiting(value = true)
    @awaiting = value
  end

  # The one primitive an answer is delivered through: the awaiting flag clears
  # with it, so no input event queues behind an answer that already landed.
  def respond(value)
    mark_awaiting(false)
    deliver(value)
  end

  # A job thread never writes a stream or its own buffer (the single-thread I/O
  # rule), so the registry stays the only writer of the record.
  def push_event(type:, origin: nil, content: nil, **extra)
    event = { type: type.to_sym, origin:, content:, job: id }
    event.merge!(extra) unless extra.empty?
    registry << event
    event
  end

  # A dependency is a precondition, so it can be a finished job or a callable
  # predicate rather than an edge.
  def ready?
    dependencies.all? do |dep|
      dep.respond_to?(:finished?) ? dep.finished? : dep.call
    end
  end

  # A finished job cannot finish twice: a second finish would answer the
  # requester a second time.
  def finish(result = nil)
    return nil if finished?

    @status = :finished
    @result = result
    requested_by&.deliver(result)
    registry.retain(self)
    result
  end

  # An awaiting job's thread is blocked on a reply nobody else will write, so
  # the owed request is answered here.
  def interrupt
    respond(Job::INTERRUPTED_ANSWER) if awaiting?
  end

  # Latest line wins ONLY while the pending event is itself a note; a note after
  # another kind queues behind it.
  def deliver(value)
    # A live parked worker takes deliveries from its own queue; the inbox keeps
    # what no worker is waiting for (notes for the loop, results for no reader).
    if @worker&.alive?
      @worker.await_work << value
      return value
    end
    pending = @inbox.size == 1 ? @inbox.pop(true) : nil
    if pending && !(note?(value) && note?(pending))
      @inbox << pending
      @inbox << value
      return value
    end
    @inbox << value
    value
  end

  def inbox_empty?
    @inbox.empty?
  end

  def poll(timeout = DEFAULT_POLL_TIMEOUT)
    @inbox.pop(false, timeout:)
  rescue ThreadError
    nil
  end

  def to_s
    "job ##{id} #{kind} #{status}"
  end

  private

  def note?(value)
    value.is_a?(Hash) && value[:type] == :note
  end
end
