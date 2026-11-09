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
        # issue #384 ladder for a file at the project root:
        # 1=whole project, 2=only this file, 3=cancel
        result, _out = drive_grant_dialog(list, "3\n")
        expect(result).to eq({ status: :denied, note: nil })
      end
    end

    it 'carries the user\'s note on a noted cancel' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        result, _out = drive_grant_dialog(list, "3 no, and because X\n")
        expect(result).to eq({ status: :denied, note: 'no, and because X' })
      end
    end

    it 'still returns :granted when the user allows just this file' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        # ladder option 2 = allow only this file
        result, _out = drive_grant_dialog(list, "2\n")
        expect(result).to eq(:granted)
        # The narrow choice grants only the file, not a whole-directory grant.
        expect(list.readable?('secret.txt')).to be(true)
      end
    end
  end

  # issue #152: the base directory a glob needs READ on used to be cut out of
  # the pattern STRING at the first '*', so a brace or bracket glob named a
  # directory that does not exist ('{README.md,lib/commands/*}' ->
  # '{README.md,lib/commands'). analysis/152/repro.rb measures both derivations.
  describe '#glob_base_dir (issue #152)' do
    def tree(dir)
      FileUtils.mkdir_p(File.join(dir, 'lib/commands'))
      FileUtils.mkdir_p(File.join(dir, 'analysis/152'))
      File.write(File.join(dir, 'README.md'), "x\n")
      File.write(File.join(dir, 'lib/a.rb'), "x\n")
      File.write(File.join(dir, 'lib/commands/clear.rb'), "x\n")
      File.write(File.join(dir, 'analysis/152/repro.rb'), "x\n")
    end

    def base_for(pattern)
      Dir.mktmpdir do |dir|
        tree(dir)
        described_class.new(workdir: dir).display_path(
          described_class.new(workdir: dir).glob_base_dir(pattern)
        )
      end
    end

    it 'strips a plain wildcard glob to its directory' do
      expect(base_for('lib/**/*.rb')).to eq('lib')
      expect(base_for('lib/*.rb')).to eq('lib')
      expect(base_for('**/*')).to eq('.')
    end

    it 'derives from the literal segments of a brace glob, not from its braces' do
      expect(base_for('{README.md,lib/commands/*}')).to eq('.')
      expect(base_for('lib/{a,b}/*.rb')).to eq('lib')
      expect(base_for('lib/tools/{file_*,git_*}.rb')).to eq('lib/tools')
    end

    it 'derives from the literal segments of a bracket glob' do
      expect(base_for('analysis/[0-9]*/repro.rb')).to eq('analysis')
    end

    it 'keeps a literal directory pattern as its own base' do
      expect(base_for('lib')).to eq('lib')
      expect(base_for('.')).to eq('.')
    end

    it 'takes the parent of a literal file path' do
      expect(base_for('lib/a.rb')).to eq('lib')
    end

    it 'never leaves the workdir for a pattern inside it' do
      Dir.mktmpdir do |dir|
        tree(dir)
        base = described_class.new(workdir: dir).glob_base_dir('**/*')
        expect(described_class.new(workdir: dir).within_workdir?(base)).to be true
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
        # issue #384 ladder: 1=new dir only, 2=whole parent directory,
        # 3=parent direct children only. Picking the whole-parent grant.
        result, _out = drive_grant_dialog(list, "2\n")
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
  # issue #105: a grant on a path that has just been deleted is stale, and
  # grant_access returns :granted without a dialog when a path is already
  # granted - so a leftover would skip fresh consent if the same path is
  # re-created. revoke_grants drops the EXACT path across all modes/tiers and
  # leaves an ancestor recursive grant (a different path string) intact.
  describe '#revoke_grants (issue #105)' do
    it 'drops every mode and tier grant on the exact path' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('a.txt', :r)
        list.add_file('a.txt', :w)
        list.add_file('a.txt', :d)

        expect(list.revoke_grants('a.txt')).to eq(3)
        expect(list.readable?('a.txt')).to be(false)
        expect(list.writable?('a.txt')).to be(false)
        expect(list.deletable?('a.txt')).to be(false)
      end
    end

    it 'leaves an ancestor recursive grant covering OTHER paths intact' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_dir('sub', :d)
        list.add_file('sub/gone.txt', :d)

        list.revoke_grants('sub/gone.txt')
        # The parent recursive grant still covers the sibling.
        expect(list.deletable?('sub/keep.txt')).to be(true)
      end
    end

    it 'returns 0 and changes nothing for a path with no grant' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        expect(list.revoke_grants('never.txt')).to eq(0)
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
        # The memory store (issue #10) is harness state like the rest of
        # .harness/: memory.* reaches it through its own reader, and the file
        # tools must not be able to write it as a path.
        expect(list.sensitive?("#{Memories::DIR}/note.md")).to be(true)
        expect(list.add_dir(Memories::DIR, :rw)).to eq(:blocked)
        expect(list.add_file("#{Memories::DIR}/note.md", :w)).to eq(:blocked)
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

  # YOLO for file access (issue #274): when the user turns the posture on, a path
  # INSIDE the working directory is covered for read/write/delete without a dialog.
  # Three boundaries the posture must never cross: a sensitive path, the owner's own
  # space (local/), and anything outside the working directory. The posture is a
  # live coverage rule (a lambda), NOT a stored grant - so it never persists, never
  # shows up in the access lists a session saves, and stops the instant it is off.
  describe 'YOLO posture coverage (issue #274)' do
    # The posture is read live through a lambda, exactly as Harness wires it.
    def list_with_posture(dir, active)
      list    = described_class.new(workdir: dir)
      state   = { on: active }
      list.posture = -> { state[:on] }
      [list, state]
    end

    it 'is off when no posture is wired (the default, unchanged behaviour)' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        expect(list.posture_active?).to be(false)
        expect(list.readable?('lib/foo.rb')).to be(false)
      end
    end

    it 'covers a workdir file for read, write and delete when the posture is on' do
      Dir.mktmpdir do |dir|
        list, = list_with_posture(dir, true)
        expect(list.posture_active?).to be(true)
        expect(list.readable?('lib/foo.rb')).to be(true)
        expect(list.writable?('lib/foo.rb')).to be(true)
        expect(list.deletable?('lib/foo.rb')).to be(true)
        # Deep paths are covered too - the coverage is the whole workdir tree,
        # which is the whole point (the analysis/<NNN>/ repetition of issue #274).
        expect(list.readable?('analysis/246/repro.rb')).to be(true)
      end
    end

    it 'never covers the owner space - local/ keeps asking in every posture' do
      Dir.mktmpdir do |dir|
        list, = list_with_posture(dir, true)
        expect(list.readable?('local/handover.md')).to be(false)
        expect(list.writable?('local/handover.md')).to be(false)
        expect(list.deletable?('local/sub/deep.md')).to be(false)
        # A lookalike is normal workdir and IS covered.
        expect(list.readable?('localback/x.md')).to be(true)
      end
    end

    # issue #385: the protected list is configurable. An explicit list replaces
    # the default (local/), so a different dir keeps its dialog and local/ is no
    # longer special unless named.
    it 'honours a configured protected_dirs list instead of the default' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir, protected_dirs: %w[secrets private])
        list.posture = -> { true }
        expect(list.readable?('secrets/key.txt')).to be(false)
        expect(list.writable?('private/a/b.md')).to be(false)
        # local/ is no longer protected unless named - it is covered now.
        expect(list.readable?('local/handover.md')).to be(true)
        # A normal workdir path is still covered.
        expect(list.readable?('lib/foo.rb')).to be(true)
      end
    end

    it 'an explicit empty protected_dirs list protects nothing (posture covers all)' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir, protected_dirs: [])
        list.posture = -> { true }
        expect(list.readable?('local/handover.md')).to be(true)
      end
    end

    it 'a human grant still covers a protected dir (the veto is posture-only)' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir, protected_dirs: %w[local])
        list.add_file(File.join(dir, 'local', 'notes.md'), :rw)
        expect(list.readable?('local/notes.md')).to be(true)
        expect(list.writable?('local/notes.md')).to be(true)
      end
    end

    it 'never covers a sensitive path, whatever the posture' do
      Dir.mktmpdir do |dir|
        list, = list_with_posture(dir, true)
        expect(list.readable?('.env')).to be(false)
        expect(list.writable?('.git/config')).to be(false)
        expect(list.deletable?('.harness/sessions/x/session.json')).to be(false)
      end
    end

    it 'still covers the skills subtree it already covered as a grant (exemption intact)' do
      Dir.mktmpdir do |dir|
        list, = list_with_posture(dir, true)
        expect(list.readable?('.harness/skills/changelog/SKILL.md')).to be(true)
        # ...but a secret name inside it stays blocked.
        expect(list.readable?('.harness/skills/.env')).to be(false)
      end
    end

    it 'never covers a path outside the working directory (a posture is not an escape)' do
      Dir.mktmpdir do |dir|
        list, = list_with_posture(dir, true)
        expect(list.readable?('../outside.rb')).to be(false)
        expect(list.writable?('../outside.rb')).to be(false)
      end
    end

    it 'stops coverage the instant the posture flips off (read live, not cached)' do
      Dir.mktmpdir do |dir|
        list, state = list_with_posture(dir, true)
        expect(list.readable?('lib/foo.rb')).to be(true)
        state[:on] = false
        expect(list.posture_active?).to be(false)
        expect(list.readable?('lib/foo.rb')).to be(false)
      end
    end

    it 'coverage is NOT a stored grant - nothing is added to the access lists' do
      Dir.mktmpdir do |dir|
        list, = list_with_posture(dir, true)
        list.readable?('lib/foo.rb')
        list.writable?('lib/foo.rb')
        list.deletable?('lib/foo.rb')
        expect(list.access_grant_count).to eq(0)
        expect(list.empty?).to be(true)
        expect(list.accessible_paths[:both][:files]).to be_empty
      end
    end

    # An auto-approval must leave a trace, the rule YOLO's shell runs follow (#221):
    # a harness.log line naming the posture that let the access through. Once per
    # mode - file.list/file.search call readable? on every candidate and dir.delete on
    # every entry, so a per-access line would bury the log.
    it 'logs the coverage to harness.log, once per mode' do
      Dir.mktmpdir do |dir|
        list, = list_with_posture(dir, true)
        logged = []
        logger = double('logger')
        allow(logger).to receive(:info) { |m| logged << m }
        list.audit_logger = logger

        5.times { list.readable?('lib/a.rb') }
        list.writable?('lib/b.rb')
        list.deletable?('lib/c.rb')

        read_lines = logged.select { |m| m.include?('read access') }
        expect(read_lines.size).to eq(1)
        expect(read_lines.first).to include('auto-granted (YOLO)')
        expect(logged.select { |m| m.include?('write access') }.size).to eq(1)
        expect(logged.select { |m| m.include?('delete access') }.size).to eq(1)
      end
    end

    it 're-announces after the posture is flipped back on' do
      Dir.mktmpdir do |dir|
        list, state = list_with_posture(dir, true)
        logged = []
        logger = double('logger')
        allow(logger).to receive(:info) { |m| logged << m }
        list.audit_logger = logger

        list.readable?('lib/a.rb')
        state[:on] = false
        list.readable?('lib/a.rb') # off: resets the per-mode flag
        state[:on] = true
        list.readable?('lib/a.rb') # back on: must announce again

        expect(logged.count { |m| m.include?('read access') }).to eq(2)
      end
    end
  end

  # issue #388: the grant dialog states each note line's KIND, so a colored
  # console can tell the purpose line (context, terminal color) from the line
  # the user must weigh before granting (the outside-workdir WARNING).
  describe 'grant dialog note kinds (issue #388)' do
    # grant_access passes ui: nil (task-thread contract); the stub serves the
    # dialog on a console WITH a palette, so the paint is observable.
    def drive_colored_grant(list, answer, purpose: nil)
      stdout = StringIO.new
      allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
        dialog.perform_direct(
          ui: UI::Console.new(stdout:, stdin: StringIO.new(answer),
                              palette: UI::Palette.new('default'))
        )
      end
      list.grant_access(*@grant_args, purpose:)
      stdout.string
    end

    it 'colors the outside-workdir WARNING and leaves the purpose plain' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['../outside.txt', :r]
        out = drive_colored_grant(list, "2\n", purpose: 'to read the config')

        # issue #476: a long note wraps to the dialog width, so the WARNING is
        # the alert color on EVERY wrapped line (the whole text survives, each
        # physical line is painted, not just the first).
        expect(out).to include(
          "\e[38;5;130mWARNING: this path is OUTSIDE the working directory - granting\e[0m"
        )
        expect(out).to include(
          "\e[38;5;130maccess may be a sandbox escape.\e[0m"
        )
        # No line carries the full un-wrapped run (it was re-wrapped).
        expect(out).not_to include(
          "\e[38;5;130mWARNING: this path is OUTSIDE the working directory - granting access may be a sandbox escape.\e[0m"
        )
        # CONTEXT is content to read, not chrome: no escape bytes around it.
        expect(out).to include("\n                to read the config\n")
      end
    end

    it 'an inside-workdir grant has no warn line to color' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        out = drive_colored_grant(list, "4\n", purpose: 'to patch it')

        expect(out).not_to include("OUTSIDE the working directory")
        expect(out).not_to include("\e[38;5;130m")
        expect(out).to include("\n                to patch it\n")
      end
    end
  end

end
