# frozen_string_literal: true

# Repro for "there is no way to delete a job": what a delete would have to answer.
# From a fresh clone:
#   BUNDLE_GEMFILE=Gemfile bundle exec ruby analysis/jobs-delete/repro.rb
# Writes only into a throwaway workdir under the system temp dir.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "cli"
require "stringio"
require "tmpdir"

def tree(workdir, id)
  dirs = Dir.glob(File.join(workdir, ".harness/sessions/#{id}/jobs/*")).map do |d|
    File.basename(d).to_i
  end.sort
  index_path = File.join(workdir, ".harness/sessions/#{id}/system.json")
  index = JSON.parse(File.read(index_path))["jobs"].map { |j| j["id"] }.sort
  files = Dir.glob(File.join(workdir, ".harness/sessions/#{id}/jobs/*/*")).map do |f|
    File.basename(f)
  end.sort.uniq
  [dirs, index, files]
end

reg = JobRegistry.new(tasks_kept: nil)
main = reg.add_job(kind: :main)
child = reg.add_job(kind: :sub_agent, requested_by: main)

# 1. A running job has a live thread of its own and the registry has no way to stop it.
job = reg.add_job(kind: :sub_agent, requested_by: main)
thread = Thread.new { sleep 5 }
job.mark_running
puts "1. running job: thread alive=#{thread.alive?} status=#{job.status} " \
  "finished?=#{job.finished?}"
puts "   registry methods that stop/delete a job: " \
  "#{JobRegistry.instance_methods.grep(/stop|kill|cancel|delete|remove|drop/).inspect}"
thread.kill

# 2. A job waiting on a dialog answer owes its thread a value.
awaiting = reg.add_job(kind: :sub_agent, requested_by: main)
awaiting.mark_running
awaiting.mark_awaiting(true)
puts "2. awaiting job: awaiting?=#{awaiting.awaiting?} inbox=#{awaiting.inbox.size}"

# 3. requested_by is a live Job object, and finish() answers it through its inbox.
puts "3. child.requested_by is #{child.requested_by.class} ##{child.requested_by.id}"
child.finish("result-for-main")
puts "   requester's inbox after the finish: #{main.inbox.size}"

workdir = Dir.mktmpdir("jobs-delete-repro")
Dir.chdir(workdir) do
  opts = { workdir:, active_model: "tm", model_profiles: [{ name: "tm", model: "tm" }] }

  # 4. What a delete has to remove on disk: the index entry AND the whole job dir.
  run = CLI.new(opts, UI::Console.new(stdout: StringIO.new))
  run.setup
  sub = run.harness_factory.add_harness_job(
    kind: :sub_agent, session_id: run.session_id, requested_by: run.registry.job(0))
  sub.finish("done")
  id = run.session_id
  run.system_saver.save_run(id)
  dirs, index, files = tree(workdir, id)
  puts "4. live jobs=#{run.registry.jobs.map(&:id).inspect} index=#{index.inspect} " \
    "dirs=#{dirs.inspect} job files=#{files.inspect}"

  # 5. The only existing drop path is the retention rule: it removes a FINISHED,
  # non-foreground job from the registry, and its dir stays on disk (#557).
  kept = CLI.new(opts.merge(output_tasks_kept: 1), UI::Console.new(stdout: StringIO.new))
  kept.setup
  dropped = 2.times.map do
    j = kept.harness_factory.add_harness_job(
      kind: :sub_agent, session_id: kept.session_id, requested_by: kept.registry.job(0))
    j.finish("done")
    j
  end
  kept_id = kept.session_id
  kept.system_saver.save_run(kept_id)
  kept_dirs, kept_index, _ = tree(workdir, kept_id)
  puts "5. retention drops #{dropped.map(&:id).inspect}: registry now " \
    "#{kept.registry.jobs.map(&:id).inspect}, index #{kept_index.inspect}, " \
    "dirs #{kept_dirs.inspect}"

  # 6. A deleted/dropped job cannot be made foreground: the registry raises, so
  # deleting the foreground job has no defined outcome today.
  begin
    kept.registry.foreground = dropped.first.id
  rescue ArgumentError => e
    puts "6. making a dropped job foreground: #{e.message}"
  end
end
