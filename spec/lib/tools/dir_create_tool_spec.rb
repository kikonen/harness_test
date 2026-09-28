# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/dir_create_tool'

RSpec.describe Tools::DirCreateTool do
  it 'forwards the user\'s denial note for the new-dir grant' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets)
        .and_return("4 nope, use a different layout\n", nil)
        # target-first prompt (issue #54): 1=target, 2=parent flat,
        # 3=parent recursive, 4=cancel

      out = tool.execute('path' => 'newdir')
      expect(out).to start_with('error: write access denied')
      expect(out).to include('user\'s note: "nope, use a different layout"')
    end
  end

  it 'offers the new directory itself first in the grant prompt (issue #54)' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets).and_return("1\n", nil)

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
      allow($stdin).to receive(:gets) # must NOT be called

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
      allow($stdin).to receive(:gets) # must NOT be called

      out = tool.execute('path' => 'newdir')
      expect(out).to eq("ok: created directory 'newdir'")
    end
  end
end