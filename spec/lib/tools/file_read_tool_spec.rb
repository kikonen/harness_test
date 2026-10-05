# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
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
end
