# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/env_command'

RSpec.describe Commands::EnvCommand do
  def stub_env(report)
    env = Object.new
    env.define_singleton_method(:probe) { report }
    env.define_singleton_method(:format) do |_rep, query: []|
      "query=#{query.inspect}"
    end
    env
  end

  def run(args, report = { error: nil, count: 1, gems: [] })
    # env is captured in the local scope: the singleton-method block runs on the
    # harness stub, where the example's helpers are not reachable.
    env = stub_env(report)
    harness = Object.new
    harness.define_singleton_method(:env_ruby) { env }
    stdout = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  it 'runs the probe and prints the formatted report' do
    expect(run('')).to eq("query=[]\n")
  end

  it 'passes space-separated gems to the same formatter the tool uses' do
    expect(run('pdf nokogiri')).to include('query=["pdf", "nokogiri"]')
  end

  it 'states the probe failure instead of printing a report' do
    out = run('', { error: 'the probe produced no output' })

    expect(out).to include('Could not probe the child ruby')
    expect(out).to include('the probe produced no output')
  end

  it 'points at the tools command for the harness tools' do
    expect(described_class::HELP.see_also).to include('tools')
  end

  it 'declares its HELP entry in the general group' do
    help = described_class::HELP

    expect(help.usage).to eq('env [gems...]')
    expect(help.group).to eq(:general)
    expect(help.summary).to include('child Ruby')
    # The point a reader must not misread: this is the child ruby's gems, not
    # the bundle the harness itself runs under.
    expect(help.summary).to include("NOT the harness' own bundle")
  end
end
