# frozen_string_literal: true

# Issue #417: a path-shaped command (bin/rspec, bin/harness, ./script.sh) can
# never be offered an "Always allow" grant, and the disaster gate does not see a
# recursive-force rm invoked BY PATH. Nothing here is EXECUTED - the script only
# CLASSIFIES strings. Run from the repo root: ruby analysis/417/repro.rb
#
# BEFORE (master b1ce5f5/424c272):
#   disaster?("bin/rm -rf /")       == false   (the gate matches the bare token "rm")
#   extract_prefix_options("bin/rspec") == []   (no candidate -> no "Always allow" option)
#   extract_prefix_options("bin/rspec spec/x -e y")
#     == ["bin/rspec spec/x -e"]    (a grant that authorizes exactly THAT invocation)
#   CommandRunner inferred "UNSAFE: contains shell constructs" from the empty list.
#
# AFTER:
#   the basename of a path token is the verb (rm/rd/del...), so bin/rm -rf / is
#   denylisted; a leading PATH program is a candidate and its DIRECTORY glob
#   (bin/*) is offered; the UNSAFE note only appears for a real danger token or a
#   parse failure.
require_relative "../../lib/command_allowlist"
require "tmpdir"

PATH_DISASTERS = [
  "bin/rm -rf /", "./rm -rf tmp", "/usr/bin/rm -r -f x",
  %q(C:\work\bin\rm.exe -rf x), %q("rm" -rf /), %q("/usr/bin/rm" -rf /)
].freeze

ONE_FLAG = ["bin/rm -r tmp", "bin/rm -f x"].freeze

QUOTED_PHRASES = [
  %q(git commit -m "bin/rm -rf x"), %q(echo "rm -rf /")
].freeze

GRANTABLE = [
  "bin/rspec", "bin/harness", "bin/rspec spec/",
  "bin/rspec spec/lib/task_spec.rb -e x"
].freeze

NO_GLOB = ["./script.sh", "bin/../evil", "bin//evil", "~/bin/tool"].freeze

puts "== 1. recursive-force rm invoked by path =="
(PATH_DISASTERS + ONE_FLAG + QUOTED_PHRASES).each do |cmd|
  puts "  %-38s disaster?=%s" % [cmd, CommandAllowlist.disaster?(cmd).inspect]
end

puts "\n== 2. grantable candidates for a path-shaped command =="
GRANTABLE.each do |cmd|
  puts "  %-40s -> %s" % [cmd, CommandAllowlist.extract_prefix_options(cmd).inspect]
end

puts "\n== 3. no glob for a current-dir / traversing / malformed directory =="
NO_GLOB.each do |cmd|
  puts "  %-24s -> %s" % [cmd, CommandAllowlist.extract_prefix_options(cmd).inspect]
end

puts "\n== 4. a stored 'bin/*' covers every DIRECT program of that directory =="
Dir.mktmpdir do |dir|
  list = CommandAllowlist.new(dir)
  list.add("bin/*")
  [
    "bin/rspec", "bin/harness", "bin/rspec spec/", "tools/build",
    "bin/deep/tool", "bin/../evil", "bin//evil"
  ].each do |seg|
    puts "  bin/* covers %-16s -> %s" % [seg, list.allowed?(seg)]
  end
end

puts "\n== 5. what a 'bin/*' grant TRUSTS (dialog note) =="
puts "  glob_note('bin/*')     = #{CommandAllowlist.glob_note('bin/*').inspect}"
puts "  glob_note('bin/rspec') = #{CommandAllowlist.glob_note('bin/rspec').inspect}"
