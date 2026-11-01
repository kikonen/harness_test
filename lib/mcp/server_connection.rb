# frozen_string_literal: true

require_relative "../text_normalizer"
require_relative "../error_text"

# One MCP server connection (issue #48, HTTP transport issue #402). Owns the
# transport - a subprocess spawned by the gem's stdio transport, or a streamable
# HTTP/SSE connection to a remote endpoint - plus the initialize handshake, the
# tool list, and the tools/call round-trip. Everything below the transport is
# the same for both: the gem's Client API (connect / tools / call_tool) is
# transport-agnostic, so only #connect branches.
#
# The `MCP` gem is NOT required here: Harness requires it lazily only when
# mcp_servers: is configured, so a run with no MCP servers never loads it. The
# ::MCP:: constants below resolve at call time, after that require.
module Mcp
  class ServerConnection
    # Stdio only: the gem's stdio transport takes a read_timeout, its HTTP
    # transport does NOT (its knobs are max_message_bytes and
    # max_reconnection_wait, which bound a message size and a reconnection
    # budget - not a read). Mapping 30 onto either would be a different policy
    # wearing the same number, so an HTTP connection uses the gem's own
    # defaults and this constant stays on the stdio transport only.
    READ_TIMEOUT = 30

    attr_reader :name, :client, :transport

    # A connection is either a spawned program (command/args/env) or a remote
    # endpoint (url/headers). HarnessConfig guarantees exactly one of them.
    def initialize(name:, command: nil, args: [], env: {}, url: nil, headers: {})
      @name     = name
      @command  = command
      @args     = args || []
      @env      = env || {}
      @url      = url
      @headers  = headers || {}
      @transport = nil
      @client    = nil
    end

    def http?
      !@url.nil?
    end

    # Open the transport, run the initialize handshake, and return its tool
    # list. For stdio this SPAWNS the server; for HTTP it connects to an already
    # running endpoint. Raises if the server cannot be reached - Harness turns
    # that into a status note rather than crashing the run.
    def connect
      @transport = http? ? http_transport : stdio_transport
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

    private

    def stdio_transport
      ::MCP::Client::Stdio.new(
        command: @command,
        args: @args,
        env: @env,
        read_timeout: READ_TIMEOUT)
    end

    def http_transport
      ::MCP::Client::HTTP.new(url: @url, headers: @headers)
    end
  end
end
