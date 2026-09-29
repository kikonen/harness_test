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
      # Options are now: Allow(1), Always allow(2), Cancel(3)
      allow($stdin).to receive(:gets)
        .and_return("3 this command is too broad, narrow it\n", nil)

      out = tool.execute('command' => 'rm -rf /')
      expect(out).to start_with('error: user denied executing the command')
      expect(out).to include('user\'s note: "this command is too broad, narrow it"')
    end
  end

  it 'returns a plain denial when the user cancels without a note' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets).and_return("3\n", nil)

      out = tool.execute('command' => 'rm -rf /')
      expect(out).to eq('error: user denied executing the command')
    end
  end

  it 'runs the command when the user allows it once' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets).and_return("1\n", nil)

      out = tool.execute('command' => 'pwd')
      expect(out).to start_with('exit code: 0')
    end
  end

  context 'always-allow (issue #69)' do
    it 'saves the prefix and auto-approves future matching commands' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})

        # First time: user picks "Always allow" (option 2).
        allow($stdin).to receive(:gets).and_return("2\n", nil)
        out1 = tool.execute('command' => 'bundle exec rspec spec/')
        expect(out1).to start_with('exit code:')

        # The prefix must now be persisted on disk.
        yml = File.join(dir, '.harness', 'allowed_commands.yml')
        expect(File.file?(yml)).to be true
        expect(YAML.safe_load(File.read(yml))).to include('bundle exec rspec')

        # Second time: same prefix - auto-approved, no dialog needed.
        # (No stdin stub: a dialog would raise on EOF.)
        out2 = tool.execute('command' => 'bundle exec rspec spec/foo_spec.rb')
        expect(out2).to start_with('exit code:')
      end
    end

    it 'still asks for commands with a different prefix' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})

        allow($stdin).to receive(:gets).and_return("2\n", nil)
        tool.execute('command' => 'bundle exec rspec spec/')

        # Different prefix (bundle exec rake) is NOT covered by the saved
        # "bundle exec rspec" prefix, so it must ask again.
        allow($stdin).to receive(:gets).and_return("3\n", nil)
        out = tool.execute('command' => 'bundle exec rake test')
        expect(out).to start_with('error: user denied executing the command')
      end
    end

    it 'auto-approves from a pre-existing allowlist file' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'allowed_commands.yml'),
                   YAML.dump(['git status']))

        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})
        # No stdin stub: a dialog would raise on EOF.
        out = tool.execute('command' => 'git status')
        expect(out).to start_with('exit code:')
      end
    end
  end
end
