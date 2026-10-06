# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/run_command_tool'

RSpec.describe Tools::RunCommandTool do
  # Drive the confirmation dialog without any real I/O: intercept
  # Dialog#show (the tool calls it with ui: nil because
  # tools run on the Task thread) and perform the interaction directly on a
  # StringIO. Returns the dialog's rendered output for assertions.
  def drive_dialog(*lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  it 'forwards the user\'s denial note to the model' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      # "rm -rf /" offers 'rm' and 'rm -rf', so:
      # Allow(1), 'rm'(2), 'rm -rf'(3), Cancel(4).
      drive_dialog("4 this command is too broad, narrow it\n")

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
      drive_dialog("4\n")

      out = tool.execute('command' => 'rm -rf /')
      expect(out).to eq('error: user denied executing the command')
    end
  end

  it 'runs the command when the user allows it once' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      drive_dialog("1\n")

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
        drive_dialog("4\n")
        out1 = tool.execute('command' => 'bundle exec rspec spec/')
        expect(out1).to start_with('exit code:')

        # The prefix must now be persisted on disk.
        yml = File.join(dir, '.harness', 'allowed_commands.yml')
        expect(File.file?(yml)).to be true
        expect(YAML.safe_load(File.read(yml))).to include('bundle exec rspec')

        # Second time: same prefix - auto-approved, no dialog needed.
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
        drive_dialog("4\n")
        out1 = tool.execute('command' => 'bundle exec rspec spec/')
        expect(out1).to start_with('exit code:')

        # Different prefix (bundle exec rake) is NOT covered by the saved
        # "bundle exec rspec" prefix, so it must ask again.
        # Options for "bundle exec rake test": Allow(1), 'bundle'(2),
        # 'bundle exec'(3), 'bundle exec rake'(4),
        # 'bundle exec rake test'(5), Cancel(6).
        drive_dialog("6\n")
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
        # No dialog stub: the command is auto-approved, so no dialog shows.
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

        # Option 2 = Cancel (Allow=1, Cancel=2); deny, only the rendered
        # dialog is under test.
        out = drive_dialog("2\n")
        tool.execute('command' => 'gh issue view 101 --json title,state')

        # 'gh', 'gh issue', and 'gh issue view' are all subsumed by the
        # stored grant - selecting any of them would be a no-op, so none
        # is offered. (Candidates beyond the leading 3 subcommand tokens
        # like '101 --json title,state' are never offered - they are not
        # subcommand-looking.)
        expect(out.string).not_to include("Always allow 'gh'")
        expect(out.string).not_to include("Always allow 'gh issue'")
        expect(out.string).not_to include("Always allow 'gh issue view'")
      end
    end

    it 'still offers other segments in a chain when one is stored (issue #164)' do
      Dir.mktmpdir do |dir|
        # Pre-seed the allowlist file BEFORE the tool is built.
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'allowed_commands.yml'),
                   YAML.dump(['gh issue view']))

        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})

        # Option 2 = Cancel; deny - only the rendered dialog is under test.
        out = drive_dialog("2\n")
        tool.execute('command' => 'git remote -v && gh issue view 113')

        # The stored 'gh ...' grant must not suppress the OTHER segment:
        # 'git' and 'git remote' are offered, while the 'gh' candidates
        # (already covered) are not.
        expect(out.string).to include("Always allow 'git'")
        expect(out.string).to include("Always allow 'git remote'")
        expect(out.string).not_to include("Always allow 'gh'")
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

        # Option 2 = "Always allow 'tail'" - saves it; either way only the
        # rendered dialog is under test.
        out = drive_dialog("2\n")
        tool.execute('command' => 'git log --oneline | tail -5')

        # 'git log' exactly matches the stored grant (no-op) and bare
        # 'git' would cover it (making the stored entry redundant), so
        # neither is offered (issue #94, issue #164). '-5' is a trailing
        # flag (a parameter), so only bare 'tail' is offered for the
        # second segment.
        expect(out.string).not_to include("Always allow 'git'")
        expect(out.string).not_to include("Always allow 'git log'")
        expect(out.string).to include("Always allow 'tail'")
      end
    end

    context 'per-prefix options with multi-select (issue #102)' do
      it 'offers one option per candidate prefix length' do
        Dir.mktmpdir do |dir|
          list = FileList.new(workdir: dir)
          tool = described_class.new(list, {})
          # Allow(1); deny - only the rendered dialog is under test.
          out = drive_dialog("1\n")
          tool.execute('command' => 'cd C:/work/x && ruby -c lib/cli.rb')

          # "cd C:/work/x" is granted as a full invocation (a path is not a
          # subcommand, so no shorter prefix), "ruby" and "ruby -c" are
          # offered as separate choices.
          expect(out.string).to include("Always allow 'cd C:/work/x'")
          expect(out.string).to include("Always allow 'ruby'")
          expect(out.string).to include("Always allow 'ruby -c'")
        end
      end

      it 'saves only the selected prefixes when several are picked at once' do
        Dir.mktmpdir do |dir|
          list = FileList.new(workdir: dir)
          tool = described_class.new(list, {})
          # Options: 1 Allow, 2 'cd C:/work/x', 3 'ruby', 4 'ruby -c'.
          drive_dialog("3 4\n")

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
          drive_dialog("2\n")

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
          drive_dialog("1\n")

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
          drive_dialog("1 2\n")

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
        out = drive_dialog("2\n")
        tool.execute('command' => 'echo hi > tmpfile')

        # No "Always allow" option offered...
        expect(out.string).not_to include("Always allow '")
        expect(out.string).not_to include("2) Always allow")
        # ...but the user is told why (redirects can't be auto-approved),
        # naming the specific offending construct (issue #102).
        expect(out.string).to include('UNSAFE: redirect to file ("> tmpfile")')

        # Cancel is now option 2 (Allow=1, Cancel=2), so "2" cancels.
        drive_dialog("2\n")
        expect(tool.execute('command' => 'echo hi > tmpfile'))
          .to start_with('error: user denied executing the command')
      end
    end

    it 'names a combined &> redirect in the note (issue #102)' do
      Dir.mktmpdir do |dir|
        list = FileList.new(workdir: dir)
        tool = described_class.new(list, {})
        # Cancel is option 2 (Allow=1, Cancel=2).
        out = drive_dialog("2\n")
        tool.execute('command' => 'run test &> build.log')

        expect(out.string).not_to include("Always allow '")
        expect(out.string).to include('UNSAFE: combined stdout+stderr redirect')
      end
    end
  end
end
