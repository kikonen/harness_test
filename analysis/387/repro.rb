# frozen_string_literal: true

# Issue #387: "Bug: cli prompt not showing [STREAM]" - the spinner badge carried the
# STREAM tag but the idle prompt line did not, so the SAME posture read differently in
# the two places. Run from the repo root:
#   ruby analysis/387/repro.rb
# The fix makes the prompt line build its posture tags from the spinner's own builder
# (Task.mode_badge), so the two cannot drift again.
#
# What is measurable WITHOUT a model server (none exists in a checkout): for every
# posture combination, the bracketed tags on the prompt line CLI#get_command prints must
# equal the tags Task.mode_badge gives the spinner badge. The spinner side is the
# reference the issue says was already right; the prompt side is what is measured.
#
# Exit 1 when a claim fails. EXPECTED BEFORE the fix (master 4a49ebd): every stream-on
# scenario reports prompt-tags MISSING [STREAM] while the spinner badge has it.
# EXPECTED AFTER: prompt-tags == spinner-badge for every scenario.
require "tmpdir"

require_relative "../../lib/cli"
require_relative "../../lib/task"
require_relative "../../lib/ui/console"
require_relative "../../lib/ui/editor"

failures = []

def record_failure(list, message)
  list << message
  puts "         FAIL: #{message}"
end

# The posture combinations a run can be in. command_safety_auto_approve only shows as
# AUTO-APPROVE when the safety check is also on (Harness#command_mode_label), so the
# scenarios stay on the two tags the issue is about: consent (MANUAL / YOLO) and stream.
SCENARIOS = [
  ["MANUAL, buffered",      { yolo: false, stream: false }],
  ["MANUAL, STREAM",        { yolo: false, stream: true }],
  ["YOLO, buffered",        { yolo: true,  stream: false }],
  ["YOLO, STREAM",          { yolo: true,  stream: true }],
  ["default (nothing set)", {}]
].freeze

# A real CLI on a throwaway workdir, its console captured, its prompt read stubbed to a
# submitted command so get_command returns after printing ONE modeline. No model is
# contacted: get_command only reads posture state.
def prompt_line(options)
  Dir.mktmpdir do |dir|
    out     = StringIO.new
    console = UI::Console.new(stdout: out, stdin: StringIO.new)
    opts = {
      workdir: dir,
      base_url: "http://localhost:1/v1",
      model: "test-model",
      active_model: "test-model",
      system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE
    }.merge(options)

    cli = CLI.new(opts, console)
    result = UI::Editor::EDITOR_RESULT.new("x", :submitted, nil)
    UI::Editor.define_method(:read_multiline) { |**| result }
    cli.send(:get_command)
    out.string
  end
end

puts "== posture tags: the idle prompt line vs the spinner badge (Task.mode_badge) =="

SCENARIOS.each do |label, options|
  Dir.mktmpdir do |dir|
    cli = CLI.new(
      {
        workdir: dir,
        base_url: "http://localhost:1/v1",
        model: "test-model",
        active_model: "test-model",
        system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE
      }.merge(options),
      UI::Console.new(stdout: StringIO.new, stdin: StringIO.new))

    # The spinner's reference: what Task.mode_badge answers for THIS harness.
    spinner = Task.mode_badge(cli.harness).to_s
    line    = prompt_line(options).lines.first.to_s.chomp
    # The modeline is "[model (effort)] <posture tags> > "; the tags are everything
    # between the model bracket and the prompt marker.
    prompt  = line[/\] (.*) > /, 1].to_s

    puts format("  %-22s spinner=%-18s prompt=%s", label, spinner.inspect, prompt.inspect)

    if prompt != spinner
      detail = "prompt #{prompt.inspect} != spinner #{spinner.inspect}"
      record_failure(failures, "#{label}: #{detail}")
    end
    unless line.include?("[test-model (off)]")
      record_failure(failures, "#{label}: modeline lost its model/effort bracket")
    end
  end
end

puts
if failures.empty?
  puts "ALL CLAIMS HOLD: the prompt line and the spinner badge carry the SAME posture " \
    "tags (one builder, Task.mode_badge), so [STREAM] shows in both."
  exit 0
end

puts "FAILURES (#{failures.size}):"
failures.each { |f| puts "  - #{f}" }
exit 1
