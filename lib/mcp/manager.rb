# frozen_string_literal: true

require_relative "server_connection"
require_relative "tool_adapter"
require_relative "../error_text"

module Mcp
  # Owns everything MCP-side for one harness run (issue #48): the declared
  # servers, their live subprocess connections, the tools they contribute to the
  # registry, and the startup notes the banner reports. Harness holds ONE of
  # these and delegates to it, so the MCP machinery does not live in Harness.
  #
  # Opt-in: #load returns before the `mcp` gem is required when no servers are
  # configured, so a run without MCP servers never loads it.
  class Manager
    attr_reader :status_notes

    def initialize(logger)
      @logger       = logger
      @connections  = []
      @status_notes = []
    end

    # Connect each declared server and register its tools into the registry.
    # A server that fails to start degrades to a status note rather than
    # crashing the run; a tool whose name collides with a built-in is skipped
    # (the built-in wins) and reported.
    def load(registry, servers)
      servers = Array(servers)
      return if servers.empty?

      begin
        require("mcp")
      rescue LoadError => e
        note("mcp gem could not be loaded (#{e.message}) - no MCP tools", :warn)
        return
      end

      servers.each { |server| connect_server(registry, server) }
    end

    # Close every server subprocess this run spawned, so a spawned server is not
    # left running after the CLI exits.
    def close
      @connections.each(&:close)
      @connections = []
    end

    private

    # One server: spawn + handshake + tools/list, then register each tool. A
    # connect failure closes the (possibly half-spawned) subprocess and records
    # a note; the run continues without that server's tools.
    def connect_server(registry, server)
      connection = ServerConnection.new(
        name: server[:name],
        command: server[:command],
        args: server[:args],
        env: server[:env])
      begin
        mcp_tools = connection.connect
      rescue StandardError => e
        connection.close
        msg = "MCP server '#{server[:name]}' failed to start (#{ErrorText.label(e)})"
        note(msg, :warn)
        return
      end
      @connections << connection

      registered = 0
      mcp_tools.each do |mcp_tool|
        adapter = ToolAdapter.new(
          server_name: server[:name],
          mcp_tool:,
          connection:)
        if registry.get(adapter.name)
          msg = "skipped MCP tool '#{adapter.name}' (name collides with a built-in tool)"
          note(msg, :warn)
          next
        end
        registry.register(adapter)
        registered += 1
      end
      note("MCP server '#{server[:name]}' connected: #{registered} tool(s)", :info)
    end

    # Every note is BOTH a banner line (status_notes) and a log line, so a
    # server that failed to load leaves a trace even when the banner is quiet.
    def note(text, level)
      @status_notes << text
      @logger.public_send(level, text)
    end
  end
end
