# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'tools/dir_delete_tool'

# Issue #290: dir.delete deletes the whole tree, and every deleted path is
# written to harness.log. Before this the tool refused a non-empty directory,
# which pushed the model to `rm -rf` through run.command - a route that records
# the command string and never the paths removed.
RSpec.describe Tools::DirDeleteTool do
  # Grant dialog driven without real I/O: intercept Dialog#show (tools run on
  # the Task thread and call it with ui: nil) and interact directly.
  def drive_dialog(*lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  def harness_with_log
    log = StringIO.new
    harness = Class.new { attr_accessor :logger }.new
    harness.logger = Logger.new(log)
    [harness, log]
  end

  # A nested tree: dir/a.txt, dir/sub/b.txt, dir/sub/deep/c.txt, dir/empty/.
  def seed_tree(dir)
    FileUtils.mkdir_p(File.join(dir, 'tree/sub/deep'))
    FileUtils.mkdir_p(File.join(dir, 'tree/empty'))
    File.write(File.join(dir, 'tree/a.txt'), 'a')
    File.write(File.join(dir, 'tree/sub/b.txt'), 'b')
    File.write(File.join(dir, 'tree/sub/deep/c.txt'), 'c')
    File.join(dir, 'tree')
  end

  # Whichever link this box can build: a real symlink, or - Windows without
  # developer mode, where File.symlink raises EACCES - an NTFS junction
  # (mklink /J, no privilege). Ruby reports a junction as a link
  # (File.symlink? true) while File.directory? still follows it, which is the
  # exact shape the guard is about. false when neither can be built.
  def make_dir_link(link, target)
    File.symlink(target, link)
    true
  rescue SystemCallError
    junction = system('cmd', '/c', 'mklink', '/J', link.tr('/', '\\'), target.tr('/', '\\'),
                      out: File::NULL, err: File::NULL)
    junction && File.symlink?(link)
  end

  def build(list, session: nil, harness: nil)
    described_class.new(list, session: session, harness: harness)
  end

  describe 'recursive deletion (issue #290)' do
    it 'deletes a non-empty directory with its whole tree' do
      Dir.mktmpdir do |dir|
        tree   = seed_tree(dir)
        list   = FileList.new(workdir: dir)
        list.add_dir('tree', :d) # recursive DELETE grant, no dialog
        harness, = harness_with_log

        out = build(list, harness: harness).execute('path' => 'tree')

        expect(out).to start_with("ok: directory 'tree' and its contents have been deleted")
        expect(out).to include('3 file(s), 3 dir(s)')
        expect(out).to include('each path logged')
        expect(File.exist?(tree)).to be(false)
      end
    end

    it 'deletes an empty directory exactly as before' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'gone'))
        list = FileList.new(workdir: dir)
        list.add_dir('gone', :d)

        out = build(list).execute('path' => 'gone')

        expect(out).to start_with("ok: directory 'gone' and its contents have been")
        expect(out).to include('0 file(s), 0 dir(s)')
        expect(File.exist?(File.join(dir, 'gone'))).to be(false)
      end
    end

    it 'refuses to delete a symlink: file.delete is the unlink path' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'keep')
        FileUtils.mkdir_p(target)
        File.write(File.join(target, 'inside.txt'), 'keep me')
        link = File.join(dir, 'link')
        skip 'no link fixture buildable on this box' unless make_dir_link(link, target)

        list = FileList.new(workdir: dir)
        list.add_dir('link', :d)

        out = build(list).execute('path' => 'link')

        expect(out).to include('is a symlink - delete it with file.delete')
        expect(File.symlink?(link)).to be(true)
        expect(File.exist?(File.join(target, 'inside.txt'))).to be(true)
      end
    end

    # The other half of the rule: a link INSIDE a tree is a leaf. Descending
    # into it would delete a tree the grant never covers (issue #290).
    it 'unlinks a symlink inside a tree as a leaf and never walks into it' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'keep')
        FileUtils.mkdir_p(target)
        File.write(File.join(target, 'inside.txt'), 'keep me')
        tree = File.join(dir, 'tree')
        FileUtils.mkdir_p(File.join(tree, 'sub'))
        File.write(File.join(tree, 'a.txt'), 'a')
        link = File.join(tree, 'sub', 'inner')
        skip 'no link fixture buildable on this box' unless make_dir_link(link, target)
        list = FileList.new(workdir: dir)
        list.add_dir('tree', :d)

        out = build(list).execute('path' => 'tree')

        expect(out).to include('2 file(s), 1 dir(s)')
        expect(File.exist?(tree)).to be(false)
        expect(File.directory?(target)).to be(true)
        expect(File.exist?(File.join(target, 'inside.txt'))).to be(true)
      end
    end

    it 'refuses the working directory itself' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        list.add_dir('.', :d)

        out = build(list).execute('path' => '.')

        expect(out).to include('is the working directory - it can never be deleted')
        expect(File.directory?(dir)).to be(true)
      end
    end

    it 'refuses a directory holding a sensitive subtree, deleting nothing' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'proj/.git'))
        File.write(File.join(dir, 'proj/.git/config'), 'x')
        File.write(File.join(dir, 'proj/keep.txt'), 'x')
        list = FileList.new(workdir: dir)
        list.add_dir('proj', :d)

        out = build(list).execute('path' => 'proj')

        expect(out).to include('contains the sensitive path')
        expect(out).to include('nothing was deleted')
        expect(File.exist?(File.join(dir, 'proj/.git/config'))).to be(true)
        expect(File.exist?(File.join(dir, 'proj/keep.txt'))).to be(true)
      end
    end

    # issue #321: the scratch rule says tmp/keep/<n> is removed when its issue
    # closes, but a git-related measurement needs REAL repos there, and a real
    # repo has a .git - so the tree tool refused to delete the very zone the
    # rule promised to clean. The exemption is the zone, not the name.
    it 'deletes a scratch zone holding a nested .git (the #318 keep zone)' do
      Dir.mktmpdir do |dir|
        seed_scratch_zone(dir)
        list = FileList.new(workdir: dir)
        list.add_dir('tmp/keep/318', :d)
        harness, log = harness_with_log

        out = build(list, harness: harness).execute('path' => 'tmp/keep/318')

        expect(out).to start_with("ok: directory 'tmp/keep/318' and its contents")
        expect(File.exist?(File.join(dir, 'tmp/keep/318'))).to be(false)
        expect(log.string).to include('dir.delete: deleted file tmp/keep/318/repo/.git/config')
        # The zone list itself is still not a zone: its own .git stays guarded.
        expect(File.directory?(File.join(dir, 'tmp/keep/.git'))).to be(true)
      end
    end

    it 'still refuses a scratch zone whose SIBLING holds the real .git' do
      Dir.mktmpdir do |dir|
        seed_scratch_zone(dir)
        list = FileList.new(workdir: dir)
        list.add_dir('tmp', :d)

        out = build(list).execute('path' => 'tmp')

        expect(out).to include('contains the sensitive path')
        expect(out).to include('tmp/keep/.git/config')
        expect(File.exist?(File.join(dir, 'tmp/keep/318/repo/.git/config'))).to be(true)
      end
    end

    it 'keeps the project own .git unremovable from inside a scratch zone path' do
      Dir.mktmpdir do |dir|
        seed_scratch_zone(dir)
        list = FileList.new(workdir: dir)
        list.add_dir('tmp/keep/318', :d)

        out = build(list).execute('path' => 'tmp/keep/318/../.git')

        expect(out).to include('blocked and can never be deleted')
        expect(File.directory?(File.join(dir, '.git'))).to be(true)
      end
    end
  end

  describe 'the DELETE grant (issue #92)' do
    it 'asks once for the whole tree and deletes it after a recursive grant' do
      Dir.mktmpdir do |dir|
        tree = seed_tree(dir)
        list = FileList.new(workdir: dir)
        # Dir prompt options: 1 = this directory only, 2 = recursive, 3 = cancel.
        dialog_out = drive_dialog("2\n") # recursive grant (dir + subdirs)

        out = build(list).execute('path' => 'tree')

        expect(out).to start_with("ok: directory 'tree' and its contents")
        expect(dialog_out.string.scan(/Access requested \(delete access\)/).size).to eq(1)
        expect(File.exist?(tree)).to be(false)
      end
    end

    it 'refuses to delete half a tree when the grant does not cover the contents' do
      Dir.mktmpdir do |dir|
        tree = seed_tree(dir)
        list = FileList.new(workdir: dir)
        drive_dialog("1\n") # 'this directory only' - does not cover the tree

        out = build(list).execute('path' => 'tree')

        expect(out).to include('does not cover its contents')
        expect(out).to include('recursive')
        # The tree must survive INTACT - a partial delete is the failure mode.
        expect(File.exist?(File.join(tree, 'sub/deep/c.txt'))).to be(true)
      end
    end

    it 'reports the denial and forwards the user note' do
      Dir.mktmpdir do |dir|
        tree = seed_tree(dir)
        list = FileList.new(workdir: dir)
        drive_dialog("3 nope, keep the scratch\n") # 3 = cancel + reason

        out = build(list).execute('path' => 'tree')

        expect(out).to start_with("error: delete access denied for 'tree'")
        expect(out).to include('user\'s note: "nope, keep the scratch"')
        expect(File.exist?(tree)).to be(true)
      end
    end
  end

  # The whole point of the issue: the deletion must be traceable from
  # harness.log, not from the shell command string.
  describe 'the audit log (issue #290)' do
    it 'logs every deleted path plus the summary' do
      Dir.mktmpdir do |dir|
        seed_tree(dir)
        list = FileList.new(workdir: dir)
        list.add_dir('tree', :d)
        harness, log = harness_with_log

        build(list, harness: harness).execute('path' => 'tree')

        # Logger adds its own timestamp/level prefix; the payload is what
        # matters (harness.log is the authoritative record of the deletion).
        logged = log.string.lines.grep(/dir\.delete: /).map { |l| l[/dir\.delete: .*/] }
        expect(logged).to include('dir.delete: deleted file tree/a.txt')
        expect(logged).to include('dir.delete: deleted file tree/sub/b.txt')
        expect(logged).to include('dir.delete: deleted file tree/sub/deep/c.txt')
        expect(logged).to include('dir.delete: deleted directory tree/sub')
        expect(logged).to include('dir.delete: deleted directory tree/empty')
        expect(logged.last)
          .to eq('dir.delete: deleted directory tree (3 file(s), 3 dir(s))')
      end
    end

    it 'still deletes (and says the paths are unlogged) when no harness is attached' do
      Dir.mktmpdir do |dir|
        tree = seed_tree(dir)
        list = FileList.new(workdir: dir)
        list.add_dir('tree', :d)

        out = build(list).execute('path' => 'tree')

        expect(out).to start_with("ok: directory 'tree'")
        expect(File.exist?(tree)).to be(false)
      end
    end

    it 'reads the logger live so the harness swapped in by /resume is followed' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'one'))
        list = FileList.new(workdir: dir)
        list.add_dir('one', :d)
        log_a = StringIO.new
        log_b = StringIO.new
        harness = Class.new do
          attr_accessor :logger
        end.new
        harness.logger = Logger.new(log_a)

        tool = build(list, harness: harness)
        harness.logger = Logger.new(log_b) # the fresh harness of a resumed run
        tool.execute('path' => 'one')

        expect(log_a.string).to be_empty
        expect(log_b.string).to include('dir.delete: deleted directory one')
      end
    end
  end

  describe 'the session file cache (issue #170)' do
    it 'drops the digest entry of every deleted file' do
      Dir.mktmpdir do |dir|
        seed_tree(dir)
        session = Session.new('sys')
        session.file_cache.record(File.join(dir, 'tree/a.txt'), 'deadbeef',
                                  workdir: dir)
        list = FileList.new(workdir: dir)
        list.add_dir('tree', :d)

        build(list, session: session).execute('path' => 'tree')

        expect(session.file_cache.known?('tree/a.txt', workdir: dir)).to be(false)
      end
    end
  end

  describe 'input validation' do
    it 'reports a path that is not a directory' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'f.txt'), 'x')
        list = FileList.new(workdir: dir)
        list.add_dir('f.txt', :d)

        out = build(list).execute('path' => 'f.txt')

        expect(out).to include('does not exist or is not a directory')
      end
    end

    it 'blocks a sensitive directory outright' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.git'))
        list = FileList.new(workdir: dir)

        out = build(list).execute('path' => '.git')

        expect(out).to include('blocked and can never be deleted')
      end
    end
  end

  # A keep zone with a scratch repo inside it, plus the zone-list .git that
  # must stay guarded, plus the project own .git.
  def seed_scratch_zone(dir)
    FileUtils.mkdir_p(File.join(dir, 'tmp/keep/318/repo/.git'))
    File.write(File.join(dir, 'tmp/keep/318/repo/.git/config'), 'x')
    File.write(File.join(dir, 'tmp/keep/318/issue_crlf.md'), 'x')
    FileUtils.mkdir_p(File.join(dir, 'tmp/keep/.git'))
    File.write(File.join(dir, 'tmp/keep/.git/config'), 'x')
    FileUtils.mkdir_p(File.join(dir, '.git'))
    File.write(File.join(dir, '.git/config'), 'x')
  end
end
