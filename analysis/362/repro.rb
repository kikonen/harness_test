# frozen_string_literal: true

# Issue #362: while a tool RAN, the spinner line still showed the LLM request
# line of the request that had already finished, so a long run.command read as
# if the model were still generating.
# Run from the repo root: ruby analysis/362/repro.rb
# One REAL Harness (scripted client) asks for ONE run.command that sleeps 0.6s,
# driven through the REAL drain loop against a captured console. "sleep" is
# pre-approved, so the ONLY thing on screen during the child-process wait is the
# spinner. The pre-fix behaviour is replayed by switching the two announce
# methods off; the AFTER run goes first because a redefinition cannot be undone.
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../../lib/harness"
require_relative "../../lib/task"
require_relative "../../lib/ui/console"

# The spinner writes each frame as this erase escape followed by the frame text.
ERASE = "\r\e[2K"

class ScriptedClient
  def initialize(responses)
    @responses = responses
  end

  def chat(_messages, **_kwargs)
    message = @responses.shift || { content: "done" }
    {
      choices: [{ message: message.merge(reasoning: nil) }],
      usage: { prompt_tokens: 200, completion_tokens: 5, total_tokens: 205 }
    }
  end
end

def tool_round
  {
    content: nil,
    tool_calls: [
      {
        id: "c1",
        function: {
          name: "run.command",
          arguments: "{\"command\":\"sleep 0.6\"}"
        }
      }
    ]
  }
end

# Pre-approving "sleep" keeps the consent dialog out of the captured output:
# during the child-process wait the spinner is the only thing the user sees.
def seed_allowlist(dir)
  FileUtils.mkdir_p(File.join(dir, ".harness"))
  path = File.join(dir, ".harness", "allowed_commands.yml")
  File.write(path, YAML.dump(["sleep"]))
end

def build_harness(dir)
  options = {
    model: "test-model",
    num_ctx: 65_536,
    system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE
  }
  harness = Harness.new(options, FileList.new([], workdir: dir))
  responses = [tool_round, { content: "done" }]
  harness.instance_variable_set(:@client, ScriptedClient.new(responses))
  harness.session.add_user("wait a moment")
  harness
end

# One real turn through the real drain loop: the spinner frames the main thread
# drew, in the order the user would have seen them.
def draw_turn(dir)
  ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
  harness = build_harness(dir)
  Task.run(harness:, ui:) { harness.call_llm }
  ui.stdout.string.split(ERASE).select { |chunk| UI::Spinner::FRAMES.include?(chunk[0]) }
end

# The pre-fix state: the waits this issue is about announced nothing.
def silence_announcements
  Harness.send(:define_method, :announce_tool_call) { |_name| nil }
  CommandRunner.send(:define_method, :announce_run) { |_command| nil }
end

# The signature of this issue: does a frame name the run that is actually
# waiting? A frame naming the model request instead is the stale one.
def naming_run(frames)
  frames.count { |f| f.include?("run.command") }
end

Dir.mktmpdir do |dir|
  seed_allowlist(dir)
  after = draw_turn(dir)

  silence_announcements
  before = Dir.mktmpdir do |dir2|
    seed_allowlist(dir2)
    draw_turn(dir2)
  end

  puts "BEFORE (no tool announcement):"
  before.each { |f| puts "  |#{f.rstrip}|" }
  puts "AFTER (spinner re-pointed for the run):"
  after.each { |f| puts "  |#{f.rstrip}|" }
  puts "frames naming the run: BEFORE #{naming_run(before)} / AFTER #{naming_run(after)}"

  puts(naming_run(after).positive? && naming_run(before).zero? ? "FIXED" : "BUG PRESENT")
end
