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

def contents(dir)
  Dir.exist?(dir) ? Dir.children(dir).sort : nil
end

workdir = Dir.mktmpdir("empty-session-repro")
Dir.chdir(workdir) do
  cli = CLI.new(
    { workdir:, active_model: "m", model: "m" },
    UI::Console.new(stdout: StringIO.new, stdin: StringIO.new))
  cli.setup
  id  = cli.locator.session_id
  dir = File.join(".harness/sessions", id)

  puts "run id:                 #{id}"
  puts "session dir after setup: #{Dir.exist?(dir)} contents=#{contents(dir).inspect}"
  puts "run log exists:          #{File.file?(cli.locator.session_log_path)}"
  log_rel = cli.locator.relative_path(cli.locator.session_log_path)
  puts "run log relative path:   #{log_rel}"

  # The exit path of CLI#run, with no prompt ever sent.
  saved = cli.send(:auto_save_session, false)
  puts "auto_save_session:       #{saved.inspect}"
  puts "any_job_has_session_state?: #{cli.registry.any_job_has_session_state?}"
  puts "session dir after exit:  #{Dir.exist?(dir)} contents=#{contents(dir).inspect}"

  locator = SessionLocator.new(workdir)
  listed  = locator.session_dirs.map { |d| File.basename(d) }
  puts "visible to /sessions?    #{listed.include?(id)}"
  puts "visible to --resume?     #{(locator.find_session_file(id) rescue nil) != nil}"
  puts "visible to --continue?   #{(locator.newest_id == id) rescue false}"
  puts "leftover session dirs:   #{Dir.glob('.harness/sessions/*').map { |d|
    File.basename(d)
  }.inspect}"
end
