# frozen_string_literal: true

# Issue #148: a command run through a shell control-flow construct (a
# 'for ... do ... done' loop) was exploded by prefix extraction into an
# "Always allow" option PER keyword, because a tokenizer reads 'for', 'do',
# 'done', 'in' as plain words and program_token? accepted any lowercase word.
# None of those grants authorizes anything real, so the dialog was a wall of
# meaningless options.
#
# The fix blocks SHELL_RESERVED_WORDS in program_token?. Nothing is run or
# granted here - the script only DERIVES candidate prefixes, so it runs from a
# fresh clone with no local state:
#   ruby analysis/148/repro.rb
require_relative "../../lib/command_allowlist"

# The exact command from the issue report.
LOOP = "cd /c/work/own/projects/ai/harness_test && " \
  "for f in lib/cli.rb lib/session_manager.rb; do ruby -c \"$f\"; done"

# The loop's own words, in the order the old per-token rule saw them.
LOOP_WORDS = %w[for f in do done].freeze

puts "Command from the report:"
puts "  #{LOOP}"
puts
puts "Candidates offered now (CommandAllowlist.extract_prefix_options):"
CommandAllowlist.extract_prefix_options(LOOP).each { |c| puts "  #{c.inspect}" }
puts
puts "No 'for'/'do'/'done' option remains; only the real program segment."

puts
puts "Why each loop word is no longer a grant (per-token decision):"
puts format("%-10s %-22s %s", "word", "old SUBCOMMAND_TOKEN", "new program_token?")
LOOP_WORDS.each do |word|
  old = CommandAllowlist::SUBCOMMAND_TOKEN.match?(word) ? "granted" : "no"
  now = CommandAllowlist.program_token?(word, 1) ? "granted" : "blocked"
  puts format("%-10s %-22s %s", word, old, now)
end

puts
puts "A real program named like a reserved word stays grantable (path rule intact):"
%w[bin/done ./done].each do |cmd|
  puts "  #{cmd.inspect} -> #{CommandAllowlist.extract_prefix_options(cmd).inspect}"
end

puts
puts "A reserved word that is only an argument does not block its program:"
puts "  'echo done' -> #{CommandAllowlist.extract_prefix_options('echo done').inspect}"
