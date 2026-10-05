# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/dir_create_tool'

RSpec.describe Tools::DirCreateTool do
  # Drive the grant dialog without any real I/O: intercept Dialog#show (the
  # tool calls it with ui: nil because tools run on the Task
  # thread) and perform the interaction directly on a StringIO. Returns the
  # dialog's rendered output for assertions.
  def drive_dialog(*lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  it 'forwards the user\'s denial note for the new-dir grant' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      # target-first prompt (issue #54): 1=target, 2=parent flat,
      # 3=parent recursive, 4=cancel
      drive_dialog("4 nope, use a different layout\n")

      out = tool.execute('path' => 'newdir')
      expect(out).to start_with('error: write access denied')
      expect(out).to include('user\'s note: "nope, use a different layout"')
    end
  end

  it 'offers the new directory itself first in the grant prompt (issue #54)' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      drive_dialog("1\n")

      out = tool.execute('path' => 'newdir')
      expect(out).to eq("ok: created directory 'newdir'")
      # The grant landed on the TARGET, not the parent: existing siblings
      # of the parent stay non-writable.
      expect(list.writable?('newdir')).to be(true)
      expect(list.writable?('sibling.txt')).to be(false)
    end
  end

  it 'creates the dir without prompting when the target itself is granted (issue #54)' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      list.add_file('newdir', :w) # grant on the target itself
      tool = described_class.new(list, {})

      out = tool.execute('path' => 'newdir')
      expect(out).to eq("ok: created directory 'newdir'")
      expect(File.directory?(File.join(dir, 'newdir'))).to be(true)
    end
  end

  it 'creates the dir without prompting when the parent is granted' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      list.add_flat_dir('.', :w)
      tool = described_class.new(list, {})

      out = tool.execute('path' => 'newdir')
      expect(out).to eq("ok: created directory 'newdir'")
    end
  end
end
