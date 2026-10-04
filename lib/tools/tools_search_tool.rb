# frozen_string_literal: true

require_relative '../tool'

# Meta-tool: searches available tools by name or description
# (case-insensitive substring match). The registry is passed in at
# construction time (it is built after this tool is instantiated, so it
# cannot be required at load time).
module Tools

  class ToolsSearchTool < Tool
    def initialize(registry)
      @registry = registry
      super(
        name: 'tools.search',
        description: 'Searches available tools by name or description (case-insensitive substring match). ' \
                     'Returns matching tools with their full descriptions. ' \
                     'Use this to find a specific tool when you are not sure of its exact name.',
        parameters: {
          type: 'object',
          properties: {
            query: { type: 'string', description: 'Search term to match against tool names and descriptions' }
          },
          required: ['query']
        }
      )
    end

    def execute(args)
      query = args['query'].to_s.strip
      return 'error: usage: tools.search(query)' if query.empty?

      matches = @registry.search(query)
      if matches.empty?
        Tool.puts "  [tools.search] no tools match '#{query}'"
        return "no tools match '#{query}'"
      end

      lines = matches.map { |t| "#{t.name} - #{t.description}" }
      Tool.puts "  [tools.search] #{matches.size} tool(s) match '#{query}'"
      lines.join("\n")
    end
  end
end
