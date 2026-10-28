# frozen_string_literal: true

require 'spec_helper'
require 'mcp/tool_adapter'

RSpec.describe Mcp::ToolAdapter do
  def fake_connection
    conn = instance_double('Mcp::ServerConnection')
    allow(conn).to receive(:call_tool)
    conn
  end

  # The three fields the adapter reads off the gem's tool object.
  def fake_tool(name = 'read_file', description = 'Read a file', schema = {})
    Struct.new(:name, :description, :input_schema).new(name, description, schema)
  end

  def adapter(tool = fake_tool, conn = fake_connection)
    described_class.new(server_name: 'fs', mcp_tool: tool, connection: conn)
  end

  describe '#initialize / namespacing' do
    it 'names the tool "<server>.<tool>"' do
      expect(adapter.name).to eq('fs.read_file')
    end

    it 'reports the MCP tool\'s own name (the harness name is namespaced)' do
      expect(adapter.mcp_tool_name).to eq('read_file')
    end

    it 'carries the MCP description' do
      expect(adapter.description).to eq('Read a file')
    end

    it 'coerces a nil description to an empty string' do
      a = adapter(fake_tool('t', nil, {}))
      expect(a.description).to eq('')
    end

    it 'is a Tool (so the registry and tools_payload treat it like a built-in)' do
      expect(adapter).to be_a(Tool)
    end
  end

  describe '#to_openai parameters mapping' do
    it 'maps an MCP inputSchema to the OpenAI object/properties/required shape' do
      schema = {
        '$schema' => 'https://json-schema.org/draft/2020-12/schema',
        'type' => 'object',
        'properties' => { 'path' => { 'type' => 'string' } },
        'required' => ['path']
      }
      a = adapter(fake_tool('read_file', 'd', schema))

      expect(a.parameters).to eq(
        type: 'object',
        properties: { 'path' => { 'type' => 'string' } },
        required: ['path']
      )
    end

    it 'drops the JSON-Schema bookkeeping ($schema, type) the OpenAI shape does not want' do
      schema = { '$schema' => 'x', 'type' => 'object', 'properties' => {}, 'required' => [] }
      a = adapter(fake_tool('t', 'd', schema))

      expect(a.parameters).not_to have_key(:$schema)
      expect(a.parameters[:properties]).to eq({})
    end

    it 'gives an empty object schema when the server sent none' do
      a = adapter(fake_tool('t', 'd', nil))

      expect(a.parameters).to eq(type: 'object', properties: {}, required: [])
    end

    it 'tolerates a schema with properties but no required list' do
      schema = { 'properties' => { 'x' => { 'type' => 'number' } } }
      a = adapter(fake_tool('t', 'd', schema))

      expect(a.parameters[:properties]).to eq('x' => { 'type' => 'number' })
      expect(a.parameters[:required]).to eq([])
    end

    it 'tolerates a non-Hash schema (a server that sent junk)' do
      a = adapter(fake_tool('t', 'd', 'not a schema'))

      expect(a.parameters).to eq(type: 'object', properties: {}, required: [])
    end

    it 'renders through Tool#to_openai with the namespaced name' do
      payload = adapter.to_openai

      expect(payload[:function][:name]).to eq('fs.read_file')
      expect(payload[:function][:parameters][:type]).to eq('object')
    end
  end

  describe '#execute' do
    it 'forwards to the connection with the MCP tool\'s own name (not the namespaced one)' do
      conn = fake_connection
      allow(conn).to receive(:call_tool).with('read_file', { 'path' => 'a.rb' }).and_return('contents')
      a = adapter(fake_tool('read_file', 'd', {}), conn)

      expect(a.execute('path' => 'a.rb')).to eq('contents')
    end

    it 'passes nil arguments through as an empty call (the connection normalizes them)' do
      conn = fake_connection
      allow(conn).to receive(:call_tool).with('noop', nil).and_return('ok')
      a = adapter(fake_tool('noop', 'd', {}), conn)

      expect(a.execute(nil)).to eq('ok')
    end
  end
end
