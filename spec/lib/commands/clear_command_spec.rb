# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'commands/clear_command'

RSpec.describe Commands::ClearCommand do
  def run_command(list, args = '')
    stdout = StringIO.new
    described_class.new(harness: nil, file_list: list, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  def seed_lists(dir, tool: [], shell: [], hosts: [])
    FileUtils.mkdir_p(File.join(dir, '.harness'))
    File.write(File.join(dir, '.harness', 'allowed_commands.yml'), YAML.dump(tool))
    File.write(File.join(dir, '.harness', 'shell_commands.yml'), YAML.dump(shell))
    File.write(File.join(dir, '.harness', 'allowed_hosts.yml'), YAML.dump(hosts))
  end

  def read_list(dir, name)
    YAML.safe_load(File.read(File.join(dir, '.harness', name)))
  end

  describe 'the bare form (access)' do
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

    it 'is a no-op on an already empty list (no error, still confirms)' do
      Dir.mktmpdir do |dir|
        list = FileList.new([], workdir: dir)
        expect(list.empty?).to be true
        expect(run_command(list)).to eq("Access list cleared.\n")
      end
    end

    # The command allowlists are SEPARATE lists (issue #129): the bare form is
    # the access list only, so a saved prefix is never collateral damage.
    it 'leaves the command allowlists alone' do
      Dir.mktmpdir do |dir|
        seed_lists(dir, tool: ['git status'], shell: ['ls'], hosts: ['api.example.com'])
        list = FileList.new([], workdir: dir)
        list.add_file('a.rb', :r)

        run_command(list)

        expect(read_list(dir, 'allowed_commands.yml')).to eq(['git status'])
        expect(read_list(dir, 'shell_commands.yml')).to eq(['ls'])
        expect(read_list(dir, 'allowed_hosts.yml')).to eq(['api.example.com'])
      end
    end

    it 'accepts "access" as the explicit form of the bare one' do
      Dir.mktmpdir do |dir|
        list = FileList.new([], workdir: dir)
        list.add_file('a.rb', :r)

        expect(run_command(list, 'access')).to eq("Access list cleared.\n")
        expect(list.readable?('a.rb')).to be false
      end
    end
  end

  # issue #104: the command and host allowlists had NO revocation path - a
  # stored entry could only be removed by hand-editing its .yml.
  describe 'the allowlist forms (issue #104)' do
    it 'clears the run.command prefixes only' do
      Dir.mktmpdir do |dir|
        seed_lists(dir, tool: ['git status', 'ls'], shell: ['echo'],
                   hosts: ['api.example.com'])
        expect(run_command(FileList.new([], workdir: dir), 'commands'))
          .to eq("Cleared 2 run.command prefixes.\n")

        expect(read_list(dir, 'allowed_commands.yml')).to eq([])
        expect(read_list(dir, 'shell_commands.yml')).to eq(['echo'])
        expect(read_list(dir, 'allowed_hosts.yml')).to eq(['api.example.com'])
      end
    end

    it 'clears the shell (!) prefixes only' do
      Dir.mktmpdir do |dir|
        seed_lists(dir, tool: ['git status'], shell: ['ls -la'])
        expect(run_command(FileList.new([], workdir: dir), 'shell'))
          .to eq("Cleared 1 shell (!) prefix.\n")

        expect(read_list(dir, 'shell_commands.yml')).to eq([])
        expect(read_list(dir, 'allowed_commands.yml')).to eq(['git status'])
      end
    end

    it 'clears the web.fetch hosts only' do
      Dir.mktmpdir do |dir|
        seed_lists(dir, tool: ['git status'], hosts: ['api.example.com'])
        out = run_command(FileList.new([], workdir: dir), 'hosts')

        expect(out).to eq("Cleared 1 web.fetch host grant.\n")
        expect(read_list(dir, 'allowed_hosts.yml')).to eq([])
        expect(read_list(dir, 'allowed_commands.yml')).to eq(['git status'])
      end
    end

    it 'says so when a list has nothing to clear and writes no file' do
      Dir.mktmpdir do |dir|
        out = run_command(FileList.new([], workdir: dir), 'commands')

        expect(out).to eq("No run.command prefixes to clear.\n")
        expect(File.exist?(File.join(dir, '.harness', 'allowed_commands.yml'))).to be false
      end
    end

    it 'clears every list with "all"' do
      Dir.mktmpdir do |dir|
        seed_lists(dir, tool: ['git status'], shell: ['ls'], hosts: ['api.example.com'])
        list = FileList.new([], workdir: dir)
        list.add_file('a.rb', :r)

        out = run_command(list, 'all')

        expect(out).to include('Access list cleared.')
        expect(out).to include('Cleared 1 run.command prefix.')
        expect(out).to include('Cleared 1 shell (!) prefix.')
        expect(out).to include('Cleared 1 web.fetch host grant.')
        expect(list.empty?).to be true
        expect(read_list(dir, 'allowed_commands.yml')).to eq([])
        expect(read_list(dir, 'shell_commands.yml')).to eq([])
        expect(read_list(dir, 'allowed_hosts.yml')).to eq([])
      end
    end

    it 'reports an unknown form without clearing anything' do
      Dir.mktmpdir do |dir|
        seed_lists(dir, tool: ['git status'])
        list = FileList.new([], workdir: dir)
        list.add_file('a.rb', :r)

        out = run_command(list, 'prefixes')

        expect(out).to include('Unknown /clear form: prefixes')
        expect(out).to include('access, commands, shell, hosts, all')
        expect(list.readable?('a.rb')).to be true
        expect(read_list(dir, 'allowed_commands.yml')).to eq(['git status'])
      end
    end

    it 'applies immediately to a runner built earlier in the run' do
      Dir.mktmpdir do |dir|
        seed_lists(dir, tool: ['echo hi'])
        list = FileList.new([], workdir: dir)
        allowlist = CommandAllowlist.new(dir)
        expect(allowlist.allowed?('echo hi')).to be true

        run_command(list, 'commands')

        expect(allowlist.allowed?('echo hi')).to be false
      end
    end
  end

  it 'declares its HELP entry in the access group' do
    help = described_class::HELP
    expect(help.usage).to eq('clear [list]')
    expect(help.forms).to eq(['clear', 'clear access', 'clear commands',
                              'clear shell', 'clear hosts', 'clear all'])
    expect(help.group).to eq(:access)
    expect(help.see_also).to eq(%w[grant access consent])
  end
end
