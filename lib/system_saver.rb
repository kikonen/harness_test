# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "system_record"

# Writes a whole layered system once - each job's conversation, system.json and
# each job's replay.json - from the registry the system's owner holds, so a
# per-job SessionManager never assembles a file it does not own. It is also the
# read side of the same layered record: a resume restores job state through it.
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

  def write_system_files(session_h)
    @record.write_system_files(@locator, session_h)
  end

  # Every job with a saved conversation dir: its own chain half, kind, status and
  # shown tail. The saved system id is passed in: this object is built before the
  # CLI has resolved one, and a resume reads the jobs of the session it resumed.
  def job_restores
    @locator.job_restores
  end

  # The saved shown tail of a job (its own replay.json), for the foreground
  # buffer a resumed run redraws. [] when the job has no replay.json.
  def replay_tail_of(job_id)
    tail_path = @locator.job_replay_file_path(job_id)
    return [] unless File.file?(tail_path)

    JSON.parse(File.read(tail_path), symbolize_names: true)
  end

  # Saved job ids with no live Job under them: dropped by the retention rule, or
  # not rebuilt by this resume. The edges naming them stay dangling.
  def dropped_job_ids
    job_restores.map { |restore| restore[:id] }.reject do |job_id|
      @registry&.job(job_id)
    end
  end

  # Remove ONE job from a saved system: unlink the index entry before rm_rf so
  # a crash between the two leaves a recoverable orphan dir, never a dangling
  # id a resume tries to rebuild ("The drop rule", doc/session_layers_design.md).
  def remove_job(job_id)
    path = @locator.system_file_path
    if File.file?(path)
      system = JSON.parse(File.read(path), symbolize_names: true)
      system[:jobs] = Array(system[:jobs]).reject do |entry|
        (entry[:id] || entry["id"]) == job_id
      end
      File.write(path, JSON.generate(system))
    end

    FileUtils.rm_rf(@locator.job_dir(job_id))
    registry&.remove_job(registry&.job(job_id))
    job_id
  end

  # The system half is written on every call, even when no job chain is
  # non-empty: the caller has already decided the run is worth saving (a
  # settings-only change has an empty chain but must still persist).
  def save_run
    # A save is the SYSTEM's write: system.json plus every retained job's own
    # files, in ONE call by the run's owner. A SessionManager never assembles
    # this - system.json carries the SYSTEM's access list and digest cache, and
    # each job Harness has its own SessionFileCache.
    #
    # Every job with an agent is written, whatever its status: a job that ran a
    # turn and was never :done is still :pending, so gating on finished? left
    # background chains unwritten and the resume with nothing to rebuild (#548).
    # Marking such a job :finished so it would save is the wrong fix - Job#finish
    # delivers its result to a live requester. A job with an empty chain is still
    # written: its job.json and model state have to survive, and whether the run
    # is worth saving at all is JobRegistry#any_job_has_session_state?'s question.
    #
    # THREADING: reading a job's messages from the main thread is safe only when
    # no thread is mutating them, and a save point has none - the exit save runs
    # after every job thread is joined, and a mid-run save of a RUNNING job goes
    # through Job#request_save so that job writes its own jobs/<id>/session.json
    # on its own thread.
    @registry.jobs.each do |job|
      harness = job.harness
      next if harness.nil?

      harness.session_manager.job_id = job.id
      harness.session_manager.save_job_session
    end

    # The system half describes the system through its foreground job: the
    # foreground carries the run's own FileList, so its to_h is where the system's
    # access list, digest cache and workdir come from.
    harness = @registry.foreground_job&.harness
    return @locator.session_id if harness.nil?

    write_system_files(harness.session.to_h(harness.file_list))
    # Must run after the index is written: it is the enumeration of what survives.
    prune_stale_job_dirs
    @locator.session_id
  end

  # Prune saved job dirs the freshly-written index no longer names (#557).
  # Enumerate dirs from DISK, not the index: a resumed job rebuilt from disk
  # stays in @jobs, so its dir is in that index and is never a candidate.
  def prune_stale_job_dirs
    return unless @locator.system_dir?

    index = Array(@locator.read_system[:jobs]).filter_map do |entry|
      entry[:id] || entry["id"]
    end
    jobs_dir = File.join(@locator.session_dir, SessionLocator::JOBS_DIR)
    return unless File.directory?(jobs_dir)

    Dir.glob(File.join(jobs_dir, "*")).each do |path|
      next unless File.directory?(path)

      FileUtils.rm_rf(path) unless index.include?(File.basename(path).to_i)
    end
  end
end
