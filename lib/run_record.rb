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
end
