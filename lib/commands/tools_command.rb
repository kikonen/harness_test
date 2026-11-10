# frozen_string_literal: true

require_relative "../command"

module Commands
  # /tools - list available tools.
  class ToolsCommand < Command
    HELP = CommandHelp.new(
      usage: "tools",
      summary: "List the tools the model can call, grouped by namespace, with " \
        "each one's description",
      group: :general,
      see_also: %w[help])

    def handle(_args)
      registry = @harness.tool_registry
      # issue #474: the tool listing is a grouped table emitted as STRUCTURE -
      # each namespace is a SECTION (a header + its rows), the rows read by name
      # like any kv row. UI::Renderer's :grouped_kv kind reproduces the old
      # @ui.puts block byte-for-byte (header at INDENT, rows one level deeper).
      emit_list(
        title: "Available tools (#{registry.tools.size}):",
        kind: :grouped_kv,
        columns: %i[header rows],
        items: grouped_items(registry),
        origin: "tools")
    end

    # Each namespace is a SECTION (header + kv rows); the row fields are the
    # tool's own name/description, read by name in the renderer.
    def grouped_items(registry)
      registry.grouped.map do |ns, tools|
        {
          header: ns,
          rows: tools.map { |t| { name: t.name, description: t.description } }
        }
      end
    end
  end
end
