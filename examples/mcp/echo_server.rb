# frozen_string_literal: true

# A minimal stdio MCP SERVER (issue #48 example): it exposes one tool,
# "echo_tool", that echoes back its message argument.
#
# Run it directly to see it wait on stdin (it speaks JSON-RPC over stdio):
#   ruby examples/mcp/echo_server.rb
# Normally a client spawns it - see echo_client.rb next to this file.

require "mcp"

class EchoTool < MCP::Tool
  description "Echoes back its message argument"
  input_schema(
    properties: {
      message: { type: "string" }
    },
    required: ["message"])

  class << self
    # The gem always passes server_context: (the connection/handshake context);
    # this tool ignores it, so the unused-argument cop is silenced for it.
    # rubocop:disable Lint/UnusedMethodArgument
    def call(message:, server_context:)
      MCP::Tool::Response.new([{ type: "text", text: "echo: #{message}" }])
    end
    # rubocop:enable Lint/UnusedMethodArgument
  end
end

server = MCP::Server.new(
  name: "echo_server",
  version: "0.1.0",
  tools: [EchoTool])

transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
