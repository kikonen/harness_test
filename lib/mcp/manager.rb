# frozen_string_literal: true

require_relative "server_connection"
require_relative "tool_adapter"
require_relative "../error_text"

module Mcp
  # Owns everything MCP-side for one harness run (issue #48): the declared
  # servers, their live connections (spawned subprocess or remote endpoint),
  # the tools they contribute to the registry, and the startup notes the banner
  # reports. Harness holds ONE of these and delegates to it, so the MCP
  # machinery does not live in Harness.
  #
  # Opt-in: #load returns before the `mcp` gem is required when no servers are
  # configured, so a run without MCP servers never loads it.
  class Manager
    # One declared server as this run actually reached it: the transport kind and
    # its target, whether it connected, and WHICH tools it contributed. This is
    # what /mcp prints (issue #405) and what the session saves, so a resumed run
    # can say whether the saved conversation's MCP tools exist in this one.
    ServerState = Struct.new(
      :name,
      :transport,
      :target,
      :connected,
      :tool_names,
      :error,
      keyword_init: true)

    attr_reader :status_notes, :servers

    def initialize(logger)
      @logger       = logger
      @connections  = []
      @status_notes = []
      @servers      = []
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
        # Every declared server is recorded as down for the same reason, so the
        # per-server report stays complete: "why is my server missing" has one
        # answer here rather than an empty list the reader must interpret.
        error = "mcp gem could not be loaded (#{e.message})"
        servers.each do |server|
          @servers << server_state(server, connected: false, tool_names: [], error:)
        end
        note("mcp gem could not be loaded (#{e.message}) - no MCP tools", :warn)
        return
      end

      servers.each { |server| connect_server(registry, server) }
    end

    # What the session stores (issue #405): the servers THIS run connected and
    # the tool names they contributed. A failed server is not stored - the saved
    # session should describe the tool set the conversation actually had, and a
    # server that never connected contributed none.
    def connected_summary
      @servers.filter_map do |server|
        next unless server.connected

        { name: server.name, transport: server.transport, tools: server.tool_names }
      end
    end

    # Issue #405: a saved session names the MCP tools its conversation had. The
    # config of the resumed run may say otherwise (the example server is no
    # longer running, the entry was removed, the server now lists different
    # tools). Comparing the two is what turns a silently smaller tool set into a
    # stated fact - the same reason the startup banner exists.
    def report_saved_session(saved)
      Array(saved).each do |entry|
        entry = entry.transform_keys(&:to_sym)
        report_saved_server(entry[:name], Array(entry[:tools]))
      end
    end

    # Close every server connection this run opened, so a spawned server is not
    # left running after the CLI exits.
    def close
      @connections.each(&:close)
      @connections = []
    end

    # A collision note is per TOOL, not per server, so /mcp reports it apart from
    # the server list. It is selected here rather than by a caller matching the
    # text: this class is what writes that note.
    def collision_notes
      @status_notes.select { |text| text.include?("collides with a built-in tool") }
    end

    private

    def report_saved_server(name, saved_tools)
      state = @servers.find { |server| server.name == name }
      label = "#{name} (#{saved_tools.size} tool(s) in the saved session)"

      if state.nil?
        note("MCP server #{label} is not declared in this run's config", :warn)
        return
      end
      unless state.connected
        note("MCP server #{label} is declared but this run could not reach it", :warn)
        return
      end

      missing = saved_tools - state.tool_names
      return if missing.empty?

      note(
        "MCP server #{name} answered with #{state.tool_names.size} tool(s); " \
          "#{missing.size} from the saved session are missing: #{missing.join(', ')}",
        :warn)
    end

    # One server: open its transport + handshake + tools/list, then register
    # each tool. A connect failure closes the (possibly half-open) connection
    # and records a note; the run continues without that server's tools. The
    # outcome is recorded as a ServerState either way - /mcp must be able to say
    # a declared server is DOWN, not only that something went wrong once at
    # startup.
    def connect_server(registry, server)
      connection = ServerConnection.new(
        name: server[:name],
        command: server[:command],
        args: server[:args],
        env: server[:env],
        url: server[:url],
        headers: server[:headers])
      begin
        mcp_tools = connection.connect
      rescue StandardError => e
        connection.close
        error = ErrorText.label(e)
        @servers << server_state(server, connected: false, tool_names: [], error:)
        note("MCP server '#{server[:name]}' failed to start (#{error})", :warn)
        return
      end
      @connections << connection

      registered_names = []
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
        registered_names << adapter.name
      end
      @servers << server_state(
        server,
        connected: true,
        tool_names: registered_names,
        error: nil)
      note(
        "MCP server '#{server[:name]}' connected: #{registered_names.size} tool(s)",
        :info)
    end

    def server_state(server, connected:, tool_names:, error:)
      ServerState.new(
        name: server[:name],
        transport: server[:url] ? "http" : "stdio",
        target: server[:url] || [server[:command], *Array(server[:args])].join(" "),
        connected:,
        tool_names:,
        error:)
    end

    # Every note is BOTH a banner line (status_notes) and a log line, so a
    # server that failed to load leaves a trace even when the banner is quiet.
    def note(text, level)
      @status_notes << text
      @logger.public_send(level, text)
    end
  end
end
