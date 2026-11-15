# frozen_string_literal: true

require_relative "output_buffer"
require_relative "job"
require_relative "task"

# The flat job list, the ONE fan-in queue that orders events across jobs, and
# the executor: a turn is AWAITED here rather than run in place by a caller.
# Design: doc/task_model_design.md.
class Registry
  # Same timeout as the drain loop, so a poll costs the same everywhere.
  DEFAULT_POLL_TIMEOUT = 0.1

  attr_reader :max_memory, :max_saved, :tasks_kept, :jobs

  # A nil limit means the caller resolved the config value already, so the
  # buffer's built-in default has to be passed in here.
  def initialize(
    max_memory: OutputBuffer::DEFAULT_MAX_MEMORY,
    max_saved: OutputBuffer::DEFAULT_MAX_SAVED,
    tasks_kept: nil
  )
    @max_memory = max_memory
    @max_saved  = max_saved
    @tasks_kept = tasks_kept
    @queue      = Thread::Queue.new
    @jobs       = []
    @next_id    = 0
    @foreground = nil
  end

  # Ids go in add order so the main turn, added first, is job #0 - the registry
  # has no special case for it.
  def add_job(
    kind:,
    dependencies: [],
    requested_by: nil
  )
    job = Job.new(
      id: @next_id,
      kind:,
      registry: self,
      buffer: OutputBuffer.new(max_memory:, max_saved:),
      dependencies:,
      requested_by:)
    @next_id += 1
    @jobs << job
    @foreground ||= job.id
    job
  end

  def job(id)
    @jobs.find { |j| j.id == id }
  end

  # Cross-job order is defined only because every job pushes onto this ONE
  # queue; the event's job field names the buffer it belongs to.
  def <<(event)
    @queue << event
    event
  end

  # The registry is the queue's only reader, which is what makes routing
  # conflict-free: job threads never read it.
  def poll(timeout = DEFAULT_POLL_TIMEOUT)
    @queue.pop(false, timeout:)
  rescue ThreadError
    nil
  end

  # True when no event is waiting on the ONE queue (the spinner check).
  def queue_empty?
    @queue.empty?
  end

  # The executor: the CLI asks the registry to run a job and awaits its result.
  # The drain loop stays the single main-thread writer of the job's buffer.
  def run(job:, harness:, ui:, input_path: nil, &block)
    error, task = Task.run(harness:, ui:, registry: self, job:, input_path:, &block)
    [error, task, job.result]
  end

  # -- Input events -----------------------------------------------------------

  def note_event(text)
    { type: :note, content: text.to_s }
  end

  # Input is routed to a job's inbox through #deliver, so the override rule (a
  # note replaces a pending note only) is applied on the way in.
  def route_input(job_id, event)
    target = job(job_id)
    return event if target.nil?
    return event if target.awaiting? # queues behind the pending answer

    target.deliver(event)
  end

  # -- Dialogs ----------------------------------------------------------------

  # A job outside the foreground cannot be shown a dialog, so it is denied with
  # an answer value. Grant dialogs are excepted: denying one would stop the job.
  def denied?(job, dialog = nil)
    return false if job.nil? || foreground?(job.id)
    return false if dialog&.grant?

    true
  end

  # mode decides head vs tail, so an event that carries no mode is a committed
  # entry: the head must never be the only copy of an answer. Control types are
  # handled as control flow by the drain loop, never stored.
  def record(event)
    return nil if event.nil?

    target = job(event[:job])
    return nil if target.nil?
    # :done carries the job's result, so it finishes the job (the drain loop
    # handles it as control flow, but the finish is the registry's).
    return target.finish(event[:result]) if event[:type] == :done

    return nil if Job::CONTROL_TYPES.include?(event[:type])

    entry = target.buffer.put(
      type: event[:type],
      origin: event[:origin],
      content: event[:content],
      mode: event[:mode])
    target.finish(event[:result]) if event[:type] == :done
    entry
  end

  def tick(timeout = DEFAULT_POLL_TIMEOUT)
    event = poll(timeout)
    record(event)
    event
  end

  # -- Foreground -------------------------------------------------------------

  # The id, not the buffer, is what the session remembers, so a resumed run can
  # restore which buffer was active.
  attr_reader :foreground

  def foreground=(id)
    raise ArgumentError, "job ##{id} is not retained" if job(id).nil?

    @foreground = id
  end

  def foreground?(id)
    @foreground == id
  end

  # A resumed run can only restore an id IT retains - a saved job is not
  # rebuilt by the resume, so an unknown id leaves the default in place.
  def restore_foreground(id)
    return @foreground if id.nil? || job(id).nil?

    @foreground = id
  end

  def foreground_job
    job(@foreground)
  end

  def foreground_buffer
    foreground_job&.buffer
  end

  # -- Inbox routing ----------------------------------------------------------

  def answer(id, value)
    target = job(id)
    # An id it does not retain has no inbox to answer, which is a caller error:
    # returning nil silently is how an answer went computed-but-never-delivered.
    raise ArgumentError, "job ##{id} is not retained" if target.nil?

    target.respond(value)
  end

  # -- Retention (tasks_kept) -------------------------------------------------

  # A dropped job can no longer be answered or read, so a running job and the
  # foreground job are never drop candidates; a finished foreground job still
  # occupies one of the retained slots.
  def retain(job)
    return job if @tasks_kept.nil?

    finished = @jobs.select(&:finished?)
    droppable = finished.reject { |j| j.id == @foreground }
    drop = finished.size - @tasks_kept
    droppable.first(drop).each { |old| @jobs.delete(old) } if drop.positive?
    job
  end

  def to_s
    "registry: #{@jobs.map(&:to_s).join(', ')} (foreground job ##{@foreground})"
  end
end
