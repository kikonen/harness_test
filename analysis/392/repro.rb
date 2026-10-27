# frozen_string_literal: true

# Issue #392: the denylist sees only the command STRING. A POSIX payload inside a
# quoted argument is invisible to it, and the two-step bypass (write a script with
# file.write, then execute it) defeats it entirely. Nothing here is EXECUTED - the
# script only CLASSIFIES strings. Run from the repo root: ruby analysis/392/repro.rb
#
# Expected (master, measured):
#   1. direct unquoted rm -fr / -r -f / --recursive --force  -> FLAGGED
#      find . -mindepth 1 -delete, and base64 | sh           -> NOT FLAGGED
#   2. the same payload quoted: NOT FLAGGED unless a marker word (sudo, mkfs)
#      carries it; the Windows twins ARE flagged (whole-text lookahead)
#   3. executing a script: NOT FLAGGED for every interpreter form
#   4. with a stored prefix, step 2 auto-approves - no dialog, no verdict
require "tmpdir"
require_relative "../../lib/command_allowlist"

DIRECT = [
  "rm -fr ~/ --one-file-system",
  "rm -rf /home/kari",
  "rm -r -f .",
  "rm --recursive --force .",
  "find . -mindepth 1 -delete",
  "find . -exec rm -rf {} +",
  "echo cm0gLWZyIH4v | base64 -d | sh"
].freeze

QUOTED = [
  %q{sh -c "rm -fr ~/"},
  %q{bash -c "rm -rf /home/kari"},
  %q{ruby -e "system(%q{rm -fr ~/})"},
  %q{perl -e "system qq{rm -fr ~/}"},
  %q{python3 -c "import shutil; shutil.rmtree('/home/kari')"},
  %q{sh -c "find . -mindepth 1 -delete"},
  %q{bash -c "sudo rm -rf /home/kari"},
  %q{sh -c "mkfs.ext4 /dev/sda1"},
  %q{cmd //c "del /q /s C:\work\*"},
  %q{powershell -Command "Remove-Item -Recurse -Force C:\work"}
].freeze

STEP2 = [
  "ruby tmp/evil.rb",
  "bash tmp/evil.sh",
  "sh tmp/evil.sh",
  "python3 tmp/evil.py",
  "chmod +x tmp/evil && ./tmp/evil",
  %q{ruby -e "system(%q{rm -fr ~/})"},
  %q{sh -c "rm -fr ~/"}
].freeze

def classify(title, cmds)
  puts "== #{title} =="
  cmds.each do |cmd|
    flagged = CommandAllowlist.disaster?(cmd)
    label = flagged ? CommandAllowlist.disaster_label(cmd) : ""
    puts format("  %-52s %-12s %s", cmd, flagged ? "FLAGGED" : "NOT FLAGGED", label)
  end
  puts
end

classify("1. direct, unquoted", DIRECT)
classify("2. same payload inside a quoted shell/interpreter argument", QUOTED)

puts "== 3. step 2: execute a script the model wrote (file.write needs no run.command) =="
STEP2.each do |cmd|
  puts format("  %-52s disaster?=%-5s", cmd, CommandAllowlist.disaster?(cmd))
end
puts

# Each prefix in its OWN allowlist: CommandAllowlist persists to a file in its
# directory, so a shared tmpdir accumulates prefixes and reads as a cross-match.
%w[ruby bash sh].each do |prefix|
  Dir.mktmpdir do |dir|
    list = CommandAllowlist.new(dir)
    list.add(prefix)
    puts "== 4. stored prefix #{prefix.inspect} (fresh allowlist) =="
    STEP2.each { |cmd| puts format("  %-50s allowed?=%s", cmd, list.allowed?(cmd)) }
    puts
  end
end
