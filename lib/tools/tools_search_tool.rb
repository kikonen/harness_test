# frozen_string_literal: true

require_relative '../tool'

# Meta-tool: searches available tools by name or description
# (case-insensitive substring match). The registry is passed in at
# construction time (it is built after this tool is instantiated, so it
# cannot be required at load time).
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
      puts "  [tools.search] no tools match '#{query}'"
      $stdout.flush
      return "no tools match '#{query}'"
    end

    lines = matches.map { |t| "#{t.name} — #{t.description}" }
    puts "  [tools.search] #{matches.size} tool(s) match '#{query}'"
    $stdout.flush
    lines.join("\n")
  end
end
