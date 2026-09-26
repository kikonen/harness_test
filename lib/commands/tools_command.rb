# frozen_string_literal: true

module Commands
  # /tools - list available tools.
  class ToolsCommand
    def initialize(harness, _file_list, _options)
      @harness = harness
    end

    def handle(_args)
      registry = @harness.tool_registry
      puts "Available tools (#{registry.tools.size}):"
      registry.grouped.each do |ns, tools|
        puts "  #{ns}:"
        tools.each do |t|
          puts "    #{t.name} - #{t.description}"
        end
      end
    end
  end
end
