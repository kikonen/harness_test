# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/file_read_tool'

RSpec.describe Tools::FileReadTool do
  it 'forwards the user\'s denial note to the model' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list)
      allow($stdin).to receive(:gets)
        .and_return("4 put tests under lib, not spec\n", nil)

      out = tool.execute('path' => 'secret.txt')
      expect(out).to start_with('error: access denied for')
      expect(out).to include('user\'s note: "put tests under lib, not spec"')
    end
  end

  it 'returns a plain denial when the user cancels without a note' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list)
      allow($stdin).to receive(:gets).and_return("4\n", nil)

      out = tool.execute('path' => 'secret.txt')
      expect(out).to eq("error: access denied for 'secret.txt'")
    end
  end
end
