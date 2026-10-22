# frozen_string_literal: true

require 'spec_helper'
require 'sensitive_files'
require 'tmpdir'
require 'fileutils'

# The NAME half of the sensitive-path guard. Whether a name counts (a scratch
# zone exempts it) is FileList#sensitive? - the only half that knows a working
# directory, which is what the zone test needs.
#
# The zone rule is also a .gitignore rule (issue #347), and a unit spec cannot
# test an ignore file - so the zone tests below drive REAL git in a throwaway
# repo, the same approach git_runner_spec takes. maintenance.auto / gc.auto are
# off through git's own config env so no detached `git maintenance` child writes
# into the tmp repo while Dir.mktmpdir walks it to delete it.
PROJECT_ROOT = File.expand_path('../..', __dir__)

GIT_EVIDENCE_ENV = {
  'GIT_AUTHOR_NAME'     => 'test',
  'GIT_AUTHOR_EMAIL'    => 'test@example.com',
  'GIT_COMMITTER_NAME'  => 'test',
  'GIT_COMMITTER_EMAIL' => 'test@example.com',
  'GIT_CONFIG_COUNT'    => '2',
  'GIT_CONFIG_KEY_0'    => 'maintenance.auto',
  'GIT_CONFIG_VALUE_0'  => 'false',
  'GIT_CONFIG_KEY_1'    => 'gc.auto',
  'GIT_CONFIG_VALUE_1'  => '0'
}.freeze

RSpec.describe SensitiveFiles do
  describe '.sensitive? (the name test)' do
    it 'blocks a .env basename and its variants' do
      expect(described_class.sensitive?('.env')).to be(true)
      expect(described_class.sensitive?('.env.production')).to be(true)
      expect(described_class.sensitive?('config/.env.production')).to be(true)
    end

    it 'blocks a sensitive directory in ANY component of the path' do
      expect(described_class.sensitive?('.git/config')).to be(true)
      expect(described_class.sensitive?('.git/objects/pack/x.idx')).to be(true)
      expect(described_class.sensitive?('vendor/.git/HEAD')).to be(true)
      expect(described_class.sensitive?('.harness/sessions/id/session.json')).to be(true)
      expect(described_class.sensitive?('C:/work/proj/tmp/keep/318/repo/.git/COMMIT_EDITMSG')).to be(true)
    end

    it 'leaves ordinary paths alone' do
      expect(described_class.sensitive?('lib/file_list.rb')).to be(false)
      expect(described_class.sensitive?('tmp/keep/318/issue_crlf.md')).to be(false)
      expect(described_class.sensitive?('tmp/keep/318/repo/README.md')).to be(false)
    end

    it 'is name-only - a zone path is still sensitive HERE (the exemption is FileList\'s)' do
      expect(described_class.sensitive?('tmp/keep/318/repo/.git/config')).to be(true)
    end
  end

  describe '.scratch_zone?' do
    it 'recognises a per-issue zone of either kind' do
      expect(described_class.scratch_zone?('tmp/keep/318/repo/.git/config')).to be(true)
      expect(described_class.scratch_zone?('tmp/scratch/321/probe.rb')).to be(true)
      expect(described_class.scratch_zone?('tmp/keep/318/sub/deep/.git/objects/x')).to be(true)
    end

    it 'accepts a zone name that is not a number' do
      expect(described_class.scratch_zone?('tmp/keep/309-316/i8_drift_and_tail.md')).to be(true)
      expect(described_class.scratch_zone?('tmp/scratch/notes/.git/config')).to be(true)
    end

    it 'requires the <n> segment - the zone list itself is not a zone' do
      expect(described_class.scratch_zone?('tmp/keep/318')).to be(false)
      expect(described_class.scratch_zone?('tmp/keep/.git/config')).to be(false)
      expect(described_class.scratch_zone?('tmp/scratch/.git/config')).to be(false)
    end

    it 'does not match a lookalike directory or the owner zone' do
      expect(described_class.scratch_zone?('tmp/keepz/318/.git/config')).to be(false)
      expect(described_class.scratch_zone?('local/keep/318/.git/config')).to be(false)
      expect(described_class.scratch_zone?('tmp/harness_story/ch01.md')).to be(false)
    end

    it 'is not a zone for a path outside the working directory (no relative form)' do
      expect(described_class.scratch_zone?(nil)).to be(false)
    end
  end

  # issue #347: the zones are also a .gitignore rule, and the two halves must
  # agree. A keep zone is gitignored BY DESIGN (a real repo clone can live there),
  # which is why evidence an issue quotes from elsewhere lives in the tracked
  # analysis/<n>/ instead. These tests drive real git with THIS project's
  # .gitignore, because that is the only way to test an ignore rule.
  describe 'the scratch zones vs .gitignore (issue #347)' do
    def project_gitignore
      File.read(File.expand_path('../../.gitignore', __dir__))
    end

    def init_repo(dir)
      File.write(File.join(dir, '.gitignore'), project_gitignore)
      system(GIT_EVIDENCE_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    end

    # git add is the honest test: git check-ignore -v prints the matching pattern
    # even when it is a NEGATION, so it cannot tell tracked from ignored.
    def tracked_files(dir)
      system(GIT_EVIDENCE_ENV, 'git', 'add', '-A', chdir: dir, exception: true)
      git_ls(dir, 'ls-files')
    end

    def git_ls(dir, subcommand, *args)
      out = IO.popen([GIT_EVIDENCE_ENV, 'git', subcommand, *args, chdir: dir], &:read)

      out.split("\n").reject(&:empty?)
    end

    it 'keeps every scratch zone out of the repo' do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        FileUtils.mkdir_p(File.join(dir, 'tmp/keep/341'))
        FileUtils.mkdir_p(File.join(dir, 'tmp/scratch/341'))
        File.write(File.join(dir, 'tmp/.gitkeep'), '')
        File.write(File.join(dir, 'tmp/keep/341/repro.rb'), "puts 1\n")
        File.write(File.join(dir, 'tmp/scratch/341/dump.txt'), "x\n")

        expect(tracked_files(dir)).to eq(['.gitignore', 'tmp/.gitkeep'])
      end
    end

    it 'leaves analysis/<n>/ trackable with the same .gitignore' do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        FileUtils.mkdir_p(File.join(dir, 'analysis/341'))
        File.write(File.join(dir, 'analysis/341/repro.rb'), "puts 1\n")

        expect(tracked_files(dir)).to eq(['.gitignore', 'analysis/341/repro.rb'])
      end
    end

    # The drift half of the rule: evidence under analysis/ that is NOT committed
    # is unreachable for the next session, which is the whole bug #347 reports.
    it 'this project has no uncommitted evidence under analysis/' do
      untracked = git_ls(PROJECT_ROOT, 'ls-files', '--others', '--', 'analysis')

      expect(untracked).to eq([])
    end
  end

  # The rule is stated in two docs; both must name the same per-issue zones.
  describe 'the documented scratch zones (issue #347)' do
    def doc_text(name)
      File.read(File.expand_path("../../#{name}", __dir__))
    end

    %w[README.md harness.md].each do |doc|
      it "#{doc} names all three per-issue zones" do
        text = doc_text(doc)

        expect(text).to include('tmp/scratch/')
        expect(text).to include('tmp/keep/')
        expect(text).to include('analysis/')
      end
    end
  end
end
