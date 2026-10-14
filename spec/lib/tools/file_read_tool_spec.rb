# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'json'
require 'tools/file_read_tool'

RSpec.describe Tools::FileReadTool do
  # Drive the grant dialog without any real I/O: intercept Dialog#show (the
  # tool calls it with ui: nil because tools run on the Task
  # thread) and perform the interaction directly on a StringIO.
  def drive_dialog(*lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
  end

  it 'forwards the user\'s denial note to the model' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list)
      drive_dialog("4 put tests under lib, not spec\n")

      out = tool.execute('path' => 'secret.txt')
      expect(out).to start_with('error: access denied for')
      expect(out).to include('user\'s note: "put tests under lib, not spec"')
    end
  end

  it 'returns a plain denial when the user cancels without a note' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list)
      drive_dialog("4\n")

      out = tool.execute('path' => 'secret.txt')
      expect(out).to eq("error: access denied for 'secret.txt'")
    end
  end

  # issue #257: a file on disk can hold bytes that are not valid UTF-8 (or a
  # code page tagged by default_external). Read raw, the string is byte
  # invalid, so the tool's own gsub raises and the returned content breaks
  # the session's JSON.save. Normalizing at the read boundary means the
  # model receives the replacement character instead of a crashed turn.
  describe 'invalid UTF-8 bytes (issue #257)' do
    def bad_bytes
      [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)
    end

    it 'returns valid UTF-8 for a file containing an undecodable byte' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'sample.txt')
        File.binwrite(path, "line1 ok\nline2 " + bad_bytes + "\n")

        list = FileList.new([], workdir: dir)
        list.add_dir(dir, :r)
        out = described_class.new(list).execute('path' => 'sample.txt')

        expect(out.valid_encoding?).to be true
        expect(out).to eq("line1 ok\nline2 ?\n")
        # The content goes straight into the message chain / session save.
        expect { JSON.generate({ 'content' => out }) }.not_to raise_error
      end
    end
  end
end
