# frozen_string_literal: true

require "base64"

require_relative "../text_normalizer"
require_relative "../error_text"
require_relative "../tool_result"

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

    # The base64 alphabet plus the line breaks a server may insert; nothing else.
    BASE64_FORM = %r{\A[ A-Za-z0-9+/]*={0,2}\z}

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

    # tools/call round-trip. The gem returns the full JSON-RPC envelope. A
    # server-returned error (which the gem RAISES as ServerError) and any
    # transport failure both become an "error: ..." string - never a raise out
    # of execute, so one bad server cannot break the turn.
    def call_tool(tool_name, arguments)
      response = @client.call_tool(name: tool_name, arguments: arguments || {})
      ServerConnection.content_to_result(
        response,
        server_name: name,
        tool_name:)
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

    # Flatten a tools/call result. NO image blocks -> a plain String, the shape
    # every built-in tool already returns. WITH image blocks -> a ToolResult
    # whose text says nothing about the images: their fate is named once, later,
    # by ImageDelivery (issue #449). Collapsing them here is what made every
    # Blender screenshot read as a broken server.
    # isError answers with the server's own error text; unknown block types are
    # compacted to JSON.
    def self.content_to_result(response, server_name:, tool_name:)
      result = response.is_a?(Hash) ? (response["result"] || response) : response
      return "error: MCP tool returned no result" if result.nil?

      images = []
      parts  = []
      Array(result["content"]).each do |block|
        image = image_block(block, server_name, tool_name)
        if image
          images << image
        else
          parts << block_to_text(block)
        end
      end
      text = parts.reject(&:empty?).join("\n")

      if result["isError"]
        return "error: #{text.empty? ? "MCP tool reported an error" : text}"
      end
      return text if images.empty?

      ToolResult.new(text:, images:)
    end

    # Decode one image block, or nil when the block is not an image (or arrived
    # with data that will not decode - then block_to_text names it, so a result
    # never silently loses an image the server sent).
    #
    # mcp 1.8.2 hands the client `mime_type` (the gem's keyword name) while the
    # MCP wire spelling is `mimeType`; both occur in the wild, so both are read.
    # Measured through a stdio round trip: reading only the wire spelling
    # reported "[image: unknown]" for a server that named its mime type.
    def self.image_block(block, server_name, tool_name)
      return nil unless block.is_a?(Hash) && block["type"] == "image"

      bytes = decode_base64(block["data"])
      return nil if bytes.nil?

      ToolResult::Image.new(
        server: server_name,
        tool: tool_name,
        mime_type: mime_of(block),
        bytes:)
    end

    def self.mime_of(block)
      return "unknown" unless block.is_a?(Hash)

      block["mimeType"] || block["mime_type"] || "unknown"
    end

    # A BINARY-tagged byte container (doc/encoding_design.md): the decoded
    # payload is not text in any encoding and must never be normalized.
    # pack("m0") output and the line-broken pack("m") form both decode; a
    # payload that is not base64 decodes to nil, because unpack("m") IGNORES
    # characters outside the alphabet - validating first is what stops corrupt
    # data from being spilled as a plausible-looking broken image.
    def self.decode_base64(data)
      text = data.to_s
      return nil if text.empty? || !BASE64_FORM.match?(text)

      bytes = text.unpack1("m")
      return nil if bytes.nil? || bytes.empty?

      bytes.force_encoding(Encoding::BINARY)
    end

    # A block that is NOT carried as data: text inlines, an image that failed
    # to decode is NAMED (mime + the fact), a resource inlines or is named by
    # uri, anything else compacts to JSON.
    def self.block_to_text(block)
      return block.to_s unless block.is_a?(Hash)

      case block["type"]
      when "text" then block["text"].to_s
      when "image" then "[image: #{mime_of(block)} - its data did not decode]"
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
