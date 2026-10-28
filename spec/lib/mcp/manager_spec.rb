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

  def server_entry(name: 'fs', command: 'ruby')
    { name: name, command: command, args: [], env: {} }
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
