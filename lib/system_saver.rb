# frozen_string_literal: true

require_relative "system_record"

# Writes a whole layered system once - each job's conversation, system.json and
# each job's replay.json - from the registry the system's owner holds, so a
# per-job SessionManager never assembles a file it does not own.
# Design: doc/session_layers_design.md.
class SystemSaver
  def initialize(locator, registry)
    @locator  = locator
    @record   = SystemRecord.new(registry)
    @registry = registry
  end

  attr_reader :registry

  def foreground_job
    @record.foreground_job
  end

  def write_system_files(id, session_h, harness)
    @record.write_system_files(@locator, id, session_h, harness)
  end

  # Which saved job ids the registry this saver was built from can rebuild.
  # A saved system.json reads kind/status back from JSON as Strings; the registry
  # needs only the ids, so they are pulled out here rather than re-symbolizing
  # the whole entry (a resumed Job is built with the real Job::KINDS symbol).
  def resumable_job_ids(system_jobs)
    ids = Array(system_jobs).map { |entry| entry[:id] || entry["id"] }
    @registry&.resumable_job_ids(ids) || []
  end

  # The system half is written on every call, even when no job chain is
  # non-empty: the caller has already decided the run is worth saving (a
  # settings-only change has an empty chain but must still persist).
  def save_run(run_id)
    fg = @registry.foreground_job
    @registry.jobs.each do |job|
      harness = job.harness
      next if harness.nil? || harness.session.empty?
      next if !job.equal?(fg) && !job.finished?

      harness.session_manager.job_id = job.id
      harness.session_manager.save_job_session(run_id)
    end

    harness = fg&.harness
    return run_id if harness.nil?

    session_h = harness.session.to_h(harness.file_list)
    write_system_files(run_id, session_h, harness)
    run_id
  end
end
