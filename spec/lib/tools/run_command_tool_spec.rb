# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/run_command_tool'

RSpec.describe Tools::RunCommandTool do
  it 'forwards the user\'s denial note to the model' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets)
        .and_return("2 this command is too broad, narrow it\n", nil)

      out = tool.execute('command' => 'rm -rf /')
      expect(out).to start_with('error: user denied executing the command')
      expect(out).to include('user\'s note: "this command is too broad, narrow it"')
    end
  end

  it 'returns a plain denial when the user cancels without a note' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets).and_return("2\n", nil)

      out = tool.execute('command' => 'rm -rf /')
      expect(out).to eq('error: user denied executing the command')
    end
  end
end
