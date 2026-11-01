# frozen_string_literal: true

require 'spec_helper'
require 'mcp/manager'

RSpec.describe Mcp::Manager do
  def fake_tool(name, description = 'd', schema = {})
    Struct.new(:name, :description, :input_schema).new(name, description, schema)
  end

  def fake_connection(tools)
    conn = instance_double('Mcp::ServerConnection')
    allow(conn).to receive(:connect).and_return(tools)
    allow(conn).to receive(:close)
    conn
  end

  def failing_connection(error)
    conn = instance_double('Mcp::ServerConnection')
    allow(conn).to receive(:connect).and_raise(error)
    allow(conn).to receive(:close)
    conn
  end

  def server_entry(name: 'fs', command: 'ruby')
    { name: name, command: command, args: [], env: {} }
  end

  def http_server_entry(name: 'remote')
    { name: name, url: 'https://example.com/mcp', headers: {} }
  end

  def build_manager(logger = instance_double('Logger'))
    allow(logger).to receive(:warn)
    allow(logger).to receive(:info)
    described_class.new(logger)
  end

  describe '#load' do
    it 'runs no MCP code path when no servers are configured' do
      allow(Mcp::ServerConnection).to receive(:new)
      manager = build_manager

      manager.load(ToolRegistry.new, [])

      expect(manager.status_notes).to eq([])
      expect(Mcp::ServerConnection).not_to have_received(:new)
    end

    it 'registers a server\'s tools under the "<server>.<tool>" namespace' do
      tools = [fake_tool('read_file', 'Read a file')]
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection(tools))
      registry = ToolRegistry.new
      manager  = build_manager

      manager.load(registry, [server_entry])

      expect(registry.get('fs.read_file')).to be_a(Mcp::ToolAdapter)
      expect(manager.status_notes).to include("MCP server 'fs' connected: 1 tool(s)")
    end

    it 'passes a url entry through to the connection (issue #402)' do
      tools = [fake_tool('ping')]
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection(tools))
      registry = ToolRegistry.new
      manager  = build_manager

      manager.load(registry, [http_server_entry])

      expect(Mcp::ServerConnection).to have_received(:new).with(
        name: 'remote', command: nil, args: nil, env: nil,
        url: 'https://example.com/mcp', headers: {}
      )
      expect(registry.get('remote.ping')).to be_a(Mcp::ToolAdapter)
    end

    it 'skips a tool whose name collides with a built-in and reports it' do
      tools = [fake_tool('read', 'Would shadow file.read')]
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection(tools))
      registry = ToolRegistry.new
      registry.register(Tool.new(name: 'file.read', description: 'built-in', parameters: {}))
      manager = build_manager

      manager.load(registry, [server_entry(name: 'file')])

      expect(registry.get('file.read').description).to eq('built-in')
      expect(manager.status_notes).to include(
        "skipped MCP tool 'file.read' (name collides with a built-in tool)"
      )
    end

    it 'degrades to a status note when a server fails to start' do
      conn = instance_double('Mcp::ServerConnection')
      allow(conn).to receive(:connect).and_raise(Errno::ENOENT, 'no such server')
      allow(conn).to receive(:close)
      allow(Mcp::ServerConnection).to receive(:new).and_return(conn)
      registry = ToolRegistry.new
      manager  = build_manager

      manager.load(registry, [server_entry(name: 'down')])

      expect(conn).to have_received(:close)
      expect(manager.status_notes.first).to include("MCP server 'down' failed to start")
      expect(manager.status_notes.first).to include('Errno::ENOENT')
      expect(registry.names).not_to include(a_string_matching(/^down\./))
    end

    it 'logs each note it records (a failed load leaves a trace)' do
      conn = instance_double('Mcp::ServerConnection')
      allow(conn).to receive(:connect).and_raise(Errno::ENOENT, 'nope')
      allow(conn).to receive(:close)
      allow(Mcp::ServerConnection).to receive(:new).and_return(conn)
      logger  = instance_double('Logger')
      allow(logger).to receive(:warn)
      allow(logger).to receive(:info)
      manager = described_class.new(logger)

      manager.load(ToolRegistry.new, [server_entry(name: 'down')])

      expect(logger).to have_received(:warn)
        .with(a_string_including("MCP server 'down' failed to start"))
    end
  end

  # Issue #405: the Manager records one ServerState per declared server so /mcp
  # can report a DOWN server, not only the ones that worked.
  describe '#servers (per-server state for /mcp)' do
    def manager_with_one_down
      allow(Mcp::ServerConnection).to receive(:new) do |**kwargs|
        kwargs[:name] == 'gone' ? failing_connection(Errno::ENOENT) : fake_connection([fake_tool('ping')])
      end
      manager = build_manager
      manager.load(ToolRegistry.new, [server_entry(name: 'up'), http_server_entry(name: 'gone')])
      manager
    end

    it 'records one entry per declared server, connected or not' do
      states = manager_with_one_down.servers

      expect(states.map(&:name)).to eq(%w[up gone])
    end

    it 'marks the transport and target the server was reached through' do
      states = manager_with_one_down.servers
      stdio = states.find { |s| s.name == 'up' }
      http  = states.find { |s| s.name == 'gone' }

      expect([stdio.transport, stdio.target]).to eq(['stdio', 'ruby'])
      expect([http.transport, http.target]).to eq(['http', 'https://example.com/mcp'])
    end

    it 'records the tools a connected server contributed and the error of a down one' do
      states = manager_with_one_down.servers
      up   = states.find { |s| s.name == 'up' }
      gone = states.find { |s| s.name == 'gone' }

      expect([up.connected, up.tool_names]).to eq([true, ['up.ping']])
      expect([gone.connected, gone.tool_names]).to eq([false, []])
      expect(gone.error).to include('Errno::ENOENT')
    end
  end

  describe '#connected_summary (what the session saves)' do
    it 'stores only the servers that connected, with their tool names' do
      allow(Mcp::ServerConnection).to receive(:new) do |**kwargs|
        kwargs[:name] == 'gone' ? failing_connection(Errno::ENOENT) : fake_connection([fake_tool('ping')])
      end
      manager = build_manager
      manager.load(ToolRegistry.new, [server_entry(name: 'up'), http_server_entry(name: 'gone')])

      expect(manager.connected_summary).to eq(
        [{ name: 'up', transport: 'stdio', tools: ['up.ping'] }]
      )
    end
  end

  describe '#collision_notes' do
    it 'selects the skipped-tool notes apart from the server notes' do
      registry = ToolRegistry.new
      registry.register(Tool.new(name: 'fs.read', description: 'built-in', parameters: {}))
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection([fake_tool('read')]))
      manager = build_manager
      manager.load(registry, [server_entry])

      expect(manager.collision_notes)
        .to eq(["skipped MCP tool 'fs.read' (name collides with a built-in tool)"])
    end
  end

  describe '#report_saved_session (resume-time comparison, issue #405)' do
    def saved_entry(name, tools)
      { name: name, transport: 'stdio', tools: tools }
    end

    it 'notes nothing when this run connected the same tools the session saved' do
      logger = instance_double('Logger')
      allow(logger).to receive(:warn)
      allow(logger).to receive(:info)
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection([fake_tool('ping')]))
      manager = described_class.new(logger)
      manager.load(ToolRegistry.new, [server_entry(name: 'fs')])

      manager.report_saved_session([saved_entry('fs', ['fs.ping'])])

      expect(logger).not_to have_received(:warn)
    end

    it 'notes it when the saved server is not declared in this run' do
      logger = instance_double('Logger')
      allow(logger).to receive(:warn)
      allow(logger).to receive(:info)
      manager = described_class.new(logger)
      manager.report_saved_session([saved_entry('fs', ['fs.ping'])])

      expect(logger).to have_received(:warn)
      allow(logger).to receive(:info)
        .with(a_string_including("fs (1 tool(s) in the saved session) is not declared in this run's config"))
    end

    it 'notes it when the saved server is declared but this run could not reach it' do
      logger = instance_double('Logger')
      allow(logger).to receive(:warn)
      allow(Mcp::ServerConnection).to receive(:new).and_return(failing_connection(Errno::ENOENT))
      manager = described_class.new(logger)
      manager.load(ToolRegistry.new, [server_entry(name: 'fs')])

      manager.report_saved_session([saved_entry('fs', ['fs.ping'])])

      expect(logger).to have_received(:warn)
        .with(a_string_including('declared but this run could not reach it'))
    end

    it 'notes the tools a connected server no longer provides' do
      logger = instance_double('Logger')
      allow(logger).to receive(:warn)
      allow(logger).to receive(:info)
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection([fake_tool('ping')]))
      manager = described_class.new(logger)
      manager.load(ToolRegistry.new, [server_entry(name: 'fs')])

      manager.report_saved_session([saved_entry('fs', %w[fs.ping fs.gone])])

      expect(logger).to have_received(:warn)
        .with(a_string_including('fs.gone'))
    end
  end

  describe '#close' do
    it 'closes every connection it opened' do
      tools = [fake_tool('ping')]
      conn  = fake_connection(tools)
      allow(Mcp::ServerConnection).to receive(:new).and_return(conn)
      manager = build_manager
      manager.load(ToolRegistry.new, [server_entry])

      manager.close

      expect(conn).to have_received(:close)
    end

    it 'is a no-op when nothing was loaded' do
      manager = build_manager

      expect { manager.close }.not_to raise_error
    end
  end
end
