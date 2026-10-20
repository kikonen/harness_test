# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tool_registry'
require 'commands/tools_command'

RSpec.describe Commands::ToolsCommand do
  def registry_with(*names)
    reg = ToolRegistry.new
    names.each { |n| reg.register(Tool.new(name: n, description: "desc of #{n}", parameters: {})) }
    reg
  end

  def run_command(registry)
    harness = Object.new
    harness.define_singleton_method(:tool_registry) { registry }
    stdout = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle('')
    stdout.string
  end

  it 'states the tool count in the header' do
    expect(run_command(registry_with('a.tool', 'b.tool'))).to include('Available tools (2):')
  end

  it 'lists each tool under its namespace with its description' do
    out = run_command(registry_with('file.read', 'file.write', 'dir.create'))

    expect(out).to include("  file:")
    expect(out).to include("    file.read - desc of file.read")
    expect(out).to include("    file.write - desc of file.write")
    expect(out).to include("  dir:")
  end

  # The grouping is the registry's (sorted for prompt caching); the command must
  # not re-sort or rename anything the model was already told about.
  it 'prints namespaces and tools in the registry order' do
    out = run_command(registry_with('zeta.tool', 'alpha.tool'))

    expect(out.lines.map(&:chomp)).to eq(
      [
        'Available tools (2):',
        '  alpha:',
        '    alpha.tool - desc of alpha.tool',
        '  zeta:',
        '    zeta.tool - desc of zeta.tool'
      ]
    )
  end

  it 'prints a header with zero when the registry is empty' do
    expect(run_command(ToolRegistry.new)).to eq("Available tools (0):\n")
  end

  it 'declares its HELP entry in the general group' do
    help = described_class::HELP

    expect(help.usage).to eq('tools')
    expect(help.group).to eq(:general)
    expect(help.see_also).to eq(%w[help])
  end
end
