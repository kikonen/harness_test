# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "session"

# The system's own persistence record - the system/world half of what a save
# writes (issue #548). Built by the system's owner (the CLI, from the JobRegistry
# it owns) and the system settings it owns, so a per-Harness SessionManager never
# reaches a scheduling registry or the system's config it does not own
# (doc/harness_job_design.md: "its owner injects it").
#
# Increment 4a hands SystemRecord the system HALF of the write: it assembles and
# writes system.json (identity, postures, access, the system -> job map) and the
# foreground job's replay.json, reading the registry LIVE so a save records the
# system as it is at save time. SessionManager keeps only its own job's
# session.json - the conversation a single LLM loop owns. A record built without
# a registry is the degenerate one-job system (its only job is 0, the main turn),
# so a standalone save still produces a valid layered record.
class SystemRecord
  def initialize(registry)
    @registry = registry
  end

  # The job that was foreground at save (issue #286); a resumed system restores
  # which buffer was active from this id. A registry-less record defaults to 0.
  def foreground_job
    (@registry&.foreground) || 0
  end

  # The saved tail of the foreground job's buffer (issue #458), the shape
  # JobRegistry#replay_tail_for_save produces. A registry-less record has none.
  def replay_tail
    @registry ? @registry.replay_tail_for_save : []
  end

  # issue #548 increment 4b: the saved tail of ANY retained job (its own buffer,
  # which the registry owns). Reading it is main-safe because the registry is the
  # only buffer writer. A registry-less record or an unretained id has no tail.
  def replay_tail_for_job(job_id)
    @registry ? @registry.replay_tail_for_job(job_id) : []
  end

  # The id the NEXT job will take (issue #548): persisted so a resumed system
  # continues numbering instead of reusing an id. Read live, not snapshotted at
  # CLI#setup - a system adds jobs as it goes. A registry-less record starts at 1.
  def next_id
    (@registry&.next_id) || 1
  end

  # One system.json entry per retained job (issue #548): the system -> job map the
  # reader needs to know which job dirs a system owns, plus the per-file keys
  # /sessions reports. The index is ENUMERATION + SIZE metadata only (issue #548 E):
  # which jobs this system owns, what each was (kind/status), and its conversation
  # size - the fields a listing reads without opening a job file. The per-job DETAIL
  # (result, requested_by, dependencies) is written ONLY into the job's own job.json
  # (see #job_record), so a fact has one source. A registry-less record writes the
  # degenerate one-job system (job 0, the main turn).
  def jobs_for_save
    return degenerate_index if @registry.nil?

    @registry.jobs.map { |job| index_entry(job) }
  end

  # Write the system half (issue #548): system.json plus, for every retained job,
  # its own job.json (the per-job record: result and edges as ids) and replay.json.
  # The conversation itself is NOT here - that is the job's SessionManager's to write
  # on its own thread. This is the record half the registry owns, so it is safe
  # for the system's owner to write.
  # session_h carries identity/access that Session#to_h produced; the postures
  # and MCP summary come from what this record was built with.
  def write_system_files(locator, id, session_h)
    system_path = locator.system_file_path(id)
    FileUtils.mkdir_p(File.dirname(system_path))
    File.write(system_path, JSON.generate(system_json(id, session_h)))

    # Every retained job gets its own job.json (what it was, how it ended, its
    # edges as ids) and its own replay.json (its own main-owned buffer), so a
    # background job's record and shown output survive a resume, not just the
    # foreground one (issue #548 increments 1 and 4b). The job.json fields are read
    # off the LIVE job, not derived from the index entry (issue #548 E: no second
    # source of one fact).
    each_saved_job do |job, job_id|
      job_path    = locator.job_file_path(id, job_id)
      replay_path = locator.job_replay_file_path(id, job_id)
      FileUtils.mkdir_p(File.dirname(job_path))
      File.write(job_path, JSON.generate(job_record(job, job_id)))
      File.write(replay_path, JSON.generate(replay_tail_for_job(job_id)))
    end
  end

  private

  # The system/world half the system's owner holds (#286). access and the digest
  # cache stay here because they are system-wide TODAY (Session#restore_access_grants
  # reaches the system-wide FileList), not per-job. The four postures and
  # mcp_connected are system state, not conversation state, so each is written so
  # a resumed system keeps the choice made for THIS session, and a session saved
  # before a key existed simply has none (#221/#28/#106/#303/#405).
  # foreground_job/next_id/jobs are the system -> job map read live from the registry.
  def system_json(id, session_h)
    {
      version: session_h[:version],
      session_id: id,
      created_at: session_h[:created_at],
      workdir: session_h[:workdir],
      Session::FILE_CACHE_KEY => session_h[Session::FILE_CACHE_KEY],
      access: session_h[:access],
      yolo: posture?(:yolo?),
      stream: posture?(:stream?),
      markdown: posture?(:markdown?),
      output_palette: palette_name,
      mcp_connected: mcp_connected_summary,
      foreground_job:,
      next_id:,
      jobs: jobs_for_save
    }
  end

  # issue #405: what the run's foreground agent connected. Read off the job the
  # system record is about to describe, the same way conversation_size reads a
  # job's own harness - never off a harness handed to the writer.
  def mcp_connected_summary
    Array(@registry&.foreground_job&.harness&.mcp_connected_summary)
  end

  # A record with no registry (or none carrying settings) records the default
  # posture, exactly as a session saved before the key existed records nothing.
  def posture?(key)
    @registry&.settings&.public_send(key) == true
  end

  def palette_name
    settings = @registry&.settings
    settings ? settings.output_palette.name : UI::Palette.fetch(nil).name
  end

  # Yields [job, job_id] for every job a save records, so the index, the job.json
  # and the replay tail are all read off the SAME live job (issue #548 E: one
  # source per fact). A registry-less record yields the degenerate one-job system.
  def each_saved_job
    if @registry.nil?
      yield nil, 0
      return
    end

    @registry.jobs.each { |job| yield job, job.id }
  end

  # The system.json index entry for a job: enumeration + size metadata only. kind
  # and status live here (a listing needs them); result and the edges do NOT - they
  # belong in the job's own record. The degenerate (registry-less) main turn is a
  # job 0 :main/:pending with no conversation.
  def index_entry(job)
    return degenerate_index.first if job.nil?

    {
      id: job.id,
      kind: job.kind,
      status: job.status,
      dir: "jobs/#{job.id}",
      messages: conversation_size(job)
    }
  end

  # The job's OWN record (jobs/<id>/job.json): the per-job detail the index does
  # not carry - how it ended (result) and its edges as ids (requested_by,
  # dependencies). kind/status repeat here because this file must be readable on
  # its own (a resume reads a job dir without the index), but result/edges have a
  # single source: this file. The id -> live Job re-resolution is the next
  # increment, so a resume treats a recorded id that names no retained job as a
  # dropped edge. A dependency that is not a Job (a timed job's clock predicate, a
  # Job#ready? callable) has no id to record and is omitted until the resume path
  # can restore it as a predicate.
  def job_record(job, job_id)
    return degenerate_record if job.nil?

    {
      id: job_id,
      kind: job.kind,
      status: job.status,
      result: result_value(job),
      requested_by: job.requested_by&.id,
      dependencies: dependency_ids(job)
    }
  end

  def result_value(job)
    return job.result if JSON.parse(JSON.generate(job.result)) == job.result

    "(unserializable #{job.result.class})"
  end

  # A registry-less save records a system whose only job is 0 (the main turn): its
  # index entry and its job record, both the degenerate one-job facts.
  def degenerate_index
    [{ id: 0, kind: :main, status: :pending, dir: "jobs/0", messages: 0 }]
  end

  def degenerate_record
    {
      id: 0,
      kind: :main,
      status: :pending,
      result: nil,
      requested_by: nil,
      dependencies: []
    }
  end

  # A dependency is a Job (edge with an id) OR a callable predicate. Only the
  # former has an id to serialize; a predicate is omitted until increment 4.
  def dependency_ids(job)
    job.dependencies.filter_map { |dep| dep.id if dep.respond_to?(:id) }
  end

  # Per-job conversation size, recorded at save so /sessions and sessions.search
  # report the breakdown from metadata instead of reading every job file.
  def conversation_size(job)
    job.harness&.session&.conversation_size || 0
  end
end
