# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'skills'
require 'tools/skills_read_tool'

RSpec.describe Tools::SkillsReadTool do
  def tool_with(dir)
    described_class.new(Skills.new(dir))
  end

  def write_skill(dir, rel, content)
    full = File.join(dir, Skills::DIR, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  it 'returns the body as the instructions to follow' do
    Dir.mktmpdir do |dir|
      write_skill(dir, 'changelog/SKILL.md', "---\ndescription: d\n---\n1. list PRs\n2. condense\n")

      expect(tool_with(dir).execute('name' => 'changelog')).to eq("1. list PRs\n2. condense\n")
    end
  end

  it 'reports what it loaded through the status line, never to stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      write_skill(dir, 'a.md', "one\ntwo\n")
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:ok, 'a (2 lines)')
      expect { tool.execute('name' => 'a') }.not_to output.to_stdout
    end
  end

  # A body is harness-owned instruction content (like harness.md), so no FileList
  # grant is asked for: the tool is constructed with only the Skills loader.
  it 'asks for no access grant' do
    Dir.mktmpdir do |dir|
      write_skill(dir, 'a.md', "body\n")

      expect { tool_with(dir).execute('name' => 'a') }.not_to raise_error
    end
  end

  describe 'an unknown name' do
    it 'names the skills that DO exist, so the model can pick a real one' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'changelog/SKILL.md', "body\n")
        write_skill(dir, 'triage.md', "body\n")
        tool = tool_with(dir)

        expect(tool).to receive(:status).with(:fail, 'no such skill: ghost')
        out = tool.execute('name' => 'ghost')

        expect(out).to start_with("error: no skill named 'ghost'")
        expect(out).to include('available: changelog, triage')
      end
    end

    it 'says plainly when the project has no skills at all' do
      Dir.mktmpdir do |dir|
        out = tool_with(dir).execute('name' => 'anything')

        expect(out).to eq("error: no skill named 'anything' (no skills defined)")
      end
    end
  end

  # The refusal is the security boundary: skills.read must not become a general
  # file reader that names its way to .git/config or a session file.
  describe 'a name that is not a single path segment' do
    [
      '../secrets',
      'a/../../.git/config',
      'nested/name',
      '.harness/sessions',
      '..',
      '.hidden'
    ].each do |bad|
      it "refuses #{bad.inspect} without touching a file" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, 'outside.md'), "escape\n")
          tool = tool_with(dir)

          expect(tool).to receive(:status).with(:fail, 'invalid skill name')
          out = tool.execute('name' => bad)

          expect(out).to include("must be one path segment")
          expect(out).not_to include('escape')
        end
      end
    end

    it 'refuses a missing or nil name' do
      Dir.mktmpdir do |dir|
        expect(tool_with(dir).execute('name' => nil))
          .to include("must be one path segment")
        expect(tool_with(dir).execute({})).to include("must be one path segment")
      end
    end
  end

  it 'advertises a required name' do
    Dir.mktmpdir do |dir|
      schema = tool_with(dir).to_openai[:function][:parameters]

      expect(schema[:properties].keys).to contain_exactly(:name)
      expect(schema[:required]).to eq(['name'])
    end
  end
end
