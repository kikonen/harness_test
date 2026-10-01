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
      # "rm -rf /" offers 'rm' and 'rm -rf', so:
      # Allow(1), 'rm'(2), 'rm -rf'(3), Cancel(4).
      allow($stdin).to receive(:gets)
        .and_return("4 this command is too broad, narrow it\n", nil)

      out = tool.execute('command' => 'rm -rf /')
      expect(out).to start_with('error: user denied executing the command')
      expect(out).to include('user\'s note: "this command is too broad, narrow it"')
    end
  end

  it 'returns a plain denial when the user cancels without a note' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      # Allow(1), 'rm'(2), 'rm -rf'(3), Cancel(4).
      allow($stdin).to receive(:gets).and_return("4\n", nil)

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

        # First time: options are Allow(1), 'bundle'(2), 'bundle exec'(3),
        # 'bundle exec rspec'(4), Cancel(5). User picks the longest
        # (most specific) prefix.
        allow($stdin).to receive(:gets).and_return("4\n", nil)
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

        # Options for "bundle exec rspec spec/": Allow(1), 'bundle'(2),
        # 'bundle exec'(3), 'bundle exec rspec'(4), Cancel(5). Save only
        # the specific 'bundle exec rspec' prefix (option 4), not the
        # broader 'bundle' or 'bundle exec'.
        allow($stdin).to receive(:gets).and_return("4\n", nil)
        out1 = tool.execute('command' => 'bundle exec rspec spec/')
        expect(out1).to start_with('exit code:')

        # Different prefix (bundle exec rake) is NOT covered by the saved
        # "bundle exec rspec" prefix, so it must ask again.
        # Options for "bundle exec rake test": Allow(1), 'bundle'(2),
        # 'bundle exec'(3), 'bundle exec rake'(4),
        # 'bundle exec rake test'(5), Cancel(6).
        allow($stdin).to receive(:gets).and_return("6\n", nil)
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

    it 'hides candidates that are subsumed by a stored grant (issue #94)' do
      Dir.mktmpdir do |dir|
        # Pre-seed the allowlist file BEFORE the tool is built.
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'allowed_commands.yml'),
                   YAML.dump(['gh issue view']))

        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})

        allow($stdin).to receive(:gets).and_return("2\n", nil)

        orig_stdout = $stdout
        $stdout = StringIO.new
        tool.execute('command' => 'gh issue view 101 --json title,state')
        out = $stdout.string
        $stdout = orig_stdout

        # 'gh', 'gh issue', and 'gh issue view' are all subsumed by the
        # stored grant - selecting any of them would be a no-op, so none
        # is offered. (Candidates beyond the leading 3 subcommand tokens
        # like '101 --json title,state' are never offered - they are not
        # subcommand-looking.)
        expect(out).not_to include("Always allow 'gh'")
        expect(out).not_to include("Always allow 'gh issue'")
        expect(out).not_to include("Always allow 'gh issue view'")
      end
    end

    it 'drops a candidate that exactly matches a stored grant (issue #94)' do
      Dir.mktmpdir do |dir|
        # Pre-seed the allowlist file BEFORE the tool is built.
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'allowed_commands.yml'),
                   YAML.dump(['git log']))

        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})

        allow($stdin).to receive(:gets).and_return("2\n", nil)

        orig_stdout = $stdout
        $stdout = StringIO.new
        tool.execute('command' => 'git log --oneline | tail -5')
        out = $stdout.string
        $stdout = orig_stdout

        # Both 'git' and 'git log' are in the same command tree as the
        # stored 'git log' grant - either would just be redundant (a no-op
        # or a widening of something already granted), so neither is
        # offered. '-5' is a trailing flag (a parameter), so only bare
        # 'tail' is offered for the second segment.
        expect(out).not_to include("Always allow 'git'")
        expect(out).not_to include("Always allow 'git log'")
        expect(out).to include("Always allow 'tail'")
      end
    end

    context 'per-prefix options with multi-select (issue #102)' do
      it 'offers one option per candidate prefix length' do
        Dir.mktmpdir do |dir|
          list = FileList.new(workdir: dir)
          tool = described_class.new(list, {})
          allow($stdin).to receive(:gets).and_return("1\n", nil)

          orig_stdout = $stdout
          $stdout = StringIO.new
          tool.execute('command' => 'cd C:/work/x && ruby -c lib/cli.rb')
          out = $stdout.string
          $stdout = orig_stdout

          # "cd C:/work/x" is granted as a full invocation (a path is not a
          # subcommand, so no shorter prefix), "ruby" and "ruby -c" are
          # offered as separate choices.
          expect(out).to include("Always allow 'cd C:/work/x'")
          expect(out).to include("Always allow 'ruby'")
          expect(out).to include("Always allow 'ruby -c'")
        end
      end

      it 'saves only the selected prefixes when several are picked at once' do
        Dir.mktmpdir do |dir|
          list = FileList.new(workdir: dir)
          tool = described_class.new(list, {})
          # Options: 1 Allow, 2 'cd C:/work/x', 3 'ruby', 4 'ruby -c'.
          allow($stdin).to receive(:gets).and_return("3 4\n", nil)

          out = tool.execute('command' => 'cd C:/work/x && ruby -c lib/cli.rb')
          expect(out).to start_with('exit code:')

          yml = File.join(dir, '.harness', 'allowed_commands.yml')
          saved = YAML.safe_load(File.read(yml))
          expect(saved).to include('ruby')
          expect(saved).to include('ruby -c')
          expect(saved).not_to include('cd C:/work/x')
        end
      end

      it 'saves a single picked prefix (bare value, not an array)' do
        Dir.mktmpdir do |dir|
          list = FileList.new(workdir: dir)
          tool = described_class.new(list, {})
          # Option 2 is 'cd C:/work/x'.
          allow($stdin).to receive(:gets).and_return("2\n", nil)

          out = tool.execute('command' => 'cd C:/work/x && ruby -c lib/cli.rb')
          expect(out).to start_with('exit code:')

          yml = File.join(dir, '.harness', 'allowed_commands.yml')
          saved = YAML.safe_load(File.read(yml))
          expect(saved).to eq(['cd C:/work/x'])
        end
      end

      it 'runs the command without saving when only "Allow" is picked' do
        Dir.mktmpdir do |dir|
          list = FileList.new(workdir: dir)
          tool = described_class.new(list, {})
          allow($stdin).to receive(:gets).and_return("1\n", nil)

          out = tool.execute('command' => 'bundle exec rspec spec/')
          expect(out).to start_with('exit code:')
          expect(File.file?(File.join(dir, '.harness', 'allowed_commands.yml'))).to be false
        end
      end

      it 'runs the command without saving when Allow is mixed into a multi-select' do
        Dir.mktmpdir do |dir|
          list = FileList.new(workdir: dir)
          tool = described_class.new(list, {})
          # Options: Allow(1), 'bundle'(2), 'bundle exec'(3),
          # 'bundle exec rspec'(4), Cancel(5). "1 2" = Allow + save 'bundle'
          # - ambiguous (user wants to run now); the command runs and
          # nothing is saved.
          allow($stdin).to receive(:gets).and_return("1 2\n", nil)

          out = tool.execute('command' => 'bundle exec rspec spec/')
          expect(out).to start_with('exit code:')
          expect(File.file?(File.join(dir, '.harness', 'allowed_commands.yml'))).to be false
        end
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
        # ...but the user is told why (redirects can't be auto-approved),
        # naming the specific offending construct (issue #102).
        expect(out).to include('UNSAFE: redirect to file ("> tmpfile")')
        # Cancel is now option 2 (Allow=1, Cancel=2), so "2" cancels.
        expect(tool.execute('command' => 'echo hi > tmpfile'))
          .to start_with('error: user denied executing the command')
      end
    end

    it 'names a combined &> redirect in the note (issue #102)' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})
        allow($stdin).to receive(:gets).and_return("2\n", nil)

        orig_stdout = $stdout
        $stdout = StringIO.new
        tool.execute('command' => 'run test &> build.log')
        out = $stdout.string
        $stdout = orig_stdout

        expect(out).not_to include("Always allow '")
        expect(out).to include('UNSAFE: combined stdout+stderr redirect')
      end
    end
  end
end
