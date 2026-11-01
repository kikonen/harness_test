# frozen_string_literal: true

require 'spec_helper'
require 'tool_registry'
require 'env_ruby'
require 'tools/env_ruby_tool'

RSpec.describe Tools::EnvRubyTool do
  # A probe stub with a canned report: the tool's contract (what it asks, how it
  # renders, what it returns on failure) is independent of THIS machine's gems.
  def stub_env(report)
    env = instance_double('EnvRuby')
    allow(env).to receive(:probe).and_return(report)
    allow(env).to receive(:format) { |_rep, query: []| "formatted(query=#{query.inspect})" }
    env
  end

  def sample_report
    { error: nil, ruby: '3.4.1', exe: '/usr/bin/ruby', bundler: 'no', count: 1,
      gems: [{ name: 'csv', version: '3.3.0', kind: 'stdlib' }] }
  end

  it 'has the env.ruby name and no required argument' do
    tool = described_class.new(stub_env(sample_report))

    expect(tool.name).to eq('env.ruby')
    expect(tool.namespace).to eq('env')
    expect(tool.parameters[:required]).to eq([])
  end

  # The model's question is "can a run.command script use gem X?" - the tool must
  # say up front that the answer is about the CHILD ruby, not the harness bundle.
  it 'names the child-ruby distinction in its description' do
    tool = described_class.new(stub_env(sample_report))

    expect(tool.description).to match(/CHILD ruby/i)
    expect(tool.description).to include("NOT this harness' own bundle")
    expect(tool.description).to include('stdlib')
  end

  it 'accepts an optional gems array and forwards it as the query' do
    env  = stub_env(sample_report)
    tool = described_class.new(env)

    expect(tool.execute('gems' => %w[pdf csv])).to eq('formatted(query=["pdf", "csv"])')
  end

  it 'forwards an empty query when no gems are given' do
    tool = described_class.new(stub_env(sample_report))

    expect(tool.execute({})).to eq('formatted(query=[])')
  end

  # A probe failure must not read as "no gems installed" - the model would then
  # hand-write parsers believing nothing is available.
  it 'returns an error string when the probe failed' do
    tool = described_class.new(stub_env({ error: 'the probe produced no output' }))

    expect(tool.execute({})).to start_with('error: could not probe the child ruby')
    expect(tool.execute({})).to include('the probe produced no output')
  end

  it 'reaches the model through the tool registry like every other tool' do
    registry = ToolRegistry.new
    registry.register(described_class.new(stub_env(sample_report)))

    payload = registry.to_openai.find { |t| t[:function][:name] == 'env.ruby' }
    expect(payload).not_to be_nil
    expect(payload[:function][:parameters]).to eq(described_class.new(stub_env(sample_report)).parameters)
  end
end
