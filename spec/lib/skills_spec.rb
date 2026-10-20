# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'skills'

RSpec.describe Skills do
  def workdir
    Dir.mktmpdir
  end

  def skills_in(dir)
    described_class.new(dir)
  end

  def write_skill(dir, rel, content)
    full = File.join(dir, described_class::DIR, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  describe 'the directory' do
    it 'is .harness/skills under the working directory' do
      Dir.mktmpdir do |dir|
        expect(skills_in(dir).dir).to eq(File.expand_path('.harness/skills', dir))
      end
    end

    it 'does not exist until a skill is written' do
      Dir.mktmpdir do |dir|
        expect(skills_in(dir).exist?).to be false
        expect(skills_in(dir).all).to eq([])
        expect(skills_in(dir).names).to eq([])
        expect(skills_in(dir).body('anything')).to be_nil
      end
    end
  end

  describe 'the two file shapes' do
    it 'reads <name>/SKILL.md' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'changelog/SKILL.md', "# Changelog\n\nDo this.\n")
        skill = skills_in(dir).find('changelog')

        expect(skill.name).to eq('changelog')
        expect(skill.path).to eq(File.expand_path('.harness/skills/changelog/SKILL.md', dir))
      end
    end

    it 'reads a single <name>.md file' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'triage.md', "# Triage\n\nSort it.\n")

        expect(skills_in(dir).find('triage').name).to eq('triage')
      end
    end

    # A directory with no SKILL.md is not a skill (it may hold anything else).
    it 'ignores a directory that has no SKILL.md, and a non-markdown file' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'notes/random.txt', "not a skill\n")
        write_skill(dir, 'README.html', "not a skill\n")

        expect(skills_in(dir).all).to eq([])
      end
    end
  end

  describe 'front matter' do
    it 'takes name and description from a --- block' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'changelog/SKILL.md', <<~MD)
          ---
          name: changelog-rollup
          description: Regenerate CHANGELOG.md from merged PR bodies
          ---
          # Body

          Step one.
        MD
        skill = skills_in(dir).find('changelog')

        # The NAME a skill is listed under comes from front matter; the file is
        # still addressed by its directory/file name.
        expect(skill.name).to eq('changelog-rollup')
        expect(skill.description).to eq('Regenerate CHANGELOG.md from merged PR bodies')
        expect(skills_in(dir).body('changelog')).to eq("# Body\n\nStep one.\n")
      end
    end

    it 'strips the front matter from the body' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'a.md', "---\ndescription: d\n---\nbody line\n")

        expect(skills_in(dir).body('a')).to eq("body line\n")
      end
    end

    # A skill with no front matter is still a skill: its first prose line is the
    # description, so a bare markdown file works.
    it 'falls back to the first prose line for the description' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'plain/SKILL.md', "# Plain\n\nDo the plain thing.\n")
        skill = skills_in(dir).find('plain')

        expect(skill.name).to eq('plain')
        expect(skill.description).to eq('Do the plain thing.')
      end
    end

    it 'truncates a long generated description' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'long.md', "# H\n\n#{'word ' * 60}\n")
        out = skills_in(dir).find('long').description

        expect(out.length).to be <= described_class::DESC_MAX + 4
        expect(out).to end_with('...')
      end
    end

    it 'survives malformed front matter (the body is still the skill)' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'bad.md', "---\n: : broken [\n---\nusable body\n")

        expect(skills_in(dir).body('bad')).to eq("usable body\n")
        expect(skills_in(dir).find('bad').name).to eq('bad')
      end
    end

    it 'treats a body that starts with --- only when a closing block follows' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'rule.md', "---\nnot front matter at all\n")

        expect(skills_in(dir).body('rule')).to eq("---\nnot front matter at all\n")
      end
    end
  end

  describe '#all' do
    it 'lists every skill sorted by name, whatever the order on disk' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'zeta/SKILL.md', "z\n")
        write_skill(dir, 'alpha.md', "a\n")
        write_skill(dir, 'mid/SKILL.md', "m\n")

        expect(skills_in(dir).names).to eq(%w[alpha mid zeta])
      end
    end
  end

  describe 'name safety (skills cannot be turned into a general file reader)' do
    it 'accepts a plain name with surrounding whitespace' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'changelog/SKILL.md', "x\n")

        expect(skills_in(dir).normalize_name('  changelog ')).to eq('changelog')
      end
    end

    [
      '../secrets',
      'a/../b',
      '../.git/config',
      '.harness/sessions',
      'nested/name',
      'nested\\name',
      'C:/windows/x',
      '..',
      '.',
      '.hidden',
      ''
    ].each do |bad|
      it "refuses #{bad.inspect}" do
        Dir.mktmpdir do |dir|
          expect(skills_in(dir).normalize_name(bad)).to be_nil
          expect(skills_in(dir).body(bad)).to be_nil
        end
      end
    end

    # Belt and braces: even a name that passed the segment test is checked against
    # the skills directory itself, so a symlink or a junction cannot escape it.
    it 'refuses a path that resolves outside the skills directory' do
      Dir.mktmpdir do |dir|
        skills = skills_in(dir)
        target = File.join(dir, 'outside.md')
        File.write(target, "escape\n")

        expect(skills.send(:inside?, target)).to be false
      end
    end
  end

  describe 'reading a body' do
    it 'returns the body verbatim (LF separators, front matter gone)' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 's.md', "# S\n\nline one\nline two\n")

        expect(skills_in(dir).body('s')).to eq("# S\n\nline one\nline two\n")
      end
    end

    it 'normalizes CRLF bytes so a Windows-authored skill reads clean' do
      Dir.mktmpdir do |dir|
        full = write_skill(dir, 's.md', "# S\n\nbody\r\n")

        expect(File.binread(full)).to include("\r\n")
        expect(skills_in(dir).body('s')).to eq("# S\n\nbody\n")
      end
    end

    it 'returns nil for a name that matches no skill' do
      Dir.mktmpdir do |dir|
        write_skill(dir, 'real.md', "x\n")

        expect(skills_in(dir).body('ghost')).to be_nil
      end
    end
  end
end
