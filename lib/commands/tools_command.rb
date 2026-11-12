# frozen_string_literal: true

require_relative "../command"

module Commands
  # /tools - list available tools.
  class ToolsCommand < Command
    HELP = CommandHelp.new(
      usage: "tools",
      summary: "List the tools the model can call, with each one's description",
      group: :general,
      see_also: %w[help])

    def handle(_args)
      registry = @harness.tool_registry
      emit_list(
        title: "Available tools (#{registry.tools.size}):",
        kind: :table,
        columns: %i[tool description],
        items: table_items(registry),
        origin: "tools")
    end

    # One row per tool. The row ORDER is the registry's namespace grouping (sorted
    # for prompt caching); the command must not re-sort or rename anything the
    # model was already told about. The namespace itself is not a column - the
    # tool name is already namespaced, so a separate group column only repeats it.
    def table_items(registry)
      registry.grouped.flat_map do |_ns, tools|
        tools.map { |t| { tool: t.name, description: t.description } }
      end
    end
  end
end
