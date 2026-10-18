# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/file_write_tool'
require 'session'

RSpec.describe Tools::FileWriteTool do
  # Drive the grant dialog without any real I/O (the tool calls it with ui: nil
  # because tools run on the Task thread).
  def drive_dialog(*lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
  end

  def tool_for(dir, name, session: nil)
    list = FileList.new(workdir: dir)
    list.add_file(name, :rw)
    described_class.new(list, session)
  end

  describe '#execute' do
    it 'writes a new file' do
      Dir.mktmpdir do |dir|
        out = tool_for(dir, 'new.txt').execute('path' => 'new.txt', 'content' => "a\nb\n")
        expect(out).to start_with('ok: wrote')
        expect(File.binread(File.join(dir, 'new.txt'))).to eq("a\nb\n")
      end
    end

    it 'creates missing parent directories' do
      Dir.mktmpdir do |dir|
        tool = tool_for(dir, 'sub/deep/new.txt')
        expect(tool.execute('path' => 'sub/deep/new.txt', 'content' => "x\n")).to start_with('ok: wrote')
        expect(File.binread(File.join(dir, 'sub/deep/new.txt'))).to eq("x\n")
      end
    end

    it 'refreshes its own digest, so a second write is not an external change' do
      Dir.mktmpdir do |dir|
        target  = File.join(dir, 'f.txt')
        File.binwrite(target, "a\nb\n")
        session = Session.new('sw')
        tool    = tool_for(dir, 'f.txt', session: session)
        session.file_cache.record(target, FileList.sha256(target), workdir: dir)

        expect(tool.execute('path' => 'f.txt', 'content' => "a\nb2\n")).to start_with('ok: wrote')
        expect(tool.execute('path' => 'f.txt', 'content' => "a\nb3\n")).to start_with('ok: wrote')
      end
    end

    it 'rejects a write when the file changed externally since the last read' do
      Dir.mktmpdir do |dir|
        target  = File.join(dir, 'f.txt')
        File.binwrite(target, "a\nb\n")
        session = Session.new('sw')
        tool    = tool_for(dir, 'f.txt', session: session)
        session.file_cache.record(target, FileList.sha256(target), workdir: dir)

        File.binwrite(target, "a\nb-external\n")
        expect(tool.execute('path' => 'f.txt', 'content' => "a\nb2\n"))
          .to start_with("error: 'f.txt' has changed externally")
      end
    end

    it 'returns a plain denial when write access is denied' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list)
        drive_dialog("4\n")

        out = tool.execute('path' => 'denied.txt', 'content' => "x\n")
        expect(out).to eq("error: access denied for 'denied.txt'")
        expect(File.exist?(File.join(dir, 'denied.txt'))).to eq(false)
      end
    end
  end

  describe 'line endings (issue #318)' do
    it 'writes LF bytes for a new file whose content is LF' do
      Dir.mktmpdir do |dir|
        tool_for(dir, 'f.txt').execute('path' => 'f.txt', 'content' => "a\nb\n")
        expect(File.binread(File.join(dir, 'f.txt'))).to eq("a\nb\n")
      end
    end

    it 'writes CRLF bytes for a new file whose content is CRLF' do
      Dir.mktmpdir do |dir|
        tool_for(dir, 'f.txt').execute('path' => 'f.txt', 'content' => "a\r\nb\r\n")
        expect(File.binread(File.join(dir, 'f.txt'))).to eq("a\r\nb\r\n")
      end
    end

    it 'leaves an existing LF file as LF bytes' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'f.txt')
        File.binwrite(target, "a\nb\n")
        tool_for(dir, 'f.txt').execute('path' => 'f.txt', 'content' => "a\nb2\n")
        expect(File.binread(target)).to eq("a\nb2\n")
      end
    end

    it 'keeps CRLF bytes when the model sends LF text to a CRLF file' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'f.txt')
        File.binwrite(target, "a\r\nb\r\n")
        out = tool_for(dir, 'f.txt').execute('path' => 'f.txt', 'content' => "a\nb2\n")
        expect(out).to start_with('ok: wrote')
        # Plain LF content is what the model ALWAYS sends, so it is the normal
        # path and carries no repair note.
        expect(out).not_to include('normalized')
        expect(File.binread(target)).to eq("a\r\nb2\r\n")
        expect(File.binread(target)).not_to include("\r\r\n")
      end
    end

    it 'normalizes doubled CR bytes in model content instead of writing them' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'f.txt')
        File.binwrite(target, "a\nb\n")
        out = tool_for(dir, 'f.txt').execute('path' => 'f.txt', 'content' => "a\r\r\nb2\r\n")
        expect(out).to include('1 bare CR normalized to LF')
        expect(File.binread(target)).to eq("a\nb2\n")
      end
    end

    it 'normalizes content that carries both endings to the file style and says so' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'f.txt')
        File.binwrite(target, "a\r\nb\r\n")
        out = tool_for(dir, 'f.txt').execute('path' => 'f.txt', 'content' => "a\r\nb2\nc\n")
        expect(out).to include('normalized to CRLF')
        expect(File.binread(target)).to eq("a\r\nb2\r\nc\r\n")
      end
    end

    it 'reports when a write replaces bytes that were not valid UTF-8' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'f.txt')
        File.binwrite(target, ['a', "\xE4", "b\n"].join.b)
        out = tool_for(dir, 'f.txt').execute('path' => 'f.txt', 'content' => "ab\n")
        expect(out).to include('not valid UTF-8')
        expect(File.binread(target)).to eq("ab\n")
      end
    end
  end
end
