# frozen_string_literal: true

# Issue #389: "command_safety_auto_approve: denylist" - let a model "safe:" verdict
# auto-approve a DENYLISTED command, so a disaster word sitting inert inside a
# quoted string stops costing a one-off Allow dialog. Run from the repo root:
#   ruby analysis/389/repro.rb
# Rationale and the design decisions: doc/denylist_safe_approve_design.md.
# Three claims to measure WITHOUT a model server (none exists in a checkout):
#
#  1. WHY the relaxation is gated on the model verdict, not on quote-awareness of
#     the denylist itself. disaster? matches the RAW command text, so it flags
#     BOTH an inert quoted word (`echo "sudo ..."`) AND an executed payload
#     (`sh -c "mkfs.ext4 ..."`). A naive "quote-aware" fix - strip quoted spans,
#     then match - silences the false positive AND un-flags the real payload: a
#     detection hole. The model verdict is the discriminator instead (inert word
#     -> safe:, executed payload -> dangerous:), so detection is never weakened;
#     only the OUTCOME for a real safe: verdict changes.
#
#  2. The override's firing conditions, driven through CommandRunner with a verdict
#     INJECTED on options (no client, no LLM call):
#       option ON  + tool path + safe       -> auto-approved (override fires)
#       option ON  + tool path + dangerous  -> dialog (floor intact)
#       option ON  + tool path + no verdict -> dialog (floor intact)
#       option OFF + tool path + safe       -> dialog (default unchanged)
#       option ON  + BANG path + safe       -> dialog (override never covers !)
#     Every override run writes a harness.log line naming the verdict and the
#     option that allowed it (the status line is Task-only, so this probe, which
#     runs outside a Task, observes the log rather than the console).
#
#  3. The SHIPPED config shape: command_safety_auto_approve as ONE enum key
#     (manual | safe | denylist | safe_denylist), a legacy true/false still read
#     as safe/manual, the separate denylist boolean ORed in, and an unrecognised
#     mode raising rather than falling back silently. This is what a user writes,
#     so the probe drives the override through the parsed config rather than
#     through a hand-written options hash.
#
# Exit 1 when a claim fails. EXPECTED BEFORE the fix (master): section 2's first
# row reads ran-no-dialog=false (master ignores the option, so the floor always
# asks), the override log line is absent, and section 3 has no enum to read.
# EXPECTED AFTER: ran-no-dialog=true with the override log line, and every mode
# mapping as tabulated. Section 1 is identical on both trees (the denylist
# itself is unchanged by #389).
require "logger"
require "stringio"
require "tmpdir"

require_relative "../../lib/command_allowlist"
require_relative "../../lib/command_runner"
require_relative "../../lib/file_list"
require_relative "../../lib/ui/console"
require_relative "../../lib/harness_config"

failures = []

def record_failure(list, message)
  list << message
  puts "         FAIL: #{message}"
end

puts "== 1. The denylist flags inert text AND executed payloads (raw-text match) =="

INERT = [
  %q{echo "sudo rm /data"},
  %q{ruby -e 'puts "mkfs.ext4 /dev/sda1"'},
  %q{echo "git push -f origin master"}
].freeze

EXECUTED = [
  %q{sh -c "mkfs.ext4 /dev/sda1"},
  %q{bash -c "sudo rm -rf /data"},
  %q{ruby -e 'system(%q{mkfs.ext4 /dev/sda1})'}
].freeze

# A naive quote-aware denylist, written here ONLY to measure that it breaks
# detection; it is not what the fix does.
NAIVE_PATTERNS = [
  /\bmkfs(\.|\s|$)/,
  /\bsudo\b/,
  /\bgit\s+push\b(?=.*(--force(?![\w-])|(?<!\w)-f(\s|$)))/
].freeze

def naive_quote_stripped_disaster?(command)
  stripped = command.gsub(/'[^']*'|"[^"]*"/, " ")
  NAIVE_PATTERNS.any? { |re| re.match?(stripped) }
end

