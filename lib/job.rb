# frozen_string_literal: true

# A graph node with its own buffer and inbox, and NO outbox: its events go to the
# registry's ONE queue tagged with its id. Design: doc/task_model_design.md.
class Job
  # A timed job's dependency is a clock predicate, not a job, so a plain
  # job-to-job DAG is not enough.
  KINDS = %i[main sub_agent command timed].freeze

  # Types the executor handles as control flow: they are never stored as
  # output, so the registry's single writer must skip them.
  CONTROL_TYPES = %i[error_ctrl __request__].freeze

  # A background job cannot be shown a dialog, so its request is answered with a
  # value the tool can return to the model. Grant dialogs are never denied -
  # denying one would stop the job from working at all.
  DENIED_ANSWER = "error: dialog denied (background job)"

  # A reply equal to STOP is not an answer, so a job must stop rather than read
  # it as a dialog result.
  # ONE sentinel for the whole model: a task and a round block on the same job
  # inbox, so two distinct objects could not both recognize the stop.
  STOP = Object.new.freeze

  # Same timeout as the drain loop, so a poll costs the same everywhere.
  DEFAULT_POLL_TIMEOUT = 0.1

  attr_reader :id, :kind, :status, :result, :registry, :buffer, :inbox
  attr_reader :dependencies, :requested_by

  # The buffer comes from the registry: its limits belong to the buffer, and the
  # fan-in queue is shared by all jobs.
  def initialize(
    id:,
    kind:,
    registry:,
    buffer:,
    dependencies: [],
    requested_by: nil
  )
    raise ArgumentError, "unknown job kind: #{kind}" unless Job::KINDS.include?(kind)

    @id           = id
    @kind         = kind
    @registry     = registry
    @buffer       = buffer
    @inbox        = Thread::Queue.new
    @dependencies = dependencies
    @requested_by = requested_by
    @status       = :pending
    @awaiting     = false
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

  # True while the executor is waiting for an ANSWER to a request it posted. An
  # input event that arrives meanwhile must queue BEHIND that answer, so the
  # registry does not deliver it to the inbox (FIFO, issue #198).
  def awaiting?
    @awaiting
  end

  def mark_awaiting(value = true)
    @awaiting = value
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
    # A finished job is not waiting for an answer, so the FIFO flag clears with
    # the delivery (the answer IS the delivery).
    @awaiting = false
    requested_by&.deliver(result)
    registry.retain(self)
    result
  end

  # Latest line wins ONLY while the pending event is itself a note; a note after
  # another kind queues behind it.
  def deliver(value)
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
