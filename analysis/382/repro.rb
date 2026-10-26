# frozen_string_literal: true

# Issue #382: "safe check logic is forcibly blocked by disaster commands logic".
# Run from the repo root:
#   ruby analysis/382/repro.rb
# What is measurable WITHOUT a model server (none exists in a checkout): WHICH
# postures run the model safety check for a DENYLISTED command, and whether the
# verdict it produced REACHES the consent dialog. That is the trial contract - a
# verdict cannot be judged against a disaster command it is never shown for.
# Exit 1 when a posture the check is enabled for shows no verdict, when the
# denylist floor moves, or when YOLO pays for a batch pre-check whose verdicts it
# cannot consume.
#
# Expected BEFORE the fix (master f105463): sections 1 and 2 already pass (the
# verdict on a denylist dialog was behaviour, never a defect) but section 3's YOLO
# row reads chat_calls=1 - a forked LLM round trip paid for verdicts that are then
# thrown away. Expected AFTER: chat_calls=0 with the skip logged.
require "json"
require "stringio"
require "tmpdir"

require_relative "../../lib/harness"
require_relative "../../lib/command_runner"
require_relative "../../lib/command_allowlist"
require_relative "../../lib/file_list"
require_relative "../../lib/task"
require_relative "../../lib/ui/console"

CHAIN = [
  {
    role: "system",
    content: "sys"
  },
  {
    role: "user",
    content: "do the thing"
  },
  {
    role: "assistant",
    content: nil,
    tool_calls: [{ id: "c1", function: { name: "run.command", arguments: "{}" } }]
  }
].freeze

MessagesOnly = Struct.new(:messages)

# Records every chat call; answers with a canned verdict line.
class FakeClient
  attr_reader :calls

  def initialize(answer)
    @answer = answer
    @calls  = []
  end

  def chat(_messages, tools: nil, **_kwargs)
    @calls << tools
    { choices: [{ message: { content: @answer } }] }
  end
end

# The posture surface CommandRunner consults on the tool path: the live YOLO flag,
# the AUTO-APPROVE gate, the client the check would use, and the chain to fork.
Posture = Struct.new(
  :client,
  :logger,
  :session,
  :yolo?,
  :command_safety_auto_approve_effective?,
  :tools_payload)

PAYLOAD = [{ type: "function", function: { name: "run.command" } }].freeze

def posture_double(client:, yolo:, auto_approve:)
  Posture.new(client, nil, MessagesOnly.new(CHAIN), yolo, auto_approve, PAYLOAD)
end

# A TOOL-path runner (list: :tool, so the YOLO posture applies) served on a console
# we can read: a real dialog over real stdin, nothing stubbed. stdin carries one
# "2" = Cancel, so a command that reaches a dialog must end denied.
def tool_runner(dir, options, harness)
  stdin  = StringIO.new("2\n")
  stdout = StringIO.new
  console = UI::Console.new(
    stdout:,
    stdin:)
  runner = CommandRunner.new(
    FileList.new([], workdir: dir),
    options,
    harness:,
    ui: console,
    list: :tool)
  [runner, stdout]
end

# Every entry MUST be denylisted - section 1 asserts that up front, so a command
# that stopped matching (a pattern change) fails here instead of silently testing
# the non-denylist path. The label comes FROM the code (disaster_label): its exact
# wording is the code's business (git push -f reports "git push", mkfs.ext4 "mkfs.").
DISASTERS = [
  ["rm -rf tmp/scratch/x", "1: safe: removes only a scratch dir"],
  ["sudo rm something", "1: dangerous: escalates privileges"],
  ["git push -f origin master", "1: dangerous: rewrites shared history"],
  ["mkfs.ext4 /dev/sda1", "1: dangerous: destroys the filesystem"]
].freeze

POSTURES = [
  ["MANUAL", false, false],
  ["AUTO-APPROVE", false, true],
  ["YOLO", true, false]
].freeze

failures = []

# Records one broken assertion: the list drives the exit code, the line says
# which posture failed and why.
def record_failure(list, message)
  list << message
  puts "         FAIL: #{message}"
end

def verdict_shown?(stdout)
  stdout.string.include?("MODEL VERDICT (advisory)")
end

puts "== 1. Does a denylisted command's dialog carry the model verdict? =="
puts "   command_safety_check: true (the check's own gate); Cancel typed every time"

