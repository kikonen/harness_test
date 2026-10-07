# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'tools/git_apply_tool'
require 'session'

RSpec.describe Tools::GitApplyTool do
  # Minimal git repo in a tmp dir: the apply tool runs real git. The
  # identity is set via the environment so no global config is needed.
  GIT_ENV = {
    'GIT_AUTHOR_NAME'     => 'test',
    'GIT_AUTHOR_EMAIL'    => 'test@example.com',
    'GIT_COMMITTER_NAME'  => 'test',
    'GIT_COMMITTER_EMAIL' => 'test@example.com'
  }.freeze

  def setup_git_repo(dir, file: 'hello.txt', content: "line1\nline2\nline3\n")
    target = File.join(dir, file)
    File.write(target, content)
    system(GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    system(GIT_ENV, 'git', 'add', file, chdir: dir, exception: true)
    system(GIT_ENV, 'git', 'commit', '-q', '-m', 'init',
           chdir: dir, exception: true)
    target
  end

  describe '#execute' do
    it 'applies a patch to the working tree' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list)

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with('ok: patch applied')
        expect(File.read(target)).to eq("line1\nline2-changed\nline3\n")
      end
    end

    it 'tolerates wrong hunk line numbers (issue #171)' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list)

        # Declared at line 50, actual match is at line 1.
        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -50,3 +50,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with('ok: patch applied')
        expect(File.read(target)).to eq("line1\nline2-changed\nline3\n")
      end
    end

    it 'tolerates stray trailing whitespace in the diff (issue #171)' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list)

        # Context lines carry a trailing space that is not in the file on
        # disk; the tool must strip it before matching.
        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1 
          -line2 
          +line2-changed 
           line3
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with('ok: patch applied')
        expect(File.read(target)).to eq("line1\nline2-changed\nline3\n")
      end
    end

    it 'applies a patch touching multiple files' do
      Dir.mktmpdir do |dir|
        a = setup_git_repo(dir, file: 'a.txt', content: "one\ntwo\n")
        b = File.join(dir, 'b.txt')
        File.write(b, "x\ny\n")
        system(GIT_ENV, 'git', 'add', 'b.txt', chdir: dir, exception: true)
        system(GIT_ENV, 'git', 'commit', '-q', '-m', 'b', chdir: dir, exception: true)

        list = FileList.new(workdir: dir)
        list.add_file('a.txt', :rw)
        list.add_file('b.txt', :rw)
        tool  = described_class.new(list)

        diff = <<~DIFF
          diff --git a/a.txt b/a.txt
          --- a/a.txt
          +++ b/a.txt
          @@ -1,2 +1,2 @@
           one
          -two
          +TWO
          diff --git a/b.txt b/b.txt
          --- a/b.txt
          +++ b/b.txt
          @@ -1,2 +1,2 @@
           x
          -y
          +Y
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with('ok: patch applied')
        expect(File.read(a)).to eq("one\nTWO\n")
        expect(File.read(b)).to eq("x\nY\n")
      end
    end

    it 'dry run does not modify the file' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list)

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('diff' => diff, 'dry_run' => true)
        expect(out).to start_with('ok: patch is valid (dry run')
        expect(File.read(target)).to eq("line1\nline2\nline3\n")
      end
    end

    it 'returns an error when the context does not match at all' do
      Dir.mktmpdir do |dir|
        setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list)

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1
          -TOTALLY-WRONG
          +line2
           line3
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with('error: git apply failed')
      end
    end

    it 'returns an error when the diff is empty' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list)

        expect(tool.execute('diff' => '  ')).to eq("error: 'diff' is required")
      end
    end
  end

  describe 'structural pre-validation (issue #22)' do
    it 'rejects a diff without any hunk up front' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list)

        out = tool.execute('diff' => "some prose\nno hunks here\n")
        expect(out).to start_with('error: the diff contains no hunks')
      end
    end

    it 'rejects a hunk without file headers up front' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        tool   = described_class.new(list)

        diff = <<~DIFF
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with('error: the diff has hunks but no file headers')
        # The rejected patch must not have touched the file.
        expect(File.read(target)).to eq("line1\nline2\nline3\n")
      end
    end
  end

  describe 'session file cache (issue #170)' do
    it 'rejects a patch when the file changed externally since the last read' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        session = Session.new('sp')
        tool    = described_class.new(list, session)

        # Seed the cache as if we had just read the file at this state.
        session.file_cache.record(target, FileList.sha256(target), workdir: dir)

        # External change after our last read.
        File.write(target, "line1\nline2-external\nline3\n")

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with("error: 'hello.txt' has changed externally")
        # The file must be untouched by the rejected patch.
        expect(File.read(target)).to eq("line1\nline2-external\nline3\n")
      end
    end

    it 'proceeds after re-reading the file (cache refreshed) and records the new digest' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        session = Session.new('sp')
        tool    = described_class.new(list, session)

        session.file_cache.record(target, FileList.sha256(target), workdir: dir)

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('diff' => diff)
        expect(out).to start_with('ok: patch applied')
        # Our own patch refreshed the cache entry.
        expect(session.file_cache.digest(target, workdir: dir))
          .to eq(FileList.sha256(target))
      end
    end

    it 'does not refresh the cache on a dry run' do
      Dir.mktmpdir do |dir|
        target = setup_git_repo(dir)
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        session = Session.new('sp')
        tool    = described_class.new(list, session)

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('diff' => diff, 'dry_run' => true)
        expect(out).to start_with('ok: patch is valid (dry run')
        expect(session.file_cache.digest(target, workdir: dir)).to be_nil
      end
    end
  end
end
