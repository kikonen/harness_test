# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'plans'
require 'tools/plan_add_tool'

RSpec.describe Tools::PlanAddTool do
  def tool_for(dir)
    described_class.new(Plans.new(dir))
  end

  it 'has the plan.add name and text required (name optional)' do
    tool = tool_for(Dir.mktmpdir)

    expect(tool.name).to eq('plan.add')
    expect(tool.namespace).to eq('plan')
    expect(tool.parameters[:required]).to eq(%w[text])
  end

  it 'writes the plan into the store dir' do
    Dir.mktmpdir do |dir|
      out = tool_for(dir).execute('name' => 'auth', 'text' => 'split the flow')

      expect(out).to start_with('ok: saved plan')
      expect(File.binread(File.join(dir, Plans::DIR, 'auth.md')))
        .to eq("split the flow\n")
    end
  end

  # The consent decision: a plan call names ONE plan NAME, never a path, so
  # there is nothing to grant and no grant is asked for.
  it 'asks for no FileList grant (the argument is a name, not a path)' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)

      expect(tool).not_to respond_to(:file_list)
      expect(tool.execute('name' => 'no-grant', 'text' => 'body')).to start_with('ok:')
    end
  end

  # A mnemonic name is generated when the model omits one (issue #359 owner note).
  it 'generates a mnemonic name when none is given' do
    Dir.mktmpdir do |dir|
      out = tool_for(dir).execute('text' => 'the plan')

      expect(out).to start_with('ok: saved plan')
      name = Plans.new(dir).names.first
      expect(name).to match(/\A[a-z]+-[a-z]+\z/)
    end
  end

  it 'reports the name and char count in the status line' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)

      expect(tool).to receive(:status).with(:ok, 'plan-name (4 chars)')
      tool.execute('name' => 'plan-name', 'text' => 'body')
    end
  end

  # A refusal the model can ACT on: the error line names the limit and the way
  # out, because re-sending the same call shape would fail identically.
  it 'refuses a duplicate name and names the alternatives' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)
      tool.execute('name' => 'plan', 'text' => 'first')

      out = tool.execute('name' => 'plan', 'text' => 'second')

      expect(out).to start_with('error:')
      expect(out).to include('already exists')
      expect(out).to include('overwrite: true')
      expect(Plans.new(dir).body('plan')).to eq('first')
    end
  end

  it 'replaces the plan when overwrite is passed' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)
      tool.execute('name' => 'plan', 'text' => 'first')
      tool.execute('name' => 'plan', 'text' => 'second', 'overwrite' => true)

      expect(Plans.new(dir).body('plan')).to eq('second')
    end
  end

  # The store must not become a writer inside .harness/: what the file tools
  # can never grant stays unreachable through plan.add too.
  it 'refuses a name that is not one path segment' do
    Dir.mktmpdir do |dir|
      expect(tool_for(dir).execute('name' => '../sessions/x/session.json', 'text' => 'boom'))
        .to include('one path segment')
      expect(Plans.new(dir).count).to eq(0)
    end
  end

  it 'refuses an empty text' do
    Dir.mktmpdir do |dir|
      expect(tool_for(dir).execute('name' => 'empty', 'text' => '  ')).to include('empty')
    end
  end

  it 'refuses a text over the body cap, quoting the limit' do
    Dir.mktmpdir do |dir|
      long = 'x' * (Plans::MAX_BODY_CHARS + 1)
      out  = tool_for(dir).execute('name' => 'huge', 'text' => long)

      expect(out).to include("max #{Plans::MAX_BODY_CHARS}")
      expect(Plans.new(dir).count).to eq(0)
    end
  end

  it 'refuses a plan when the store is full and names deletion as the way out' do
    Dir.mktmpdir do |dir|
      plans = Plans.new(dir)
      Plans::MAX_PLANS.times { |i| plans.add("plan-#{i}", 'text') }

      out = tool_for(dir).execute('name' => 'too-many', 'text' => 'body')

      expect(out).to include("full (#{Plans::MAX_PLANS} plans)")
      expect(out).to include('plan.delete')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      expect { tool_for(dir).execute('name' => 'one', 'text' => 'body') }.not_to output.to_stdout
    end
  end
end
