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

  # Split a markdown table row (`| a | b | c |`) into its trimmed cells.
  def split_row(line)
    line.strip.sub(/\A\|/, '').sub(/\|\z/, '').split(/\s*\|\s*/).map(&:strip)
  end

  # The listing is a :table (a markdown table; this console has no palette, so
  # the raw markdown fallback - the re-lay-out-able DATA the buffer keeps).
  it 'states the tool count in the header' do
    expect(run_command(registry_with('a.tool', 'b.tool'))).to include('Available tools (2):')
  end

  it 'lists each tool as a table row with its description' do
    out = run_command(registry_with('file.read', 'file.write', 'dir.create'))
    lines = out.lines.map(&:chomp)

    expect(split_row(lines[1])).to eq(%w[tool description])
    expect(lines).to include(a_string_matching(/\A\| [-| ]+\|\z/)) # the markdown rule row
    rows = lines[3..].map { |l| split_row(l) }
    expect(rows).to eq(
      [
        ['dir.create', 'desc of dir.create'],
        ['file.read', 'desc of file.read'],
        ['file.write', 'desc of file.write']
      ]
    )
  end

  # The grouping is the registry's (sorted for prompt caching); the command must
  # not re-sort or rename anything the model was already told about.
  it 'prints namespaces and tools in the registry order' do
    out = run_command(registry_with('zeta.tool', 'alpha.tool'))
    rows = out.lines.map(&:chomp)[3..].map { |l| split_row(l) }

    expect(rows).to eq(
      [
        ['alpha.tool', 'desc of alpha.tool'],
        ['zeta.tool', 'desc of zeta.tool']
      ]
    )
  end

  it 'prints a header with zero (and no tool rows) when the registry is empty' do
    out = run_command(ToolRegistry.new)
    rows = out.lines.map(&:chomp)[3..]

    expect(out).to include('Available tools (0):')
    expect(rows).to all(satisfy { |l| l.start_with?('|') }) # header + rule only
    expect(rows.reject { |l| l.match?(/\A\| [-| ]+\|\z/) }).to be_empty
  end

  it 'declares its HELP entry in the general group' do
    help = described_class::HELP

    expect(help.usage).to eq('tools')
    expect(help.group).to eq(:general)
    expect(help.see_also).to eq(%w[help])
  end
end
