# frozen_string_literal: true

# Repro for "a run that saves nothing still leaves a session dir with a log".
# Runs from a fresh clone: run it from the repo root with
#   BUNDLE_GEMFILE=Gemfile bundle exec ruby analysis/empty-session-dir/repro.rb
# It writes NOTHING into this repo's own .harness/: the CLI is pointed at a
# throwaway workdir under the system temp dir.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "cli"
require "stringio"
require "tmpdir"

workdir = Dir.mktmpdir("empty-session-repro")
Dir.chdir(workdir) do
  cli = CLI.new(
    { workdir:, active_model: "m", model: "m" },
    UI::Console.new(stdout: StringIO.new, stdin: StringIO.new))
  cli.setup
  dir = File.join(".harness/sessions", cli.session_id)

  puts "run id:                 #{cli.session_id}"
  puts "dir right after setup:  #{Dir.exist?(dir)} contents=#{Dir.children(dir).inspect}"

  # The exit path of CLI#run, with no prompt ever sent.
  saved = cli.send(:auto_save_session, false)
  puts "auto_save_session:      #{saved.inspect}"
  puts "any_job_has_session_state?: #{cli.registry.any_job_has_session_state?}"
  puts "dir after the exit save: #{Dir.exist?(dir)} contents=#{Dir.children(dir).inspect}"

  locator = SessionLocator.new(workdir)
  listed = locator.session_dirs.map { |d| File.basename(d) }
  puts "visible to /sessions?   #{listed.include?(cli.session_id)}"
  puts "visible to --resume?    #{!locator.find_session_file(cli.session_id).nil?}"
  puts "visible to --continue?  #{locator.newest_id == cli.session_id rescue false}"
  puts "leftover dirs on disk:  #{Dir.glob('.harness/sessions/*').map { |d|
    File.basename(d)
  }.inspect}"
end
