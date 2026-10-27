# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'plans'
require 'tools/plan_delete_tool'

RSpec.describe Tools::PlanDeleteTool do
  def tool_with(dir)
    described_class.new(Plans.new(dir))
  end

  it 'has the plan.delete name and a name argument required' do
    tool = tool_with(Dir.mktmpdir)

    expect(tool.name).to eq('plan.delete')
    expect(tool.namespace).to eq('plan')
    expect(tool.parameters[:required]).to eq(['name'])
  end

  it 'removes the plan and reports the count left' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('gone', 'text')

      expect(tool_with(dir).execute('name' => 'gone'))
        .to eq("ok: removed plan 'gone' (0 left)")
      expect(Plans.new(dir).names).to eq([])
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
      Plans.new(dir).add('keep', 'text')

      expect(tool_with(dir).execute('name' => '../keep')).to include('one path segment')
      expect(Plans.new(dir).names).to eq(['keep'])
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('one', 'body')

      expect { tool_with(dir).execute('name' => 'one') }.not_to output.to_stdout
    end
  end
end
