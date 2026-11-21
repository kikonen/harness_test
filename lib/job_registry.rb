# frozen_string_literal: true

require_relative "output_buffer"
require_relative "job"
require_relative "task"

# The flat job list, the ONE fan-in queue that orders events across jobs, and
# the executor: a turn is AWAITED here rather than run in place by a caller.
# Design: doc/task_model_design.md.
class JobRegistry
  # Same timeout as the drain loop, so a poll costs the same everywhere.
  DEFAULT_POLL_TIMEOUT = 0.1
  attr_reader :max_memory, :max_saved, :tasks_kept, :jobs, :next_id
  attr_reader :settings

  # A nil limit means the caller resolved the config value already, so the
  # buffer's built-in default has to be passed in here.
  def initialize(
    max_memory: OutputBuffer::DEFAULT_MAX_MEMORY,
    max_saved: OutputBuffer::DEFAULT_MAX_SAVED,
    tasks_kept: nil,
    settings: nil,
    # A resumed run must continue numbering where its saved system left off, or
    # its next job reuses an id already on disk (#548). 0 = a fresh run. The CLI
    # seeds it from the saved system.json's next_id.
    next_id: 0
  )
    @max_memory = max_memory
    @max_saved  = max_saved
    @tasks_kept = tasks_kept
    @queue      = Thread::Queue.new
    @jobs       = []
    @next_id    = next_id
    @foreground = nil
    # The run's SystemSettings: the postures a save records are SYSTEM state,
    # and the registry is the system-side object a record may read them from.
    @settings = settings
  end

  # Ids go in add order so the main turn, added first, is job #0 - the registry
  # has no special case for it. A resumed run REBUILDS a saved job with an explicit
  # id: (its saved id) so a job's live id matches the job dir its files live under
  # (#548); next_id is then advanced past every used id so a new job never reuses
  # one (#548 A).
  def add_job(
    kind:,
    dependencies: [],
    requested_by: nil,
    harness: nil,
    id: nil
  )
    job_id = id || @next_id
    job = Job.new(
      id: job_id,
      kind:,
      registry: self,
      buffer: OutputBuffer.new(max_memory:, max_saved:),
      dependencies:,
      requested_by:,
      harness:)
    # An explicit id (a rebuilt saved job) keeps next_id ahead of every id in use.
    @next_id = job_id + 1 if job_id >= @next_id
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
  def run(job:, ui:, input_path: nil, &block)
    # The Harness is the job's (#286): a Harness lives INSIDE the job it drives,
    # so the executor reads it off the job rather than taking it from the caller.
    error, task = Task.run(
      harness: job.harness, ui:, registry: self, job:, input_path:, &block)
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

  # issue #548: which saved job ids this registry can rebuild a live Job from -
  # the ones it already has. A saved id naming nothing is a dropped job, and an
  # edge naming it stays dangling. Main-safe: reads only, writes nothing.
  def resumable_job_ids(saved_entries)
    Array(saved_entries).filter_map do |entry|
      id = entry.is_a?(Hash) ? (entry[:id] || entry["id"]) : entry
      id if job(id)
    end
  end

  def foreground_job
    job(@foreground)
  end

  def foreground_buffer
    foreground_job&.buffer
  end

  # -- Session-worthy (issue #548 increment 5) ------------------------------

  # Does ANY retained job own session state worth saving? This is the honest
  # cross-job question #548 wants in place of #188's foreground-emptiness test:
  # a background/sub-agent job that did real work must count even when the
  # foreground chain is empty. A job the run never drove (harness nil, OPEN
  # QUESTION 5) owns no conversation, so it is not counted.
  def any_job_has_session_state?
    @jobs.any? { |job| job.harness && !job.harness.session.empty? }
  end

  # -- Run record (issue #458 / #286) ---------------------------------------
  #
  # The run record is the FOREGROUND job's buffer, and the registry - not the
  # per-LLM turn engine - is its owner. Main-thread only. The max_saved guard
  # is the disable: resume_replay_entries 0 records nothing.

  # Record the user's own submitted line. It is a first-class ROLE (type
  # :user, not plain :text) so UI::Renderer labels it 'user:' on the resume
  # redraw - the both-sides record #146 asks for.
  def record_user_prompt(text)
    return if @max_saved.zero?

    record_report(type: :user, origin: :user, content: text.to_s)
  end

  # Record a main-thread slash-command report so a resumed run redraws it
  # (#474). A structured :list payload is stored AS the structure, not a
  # pre-rendered line (issue #146).
  def record_report_output(type:, origin:, content:)
    return if @max_saved.zero?

    record_report(type:, origin:, content:)
  end

  # The saved form of the tail (Entry#to_h hashes) for the session JSON.
  def replay_tail_for_save
    return [] if @max_saved.zero?

    Array(foreground_buffer&.replay_tail(@max_saved)).map(&:to_h)
  end

  # issue #548 increment 4b: the saved tail of ANY retained job's buffer, not
  # only the foreground one. The registry is the only writer of every job's
  # buffer (the single-thread I/O rule), so reading a job's tail is main-safe
  # for every job. A job id the registry does not retain has no tail.
  def replay_tail_for_job(job_id)
    return [] if @max_saved.zero?

    Array(job(job_id)&.buffer&.replay_tail(@max_saved)).map(&:to_h)
  end

  # A resumed run seeds its record from the saved tail so the startup banner
  # can redraw the last topic. restore() normalizes the JSON's string
  # type/origin back to symbols. A disabled window (max_saved 0) seeds nothing.
  def restore_replay_tail(entries)
    return if @max_saved.zero?

    foreground_buffer&.restore(entries)
  end

  # -- Inbox routing ----------------------------------------------------------

  def answer(id, value)
    target = job(id)
    return nil if target.nil?

    target.deliver(value)
  end

  # Ask a retained job's own agent to persist its conversation at its next safe
  # point (issue #548 F). The registry only reaches the job; the save happens on
  # that job's own thread. A job with no agent (no LLM round) saves nothing.
  def request_save(job_id)
    target = job(job_id)
    return nil if target.nil?

    target.request_save
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

  private

  # Write one entry into the foreground buffer and enforce the saved window -
  # the same pair every tail put through #record does.
  def record_report(type:, origin:, content:)
    foreground_buffer&.put(type:, origin:, content:)
    foreground_buffer&.keep_window
  end
end
