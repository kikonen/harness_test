# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'skills'
require 'commands/skills_command'

RSpec.describe Commands::SkillsCommand do
  def harness_with(dir)
    skills = Skills.new(dir)
    h = Object.new
    h.define_singleton_method(:skills) { skills }
    h
  end

  def run_command(dir, args = '')
    stdout = StringIO.new
    described_class.new(harness: harness_with(dir), file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  def write_skill(dir, rel, content)
    full = File.join(dir, Skills::DIR, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  describe 'with no argument (the listing)' do
    it 'lists each skill with its description and the count' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'changelog/SKILL.md', "---\ndescription: Regenerate the changelog\n---\nb\n")
        write_skill(dir, 'triage.md', "---\ndescription: Sort issues\n---\nb\n")
        out = run_command(dir)

        expect(out).to include('Skills (2):')
        expect(out).to include('  changelog - Regenerate the changelog')
        expect(out).to include('  triage - Sort issues')
        expect(out).to include('Show one with: /skills <name>')
      end
    end

    # An empty project is the everyday state; the answer names where a skill goes
    # so the owner can add one without looking it up.
    it 'says where to add a skill when there are none' do
      Dir.mktmpdir do |dir|
        out = run_command(dir)

        expect(out).to include('No skills defined')
        expect(out).to include('.harness/skills/<name>/SKILL.md')
      end
    end
  end

  describe 'with a name (one skill body)' do
    it 'prints the body under a named rule' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'changelog/SKILL.md', "---\ndescription: d\n---\nstep one\nstep two\n")
        out = run_command(dir, 'changelog')

        expect(out).to include('--- changelog (.harness/skills)')
        expect(out).to include("step one\nstep two\n")
        expect(out).not_to include('description: d')
      end
    end

    it 'prints a body with no trailing newline without swallowing it' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 's.md', "last line, no newline")

        expect(run_command(dir, 's')).to end_with("last line, no newline\n")
      end
    end

    it 'names the available skills when the name matches none' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'real.md', "x\n")
        out = run_command(dir, 'ghost')

        expect(out).to start_with("[error] no skill named 'ghost'")
        expect(out).to include('real')
      end
    end

    it 'refuses a name that is not one path segment' do
      Dir.mktmpdir do |dir|
        expect(run_command(dir, '../sessions'))
          .to eq("[error] a skill name is one path segment: ../sessions\n")
      end
    end
  end

  # The user's view and the model's skills.list read the same loader, so the
  # listing shown here is the listing the model gets.
  it 'shows the same skills skills.list would list' do
    Dir.mktmpdir do |dir|
      write_skill(dir, 'a/SKILL.md', "---\ndescription: A skill\n---\nx\n")
      write_skill(dir, 'b.md', "---\ndescription: B skill\n---\nx\n")
      listed = Skills.new(dir).all.map(&:name)

      expect(run_command(dir)).to include(*listed)
    end
  end

  it 'declares both accepted forms in its HELP entry' do
    help = described_class::HELP

    expect(help.usage).to eq('skills [name]')
    expect(help.forms).to eq(['skills', 'skills <name>'])
    expect(help.group).to eq(:session)
  end
end
