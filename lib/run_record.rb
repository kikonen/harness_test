# frozen_string_literal: true

# The run's own persistence record - the run/world half of what save_session
# writes (issue #548 increment 1). Built by the run's owner (the CLI, from the
# JobRegistry it owns) and injected into SessionManager in place of the raw
# registry, so a per-Harness SessionManager no longer reaches a scheduling
# registry it does not own (doc/harness_job_design.md: "its owner injects it").
#
# Increment 1 keeps the single-file layout: RunRecord only supplies the keys the
# registry owns - the foreground job id and the foreground buffer's replay tail -
# read live so a save records the registry as it is at save time, not a snapshot
# taken at CLI#setup (jobs are added and the foreground switches during a run).
class RunRecord
  def initialize(registry)
    @registry = registry
  end

  # The job that was foreground at save (issue #286); a resumed run restores
  # which buffer was active from this id.
  def foreground_job
    @registry.foreground
  end

  # The saved tail of the foreground job's buffer (issue #458), the shape
  # JobRegistry#replay_tail_for_save produces.
  def replay_tail
    @registry.replay_tail_for_save
  end

  # The id the NEXT job will take (issue #548): persisted so a resumed run
  # continues numbering instead of reusing an id. read live, not snapshotted at
  # CLI#setup - a run adds jobs as it goes.
  def next_id
    @registry.next_id
  end

  # One run.json entry per retained job (issue #548). The run -> agent map and
  # the job list the reader needs to know which job dirs a run owns. EDGES ARE
  # SERIALIZED AS IDS here (a Job reference is not JSON): requested_by and
  # dependencies become int ids. Re-resolving those ids back to live Jobs on
  # resume is increment 4's work - increment 2 only writes the ids. A dependency
  # that is not a Job (a timed job's clock predicate, a Job#ready? callable) has
  # no id to record and is omitted: it cannot be re-resolved as a job edge until
  # increment 4 gives the resume path a predicate-restoring form.
  def jobs_for_save
    @registry.jobs.map do |job|
      {
        id: job.id,
        kind: job.kind,
        status: job.status,
        requested_by: job.requested_by&.id,
        dependencies: dependency_ids(job),
        dir: "jobs/#{job.id}"
      }
    end
  end

  # A dependency is a Job (edge with an id) OR a callable predicate. Only the
  # former has an id to serialize; a predicate is omitted until increment 4.
  def dependency_ids(job)
    job.dependencies.filter_map { |dep| dep.id if dep.respond_to?(:id) }
  end
end
