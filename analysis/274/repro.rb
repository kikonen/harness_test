# frozen_string_literal: true

# Issue #274: "YOLO covers commands but not file access - I am constantly stopped
# to grant access to analysis/NNN dirs, without any way to grant recursive access
# to analysis itself". Run from the repo root:
#   ruby analysis/274/repro.rb
# What is measurable WITHOUT a model server (none exists in a checkout): whether
# each file-access mode (read, write, delete) is COVERED for a workdir path in
# the YOLO posture without a dialog, and what the posture must NEVER cover:
# a sensitive path, the owner's own space (local/), and a path outside the
# working directory. A real Logger records the audit line - an auto-approval
# that leaves no trace is invisible in the session log.
# Exit 1 when a mode stays blocked in YOLO, when the posture covers one of the
# three forbidden regions, or when the audit line is missing.
#
# Expected BEFORE the fix (master): every yolo=true row of section 1 reads
# covered=false (the posture was shell-only) and section 3 records "no audit
# line". Expected AFTER: all yolo rows covered=true, sections 2 and 3 clean.
require "logger"
require "stringio"
require "tmpdir"

require_relative "../../lib/file_list"
require_relative "../../lib/sensitive_files"

failures = []

def record_failure(list, message)
  list << message
  puts "         FAIL: #{message}"
end

def list_with(dir, yolo)
  list = FileList.new([], workdir: dir)
  # The posture hook is what the fix adds; a run against the pre-fix lib has no
  # such accessor, so the coverage rows simply report false there.
  list.posture = -> { yolo } if list.respond_to?(:posture=)
  log_io = StringIO.new
  list.audit_logger = Logger.new(log_io) if list.respond_to?(:audit_logger=)
  [list, log_io]
end

# The owner's actual pain point: a per-issue analysis dir reached file.read /
# file.search on every candidate file, and each one paid a dialog in MANUAL.
TARGETS = [
  ["analysis/274/repro.rb", :r],
  ["analysis/274/repro.rb", :w],
  ["analysis/274/repro.rb", :d],
  ["tmp/scratch/274/probe.rb", :w]
].freeze

def covered_by?(list, path, mode)
  case mode
  when :r then list.readable?(path)
  when :w then list.writable?(path)
  else list.deletable?(path)
  end
end

puts "== 1. Workdir coverage per mode and posture =="
[false, true].each do |yolo|
  Dir.mktmpdir do |dir|
    list, _log = list_with(dir, yolo)
    TARGETS.each do |path, mode|
      covered = covered_by?(list, path, mode)
      puts format("     yolo=%-5s %-6s %-24s covered=%s", yolo, mode, path, covered)
      if yolo && !covered
        record_failure(failures, "YOLO did not cover #{mode} of #{path}")
      end
      if !yolo && covered
        record_failure(failures, "MANUAL covered #{mode} of #{path} without a grant")
      end
    end
  end
end

puts
puts "== 2. What the posture must NEVER cover =="
Dir.mktmpdir do |dir|
  list, _log = list_with(dir, true)
  forbidden = [
    [".git/config", "a sensitive dir"],
    [".harness/session.json", "harness state"],
    [".env.local", "an env-named file"],
    ["local/notes.md", "the owner's own space"]
  ]
  forbidden.each do |path, why|
    covered = list.readable?(path) || list.writable?(path) || list.deletable?(path)
    puts format("     %-24s (%s) covered=%s", path, why, covered)
    record_failure(failures, "YOLO covers #{path} (#{why})") if covered
  end

  outside = File.join(File.dirname(dir), "outside-274.txt")
  covered = list.readable?(outside)
  puts format("     %-24s (outside the workdir) covered=%s", outside, covered)
  record_failure(failures, "YOLO escapes the workdir: #{outside}") if covered

  list.add_dir("local", :r)
  human = list.readable?("local/notes.md")
  puts "     human grant on local/ still works after that: covered=#{human}"
  record_failure(failures, "a human grant on local/ broke") unless human
end

puts
puts "== 3. The posture is live and leaves a trace, but is never a grant =="
Dir.mktmpdir do |dir|
  list, _log = list_with(dir, true)
  if list.respond_to?(:audit_logger=)
    log2 = StringIO.new
    list.audit_logger = Logger.new(log2)
  end
  list.readable?("analysis/274/repro.rb")
  list.readable?("analysis/274/other.rb")
  list.writable?("lib/a.rb")
  audit = log2 ? log2.string : ""
  lines = audit.lines.count { |l| l.include?("auto-granted (YOLO)") }
  puts "     audit lines for 3 covered accesses: #{lines} (expect one per mode)"
  record_failure(failures, "no audit line: an auto-approval left no trace") if lines.zero?
  record_failure(failures, "audit line per access, not per mode") if lines > 2

  stored = list.accessible_paths[:read][:files] +
    list.accessible_paths[:read][:dirs] +
    list.accessible_paths[:write][:files] +
    list.accessible_paths[:write][:dirs] +
    list.accessible_paths[:delete][:files] +
    list.accessible_paths[:delete][:dirs]
  puts "     stored grants after the coverage: #{stored.size} (expect 0)"
  unless stored.empty?
    record_failure(failures, "the posture stored a grant: #{stored.inspect}")
  end

  # Live flip on the SAME list: switching YOLO off must remove the coverage at
  # once, not leave a standing grant behind.
  state = { on: true }
  list.posture = -> { state[:on] } if list.respond_to?(:posture=)
  was_covered = list.readable?("analysis/274/repro.rb")
  state[:on] = false
  after_off = list.readable?("analysis/274/repro.rb")
  puts "     live flip: on=#{was_covered} off=#{after_off} (expect true then false)"
  record_failure(failures, "coverage survived YOLO being switched off") if after_off
end

puts
if failures.empty?
  puts "RESULT: OK - YOLO covers read/write/delete inside the workdir, " \
    "never a sensitive path, local/, or a path outside it."
  exit 0
end

puts "RESULT: #{failures.size} failure(s)"
failures.each { |f| puts " - #{f}" }
exit 1
