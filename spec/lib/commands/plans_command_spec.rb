# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'plans'
require 'commands/plans_command'

RSpec.describe Commands::PlansCommand do
  def harness_with(dir)
    plans = Plans.new(dir)
    h = Object.new
    h.define_singleton_method(:plans) { plans }
    h
  end

  def run_command(dir, args = '')
    stdout = StringIO.new
    described_class.new(harness: harness_with(dir), file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  def write_plan(dir, name, content)
    FileUtils.mkdir_p(File.join(dir, Plans::DIR))
    File.write(File.join(dir, Plans::DIR, "#{name}.md"), content)
  end

  describe 'the help entry (issue #323 contract)' do
    it 'declares a HELP entry whose usage starts with its registered name' do
      help = described_class.help

      expect(help.usage).to start_with('plans')
      expect(help.summary).not_to be_empty
      expect(CommandHelp::GROUPS).to have_key(help.group)
    end
  end

  describe 'with no argument (the listing)' do
    it 'lists each plan with its description and the count' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'auth', 'split the flow into steps.')
        write_plan(dir, 'ci', "# CI\n\nrspec and rubocop on ubuntu.")

        out = run_command(dir)

        expect(out).to include("Plans (2/#{Plans::MAX_PLANS} plans")
        expect(out).to include('  auth - split the flow into steps.')
        expect(out).to include('  ci - rspec and rubocop on ubuntu.')
        expect(out).to include('Show one with: /plans <name>')
      end
    end

    # An empty store is the everyday state; the answer names both the model's
    # route (plan.add) and the file the owner can inspect.
    it 'answers an empty store with where a plan would live' do
      Dir.mktmpdir do |dir|
        out = run_command(dir)

        expect(out).to include('No plans stored')
        expect(out).to include('plan.add(name:, text:)')
        expect(out).to include("#{Plans::DIR}/<name>.md")
      end
    end

    it 'shows each plan size in chars' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'sized', '12345')

        expect(run_command(dir)).to include('sized - 12345 (5 chars)')
      end
    end
  end

  describe 'with a name (the body)' do
    it 'prints one plan body under a named rule line' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'pipeline', "step one\nstep two\n")

        out = run_command(dir, 'pipeline')

        expect(out).to include("--- pipeline (#{Plans::DIR})")
        expect(out).to include("step one\nstep two")
      end
    end

    # Same data the model sees through plan.read (one reader, no drift).
    it 'prints the same text plan.read returns' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'shared', "a\nb\n")

        command_out = run_command(dir, 'shared')
        model_out   = Tools::PlanReadTool.new(Plans.new(dir)).execute('name' => 'shared')

        expect(command_out).to include(model_out)
      end
    end

    it 'reports an unknown name with the names that exist' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'real', 'text')

        out = run_command(dir, 'typo')

        expect(out).to include('no plan named')
        expect(out).to include('real')
      end
    end

    it 'refuses a name that is not one path segment' do
      Dir.mktmpdir do |dir|
        expect(run_command(dir, '../sessions')).to include('one path segment')
      end
    end
  end

  it 'reads harness.plans, the same store plan.* writes (issue #359)' do
    Dir.mktmpdir do |dir|
      Plans.new(dir).add('written-by-model', 'body')

      expect(run_command(dir)).to include('written-by-model')
    end
  end
end
