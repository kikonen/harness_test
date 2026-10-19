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
      @ui.puts "Available tools (#{registry.tools.size}):"
      registry.grouped.each do |ns, tools|
        @ui.puts "  #{ns}:"
        tools.each do |t|
          @ui.puts "    #{t.name} - #{t.description}"
        end
      end
    end
  end
end
