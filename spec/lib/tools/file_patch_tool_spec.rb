# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'digest'
require 'tools/file_patch_tool'

RSpec.describe FilePatchTool do
  def sha_of(path)
    Digest::SHA256.file(path).hexdigest
  end

  describe '#execute' do
    it 'applies a simple single-hunk patch and returns the new sha' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'hello.txt')
        File.write(target, "line1\nline2\nline3\n")
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list, {})

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-changed
           line3
        DIFF

        out = tool.execute('path' => 'hello.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('ok: applied 1 hunk(s)')
        expect(out).to include("sha256: #{sha_of(target)}")
        expect(File.read(target)).to eq("line1\nline2-changed\nline3\n")
      end
    end

    it 'rejects a patch when the sha does not match' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'hello.txt')
        File.write(target, "line1\nline2\n")
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list, {})

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,2 +1,2 @@
           line1
          -line2
          +line2-new
        DIFF

        out = tool.execute('path' => 'hello.txt', 'diff' => diff, 'sha' => 'deadbeef')
        expect(out).to start_with('error: sha mismatch')
        expect(out).to include(sha_of(target))
      end
    end

    it 'rejects a patch when sha is missing' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'hello.txt')
        File.write(target, "line1\n")
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list, {})

        out = tool.execute('path' => 'hello.txt', 'diff' => '@@ -1 +1 @@', 'sha' => '')
        expect(out).to start_with("error: 'sha' is required")
      end
    end

    it 'returns an error when the file does not exist' do
      Dir.mktmpdir do |dir|
        list   = FileList.new(workdir: dir)
        list.add_file('missing.txt', :rw)
        tool   = described_class.new(list, {})

        out = tool.execute('path' => 'missing.txt', 'diff' => '@@ -1 +1 @@', 'sha' => 'abc')
        expect(out).to start_with("error: file 'missing.txt' does not exist")
      end
    end

    it 'returns an error when the diff contains no hunks' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'hello.txt')
        File.write(target, "line1\n")
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list, {})

        out = tool.execute('path' => 'hello.txt', 'diff' => 'no hunks here', 'sha' => sha_of(target))
        expect(out).to include('no hunks')
      end
    end

    it 'returns an error when the @@ header is malformed' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'hello.txt')
        File.write(target, "line1\n")
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list, {})

        out = tool.execute('path' => 'hello.txt', 'diff' => "@@ -abc +def @@\n+new", 'sha' => sha_of(target))
        expect(out).to start_with('error: could not parse the diff')
      end
    end

    it 'returns a plain denial when write access is denied' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'hello.txt')
        File.write(target, "line1\n")
        list   = FileList.new(workdir: dir)
        tool   = described_class.new(list, {})
        allow($stdin).to receive(:gets).and_return("4\n", nil)

        out = tool.execute('path' => 'hello.txt', 'diff' => '@@ -1 +1 @@\n+new', 'sha' => sha_of(target))
        expect(out).to eq("error: access denied for 'hello.txt'")
      end
    end

    it 'does not modify the file when dry_run is set' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'hello.txt')
        File.write(target, "line1\nline2\n")
        list   = FileList.new(workdir: dir)
        list.add_file('hello.txt', :rw)
        tool   = described_class.new(list, dry_run: true)

        diff = <<~DIFF
          --- a/hello.txt
          +++ b/hello.txt
          @@ -1,2 +1,2 @@
           line1
          -line2
          +line2-new
        DIFF

        out = tool.execute('path' => 'hello.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('DRY RUN:')
        expect(File.read(target)).to eq("line1\nline2\n")
      end
    end

    it 'applies multiple edits in a single hunk' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'multi.txt')
        File.write(target, "a\nb\nc\nd\ne\n")
        list   = FileList.new(workdir: dir)
        list.add_file('multi.txt', :rw)
        tool   = described_class.new(list, {})

        diff = <<~DIFF
          --- a/multi.txt
          +++ b/multi.txt
          @@ -1,5 +1,5 @@
          -a
          +A
           b
           c
          -d
          +D
           e
        DIFF

        out = tool.execute('path' => 'multi.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('ok: applied 1 hunk(s)')
        expect(File.read(target)).to eq("A\nb\nc\nD\ne\n")
      end
    end

    it 'locates the hunk by context even when declared line numbers are off' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'offset.txt')
        File.write(target, "x\ny\nz\nw\nv\nu\nt\ns\nr\nq\n")
        list   = FileList.new(workdir: dir)
        list.add_file('offset.txt', :rw)
        tool   = described_class.new(list, {})

        # Declared at line 2 but the actual match is at line 3 (off by one).
        diff = <<~DIFF
          --- a/offset.txt
          +++ b/offset.txt
          @@ -2,3 +2,3 @@
           z
          -w
          +W
           v
        DIFF

        out = tool.execute('path' => 'offset.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('ok: applied 1 hunk(s)')
        expect(File.read(target)).to eq("x\ny\nz\nW\nv\nu\nt\ns\nr\nq\n")
      end
    end

    it 'handles CRLF files and restores CRLF after patching' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'crlf.txt')
        File.write(target, "line1\r\nline2\r\nline3\r\n")
        list   = FileList.new(workdir: dir)
        list.add_file('crlf.txt', :rw)
        tool   = described_class.new(list, {})

        diff = <<~DIFF
          --- a/crlf.txt
          +++ b/crlf.txt
          @@ -1,3 +1,3 @@
           line1
          -line2
          +line2-new
           line3
        DIFF

        out = tool.execute('path' => 'crlf.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('ok: applied 1 hunk(s)')
        expect(File.read(target)).to eq("line1\r\nline2-new\r\nline3\r\n")
      end
    end

    it 'returns a diagnostic when the hunk context does not match' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'nomatch.txt')
        File.write(target, "alpha\nbeta\ngamma\n")
        list   = FileList.new(workdir: dir)
        list.add_file('nomatch.txt', :rw)
        tool   = described_class.new(list, {})

        diff = <<~DIFF
          --- a/nomatch.txt
          +++ b/nomatch.txt
          @@ -1,3 +1,3 @@
           alpha
          -WRONG
          +right
           gamma
        DIFF

        out = tool.execute('path' => 'nomatch.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('error: hunk at old-line')
        expect(out).to include('did not apply cleanly')
      end
    end

    it 'applies a pure insertion hunk (no deletion lines)' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'insert.txt')
        File.write(target, "top\nbottom\n")
        list   = FileList.new(workdir: dir)
        list.add_file('insert.txt', :rw)
        tool   = described_class.new(list, {})

        diff = <<~DIFF
          --- a/insert.txt
          +++ b/insert.txt
          @@ -1,2 +1,3 @@
           top
          +middle
           bottom
        DIFF

        out = tool.execute('path' => 'insert.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('ok: applied 1 hunk(s)')
        expect(File.read(target)).to eq("top\nmiddle\nbottom\n")
      end
    end

    it 'tolerates blank context lines (leading space omitted by model)' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'blank.txt')
        File.write(target, "a\n\nb\nc\n")
        list   = FileList.new(workdir: dir)
        list.add_file('blank.txt', :rw)
        tool   = described_class.new(list, {})

        # The blank line between "a" and "b" has no leading space (model quirk).
        diff = <<~DIFF
          --- a/blank.txt
          +++ b/blank.txt
          @@ -1,4 +1,4 @@
           a

          -b
          +B
           c
        DIFF

        out = tool.execute('path' => 'blank.txt', 'diff' => diff, 'sha' => sha_of(target))
        expect(out).to start_with('ok: applied 1 hunk(s)')
        expect(File.read(target)).to eq("a\n\nB\nc\n")
      end
    end

    it 'returns the updated sha in the success message' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'sha.txt')
        File.write(target, "before\n")
        list   = FileList.new(workdir: dir)
        list.add_file('sha.txt', :rw)
        tool   = described_class.new(list, {})

        diff = <<~DIFF
          --- a/sha.txt
          +++ b/sha.txt
          @@ -1 +1 @@
          -before
          +after
        DIFF

        out = tool.execute('path' => 'sha.txt', 'diff' => diff, 'sha' => sha_of(target))
        new_sha = Digest::SHA256.file(target).hexdigest
        expect(out).to include("sha256: #{new_sha}")
      end
    end
  end
end
