# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'commands/clear_command'

RSpec.describe Commands::ClearCommand do
  def run_command(list)
    stdout = StringIO.new
    described_class.new(harness: nil, file_list: list, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle('')
    stdout.string
  end

  it 'removes every access grant' do
    Dir.mktmpdir do |dir|
      list = FileList.new([], workdir: dir)
      list.add_file('lib/a.rb', :rw)
      list.add_dir('spec', :r)
      list.add_file('tmp/x.txt', :d)
      expect(list.access_grant_count).to be > 0

      expect(run_command(list)).to eq("Access list cleared.\n")
      expect(list.empty?).to be true
      expect(list.readable?('lib/a.rb')).to be false
      expect(list.writable?('lib/a.rb')).to be false
      expect(list.deletable?('tmp/x.txt')).to be false
    end
  end

  # The command allowlists are SEPARATE lists (issue #129): /clear clears the
  # access grants and must never touch a saved command prefix.
  it 'leaves the command allowlists alone' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, '.harness'))
      tool_yml  = File.join(dir, '.harness', 'allowed_commands.yml')
      shell_yml = File.join(dir, '.harness', 'shell_commands.yml')
      File.write(tool_yml, YAML.dump(['git status']))
      File.write(shell_yml, YAML.dump(['ls']))
      list = FileList.new([], workdir: dir)
      list.add_file('a.rb', :r)

      run_command(list)

      expect(YAML.safe_load(File.read(tool_yml))).to eq(['git status'])
      expect(YAML.safe_load(File.read(shell_yml))).to eq(['ls'])
    end
  end

  it 'is a no-op on an already empty list (no error, still confirms)' do
    Dir.mktmpdir do |dir|
      list = FileList.new([], workdir: dir)
      expect(list.empty?).to be true
      expect(run_command(list)).to eq("Access list cleared.\n")
    end
  end

  it 'declares its HELP entry in the access group' do
    help = described_class::HELP
    expect(help.usage).to eq('clear')
    expect(help.group).to eq(:access)
    expect(help.see_also).to eq(%w[grant access])
  end
end
