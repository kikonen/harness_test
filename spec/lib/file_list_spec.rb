# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'

RSpec.describe FileList do
  # Drive the grant dialog without any real I/O: intercept Dialog#show and
  # perform it on StringIO streams we control. grant_access passes
  # ui: nil (task-thread contract), so the stub must NOT
  # call through to show - it performs the direct I/O itself. Returns
  # [grant result, dialog output].
  def drive_grant_dialog(list, *lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    result = list.grant_access(*@grant_args)
    [result, stdout.string]
  end

  describe '#grant_access denial' do
    it 'returns { status: :denied, note: nil } for a plain cancel' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        # file prompt: 1=file, 2=parent flat, 3=parent recursive, 4=cancel
        result, _out = drive_grant_dialog(list, "4\n")
        expect(result).to eq({ status: :denied, note: nil })
      end
    end

    it 'carries the user\'s note on a noted cancel' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        result, _out = drive_grant_dialog(list, "4 no, and because X\n")
        expect(result).to eq({ status: :denied, note: 'no, and because X' })
      end
    end

    it 'still returns :granted when the user allows' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        # file prompt option 1 = allow this file only
        result, _out = drive_grant_dialog(list, "1\n")
        expect(result).to eq(:granted)
      end
    end
  end

  describe '#grant_access for a new directory (issue #54)' do
    it 'offers the target directory itself as the first option' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['newdir', :w]
        result, _out = drive_grant_dialog(list, "1\n")
        expect(result).to eq(:granted)
        # The grant must be on the TARGET, not the parent: existing siblings
        # of the parent stay non-writable.
        expect(list.writable?('newdir')).to be(true)
        expect(list.writable?('sibling.txt')).to be(false)
      end
    end

    it 'still allows a parent-dir grant when the user prefers one' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['newdir', :w]
        # 1=target, 2=parent flat, 3=parent recursive
        result, _out = drive_grant_dialog(list, "3\n")
        expect(result).to eq(:granted)
        expect(list.writable?('newdir')).to be(true)
        expect(list.writable?('sibling.txt')).to be(true)
      end
    end
  end

  describe '#deletable? (issue #92)' do
    it 'is independent of read and write grants' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('a.txt', :rw)
        expect(list.readable?('a.txt')).to be(true)
        expect(list.writable?('a.txt')).to be(true)
        expect(list.deletable?('a.txt')).to be(false)
      end
    end

    it 'grants delete on a file and does not imply read/write' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('a.txt', :d)
        expect(list.deletable?('a.txt')).to be(true)
        expect(list.readable?('a.txt')).to be(false)
        expect(list.writable?('a.txt')).to be(false)
      end
    end

    it 'honours recursive and flat directory delete grants' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_dir('sub', :d)
        expect(list.deletable?('sub/nested/x.txt')).to be(true)

        flat = described_class.new(workdir: dir)
        flat.add_flat_dir('sub', :d)
        expect(flat.deletable?('sub/top.txt')).to be(true)
        expect(flat.deletable?('sub/nested/x.txt')).to be(false)
      end
    end

    it 'exposes delete grants in accessible_paths under a delete section' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('a.txt', :d)
        access = list.accessible_paths
        expect(access[:delete][:files]).to include(list.resolve('a.txt'))
        expect(access[:both][:files] + access[:read][:files] + access[:write][:files])
          .not_to include(list.resolve('a.txt'))
      end
    end
  end
  describe 'the scratch-zone exemption (issue #321)' do
    # The guard protects THIS project's git/harness state. A scratch repo the
    # harness cloned under tmp/keep/<n>/ is disposable, and that zone is exactly
    # the directory the scratch rule says must be deletable.
    it 'lets a zone grant cover a nested .git, .harness and .env' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_dir('tmp/keep/318', :d)
        %w[
          tmp/keep/318
          tmp/keep/318/repo/.git/config
          tmp/keep/318/repo/.git/objects/pack/x.idx
          tmp/keep/318/.harness/harness.log
          tmp/keep/318/.env.production
        ].each do |path|
          expect(list.deletable?(path)).to be(true), path
        end
        list.add_dir('tmp/scratch/321', :d)
        expect(list.deletable?('tmp/scratch/321/repo/.git/HEAD')).to be(true)
      end
    end

    it 'keeps the guard everywhere else - a bare .git is never grantable' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        expect(list.sensitive?('.git/config')).to be(true)
        expect(list.sensitive?('lib/.git/config')).to be(true)
        expect(list.sensitive?('tmp/.git/config')).to be(true)
        expect(list.sensitive?('tmp/keep/.git/config')).to be(true)
        expect(list.sensitive?('tmp/scratch/.env')).to be(true)
        expect(list.deletable?('.git/config')).to be(false)
        expect(list.add_file('.git/config', :rw)).to eq(:blocked)
        expect(list.add_dir('tmp/.git', :rw)).to eq(:blocked)
        expect(list.grant_access('.git', :d)).to eq(:blocked)
      end
    end

    it 'is decided on the RESOLVED path, so ".." cannot smuggle a name out of the zone' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        expect(list.scratch_zone?('tmp/keep/318/repo/.git/config')).to be(true)
        expect(list.scratch_zone?('tmp/keep/318/../.git/config')).to be(false)
        expect(list.sensitive?('tmp/keep/318/../.git/config')).to be(true)
      end
    end

    it 'does not exempt a directory that merely looks like a zone segment' do
      Dir.mktmpdir do |dir|
        root = File.join(dir, 'keep')
        FileUtils.mkdir_p(File.join(root, 'tmp/keep/318/.git'))
        list = described_class.new(workdir: root)
        expect(list.sensitive?('tmp/keep/318/.git/config')).to be(false)
        expect(list.sensitive?('.git/config')).to be(true)
      end
    end
  end

  describe 'the skills-zone exemption (issue #12)' do
    # .harness/skills is repo content the owner chose to keep, so it is the one
    # part of .harness/ a grant can cover. Everything else in .harness/ (sessions,
    # logs, allowlists) stays blocked, and a .env* NAME inside skills stays blocked.
    it 'lets a grant cover the skills directory and its files' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_dir('.harness/skills', :rw)

        expect(list.sensitive?('.harness/skills')).to be(false)
        expect(list.readable?('.harness/skills/changelog/SKILL.md')).to be(true)
        expect(list.writable?('.harness/skills/changelog/SKILL.md')).to be(true)
        expect(list.add_file('.harness/skills/triage.md', :r)).to eq(:added)
        expect(list.add_dir('.harness/skills/changelog', :w)).to eq(:added)
      end
    end

    it 'lets a DELETE grant cover a skill file (a skill is editable content)' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('.harness/skills/old.md', :d)

        expect(list.deletable?('.harness/skills/old.md')).to be(true)
      end
    end

    it 'keeps the rest of .harness/ blocked' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        expect(list.sensitive?('.harness/config.yml')).to be(true)
        expect(list.sensitive?('.harness/sessions/id/session.json')).to be(true)
        expect(list.sensitive?('.harness/skills/../sessions/id/session.json')).to be(true)
        expect(list.add_dir('.harness/skills/../sessions', :r)).to eq(:blocked)
        expect(list.sensitive?('.harness/skillsx/a.md')).to be(true)
        expect(list.sensitive?('.harness/skills-backup/a.md')).to be(true)
        expect(list.add_dir('.harness', :rw)).to eq(:blocked)
      end
    end

    # The exemption lifts the .harness COMPONENT rule only. A secret-file name is
    # still a secret file wherever it sits.
    it 'keeps a .env* name blocked inside the skills directory' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_dir('.harness/skills', :rw)

        expect(list.sensitive?('.harness/skills/.env')).to be(true)
        expect(list.sensitive?('.harness/skills/changelog/.env.production')).to be(true)
        expect(list.readable?('.harness/skills/.env')).to be(false)
        expect(list.add_file('.harness/skills/.env', :r)).to eq(:blocked)
      end
    end
  end

end
