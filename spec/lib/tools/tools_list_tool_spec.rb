# frozen_string_literal: true

require 'spec_helper'
require 'tool'
require 'tool_registry'
require 'tools/tools_list_tool'

class ListProbe < Tool
  def initialize(name, description: "the #{name} tool")
    super(name:, description:, parameters: {})
  end

  def execute(args)
    args
  end
end

RSpec.describe Tools::ToolsListTool do
  # The registry is injected at construction (it is built after this tool is
  # instantiated), so the spec builds a real registry of named stand-ins.

  def registry_with(*names)
    names.inject(ToolRegistry.new) { |reg, n| reg.register(ListProbe.new(n)) }
  end

  def execute_for(registry)
    described_class.new(registry).execute({})
  end

  it 'lists every tool as "name - description", in name order' do
    out = execute_for(registry_with('file.read', 'git.diff', 'ui.notify'))

    expect(out.split("\n")).to eq([
      'file.read - the file.read tool',
      'git.diff - the git.diff tool',
      'ui.notify - the ui.notify tool'
    ])
  end

  # The count is the status line the user sees: it must match what the listing
  # actually contains, not the registry's internal size.
  it 'reports the count through the status line and not to stdout (issue #40)' do
    registry = registry_with('a.tool', 'b.tool')
    tool     = described_class.new(registry)

    expect(tool).to receive(:status).with(:info, '2 tool(s)')
    expect { tool.execute({}) }.not_to output.to_stdout
  end

  # An empty registry is a legitimate state during startup; the tool must answer
  # with an empty listing rather than crash on the join.
  it 'answers an empty registry with an empty listing' do
    expect(execute_for(ToolRegistry.new)).to eq('')
  end

  it 'needs no arguments (it takes the registry from construction)' do
    Dir.mktmpdir do
      schema = described_class.new(ToolRegistry.new).to_openai[:function][:parameters]
      expect(schema[:properties]).to eq({})
      expect(schema[:required]).to eq([])
    end
  end
end
