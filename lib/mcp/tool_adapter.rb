# frozen_string_literal: true

require_relative "../tool"

module Mcp
  # A harness Tool that forwards to one tool on an external MCP server
  # (issue #48). It is registered as "<server>.<tool>" so each server is its own
  # namespace, and its OpenAI parameters are the MCP inputSchema (the gem's
  # inputSchema is already a JSON-Schema object, so it maps directly).
  #
  # CONSENT: an MCP tool runs like a built-in tool - no per-call dialog - because
  # the USER declared the server in config.yml. It is NOT a shell command, so the
  # run.command disaster denylist does not apply to the call itself; the server is
  # the trust boundary the user chose.
  class ToolAdapter < Tool
    def initialize(server_name:, mcp_tool:, connection:)
      @server_name = server_name
      @mcp_tool    = mcp_tool
      @connection  = connection
      super(
        name: "#{server_name}.#{mcp_tool.name}",
        description: mcp_tool.description.to_s,
        parameters: normalize_parameters(mcp_tool.input_schema)
      )
    end

    # The MCP tool's own name on the server (the harness name is namespaced).
    def mcp_tool_name
      @mcp_tool.name
    end

    def execute(args)
      @connection.call_tool(@mcp_tool.name, args)
    end

    private

    # The gem's inputSchema carries JSON-Schema bookkeeping ($schema, type) that
    # the OpenAI function schema does not want. Keep the object/properties/required
    # shape the model's tool-calling expects; a server that sent no usable schema
    # gets an empty object so the call still validates.
    def normalize_parameters(schema)
      schema = schema.is_a?(Hash) ? schema : {}
      properties = schema["properties"]
      required   = Array(schema["required"])

      {
        type: "object",
        properties: properties.is_a?(Hash) ? properties : {},
        required:
      }
    end
  end
end
