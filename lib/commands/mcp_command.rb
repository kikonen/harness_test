# frozen_string_literal: true

require_relative "../command"

module Commands
  # /mcp - report the MCP servers this run declared (issue #405).
  #
  # The startup banner prints the MCP notes ONCE and they are then unreachable:
  # mid-session there is no way to ask which servers are actually up, which tools
  # each contributed, or why one is down. This is that read-out.
  #
  # It is a REPORT, not a toggle. A server is declared in the config and its tool
  # definitions go into tools_payload - the list sent with EVERY request - so the
  # tool set stays fixed for the whole run (issue #246: every request must send an
  # identical payload or a chat-template server sees a different prompt).
  class McpCommand < Command
    HELP = CommandHelp.new(
      usage: "mcp",
      summary: "List the MCP servers this run declared: whether each connected, " \
        "the tools each contributed, and any startup problem",
      group: :general,
      see_also: %w[tools])

    def handle(_args)
      states = @harness.mcp.servers
      return nothing_declared if states.empty?

      report(states)
    end

    private

    def nothing_declared
      @ui.puts "No MCP servers declared: no MCP code ran and the gem was never loaded."
      @ui.puts "  Declare one under 'mcp_servers:' in the config (.harness/config.yml or"
      @ui.puts "  the user-home config): 'command' to spawn a server, or 'url' to connect"
      @ui.puts "  to one (issue #402). Runnable examples of both: examples/mcp/."
    end

    def report(states)
      connected  = states.count(&:connected)
      tool_count = states.sum { |s| s.tool_names.size }

      @ui.puts "MCP servers: #{states.size} declared, #{connected} connected " \
        "(#{tool_count} tool(s) available)"
      states.each { |state| report_server(state) }
      report_collisions

      @ui.puts "  A server's tools are namespaced '<server>.<tool>'; /tools lists them"
      @ui.puts "  together with the built-ins."
      @ui.puts "  No live toggle: a server comes from the config and its tool definitions"
      @ui.puts "  are sent with every request, so they stay fixed for the run."
      @ui.puts "  What connected is saved with the session; a resumed run names a saved"
      @ui.puts "  server it can no longer reach."
    end

    def report_server(state)
      @ui.puts "  #{state.name}  [#{state.transport}]  #{state.target}"
      if state.connected
        @ui.puts "    connected: #{state.tool_names.size} tool(s)"
        report_tools(state)
      else
        @ui.puts "    DOWN (#{state.error})"
      end
    end

    # Descriptions come from the registry, not re-read from the server: the
    # registry holds what the model was actually told, which is the thing a user
    # checking "what can the model call" wants to see.
    def report_tools(state)
      registry = @harness.tool_registry
      state.tool_names.each do |name|
        @ui.puts "      #{name} - #{registry.get(name)&.description}"
      end
    end

    # A collision is about a tool on BOTH sides (the built-in wins), so it belongs
    # to no single server and would otherwise only ever appear in the banner.
    def report_collisions
      collisions = @harness.mcp.collision_notes
      return if collisions.empty?

      @ui.puts "  skipped (a built-in tool holds the name):"
      collisions.each do |note|
        @ui.puts "    #{note.sub(/\Askipped MCP tool '/, "").sub(/'$/, "")}"
      end
    end
  end
end
