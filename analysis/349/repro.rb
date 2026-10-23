# frozen_string_literal: true

# Issue #349: a DENYLISTED command the user then allowed showed its FULL text
# twice - once in the pre-dialog refusal line, once in the outcome line.
# Run from the repo root: ruby analysis/349/repro.rb
# Expected (fixed): the outcome line names it by handle -
#   [run.command] ... rm -rf tmp/scratch/hist echo ... (exit 0, 0.05s)
# Before the fix that line repeated "one two three four five" a second time.
require "stringio"
require "tmpdir"
require_relative "../../lib/command_runner"
require_relative "../../lib/file_list"
require_relative "../../lib/ui/console"

Dir.mktmpdir do |dir|
  stdin  = StringIO.new("1\n") # Allow(1); a denylisted command offers no grant option
  stdout = StringIO.new
  ui        = UI::Console.new(stdout:, stdin:)
  file_list = FileList.new([], workdir: dir)
  runner    = CommandRunner.new(file_list, {}, label: "run.command", ui:)
  runner.run("rm -rf tmp/scratch/hist\necho one two three four five")

  lines = stdout.string.lines.map(&:chomp)
  puts lines
  outcome = lines.find { |l| l.include?("(exit 0") }
  repeated = outcome.to_s.include?("one two three four five (exit 0")
  verdict = repeated ? "BUG PRESENT: full command repeated" : "FIXED: handle form"
  puts "outcome line: #{outcome.inspect}"
  puts verdict
end
