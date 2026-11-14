# frozen_string_literal: true

require_relative "output_buffer"
require_relative "job"

# The flat job list and the ONE fan-in queue that orders events across jobs.
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

  # mode decides head vs tail, so an event that carries no mode is a committed
  # entry: the head must never be the only copy of an answer.
  def record(event)
    return nil if event.nil?

    target = job(event[:job])
    return nil if target.nil?

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

  def foreground_job
    job(@foreground)
  end

  def foreground_buffer
    foreground_job&.buffer
  end

  # -- Inbox routing ----------------------------------------------------------

  def answer(id, value)
    target = job(id)
    return nil if target.nil?

    target.deliver(value)
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
