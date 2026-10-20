# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'skills'
require 'tools/skills_list_tool'

RSpec.describe Tools::SkillsListTool do
  def tool_with(dir)
    described_class.new(Skills.new(dir))
  end

  def write_skill(dir, rel, content)
    full = File.join(dir, Skills::DIR, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  it 'lists each skill as "name - description"' do
    Dir.mktmpdir do |dir|
      write_skill(dir, 'changelog/SKILL.md', "---\ndescription: Regenerate the changelog\n---\nbody\n")
      write_skill(dir, 'triage.md', "---\ndescription: Sort incoming issues\n---\nbody\n")
      out = tool_with(dir).execute({})

      expect(out).to include('changelog - Regenerate the changelog')
      expect(out).to include('triage - Sort incoming issues')
      expect(out.lines.size).to eq(3) # header + 2 skills
    end
  end

  it 'names the count in the header and the status line' do
    Dir.mktmpdir do |dir|
      write_skill(dir, 'a.md', "x\n")
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:info, '1 skill(s)')
      expect(tool.execute({})).to include('Skills (1)')
    end
  end

  # A project with no skills is the normal state, not an error: the answer says
  # where a skill would go so the model does not go hunting for one.
  it 'answers an empty project with a plain no-skills line' do
    Dir.mktmpdir do |dir|
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:info, 'no skills defined')
      expect(tool.execute({})).to eq('no skills defined (.harness/skills/ does not exist in this project)')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      write_skill(dir, 'a.md', "x\n")

      expect { tool_with(dir).execute({}) }.not_to output.to_stdout
    end
  end

  it 'advertises no parameters' do
    Dir.mktmpdir do |dir|
      schema = tool_with(dir).to_openai[:function][:parameters]

      expect(schema[:properties]).to eq({})
      expect(schema[:required]).to eq([])
    end
  end
end
