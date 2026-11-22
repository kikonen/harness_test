# frozen_string_literal: true

# Repro for "dropped jobs leave their jobs/<id>/ dir on disk forever".
# From a fresh clone:
#   BUNDLE_GEMFILE=Gemfile bundle exec ruby analysis/stale-job-dirs/repro.rb
# Writes only into a throwaway workdir under the system temp dir.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "cli"
require "stringio"
require "tmpdir"

workdir = Dir.mktmpdir("stale-job-repro")
Dir.chdir(workdir) do
  opts = {
    workdir:,
    active_model: "tm",
    model_profiles: [{ name: "tm", model: "tm" }]
  }

  # Run 1: five sub-agent jobs. Each finish runs the retention rule (tasks_kept: 2),
  # so jobs 1-3 are dropped out of the registry WHILE the run is still adding
  # jobs - the order a real session gets into. The final save therefore writes an
  # index of [0, 4] only, but jobs/1..3 were already written by earlier saves.
  run1 = CLI.new(opts.merge(output_tasks_kept: 2), UI::Console.new(stdout: StringIO.new))
  run1.setup
  main = run1.registry.job(0)
  4.times.map do
    job = run1.harness_factory.add_harness_job(
      kind: :sub_agent, session_id: run1.session_id, requested_by: main)
    # A save while all five jobs are still retained writes all five job dirs.
    run1.system_saver.save_run(run1.session_id) if job.id == 2
    job.finish("done")
    job
  end
  main.finish("main done")
  id = run1.session_id
  puts "run 1 registry after the drop rule: #{run1.registry.jobs.map(&:id).inspect}"
  run1.system_saver.save_run(id)

  dirs = Dir.glob(".harness/sessions/#{id}/jobs/*").map { |d| File.basename(d).to_i }.sort
  index = JSON.parse(File.read(".harness/sessions/#{id}/system.json"))["jobs"].map { |j|
    j["id"]
  }.sort
  puts "saved index ids:   #{index.inspect}"
  puts "jobs/ dirs on disk: #{dirs.inspect}"
  puts "STALE dirs (no index entry): #{(dirs - index).inspect}"

  # Run 2: resume it. The resume rebuilds the INDEX jobs only, and a save
  # writes what the live registry holds - the stale dirs are never touched.
  run2 = CLI.new(opts.merge(resume: id), UI::Console.new(stdout: StringIO.new))
  run2.setup
  puts "run 2 rebuilt jobs: #{run2.registry.jobs.map(&:id).inspect}"
  run2.system_saver.save_run(id)
  dirs2 = Dir.glob(".harness/sessions/#{id}/jobs/*").map { |d|
    File.basename(d).to_i
  }.sort
  puts "jobs/ dirs after re-save: #{dirs2.inspect}"
  puts "stale after re-save:      #{(dirs2 - index).inspect}"
end
