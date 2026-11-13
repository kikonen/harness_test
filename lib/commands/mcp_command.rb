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
      # The whole read-out is contiguous prose -> ONE note call, two paragraphs.
      emit_role(
        :note,
        [
          "No MCP servers declared: no MCP code ran and the gem was never loaded.",
          "Declare one under 'mcp_servers:' in the config (.harness/config.yml " \
            "or the user-home config): 'command' to spawn a server, or 'url' to " \
            "connect to one (issue #402). Runnable examples of both: examples/mcp/."
        ])
    end

    def report(states)
      connected  = states.count(&:connected)
      tool_count = states.sum { |s| s.tool_names.size }

      emit_role(
        :note,
        "MCP servers: #{states.size} declared, #{connected} connected " \
          "(#{tool_count} tool(s) available)")
      emit_list(
        title: nil,
        kind: :table,
        columns: %i[name transport target status],
        items: states.map { |state| server_item(state) },
        origin: "mcp")
      states.each { |state| report_tools(state) if state.connected }
      report_collisions

      # The trailing guidance is contiguous prose -> ONE note call, three paragraphs.
      emit_role(
        :note,
        [
          "A server's tools are namespaced '<server>.<tool>'; /tools lists them " \
            "together with the built-ins.",
          "No live toggle: a server comes from the config and its tool " \
            "definitions are sent with every request, so they stay fixed for the run.",
          "What connected is saved with the session; a resumed run names a saved " \
            "server it can no longer reach."
        ])
    end

    # The status column carries either the tool count or the failure reason -
    # the two do not share a schema, so the status IS a named field, not a
    # sub-line the emitter bakes.
    def server_item(state)
      status = state.connected ? "connected (#{state.tool_names.size} tool(s))" \
                               : "DOWN (#{state.error})"
      { name: state.name, transport: state.transport, target: state.target, status: }
    end

    # Descriptions come from the registry, not re-read from the server: the
    # registry holds what the model was actually told, which is the thing a user
    # checking "what can the model call" wants to see.
    #
    # A :table, not a fused "name - description" line: MCP descriptions are the
    # one report text that is genuinely multi-paragraph markdown (servers send
    # them as real prose), so the field boundaries must survive to the data.
    # UI::Renderer#markdown_table expands each multi-paragraph description into
    # one row per paragraph (the tool name on its first row only), because
    # kramdown-ansi cannot stack paragraphs in a single cell.
    def report_tools(state)
      registry = @harness.tool_registry
      items = state.tool_names.map do |name|
        { tool: name, description: registry.get(name)&.description.to_s }
      end
      emit_list(
        columns: %i[tool description],
        items:,
        title: nil,
        kind: :table,
        origin: "tools")
    end

    # A collision is about a tool on BOTH sides (the built-in wins), so it belongs
    # to no single server and would otherwise only ever appear in the banner.
    def report_collisions
      collisions = @harness.mcp.collision_notes
      return if collisions.empty?

      items = collisions.map do |note|
        { value: note.sub(/\Askipped MCP tool '/, "").sub(/'$/, "") }
      end
      emit_list(
        title: "skipped (a built-in tool holds the name):",
        columns: [:value],
        items:,
        origin: "mcp")
    end
  end
end
