# frozen_string_literal: true

# Issue #344: SafetyCheck mapped verdict LINES onto commands by POSITION, so one
# extra model line shifted every verdict onto the wrong command. Run from the repo
# root: ruby analysis/344/repro.rb
#
# Expected BEFORE the fix (master before #344: the question numbered the COMMANDS
# but the shipped prompt demanded an UNNUMBERED answer - "EXACTLY one line per
# command (same order)" - and nothing verified either the count or the shape;
# whatever line came back was stored verbatim):
#   preamble answer    -> {"ruby -c a.rb" => "Here are my verdicts:",
#                          "rm -rf /tmp/x" => "safe: syntax check"}
#                         and that verdict AUTO-APPROVES the destructive command
#   prompt-shaped      -> verdicts stored verbatim as "1: safe: ..." /
#                         "2: dangerous: ...", so no verdict ever matched the
#                         consumer's /\Asafe:/ - AUTO-APPROVE silently never fired
# Expected AFTER the fix:
#   preamble answer    -> both nil (no verdict -> plain dialog), drop logged
#   prompt-shaped      -> "safe: syntax check" / "dangerous: deletes files",
#                         auto-approve fires on the safe one ONLY
require_relative "../../lib/safety_check"
require_relative "../../lib/command_runner"
require_relative "../../lib/file_list"

PREAMBLE_ANSWER = "Here are my verdicts:\nsafe: syntax check\ndangerous: deletes files"
NUMBERED_ANSWER = "1: safe: syntax check\n2: dangerous: deletes files"
COMMANDS        = ["ruby -c a.rb", "rm -rf /tmp/x"].freeze
CHAIN           = [
  { role: "system", content: "s" },
  { role: "user", content: "go" }
].freeze

def scripted_client(text)
  client = Object.new
  client.define_singleton_method(:chat) do |*_, **|
    { choices: [{ message: { content: text } }], usage: {} }
  end
  client
end

# CommandRunner#auto_approve_safe? - the consumer that decides whether a verdict
# skips the consent dialog in the AUTO-APPROVE posture.
runner = CommandRunner.new(FileList.new([], workdir: Dir.pwd), {})
approves = ->(verdict) { runner.send(:auto_approve_safe?, verdict) }

def show(label, verdicts, approves)
  puts "#{label}:"
  verdicts.each do |command, verdict|
    puts format(
      "   %-14s verdict=%-26s auto-approves=%s",
      command,
      verdict.inspect,
      approves.call(verdict))
  end
end

logged = []
logger = Object.new
logger.define_singleton_method(:info) { |msg| logged << msg }

show(
  "preamble answer",
  SafetyCheck.run(scripted_client(PREAMBLE_ANSWER), CHAIN, COMMANDS, logger:),
  approves)
show(
  "numbered answer",
  SafetyCheck.run(scripted_client(NUMBERED_ANSWER), CHAIN, COMMANDS, logger:),
  approves)

puts "dropped-verdict log lines:"
logged.each { |line| puts "   #{line}" }
