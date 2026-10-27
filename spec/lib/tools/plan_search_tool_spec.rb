# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'plans'
require 'tools/plan_search_tool'

RSpec.describe Tools::PlanSearchTool do
  def tool_with(dir)
    described_class.new(Plans.new(dir))
  end

  it 'has the plan.search name and a query argument required' do
    tool = tool_with(Dir.mktmpdir)

    expect(tool.name).to eq('plan.search')
    expect(tool.namespace).to eq('plan')
    expect(tool.parameters[:required]).to eq(['query'])
  end

  it 'lists the matching plans as "name - description" under a match header' do
    Dir.mktmpdir do |dir|
      plans = Plans.new(dir)
      plans.add('auth', 'split the authentication flow')
      plans.add('build', 'run bundle exec rspec')

      out = tool_with(dir).execute('query' => 'authentication')

      expect(out).to start_with('Plans matching "authentication" (1)')
      expect(out).to include('auth - split the authentication flow')
    end
  end

  it 'matches names as well as bodies' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('refactor-auth', 'text')

      out = tool_with(dir).execute('query' => 'refactor')

      expect(out).to include('refactor-auth - text')
    end
  end

  it 'reports no match with the count stored' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('one', 'text')

      expect(tool_with(dir).execute('query' => 'absent'))
        .to eq('no plans match "absent" (1 stored)')
    end
  end

  it 'refuses an empty query and points at plan.list' do
    Dir.mktmpdir do |dir|
      out = tool_with(dir).execute('query' => '   ')

      expect(out).to start_with('error:')
      expect(out).to include('non-empty query')
      expect(out).to include('plan.list')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('one', 'body')

      expect { tool_with(dir).execute('query' => 'body') }.not_to output.to_stdout
    end
  end
end