POSTURES.each do |posture, yolo, auto_approve|
  puts "  -- #{posture}"
  Dir.mktmpdir do |dir|
    DISASTERS.each do |command, answer|
      label = CommandAllowlist.disaster_label(command)
      record_failure(failures, "#{command} is no longer denylisted") \
        if label.to_s.strip.empty?

      client = FakeClient.new(answer)
      h      = posture_double(client:, yolo:, auto_approve:)
      runner, stdout = tool_runner(dir, { command_safety_check: true }, h)
      result  = runner.run(command)
      asked   = stdout.string.include?("The model is requesting")
      checked = client.calls.size.positive?
      verdict = verdict_shown?(stdout)
      auto    = stdout.string.include?("auto-approved")
      denied  = result.start_with?("error: user denied")

      puts format(
        "     %-26s asked=%-5s checked=%-5s verdict=%-5s auto=%-5s",
        command[0, 26],
        asked,
        checked,
        verdict,
        auto)

      tag = "#{posture} / #{command}"
      record_failure(failures, "#{tag}: dialog did not open") unless asked
      record_failure(failures, "#{tag}: verdict not shown")   unless verdict
      record_failure(failures, "#{tag}: FLOOR BROKEN (auto-approved)") if auto
      record_failure(failures, "#{tag}: cancel did not deny") unless denied
      record_failure(failures, "#{tag}: denylist label missing") \
        unless stdout.string.include?("DENYLISTED: #{label}")
    end
  end
end

puts
puts "== 2. The same commands with command_safety_check OFF (the gate) =="
Dir.mktmpdir do |dir|
  POSTURES.each do |posture, yolo, auto_approve|
    command, answer = DISASTERS.first
    client = FakeClient.new(answer)
    h      = posture_double(client:, yolo:, auto_approve:)
    runner, stdout = tool_runner(dir, {}, h)
    runner.run(command)
    checked = client.calls.size.positive?
    verdict = verdict_shown?(stdout)
    puts format("     %-13s checked=%-5s verdict=%-5s", posture, checked, verdict)
    record_failure(failures, "#{posture}: check ran with the option off") if checked
    record_failure(failures, "#{posture}: verdict shown with the option off") if verdict
  end
end

puts
puts "== 3. Does YOLO pay for a batch pre-check it cannot consume? (the #238 cost) =="

def batch_calls(harness)
  commands = ["echo one", "echo two"]
  calls = commands.each_with_index.map do |c, i|
    {
      id: "c#{i + 1}",
      function: { name: "run.command", arguments: JSON.dump(command: c) }
    }
  end
  harness.precheck_batch_safety(calls)
end

def harness_with_check(dir, yolo)
  options = {
    system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE,
    num_ctx: 65_536,
    command_safety_check: true,
    yolo:
  }
  Harness.new(options, FileList.new([], workdir: dir))
end

[[false, "MANUAL / AUTO-APPROVE"], [true, "YOLO"]].each do |yolo, label|
  Dir.mktmpdir do |dir|
    client = FakeClient.new("1: safe: a\n2: safe: b")
    h = harness_with_check(dir, yolo)
    h.instance_variable_set(:@client, client)
    h.session.add_user("go")
    verdicts = batch_calls(h)
    puts format(
      "     yolo=%-5s chat_calls=%d verdicts_cached=%-5s",
      yolo,
      client.calls.size,
      !verdicts.nil?)
    if yolo
      paid = client.calls.size
      if paid.positive?
        record_failure(failures, "YOLO paid #{paid} batch call(s) it cannot use")
      end
      unless verdicts.nil?
        record_failure(failures, "YOLO cached verdicts it cannot consume")
      end
      log = File.read(h.session_log_path)
      skip_note = "safety pre-check skipped"
      record_failure(failures, "the skip was not logged") unless log.include?(skip_note)
    else
      record_failure(failures, "#{label} lost its pre-check") if client.calls.size.zero?
      record_failure(failures, "#{label} cached no verdicts") if verdicts.nil?
    end
  end
end

puts
if failures.empty?
  puts "RESULT: TRIAL CONTRACT HOLDS - every posture that enables the check shows its"
  puts "        verdict on a denylist dialog, the floor never moves, and YOLO pays for"
  puts "        no batch check it cannot consume."
  puts
  puts "LIVE TRIAL (the half a checkout cannot do - it needs your server):"
  puts "  command_safety_check: true in the config, then in the session:"
  puts "    /yolo on     (or Ctrl+A for AUTO-APPROVE)"
  puts "  and ask for a denylist-shaped command, e.g."
  puts "    'clean up tmp/scratch/<n> with rm -rf', 'undo a push with git push -f'."
  puts "  Judge the MODEL VERDICT (advisory) line on that dialog. harness.log carries"
  puts "  the same verdict and every drop reason, so a whole batch can be audited after"
  puts "  the fact: grep 'safety pre-check' and 'safety check:' in the session log."
  exit 0
end

puts "RESULT: TRIAL CONTRACT BROKEN (#{failures.size} problem(s))"
exit 1
