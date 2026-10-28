# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'cli_options'

# CLIOptions resolves the run's options from ARGV + the config file. These
# specs run it directly (with -c, so no user-home config is touched) because
# they are about option resolution, not the CLI run itself.
RSpec.describe CLIOptions do
  let(:workdir) { Dir.mktmpdir }

  def resolve(argv)
    original = ARGV.dup
    ARGV.replace(argv)
    CLIOptions.parse
  ensure
    ARGV.replace(original)
  end

  def write_config(name, body)
    path = File.join(workdir, name)
    File.write(path, body)
    path
  end

  # issue #33: web.fetch may not reach a private address unless the USER asked
  # for it, and the only way to ask is the config key - so option resolution is
  # what carries it.
  describe 'web.fetch private-address key (issue #33)' do
    it 'is off when the config says nothing' do
      opts = resolve(['-m', 'test-model', '-d', workdir,
                      '-c', write_config('fetch-config.yml', "model: test-model\n")])
      expect(opts[:web_fetch_allow_private]).to be(false)
    end

    it 'is on when the config asks for it' do
      path = write_config('fetch-config.yml',
                          "model: test-model\nweb_fetch_allow_private: true\n")
      opts = resolve(['-m', 'test-model', '-d', workdir, '-c', path])
      expect(opts[:web_fetch_allow_private]).to be(true)
    end
  end

  # issue #389: command_safety_auto_approve as one enum key; resolution splits
  # it into the two option halves CommandRunner consults. Off unless the config
  # asks.
  describe 'command_safety_auto_approve enum (issue #389)' do
    def resolve_config(body)
      resolve(['-m', 'test-model', '-d', workdir,
               '-c', write_config('dl-config.yml', body)])
    end

    it 'is off when the config says nothing' do
      opts = resolve_config("model: test-model\n")
      expect(opts[:command_safety_denylist_safe_approve]).to be(false)
    end

    it 'is on when the config asks for it' do
      opts = resolve_config("model: test-model\ncommand_safety_denylist_safe_approve: true\n")
      expect(opts[:command_safety_denylist_safe_approve]).to be(true)
    end

    it "maps the enum mode 'denylist' onto the two halves" do
      opts = resolve_config("model: test-model\ncommand_safety_auto_approve: denylist\n")
      expect(opts[:command_safety_auto_approve]).to be(false)
      expect(opts[:command_safety_denylist_safe_approve]).to be(true)
    end

    it "maps 'safe_denylist' onto both halves" do
      opts = resolve_config("model: test-model\ncommand_safety_auto_approve: safe_denylist\n")
      expect(opts[:command_safety_auto_approve]).to be(true)
      expect(opts[:command_safety_denylist_safe_approve]).to be(true)
    end
  end

  # issue #106: the markdown table-width basis. --markdown-width N > config
  # 'markdown_max_width' > nil (the renderer's default, 80% of the terminal).
  describe 'markdown_max_width (issue #106)' do
    it 'is nil when neither the flag nor the config gives one' do
      opts = resolve(['-m', 'test-model', '-d', workdir,
                      '-c', write_config('md-config.yml', "model: test-model\n")])
      expect(opts[:markdown_max_width]).to be_nil
    end

    it 'reads the config key' do
      path = write_config('md-config.yml', "model: test-model\nmarkdown_max_width: 120\n")
      opts = resolve(['-m', 'test-model', '-d', workdir, '-c', path])
      expect(opts[:markdown_max_width]).to eq(120)
    end

    it 'the flag overrides the config key' do
      path = write_config('md-config.yml', "model: test-model\nmarkdown_max_width: 120\n")
      opts = resolve(['-m', 'test-model', '-d', workdir, '-c', path,
                      '--markdown-width', '90'])
      expect(opts[:markdown_max_width]).to eq(90)
    end

    it 'a non-integer --markdown-width is a CLI error, not a silent nil' do
      expect {
        resolve(['-m', 'test-model', '-d', workdir,
                 '-c', write_config('md-config.yml', "model: test-model\n"),
                 '--markdown-width', 'wide'])
      }.to raise_error(HarnessError, /--markdown-width needs an integer/)
    end
  end

  # Standing constraint (issue #106): markdown rendering stays default OFF. The
  # config level is pinned in harness_config_spec; this pins the resolution
  # path - with no --markdown flag and no config key, a run renders plain.
  describe 'markdown stays default off (issue #106)' do
    it 'is off when neither the flag nor the config asks for it' do
      path = write_config('md-off.yml', "model: test-model\n")
      opts = resolve(['-m', 'test-model', '-d', workdir, '-c', path])
      expect(opts[:markdown]).to be(false)
    end
  end

  # issue #48: external MCP servers are config-only (no CLI flag - a server is
  # a declared, persistent setup, not a one-run toggle). An empty list means
  # the MCP code path never runs.
  describe 'mcp_servers (issue #48)' do
    it 'is empty when the config says nothing (no MCP code path runs)' do
      opts = resolve(['-m', 'test-model', '-d', workdir,
                      '-c', write_config('mcp-config.yml', "model: test-model\n")])
      expect(opts[:mcp_servers]).to eq([])
    end

    it 'carries the normalized entries from the config' do
      path = write_config('mcp-config.yml', <<~YAML)
        model: test-model
        mcp_servers:
          - name: fs
            command: ruby
            args: ["srv.rb"]
      YAML
      opts = resolve(['-m', 'test-model', '-d', workdir, '-c', path])
      expect(opts[:mcp_servers]).to eq(
        [{ name: 'fs', command: 'ruby', args: ['srv.rb'], env: {} }]
      )
    end
  end

  # issue #385: dirs the YOLO posture never auto-covers. Config-only. nil (key
  # absent) means FileList applies its default (local/); an explicit list is
  # carried through to build_file_list.
  describe 'protected_dirs (issue #385)' do
    it 'is nil when the config says nothing (FileList applies its default)' do
      opts = resolve(['-m', 'test-model', '-d', workdir,
                      '-c', write_config('prot-config.yml', "model: test-model\n")])
      expect(opts[:protected_dirs]).to be_nil
    end

    it 'carries the configured list' do
      path = write_config('prot-config.yml', "model: test-model\nprotected_dirs: [secrets, private]\n")
      opts = resolve(['-m', 'test-model', '-d', workdir, '-c', path])
      expect(opts[:protected_dirs]).to eq(%w[secrets private])
    end
  end

  describe 'model requirement' do
    it 'raises when neither -m nor a default model is set (and not listing)' do
      expect {
        resolve(['-d', workdir, '-c', write_config('no-model.yml', "default_model: \n")])
      }.to raise_error(HarnessError, /-m \/ --model is required/)
    end

    it 'does not require a model for --list-sessions' do
      opts = resolve(['--list-sessions', '-d', workdir,
                      '-c', write_config('list.yml', "model: test-model\n")])
      expect(opts[:list_sessions]).to be_truthy
    end
  end
end
