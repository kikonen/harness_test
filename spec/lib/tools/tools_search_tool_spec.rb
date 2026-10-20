# frozen_string_literal: true

require 'spec_helper'
require 'tool'
require 'tool_registry'
require 'tools/tools_search_tool'

class SearchProbe < Tool
  def initialize(name, description: "the #{name} tool")
    super(name:, description:, parameters: {})
  end

  def execute(args)
    args
  end
end

RSpec.describe Tools::ToolsSearchTool do
  # The registry is injected at construction, the same way tools_list_tool gets it.

  def registry_with(*names)
    names.inject(ToolRegistry.new) { |reg, n| reg.register(SearchProbe.new(n)) }
  end

  def search(registry, query)
    described_class.new(registry).execute('query' => query)
  end

  it 'returns the matching tools with their full descriptions' do
    out = search(registry_with('file.read', 'git.diff'), 'file')

    expect(out).to eq('file.read - the file.read tool')
  end

  # The point of the tool: a caller who only knows what a tool DOES finds it
  # through its description, not its name.
  it 'matches on the description as well as the name' do
    registry = registry_with('meta.one', 'meta.two')
    allow(registry.get('meta.one')).to receive(:description).and_return('Searches available tools by name')

    out = search(registry, 'searches available')
    expect(out).to eq('meta.one - Searches available tools by name')
    expect(out).not_to include('meta.two')
  end

  it 'is case-insensitive' do
    expect(search(registry_with('file.read'), 'FILE.READ')).to include('file.read')
    expect(search(registry_with('file.read'), 'File.Read')).to include('file.read')
  end

  it 'rejects an empty query with the usage line' do
    expect(search(registry_with('file.read'), '   ')).to eq('error: usage: tools.search(query)')
    expect(search(registry_with('file.read'), nil)).to eq('error: usage: tools.search(query)')
  end

  it 'reports no match rather than an empty result' do
    expect(search(registry_with('file.read'), 'nomatchhere'))
      .to eq("no tools match 'nomatchhere'")
  end

  it 'returns several matches in name order' do
    registry = registry_with('z.search', 'a.search', 'm.other')
    expect(search(registry, 'search').split("\n")).to eq([
      'a.search - the a.search tool',
      'z.search - the z.search tool'
    ])
  end

  # The count is the status line the user sees (issue #40: it goes over the task's
  # event queue, never to stdout from the tool thread).
  it 'reports the match count through the status line, not stdout' do
    tool = described_class.new(registry_with('a.tool', 'b.tool'))
    expect(tool).to receive(:status).with(:info, "2 tool(s) match 'tool'")
    expect { tool.execute('query' => 'tool') }.not_to output.to_stdout
  end

  it 'says so when the registry is empty' do
    expect(search(ToolRegistry.new, 'anything')).to eq("no tools match 'anything'")
  end

  it 'advertises a required query' do
    schema = described_class.new(ToolRegistry.new).to_openai[:function][:parameters]
    expect(schema[:properties].keys).to contain_exactly(:query)
    expect(schema[:required]).to eq(['query'])
  end
end
