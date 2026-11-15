# frozen_string_literal: true

require 'spec_helper'
require 'tool'
require 'tool_registry'
require 'agent_toolset'

# A stand-in tool carrying only the name the set is keyed on: AgentToolset.build
# copies INSTANCES by name, so the pin is about which names appear, not what a
# real tool does.
class NamedTool < Tool
  def initialize(name)
    super(name:, description: 'probe', parameters: { type: 'object', properties: {} })
  end

  def execute(args)
    args
  end
end

RSpec.describe AgentToolset do
  def harness_with(names)
    source = ToolRegistry.new
    names.each { |name| source.register(NamedTool.new(name)) }
    Class.new do
      define_method(:tool_registry) { source }
    end.new
  end

  it 'names the read half of the run registry' do
    expect(described_class::READ_ONLY).to include('file.read', 'git.status', 'ui.dialog')
    expect(described_class::READ_ONLY).not_to include('file.write', 'run.command', 'ui.note')
  end

  it 'reuses the run tool instances, so the run FileList and grants still apply' do
    source = ToolRegistry.new
    tool = NamedTool.new('file.read')
    source.register(tool)
    harness = Class.new { define_method(:tool_registry) { source } }.new
    set = described_class.build(harness)

    expect(set.get('file.read')).to equal(tool)
  end

  it 'registers exactly the READ_ONLY names, in that set only' do
    set = described_class.build(harness_with(described_class::READ_ONLY + ['file.write', 'ui.note']))

    expect(set.names).to eq(described_class::READ_ONLY.sort)
  end

  # A phase-1 sub-agent cannot nest, and cannot write into the main session.
  it 'excludes agent.explore and ui.note even when the run registry has them' do
    set = described_class.build(harness_with(described_class::READ_ONLY + %w[agent.explore ui.note]))

    expect(set.names).not_to include('agent.explore')
    expect(set.names).not_to include('ui.note')
  end

  it 'answers an empty set for a harness with no tool registry to read' do
    set = described_class.build(Class.new)

    expect(set).to be_a(ToolRegistry)
    expect(set.empty?).to be true
  end
end
