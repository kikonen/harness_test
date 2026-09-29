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

    it 'marks already-allowed prefixes with (*) in the option (issue #94)' do
      Dir.mktmpdir do |dir|
        # Pre-seed the allowlist file BEFORE the tool is built.
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'allowed_commands.yml'), YAML.dump(['tail']))

        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})

        allow($stdin).to receive(:gets).and_return("1\n", nil)

        orig_stdout = $stdout
        $stdout = StringIO.new
        tool.execute('command' => 'git log --oneline | tail -5')
        out = $stdout.string
        $stdout = orig_stdout

        # "git log" is new, "tail" is already allowed -> starred.
        expect(out).to include("Always allow 'git log', 'tail' (*)")
      end
    end

    it 'reports which prefixes were already allowed on save (issue #94)' do
      Dir.mktmpdir do |dir|
        # Pre-seed the allowlist file BEFORE the tool is built.
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'allowed_commands.yml'), YAML.dump(['tail']))

        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})

        allow($stdin).to receive(:gets).and_return("2\n", nil)

        orig_stdout = $stdout
        $stdout = StringIO.new
        tool.execute('command' => 'git log --oneline | tail -5')
        out = $stdout.string
        $stdout = orig_stdout

        expect(out).to include("always-allowed: git log (saved to allowlist)")
        expect(out).to include('already allowed: tail')
      end
    end

    it 'notes that "Always allow" only covers simple invocations' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})
        allow($stdin).to receive(:gets).and_return("1\n", nil)

        orig_stdout = $stdout
        $stdout = StringIO.new
        tool.execute('command' => 'bundle exec rspec spec/')
        out = $stdout.string
        $stdout = orig_stdout
        expect(out).to include('Simple invocations only (no redirects / $vars / &)')
      end
    end
  end

  context 'dangerous constructs (issue #69)' do
    it 'hides "Always allow" and explains why in a dialog note' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})
        # "rm -rf /" is simple (gets an option); "echo hi > f" is not.
        allow($stdin).to receive(:gets).and_return("2\n", nil)

        orig_stdout = $stdout
        $stdout = StringIO.new
        tool.execute('command' => 'echo hi > tmpfile')
        out = $stdout.string
        $stdout = orig_stdout
        # No "Always allow" option offered...
        expect(out).not_to include("Always allow '")
        expect(out).not_to include("2) Always allow")
        # ...but the user is told why (redirects can't be auto-approved).
        expect(out).to include('UNSAFE: redirects / $vars / &.')
        # Cancel is now option 2 (Allow=1, Cancel=2), so "2" cancels.
        expect(tool.execute('command' => 'echo hi > tmpfile'))
          .to start_with('error: user denied executing the command')
      end
    end
  end
end
