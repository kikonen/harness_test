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

  # A harness that answers a palette is the real-run shape (Harness#output_palette
  # is ALWAYS a palette there), and it is what makes the body render as markdown
  # (issue #416). palette: 'none' renders structure with no ANSI.
  def harness_with_palette(dir, name = 'default')
    plans = Plans.new(dir)
    h = Object.new
    h.define_singleton_method(:plans) { plans }
    h.define_singleton_method(:output_palette) { UI::Palette.new(name) }
    h.define_singleton_method(:markdown_max_width) { nil }
    h
  end

  def run_command(dir, args = '')
    stdout = StringIO.new
    described_class.new(harness: harness_with(dir), file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  def run_with_palette(dir, args = '', palette = 'default')
    stdout = StringIO.new
    described_class.new(harness: harness_with_palette(dir, palette),
                        file_list: nil, options: nil,
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
        expect(out).to include('  1. auth - split the flow into steps.')
        expect(out).to include('  2. ci - rspec and rubocop on ubuntu.')
        expect(out).to include('Show one with: /plans <name>  or  /plans <N>')
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

  # Issue #416 part 2: the listing is numbered so a plan can be opened by its
  # number instead of typing a mnemonic name.
  describe 'the numbering (issue #416)' do
    def three_plans(dir)
      write_plan(dir, 'auth', 'auth body text')
      write_plan(dir, 'brave-falcon', 'falcon body text')
      write_plan(dir, 'ci', 'ci body text')
    end

    it 'numbers the listing in its sorted order' do
      Dir.mktmpdir do |dir|
        three_plans(dir)

        expect(run_command(dir)).to include(
          "  1. auth - auth body text (14 chars)\n  2. brave-falcon - falcon body text (16 chars)" \
          "\n  3. ci - ci body text (12 chars)"
        )
      end
    end

    it 'opens a plan by its listing number' do
      Dir.mktmpdir do |dir|
        three_plans(dir)

        out = run_command(dir, '2')

        expect(out).to include("--- 2. brave-falcon (#{Plans::DIR})")
        expect(out).to include('falcon body text')
        expect(out).not_to include('ci body text')
      end
    end

    it 'right-aligns the numbers so the listing stays readable past 9 plans' do
      Dir.mktmpdir do |dir|
        10.times { |i| write_plan(dir, format('plan%02d', i), "body #{i}") }

        out = run_command(dir)

        expect(out).to include('  1. plan00 - body 0')
        expect(out).to include(' 10. plan09 - body 9')
      end
    end

    # The index only wins while it is IN RANGE, so a plan genuinely named with
    # digits is still reachable by that name.
    it 'keeps a digit-named plan reachable when the number is out of range' do
      Dir.mktmpdir do |dir|
        write_plan(dir, '3', 'named-three body')
        write_plan(dir, 'alpha', 'alpha body')

        out = run_command(dir, '3')

        expect(out).to include('named-three body')
        expect(out).not_to include('alpha body')
      end
    end

    it 'reports an out-of-range number with the names that exist' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'real', 'text')

        out = run_command(dir, '9')

        expect(out).to include('no plan named')
        expect(out).to include('real')
      end
    end

    it 'shows the number in the header only when a number was asked for' do
      Dir.mktmpdir do |dir|
        three_plans(dir)

        expect(run_command(dir, 'brave-falcon')).to include("--- brave-falcon (#{Plans::DIR})")
      end
    end
  end

  # Issue #416 part 1: the body IS a markdown file, so it renders instead of
  # being dumped with its markers visible.
  describe 'markdown rendering of the body (issue #416)' do
    it 'renders headings and bold with ANSI when the run has a palette' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'styled', "# Title\n\nRun **bin/rspec** first.\n")

        out = run_with_palette(dir, 'styled')

        expect(out).to include("\e[")
        expect(out).to include('bin/rspec')
        # The markdown markers are consumed by the render, not printed.
        expect(out).not_to include('# Title')
        expect(out).not_to include('**bin/rspec**')
      end
    end

    # palette 'none' (--no-color) still renders the STRUCTURE: plain text,
    # no ANSI, no markers.
    it 'renders plain marker-free text under palette none' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'plain', "# Title\n\nRun **bin/rspec** first.\n")

        out = run_with_palette(dir, 'plain', 'none')

        expect(out).not_to include("\e[")
        expect(out).to include('Title')
        expect(out).to include('Run bin/rspec first.')
        expect(out).not_to include('# Title')
      end
    end

    # Without a palette to render with (a spec double, a bare console) the body
    # stays byte-for-byte what the file holds - the pre-#416 behaviour.
    it 'prints the body verbatim when the harness answers no palette' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'raw', "# Title\n\nRun **bin/rspec** first.\n")

        out = run_command(dir, 'raw')

        expect(out).to include('# Title')
        expect(out).to include('**bin/rspec**')
      end
    end

    # The render and the verbatim dump must end the same way: one newline, no
    # trailing blank block (the gem closes its last block with a blank line).
    it 'ends with a single newline, like the verbatim dump' do
      Dir.mktmpdir do |dir|
        write_plan(dir, 'tail', "step one\nstep two")

        expect(run_with_palette(dir, 'tail')).to eq(run_command(dir, 'tail'))
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
