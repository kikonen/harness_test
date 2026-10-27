# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'plans'
require 'tools/plan_list_tool'

RSpec.describe Tools::PlanListTool do
  def tool_with(dir)
    described_class.new(Plans.new(dir))
  end

  def add(dir, name, text = 'a stored plan')
    Plans.new(dir).add(name, text)
  end

  it 'has the plan.list name and a namespace of plan' do
    tool = tool_with(Dir.mktmpdir)

    expect(tool.name).to eq('plan.list')
    expect(tool.namespace).to eq('plan')
    expect(tool.parameters[:required]).to eq([])
  end

  # The description is the ONLY place a model learns the feature exists (plans
  # are not injected into the system prompt), so it has to name the point of them.
  it 'says in its description that plans survive compaction and later sessions' do
    desc = tool_with(Dir.mktmpdir).description

    expect(desc).to include('compaction')
    expect(desc).to include('later sessions')
  end

  it 'lists each plan as "name - description" under a count header' do
    Dir.mktmpdir do |dir|
      add(dir, 'refactor-auth', 'split the flow into steps.')
      add(dir, 'ci', 'run rspec and rubocop on ubuntu.')

      out = tool_with(dir).execute({})

      expect(out).to start_with("Plans (2/#{Plans::MAX_PLANS})")
      expect(out).to include('refactor-auth - split the flow into steps.')
      expect(out).to include('ci - run rspec and rubocop on ubuntu.')
      expect(out.lines.size).to eq(3) # header + 2 plans
    end
  end

  it 'reports the count through the status line' do
    Dir.mktmpdir do |dir|
      add(dir, 'one')
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:info, "1/#{Plans::MAX_PLANS} plans")
      tool.execute({})
    end
  end

  # An empty store is the everyday state; the answer names the way to fill it so
  # the model does not go hunting.
  it 'answers an empty store with a plain line naming how to save one' do
    Dir.mktmpdir do |dir|
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:info, 'no plans stored')
      expect(tool.execute({}))
        .to eq("no plans stored (#{Plans::DIR}/ is empty) - " \
               'save one with plan.add(name:, text:)')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      add(dir, 'one')

      expect { tool_with(dir).execute({}) }.not_to output.to_stdout
    end
  end
end
