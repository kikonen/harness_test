# frozen_string_literal: true

require 'spec_helper'
require 'registry'
require 'job'
require 'tool_registry'
require 'sub_agent'

# A scripted client plays the answers so the pins stay deterministic, and
# records each request so the buffered-stream pin can read it.
class FakeClient
  attr_reader :seen

  def initialize(responses)
    @responses = responses
    @seen = []
  end

  def chat(_messages, tools:, stream: false)
    @seen << { stream: stream, tools: tools }
    { choices: [{ message: @responses.shift }] }
  end
end

RSpec.describe SubAgent do
  # The round needs a harness for three things only: the client, the system
  # prompt, and the tool execution path.
  def fake_harness(client, capture)
    Class.new do
      define_method(:client) { client }
      define_method(:build_system_prompt) { 'read-only sub agent' }
      define_method(:execute_tool_call) do |tc, registry: nil|
        capture[:registry] = registry
        "ran #{tc[:function][:name]}"
      end
    end.new
  end

  def build(responses, max_iterations: nil, max_findings: nil)
    registry = Registry.new
    requester = registry.add_job(kind: :main)
    job = registry.add_job(kind: :sub_agent, requested_by: requester)
    client = FakeClient.new(responses)
    capture = {}
    toolset = ToolRegistry.new
    agent = described_class.new(
      harness: fake_harness(client, capture),
      job:,
      registry: toolset,
      instruction: 'find the callers',
      max_iterations: max_iterations || described_class::DEFAULT_MAX_ITERATIONS,
      max_findings: max_findings || described_class::DEFAULT_MAX_FINDINGS
    )
    [agent, job, registry, client, capture, toolset]
  end

  # Drain the ONE queue until the round's :done lands - the registry is the only
  # place a job finishes, and finishing is what answers the requester.
  def finish(registry, job, timeout = 3)
    deadline = Time.now + timeout
    while Time.now < deadline
      event = registry.poll(0.1)
      next if event.nil?

      registry.record(event)
      break if event[:job] == job.id && event[:type] == :done
    end
    job
  end

  # Every exit path must deliver: the requester blocks on its inbox, so a round
  # that delivered nothing would hang it forever.
  it 'delivers findings to the requester inbox on the :done event' do
    agent, job, registry, = build([{ content: '3 callers in lib/task.rb', tool_calls: nil }])
    agent.start
    finish(registry, job)

    expect(job.finished?).to be true
    expect(job.result).to eq('3 callers in lib/task.rb')
    expect(job.requested_by.inbox.pop(true)).to eq('3 callers in lib/task.rb')
  end

  it 'delivers an error value when the round raises' do
    agent, job, registry, = build([])
    agent.start
    finish(registry, job)

    expect(job.result).to include('error:')
    expect(job.requested_by.inbox.pop(true)).to eq(job.result)
  end

  # The cap is enforced in code, not by asking the model to be short - the point
  # of a sub-agent is that the main context stays small.
  it 'raises past its iteration cap and delivers that as an error value' do
    tool_call = { id: 'c1', function: { name: 'file.read', arguments: '{}' } }
    responses = Array.new(3) { { content: nil, tool_calls: [tool_call] } }
    agent, job, registry, = build(responses, max_iterations: 2)
    agent.start
    finish(registry, job)

    expect(job.result).to include('exceeded its iteration limit (2)')
  end

  it 'runs tool calls against its OWN read-only set, not the run registry' do
    tool_call = { id: 'c1', function: { name: 'file.read', arguments: '{}' } }
    agent, job, registry, client, capture, toolset = build([
      { content: nil, tool_calls: [tool_call] },
      { content: 'found it', tool_calls: nil }
    ])
    agent.start
    finish(registry, job)

    expect(capture[:registry]).to equal(toolset)
    expect(job.result).to eq('found it')
    expect(client.seen.size).to eq(2)
  end

  # The streaming posture belongs to the foreground turn: a background job has
  # no spinner to feed, so its request is always buffered.
  it 'always requests buffered' do
    agent, job, registry, client, = build([{ content: 'done', tool_calls: nil }])
    agent.start
    finish(registry, job)

    expect(client.seen[0][:stream]).to be false
  end

  describe '#clamp' do
    def agent(max_findings:)
      described_class.new(harness: nil, job: nil, registry: nil,
                          instruction: 'x', max_findings:)
    end

    it 'returns short findings unchanged' do
      expect(agent(max_findings: 100).clamp('  short  ')).to eq('short')
    end

    it 'truncates over the cap and says so' do
      out = agent(max_findings: 10).clamp('a' * 30)
      expect(out).to start_with('a' * 10)
      expect(out).to include('truncated at 10 chars')
    end
  end
end
