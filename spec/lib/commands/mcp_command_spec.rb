# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tool_registry'
require 'mcp/manager'
require 'commands/mcp_command'

RSpec.describe Commands::McpCommand do
  # The command reads tool descriptions from the harness registry - the one the
  # model was actually given - so the spec wires ONE registry: Mcp::Manager loads
  # its tools into it, and the harness stub hands back that same object. A
  # hand-made registry would let the command pass while reading a description no
  # real run ever stored.
  def fake_mcp_tool(name)
    Struct.new(:name, :description, :input_schema).new(name, "desc of #{name}", {})
  end

  def logger
    log = instance_double('Logger')
    allow(log).to receive(:warn)
    allow(log).to receive(:info)
    log
  end

  def stub_connection(listed)
    conn = instance_double('Mcp::ServerConnection')
    if listed.empty?
      allow(conn).to receive(:connect).and_raise(Errno::ENOENT, 'server not running')
    else
      allow(conn).to receive(:connect).and_return(listed.map { |t| fake_mcp_tool(t) })
    end
    allow(conn).to receive(:close)
    conn
  end

  # Build a Manager whose servers are stubbed, loading them into `registry` so
  # the command and the manager agree on the tools that exist. A server listed
  # with no tools is a DOWN server (its connect raises).
  def load_manager(servers, tools, registry = ToolRegistry.new)
    allow(Mcp::ServerConnection).to receive(:new) do |**kwargs|
      stub_connection(Array(tools[kwargs[:name]]))
    end
    manager = Mcp::Manager.new(logger)
    manager.load(registry, servers)
    [manager, registry]
  end

  def run(manager, registry)
    harness = Object.new
    harness.define_singleton_method(:mcp) { manager }
    harness.define_singleton_method(:tool_registry) { registry }
    stdout = StringIO.new
    described_class.new(
      harness: harness,
      file_list: nil,
      options: nil,
      ui: UI::Console.new(stdout: stdout)).handle('')
    stdout.string
  end

  def stdio_entry(name: 'fs', command: 'npx', args: ['-y', 'srv'])
    { name:, command:, args:, env: {} }
  end

  def http_entry(name: 'remote', url: 'https://example.com/mcp')
    { name:, url:, headers: {} }
  end

  def report(servers, tools)
    manager, registry = load_manager(servers, tools)
    run(manager, registry)
  end

  describe 'servers that connected' do
    it 'states how many were declared and how many connected' do
      out = report([stdio_entry], 'fs' => ['read_file'])

      expect(out).to include('MCP servers: 1 declared, 1 connected (1 tool(s) available)')
    end

    it 'names each server with its transport and its target' do
      out = report([stdio_entry, http_entry],
                   'fs' => ['read_file'], 'remote' => ['ping'])

      expect(out).to include('fs  [stdio]  npx -y srv')
      expect(out).to include('remote  [http]  https://example.com/mcp')
    end

    it 'lists each connected server\'s tools from the registry it was registered in' do
      out = report([http_entry], 'remote' => ['ping'])

      expect(out).to include('remote.ping - desc of ping')
    end

    it 'counts the tools it registered across servers' do
      out = report([stdio_entry, http_entry], 'fs' => %w[a b], 'remote' => ['ping'])

      expect(out).to include('(3 tool(s) available)')
    end
  end

  describe 'a server that did not connect' do
    it 'says the server is DOWN and why, instead of omitting it' do
      out = report([stdio_entry], 'fs' => [])

      expect(out).to include('MCP servers: 1 declared, 0 connected (0 tool(s) available)')
      expect(out).to include('DOWN (Errno::ENOENT')
    end

    # The point of the command (issue #405): mid-session the banner is gone, so
    # the only way to learn a declared server is missing is to be told per server.
    it 'reports the failed server under the ones that worked' do
      out = report([stdio_entry, http_entry(name: 'gone')], 'fs' => ['read_file'])

      expect(out).to include('MCP servers: 2 declared, 1 connected (1 tool(s) available)')
      expect(out).to include('gone  [http]  https://example.com/mcp')
      expect(out).to include('DOWN (')
    end
  end

  describe 'name collisions' do
    it 'reports a tool skipped because a built-in holds the name' do
      registry = ToolRegistry.new
      registry.register(Tool.new(name: 'fs.read', description: 'built-in', parameters: {}))
      allow(Mcp::ServerConnection).to receive(:new).and_return(stub_connection(['read']))
      manager = Mcp::Manager.new(logger)
      manager.load(registry, [stdio_entry])

      out = run(manager, registry)

      expect(out).to include('skipped (a built-in tool holds the name):')
      expect(out).to include('fs.read')
    end
  end

  describe 'no servers declared' do
    it 'says no MCP code ran and points at the config key' do
      manager = Mcp::Manager.new(logger)
      manager.load(ToolRegistry.new, [])

      out = run(manager, ToolRegistry.new)

      expect(out).to include('No MCP servers declared')
      expect(out).to include('mcp_servers:')
      expect(out).to include('examples/mcp/')
    end
  end

  # The tool set is part of tools_payload, sent with every request: a live toggle
  # would change the payload mid-run (issue #246). The command must not imply one.
  describe 'no live toggle' do
    it 'states that the servers stay fixed for the run' do
      out = report([stdio_entry], 'fs' => ['read_file'])

      expect(out).to include('No live toggle')
      expect(out).to include('fixed for the run')
    end
  end

  it 'points at the saved-session comparison a resumed run reports' do
    out = report([stdio_entry], 'fs' => ['read_file'])

    expect(out).to include('saved with the session')
  end

  it 'declares its HELP entry in the general group' do
    help = described_class::HELP

    expect(help.usage).to eq('mcp')
    expect(help.group).to eq(:general)
    expect(help.summary).to include('MCP servers')
  end
end
