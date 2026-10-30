# frozen_string_literal: true

require_relative "../text_normalizer"
require_relative "../error_text"

# One stdio MCP server connection (issue #48). Owns the subprocess spawned by
# the gem's stdio transport, the initialize handshake, the tool list, and the
# tools/call round-trip. The `MCP` gem is NOT required here: Harness requires it
# lazily only when mcp_servers: is configured, so a run with no MCP servers never
# loads it. The ::MCP:: constants below resolve at call time, after that require.
module Mcp
  class ServerConnection
    READ_TIMEOUT = 30

    attr_reader :name, :client, :transport

    def initialize(name:, command:, args: [], env: {})
      @name     = name
      @command  = command
      @args     = args
      @env      = env
      @transport = nil
      @client    = nil
    end

    # Spawn the server, run the initialize handshake, and return its tool list.
    # Raises if the server cannot be reached - Harness turns that into a status
    # note rather than crashing the run.
    def connect
      @transport = ::MCP::Client::Stdio.new(
        command: @command,
        args: @args,
        env: @env,
        read_timeout: READ_TIMEOUT)
      @client = ::MCP::Client.new(transport: @transport)
      @client.connect
      @client.tools
    end

    # tools/call round-trip. The gem returns the full JSON-RPC envelope; the
    # content blocks are flattened to a single normalized string for the model
    # chain. A server-returned error (which the gem RAISES as ServerError) and
    # any transport failure both become an "error: ..." string - never a raise
    # out of execute, so one bad server cannot break the turn.
    def call_tool(tool_name, arguments)
      response = @client.call_tool(name: tool_name, arguments: arguments || {})
      ServerConnection.content_to_text(response)
    rescue ::MCP::Client::ServerError => e
      "error: MCP tool '#{tool_name}' failed: #{e.message}"
    rescue StandardError => e
      "error: MCP tool '#{tool_name}' failed (#{ErrorText.label(e)})"
    end

    def close
      @transport&.close
    rescue StandardError
      nil
    end

    # Flatten a tools/call result to text. isError answers with the server's own
    # error text; image blocks are named, not dumped (base64 in the chain is
    # huge and useless to the model); unknown blocks are compacted to JSON.
    def self.content_to_text(response)
      result = response.is_a?(Hash) ? (response["result"] || response) : response
      return "error: MCP tool returned no result" if result.nil?

      blocks = Array(result["content"])
      text   = blocks.map { |block| block_to_text(block) }.reject(&:empty?).join("\n")
      if result["isError"]
        return "error: #{text.empty? ? "MCP tool reported an error" : text}"
      end

      text
    end

    def self.block_to_text(block)
      return block.to_s unless block.is_a?(Hash)

      case block["type"]
      when "text" then block["text"].to_s
      when "image" then "[image: #{block["mimeType"] || "unknown"}]"
      when "resource" then resource_to_text(block["resource"])
      else JSON.dump(block)
      end
    end

    def self.resource_to_text(resource)
      return "" unless resource.is_a?(Hash)

      content = resource["text"]
      return content.to_s unless content.nil?

      "[resource: #{resource["uri"] || "unknown"}]"
    end
  end
end
