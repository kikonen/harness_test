# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'plans'
require 'tools/plan_read_tool'

RSpec.describe Tools::PlanReadTool do
  def tool_with(dir)
    described_class.new(Plans.new(dir))
  end

  it 'has the plan.read name and a name argument required' do
    tool = tool_with(Dir.mktmpdir)

    expect(tool.name).to eq('plan.read')
    expect(tool.namespace).to eq('plan')
    expect(tool.parameters[:required]).to eq(['name'])
  end

  it 'returns the plan body verbatim' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('flow', "step one\nstep two")

      expect(tool_with(dir).execute('name' => 'flow')).to eq("step one\nstep two")
    end
  end

  it 'reads the same plan whichever case the name is given in' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('flow', 'body')

      expect(tool_with(dir).execute('name' => 'FLOW')).to eq('body')
    end
  end

  it 'reports a missing name with the names that exist' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('real', 'text')
      out = tool_with(dir).execute('name' => 'typo')

      expect(out).to start_with('error:')
      expect(out).to include('no plan named')
      expect(out).to include('real')
    end
  end

  it 'refuses a name that is not one path segment' do
    Dir.mktmpdir do |dir|
      expect(tool_with(dir).execute('name' => '../sessions/x/session.json'))
        .to include('one path segment')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('one', 'body')

      expect { tool_with(dir).execute('name' => 'one') }.not_to output.to_stdout
    end
  end
end
