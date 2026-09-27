# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/dir_create_tool'

RSpec.describe DirCreateTool do
  it 'forwards the user\'s denial note for the parent dir grant' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets)
        .and_return("3 nope, use a different layout\n", nil) # grant target is the PARENT (existing dir) -> dir prompt: 1=flat, 2=recursive, 3=cancel

      out = tool.execute('path' => 'newdir')
      expect(out).to start_with('error: write access denied')
      expect(out).to include('user\'s note: "nope, use a different layout"')
    end
  end
end