INERT.each do |cmd|
  now = CommandAllowlist.disaster?(cmd)
  naive = naive_quote_stripped_disaster?(cmd)
  puts format(
    "  inert     %-38s disaster?=%-5s naive-strip?=%s",
    cmd[0, 38],
    now,
    naive)
  record_failure(failures, "inert command not flagged today: #{cmd}") unless now
  if naive
    record_failure(failures, "naive strip failed to silence it: #{cmd}")
  end
end

EXECUTED.each do |cmd|
  now = CommandAllowlist.disaster?(cmd)
  naive = naive_quote_stripped_disaster?(cmd)
  puts format(
    "  EXECUTED  %-38s disaster?=%-5s naive-strip?=%s",
    cmd[0, 38],
    now,
    naive)
  record_failure(failures, "executed payload not flagged today: #{cmd}") unless now
  # The decisive measurement: the same strip that fixes the false positive
  # un-flags a payload that IS executed -> a real detection hole.
  if naive
    record_failure(failures, "naive strip still flags #{cmd} (no hole proved)")
  end
end
puts "  conclusion: quote surgery opens a hole; gate the relaxation on the verdict"

puts
puts "== 2. CommandRunner override conditions (verdict injected on options) =="

# A tool-path dialog (show(ui: nil) needs a Task) served in place on a captured
# console - the same shape the specs stub. Empty stdin EOF-cancels, which is what
# a floor-intact scenario needs: the dialog must OPEN and be denied.
def with_dialog(lines)
  console = UI::Console.new(
    stdout: StringIO.new,
    stdin: StringIO.new(lines.join("\n")))
  UI::Dialog.define_singleton_method(:probe_console) { console }
  previous = UI::Dialog.instance_method(:show)
  UI::Dialog.define_method(:show) do |_ui|
    perform_direct(ui: UI::Dialog.probe_console)
  end
  result = yield
  UI::Dialog.define_method(:show, previous)
  [result, console.stdout.string]
end

# A command that IS denylisted (sudo) but wholly inert: safe to execute here.
INERT_CMD = %q{echo "sudo rm /data"}

def logged_runner(dir, options)
  logged = []
  logger = Logger.new(StringIO.new)
  logger.formatter = proc { |_sev, _time, _prog, msg| logged << msg; "" }
  runner = CommandRunner.new(
    FileList.new([], workdir: dir),
    options,
    harness: Struct.new(:logger).new(logger))
  [runner, logged]
end

def tool_options(option_on, verdict)
  {
    command_safety_check: true,
    command_safety_denylist_safe_approve: option_on,
    safety_verdicts: { INERT_CMD => verdict }
  }
end

SCENARIOS = [
  ["option ON  + tool + safe", true, "safe: inert quoted data", true],
  ["option ON  + tool + dangerous", true, "dangerous: real wipe", false],
  ["option ON  + tool + no verdict", true, nil, false],
  ["option OFF + tool + safe", false, "safe: inert quoted data", false]
].freeze

SCENARIOS.each do |label, option_on, verdict, expect_override|
  Dir.mktmpdir do |dir|
    runner, logged = logged_runner(dir, tool_options(option_on, verdict))
    result, out = with_dialog([]) { runner.run(INERT_CMD) }
    ran_no_dialog = result.start_with?("exit code: 0")
    asked = out.include?("DENYLISTED")
    override_log = logged.any? { |m| m.include?("denylist safe-override") }
    names_option = logged.any? { |m| m.include?("command_safety_denylist_safe_approve") }
    names_verdict = logged.any? { |m| verdict && m.include?(verdict) }
    puts format(
      "  %-28s ran-no-dialog=%-5s dialog-denied=%-5s override-log=%s",
      label,
      ran_no_dialog,
      asked,
      override_log)

    if expect_override
      unless ran_no_dialog
        record_failure(failures, "#{label}: override did not auto-approve")
      end
      unless override_log
        record_failure(failures, "#{label}: override not logged to harness.log")
      end
      unless names_option
        record_failure(failures, "#{label}: log does not name the option")
      end
      unless names_verdict
        record_failure(failures, "#{label}: log does not name the verdict")
      end
    else
      if ran_no_dialog
        record_failure(failures, "#{label}: floor WRONGLY relaxed (no dialog)")
      end
      record_failure(failures, "#{label}: dialog did not open") unless asked
      if override_log
        record_failure(failures, "#{label}: override fired when it must not")
      end
    end
  end
