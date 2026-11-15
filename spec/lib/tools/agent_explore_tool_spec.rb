# frozen_string_literal: true

require 'spec_helper'
require 'tool'
require 'tool_registry'
require 'registry'
require 'job'
require 'requester'
require 'tools/agent_explore_tool'

# A requester stands in for the turn that calls the tool: #execute runs on the
# task thread and cannot run a Task, so it posts one request and blocks on the
# inbox the main thread answers.
class ExploreRequester
  include Requester

  attr_reader :job

  def initialize(job)
    @job = job
  end

  def push_event(**event)
    job.push_event(**event)
  end
end

# The tool needs the harness for two things only: the registry the job lands on,
# and the tool set it reads the read-only half out of.
class ExploreHarness
  attr_reader :registry, :tool_registry

  def initialize(registry, tool_registry)
    @registry = registry
    @tool_registry = tool_registry
  end
end

RSpec.describe Tools::AgentExploreTool do
  def harness
    source = ToolRegistry.new
    source.register(Tools::EchoTool.new)
    source.register(Tools::FileWriteTool.new(FileList.new, nil))
    ExploreHarness.new(Registry.new, source)
  end

  def post(run, args)
    job = run.registry.add_job(kind: :main)
    requester = ExploreRequester.new(job)
    seen = { result: nil }

    thread = Thread.new do
      Thread.current[:harness_sub_agent] = requester
      seen[:result] = described_class.new(run).execute(args)
      Thread.current[:harness_sub_agent] = nil
    end

    event = nil
    20.times do
      event = run.registry.poll(0.5)
      break if event
    end
    [event, thread, seen]
  end

  it 'has the agent.explore name and a required instruction argument' do
    tool = described_class.new(harness)
    expect(tool.name).to eq('agent.explore')
    expect(tool.namespace).to eq('agent')
    expect(tool.parameters[:required]).to eq(['instruction'])
  end

  # A request with no requester has no inbox to block on, so the tool reports it
  # rather than hanging forever (the single-thread I/O rule).
  it 'refuses when no requester is running the call' do
    expect(described_class.new(harness).execute('instruction' => 'find the callers'))
      .to eq('error: no requester running this call')
  end

  it 'refuses an empty instruction without asking for a job' do
    expect(described_class.new(harness).execute('instruction' => '   '))
      .to eq('error: agent.explore needs an instruction')
  end

  describe '#execute posts one request and blocks for the result' do
    # The tool does not run the round: the main thread registers the job. The
    # answer IS the round's finish delivery, so the tool cannot return before it
    # lands on the inbox.
    it 'names the requester job and posts the read-only set, not the run set' do
      h = harness
      event, thread, seen = post(h, 'instruction' => 'find the callers')

      expect(event[:type]).to eq(:__request__)
      expect(event[:kind]).to eq(:sub_agent)
      expect(event[:instruction]).to eq('find the callers')
      expect(event[:job]).to eq(h.registry.jobs.first.id)
      # The set is built from the run's registry but is not the run's registry,
      # so a write tool is not reachable from inside a round.
      expect(event[:registry]).not_to equal(h.tool_registry)
      expect(event[:registry].names).not_to include('file.write')

      h.registry.answer(event[:job], '3 callers in lib/task.rb')
      thread.join(2)
      expect(seen[:result]).to eq('3 callers in lib/task.rb')
    end

    # A failure must come back as a value the model can act on, never silence.
    it 'reports a nil answer as an error value' do
      h = harness
      event, thread, seen = post(h, 'instruction' => 'find the callers')
      h.registry.answer(event[:job], nil)
      thread.join(2)

      expect(seen[:result]).to eq('error: the sub agent delivered no result')
    end
  end
end
