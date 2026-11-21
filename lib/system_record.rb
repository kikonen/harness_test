# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "session"

# The system's own persistence record - the system/world half of what a save
# writes (issue #548). Built by the system's owner (the CLI, from the JobRegistry
# it owns) and injected into SessionManager in place of the raw registry, so a
# per-Harness SessionManager no longer reaches a scheduling registry it does not
# own (doc/harness_job_design.md: "its owner injects it").
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

  # One system.json entry per retained job (issue #548). The system -> job map and
  # the job list the reader needs to know which job dirs a system owns. EDGES ARE
  # SERIALIZED AS IDS here (a Job reference is not JSON): requested_by and
  # dependencies become int ids. Re-resolving those ids back to live Jobs on
  # resume is increment 4's work - increment 2 only writes the ids. A dependency
  # that is not a Job (a timed job's clock predicate, a Job#ready? callable) has
  # no id to record and is omitted: it cannot be re-resolved as a job edge until
  # increment 4 gives the resume path a predicate-restoring form. A registry-less
  # record writes the degenerate one-job system (job 0, the main turn).
  def jobs_for_save
    return degenerate_job if @registry.nil?

    @registry.jobs.map do |job|
      {
        id: job.id,
        kind: job.kind,
        status: job.status,
        requested_by: job.requested_by&.id,
        dependencies: dependency_ids(job),
        dir: "jobs/#{job.id}",
        messages: conversation_size(job)
      }
    end
  end

  # Write the system half (issue #548 increment 4a): system.json and the
  # foreground job's replay.json. The conversation itself is NOT here - that is
  # the job's SessionManager's to write on its own thread. This is the record
  # half the registry owns, so it is safe for the system's owner to write.
  # `harness` supplies the system-wide postures and the MCP summary live;
  # session_h carries identity/access that Session#to_h produced.
  def write_system_files(locator, id, session_h, harness)
    system_path = locator.system_file_path(id)
    FileUtils.mkdir_p(File.dirname(system_path))
    File.write(system_path, JSON.generate(system_json(id, session_h, harness)))

    # Every retained job writes its own replay.json (its own main-owned buffer),
    # so a background job's shown output survives a resume, not just the
    # foreground one (issue #548 increment 4b).
    jobs_for_save.each do |entry|
      replay_path = locator.job_replay_file_path(id, entry[:id])
      FileUtils.mkdir_p(File.dirname(replay_path))
      File.write(replay_path, JSON.generate(replay_tail_for_job(entry[:id])))
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
  def system_json(id, session_h, harness)
    {
      version: session_h[:version],
      session_id: id,
      created_at: session_h[:created_at],
      workdir: session_h[:workdir],
      Session::FILE_CACHE_KEY => session_h[Session::FILE_CACHE_KEY],
      access: session_h[:access],
      yolo: harness.settings.yolo? == true,
      stream: harness.settings.stream? == true,
      markdown: harness.settings.markdown? == true,
      output_palette: harness.settings.output_palette.name,
      mcp_connected: harness.mcp_connected_summary,
      foreground_job:,
      next_id:,
      jobs: jobs_for_save
    }
  end

  # A registry-less save records a system whose only job is 0 (the main turn).
  def degenerate_job
    [
      {
        id: 0,
        kind: :main,
        status: :pending,
        requested_by: nil,
        dependencies: [],
        dir: "jobs/0",
        messages: 0
      }
    ]
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