end

# The bang path is never covered by the override, even option ON + safe verdict.
Dir.mktmpdir do |dir|
  stdout = StringIO.new
  options = tool_options(true, "safe: inert")
  runner = CommandRunner.new(
    FileList.new([], workdir: dir),
    options,
    label: "shell",
    list: :shell,
    ui: UI::Console.new(stdout:, stdin: StringIO.new("2\n")))
  result = runner.run(INERT_CMD)
  denied = result.start_with?("error: user denied")
  leaked = stdout.string.include?("denylist safe-override")
  puts "  option ON + BANG + safe        dialog+denied=#{denied} status-leak=#{leaked}"
  unless denied
    record_failure(failures, "override leaked onto the bang path (floor relaxed)")
  end
  if leaked
    record_failure(failures, "override status leaked onto the bang path")
  end
end

puts
puts "== 3. The shipped config shape: command_safety_auto_approve as one enum =="

MODES = {
  "manual" => [false, false],
  "safe" => [true, false],
  "denylist" => [false, true],
  "safe_denylist" => [true, true]
}.freeze

if !HarnessConfig.new({}).respond_to?(:command_safety_denylist_safe_approve_enabled)
  record_failure(failures, "no config getter for the denylist half (no enum shipped)")
else
  MODES.each do |mode, (approve, denylist)|
    cfg = HarnessConfig.new(command_safety_auto_approve: mode)
    got = [
      cfg.command_safety_auto_approve_enabled,
      cfg.command_safety_denylist_safe_approve_enabled
    ]
    puts format("  %-14s approve=%-5s denylist=%s", mode, got[0], got[1])
    record_failure(failures, "#{mode}: got #{got.inspect}") unless got == [
      approve,
      denylist
    ]
  end

  legacy = HarnessConfig.new(command_safety_auto_approve: true)
  puts "  legacy true  approve=#{legacy.command_safety_auto_approve_enabled} " \
    "denylist=#{legacy.command_safety_denylist_safe_approve_enabled}"
  if [
    legacy.command_safety_auto_approve_enabled,
    legacy.command_safety_denylist_safe_approve_enabled
  ] != [true, false]
    record_failure(failures, "legacy true no longer reads as safe")
  end

  both = HarnessConfig.new(
    command_safety_auto_approve: "safe",
    command_safety_denylist_safe_approve: true)
  unless both.command_safety_denylist_safe_approve_enabled
    record_failure(failures, "separate denylist boolean not ORed into the enum")
  end

  begin
    HarnessConfig.new(command_safety_auto_approve: "yes")
    record_failure(failures, "an unrecognised mode fell back silently")
  rescue HarnessError
    puts "  junk \"yes\"   HarnessError (no silent fallback)"
  end

  # End to end: the mode a user writes is what arms the override.
  Dir.mktmpdir do |dir|
    cfg = HarnessConfig.new(
      command_safety_check: true,
      command_safety_auto_approve: "denylist")
    armed_options = {
      command_safety_check: cfg.command_safety_check_enabled,
      command_safety_denylist_safe_approve:
        cfg.command_safety_denylist_safe_approve_enabled,
      safety_verdicts: { INERT_CMD => "safe: inert quoted data" }
    }
    runner, logged = logged_runner(dir, armed_options)
    result, = with_dialog([]) { runner.run(INERT_CMD) }
    armed = result.start_with?("exit code: 0") &&
      logged.any? { |m| m.include?("denylist safe-override") }
    puts "  denylist mode through HarnessConfig -> override armed=#{armed}"
    record_failure(failures, "denylist mode did not arm the override") unless armed
  end
end

puts
if failures.empty?
  puts "RESULT: OK - quote surgery opens a hole; the relaxation is verdict-gated, " \
    "config-only, tool-path-only, and logged with the verdict that allowed it."
  exit 0
end

puts "RESULT: #{failures.size} failure(s)"
failures.each { |f| puts " - #{f}" }
exit 1
