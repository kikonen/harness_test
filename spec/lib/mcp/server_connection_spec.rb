# frozen_string_literal: true

require 'spec_helper'
require 'mcp/server_connection'
# call_tool's rescue names ::MCP::Client::ServerError; in the real flow that
# constant is defined because load_mcp_tools required the gem first. The error-
# mapping specs exercise that rescue, so they load the gem the same way.
require 'mcp'

RSpec.describe Mcp::ServerConnection do
  describe '.content_to_text (tools/call result flattening)' do
    it 'joins text content blocks with newlines' do
      response = { 'result' => { 'content' => [
        { 'type' => 'text', 'text' => 'line one' },
        { 'type' => 'text', 'text' => 'line two' }
      ] } }

      expect(described_class.content_to_text(response)).to eq("line one\nline two")
    end

    it 'accepts a bare result (no JSON-RPC envelope wrapper)' do
      response = { 'content' => [{ 'type' => 'text', 'text' => 'direct' }] }

      expect(described_class.content_to_text(response)).to eq('direct')
    end

    it 'names an image block instead of dumping base64 into the chain' do
      response = { 'result' => { 'content' => [
        { 'type' => 'image', 'mimeType' => 'image/png', 'data' => 'base64...' }
      ] } }

      expect(described_class.content_to_text(response)).to eq('[image: image/png]')
    end

    it 'inlines a resource block with text, or names it by uri when it has none' do
      with_text = { 'result' => { 'content' => [
        { 'type' => 'resource', 'resource' => { 'uri' => 'file:/a', 'text' => 'body' } }
      ] } }
      without_text = { 'result' => { 'content' => [
        { 'type' => 'resource', 'resource' => { 'uri' => 'file:/b' } }
      ] } }

      expect(described_class.content_to_text(with_text)).to eq('body')
      expect(described_class.content_to_text(without_text)).to eq('[resource: file:/b]')
    end

    it 'compacts an unknown block type to JSON' do
      response = { 'result' => { 'content' => [
        { 'type' => 'audio', 'data' => 'x' }
      ] } }

      expect(described_class.content_to_text(response)).to eq('{"type":"audio","data":"x"}')
    end

    it 'reports the server\'s own error text when isError is set' do
      response = { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'boom' }],
                                 'isError' => true } }

      expect(described_class.content_to_text(response)).to eq('error: boom')
    end

    it 'reports a generic error when isError is set with no text' do
      response = { 'result' => { 'content' => [], 'isError' => true } }

      expect(described_class.content_to_text(response)).to eq('error: MCP tool reported an error')
    end

    it 'reports an error when the result is nil' do
      expect(described_class.content_to_text(nil)).to eq('error: MCP tool returned no result')
    end

    it 'returns an empty string for a successful call with no content' do
      response = { 'result' => { 'content' => [] } }

      expect(described_class.content_to_text(response)).to eq('')
    end
  end

  describe '#connect (transport branch)' do
    # connect builds the transport, then a Client around it; stubbing both
    # classes exercises the branch with no subprocess and no endpoint.
    def stub_client(tools)
      client = instance_double('MCP::Client')
      allow(client).to receive(:connect)
      allow(client).to receive(:tools).and_return(tools)
      allow(MCP::Client).to receive(:new).and_return(client)
      client
    end

    it 'spawns a stdio transport for a command entry' do
      transport = instance_double('MCP::Client::Stdio')
      allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
      allow(MCP::Client::HTTP).to receive(:new)
      stub_client([])
      conn = described_class.new(name: 'fs', command: 'npx', args: ['-y', 'srv'],
                                 env: { 'KEY' => 'v' })

      conn.connect

      expect(conn).not_to be_http
      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: 'npx', args: ['-y', 'srv'], env: { 'KEY' => 'v' },
        read_timeout: described_class::READ_TIMEOUT
      )
      expect(MCP::Client::HTTP).not_to have_received(:new)
    end

    it 'opens an HTTP transport for a url entry, passing url and headers' do
      transport = instance_double('MCP::Client::HTTP')
      allow(MCP::Client::HTTP).to receive(:new).and_return(transport)
      stub_client([])
      conn = described_class.new(name: 'remote', url: 'https://example.com/mcp',
                                 headers: { 'Authorization' => 'Bearer t' })

      conn.connect

      expect(conn).to be_http
      expect(MCP::Client::HTTP).to have_received(:new).with(
        url: 'https://example.com/mcp', headers: { 'Authorization' => 'Bearer t' }
      )
      expect(conn.transport).to be(transport)
    end

    it 'does not give the HTTP transport a read_timeout (it has no such knob)' do
      transport = instance_double('MCP::Client::HTTP')
      allow(MCP::Client::HTTP).to receive(:new).and_return(transport)
      stub_client([])
      conn = described_class.new(name: 'remote', url: 'https://example.com/mcp')

      conn.connect

      expect(MCP::Client::HTTP).to have_received(:new).with(
        url: 'https://example.com/mcp', headers: {}
      )
    end
  end

  describe '#call_tool (round-trip error mapping)' do
    # The gem is not required by this file; call_tool resolves ::MCP:: lazily, so
    # a stubbed client exercises the mapping without a real server.
    def connection_with(client)
      conn = described_class.new(name: 'fs', command: 'ruby')
      conn.instance_variable_set(:@client, client)
      conn
    end

    it 'flattens a successful result to text' do
      client = instance_double('MCP::Client')
      allow(client).to receive(:call_tool).with(name: 'echo', arguments: { 'm' => 'hi' })
                                          .and_return({ 'result' => { 'content' => [
                                            { 'type' => 'text', 'text' => 'echo: hi' }
                                          ] } })
      conn = connection_with(client)

      expect(conn.call_tool('echo', 'm' => 'hi')).to eq('echo: hi')
    end

    it 'maps a server-raised ServerError to an "error:" string (never a raise)' do
      client = instance_double('MCP::Client')
      allow(client).to receive(:call_tool).and_raise(
        MCP::Client::ServerError.new('bad args', code: -32603)
      )
      conn = connection_with(client)

      expect(conn.call_tool('boom', {})).to eq("error: MCP tool 'boom' failed: bad args")
    end

    it 'maps any other transport failure to an "error:" string' do
      client = instance_double('MCP::Client')
      allow(client).to receive(:call_tool).and_raise(IOError, 'pipe closed')
      conn = connection_with(client)

      expect(conn.call_tool('boom', {})).to eq("error: MCP tool 'boom' failed (IOError: pipe closed)")
    end

    it 'normalizes nil arguments to an empty hash' do
      client = instance_double('MCP::Client')
      allow(client).to receive(:call_tool).with(name: 'noop', arguments: {})
                                          .and_return({ 'result' => { 'content' => [
                                            { 'type' => 'text', 'text' => 'ok' }
                                          ] } })
      conn = connection_with(client)

      expect(conn.call_tool('noop', nil)).to eq('ok')
    end
  end

  describe '#close' do
    it 'closes the transport' do
      transport = instance_double('MCP::Client::Stdio')
      allow(transport).to receive(:close)
      conn = described_class.new(name: 'fs', command: 'ruby')
      conn.instance_variable_set(:@transport, transport)

      conn.close

      expect(transport).to have_received(:close)
    end

    it 'is a no-op (no raise) when there is no transport yet' do
      conn = described_class.new(name: 'fs', command: 'ruby')

      expect { conn.close }.not_to raise_error
    end

    it 'swallows a transport close failure' do
      transport = instance_double('MCP::Client::Stdio')
      allow(transport).to receive(:close).and_raise(IOError, 'already gone')
      conn = described_class.new(name: 'fs', command: 'ruby')
      conn.instance_variable_set(:@transport, transport)

      expect { conn.close }.not_to raise_error
    end
  end
end
