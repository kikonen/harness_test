# frozen_string_literal: true

# Issue #368: while a STREAMED model writes a tool call, no TEXT is arriving, so
# the spinner's tail stopped moving and the line read as a frozen connection.
# Run from the repo root: ruby analysis/368/repro.rb
# One REAL Harness turn (stream posture ON) through the REAL drain loop against a
# captured console: the scripted client plays reasoning, then a tool call in
# fragments with real pauses between them. The tool is test.echo, registered by
# every Harness, so no consent dialog competes for the line. The pre-fix state is
# replayed by redefining streaming_wait_line back to the tail-only version; the
# AFTER run goes first because a redefinition cannot be undone.
require "stringio"
require "tmpdir"
require_relative "../../lib/harness"
require_relative "../../lib/task"
require_relative "../../lib/ui/console"

# The spinner writes each frame as this erase escape followed by the frame text.
ERASE = "\r\e[2K"

class StreamingScriptedClient
  def initialize
    @calls = 0
  end

  def chat(_messages, **kwargs)
    @calls += 1
    if @calls > 1
      return { choices: [{ message: { content: "done", reasoning: nil } }] }
    end

    on_delta = kwargs[:on_delta]
    on_delta&.call({ reasoning: "I will write that file now. " })
    sleep 0.4
    # The tool call arrives as fragments; NO text arrives during them, which is
    # the phase the spinner line has to describe.
    4.times do
      on_delta&.call({ tool_call_names: ["test.echo"] })
      sleep 0.4
    end
    {
      choices: [
        {
          message: {
            content: nil,
            tool_calls: [
              { id: "c1", function: { name: "test.echo", arguments: '{"text":"x"}' } }
            ]
          }
        }
      ],
      usage: { prompt_tokens: 200, completion_tokens: 40, total_tokens: 240 }
    }
  end
end

def build_harness(dir)
  harness = Harness.new(
    {
      model: "test-model",
      num_ctx: 65_536,
      stream: true,
      system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE
    },
    FileList.new([], workdir: dir))
  harness.instance_variable_set(:@client, StreamingScriptedClient.new)
  harness.session.add_user("write the file")
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

# The frame glyph and the turn's elapsed clock change every frame; the CONTENT is
# what a user reads, so that is what distinguishes one distinct line from the next.
def distinct(frames)
  frames.map { |f| f[1..].to_s.sub(/\d+s/, "Ns") }.uniq
end

Dir.mktmpdir do |dir|
  after = draw_turn(dir)

  # Pre-fix streaming_wait_line: the tail and its rate, whatever the stream is
  # actually doing.
  Harness.send(:define_method, :streaming_wait_line) do
    tail = stream_preview_line
    next nil if tail.nil?

    rate = LLM::UsageStats.rate_segment(
      @stream_preview&.live_rate, measured_by_server: false, pad: true)
    rate ? "#{tail} #{rate}" : tail
  end
  before = Dir.mktmpdir { |dir2| draw_turn(dir2) }

  puts "BEFORE (the tail freezes for the whole tool call):"
  distinct(before).each { |f| puts "  |#{f.rstrip}|" }
  puts "AFTER (the line names the phase):"
  distinct(after).each { |f| puts "  |#{f.rstrip}|" }
  puts "distinct lines BEFORE #{distinct(before).size} / AFTER #{distinct(after).size}"

  names_phase = after.any? { |f| f.include?("writing tool call: test.echo") }
  frozen = before.any? { |f| f.include?("I will write that file now") } &&
    before.none? { |f| f.include?("tool call") }
  puts(names_phase && frozen ? "FIXED" : "BUG PRESENT")
end
