# frozen_string_literal: true

# Issue #376: a task-thread exception lost its backtrace. Run from the repo root:
#   ruby analysis/376/repro.rb
# A task thread owns no console (single-thread I/O rule), so an exception raised
# inside a turn block survives ONLY as the one string the drain loop carries.
# Expected BEFORE the fix (master 3d6f50f):
#   returned  : "NoMethodError: undefined method 'record' for nil"
#   harness.log: no ERROR line, no frames - the trace died with the thread
# Expected AFTER the fix:
#   returned  : the same one line (the contract is unchanged)
#   harness.log: "[ERROR] task thread raised NoMethodError: ..." plus the frames
require "fileutils"
require "stringio"
require "tmpdir"

require_relative "../../lib/harness"
require_relative "../../lib/task"
require_relative "../../lib/ui/console"

workdir = Dir.mktmpdir("issue-376")
at_exit { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

file_list = FileList.new([], workdir:)
harness   = Harness.new({ system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE }, file_list)
console   = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)

error, = Task.run(harness:, ui: console) do
  nil.record
end

lines  = File.read(harness.session_log_path).lines.map(&:chomp)
raised = lines.grep(/task thread raised/)
frames = lines.grep(/:in '/)

puts "returned  : #{error.inspect}"
puts "log ERROR : #{raised.empty? ? "(none)" : raised.first}"
puts "log frames: #{frames.size}"
puts "session log: #{harness.session_log_path.sub("#{workdir}/", "")}"

if raised.empty? || frames.empty?
  puts "RESULT: TRACE LOST - the log carries no ERROR line and no frames"
  exit 1
end

puts "RESULT: TRACE KEPT - the frames are in the session's harness.log"
