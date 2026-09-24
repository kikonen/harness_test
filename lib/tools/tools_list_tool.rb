# frozen_string_literal: true

require_relative '../tool'

# Meta-tool: lists all available tools with their descriptions.
# The registry is passed in at construction time (it is built after this
# tool is instantiated, so it cannot be required at load time).
class ToolsListTool < Tool
  def initialize(registry)
    @registry = registry
    super(
      name: 'tools.list',
      description: 'Lists all available tools with their names and descriptions. ' \
                   'Use this to discover what tools exist before calling them, ' \
                   'or to get the full description of a tool you are unsure about.',
      parameters: {
        type: 'object',
        properties: {},
        required: []
      }
    )
  end

  def execute(_args)
    lines = @registry.sorted_tools.map do |t|
      "#{t.name} — #{t.description}"
    end
    puts "  [tools.list] #{lines.size} tool(s)"
    $stdout.flush
    lines.join("\n")
  end
end
