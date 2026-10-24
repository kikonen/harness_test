# frozen_string_literal: true

require_relative "../tool"
require_relative "../memories"

# Loads ONE memory's body (markdown) so the model can act on what was learned
# in an earlier session. The store is harness-owned - like a skill body - so
# reading it needs no FileList grant. doc/memory_design.md.
module Tools
  class MemoryReadTool < Tool
    def initialize(memories)
      @memories = memories
      super(
        name: "memory.read",
        description: "Loads the full body of one stored memory (markdown) and " \
          "returns it as background for the current task. Call memory.list " \
          "first if you do not know the name. A name is one path segment: one " \
          "carrying a separator or '..' is refused, so this reads memories, " \
          "not arbitrary files.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Memory name (as listed by memory.list)"
            }
          },
          required: ["name"]
        }
      )
    end

    def execute(args)
      raw  = args["name"]
      name = @memories.normalize_name(raw)

      if name.nil?
        status(:fail, "invalid memory name")
        return "error: #{@memories.name_error(raw)}"
      end

      body = @memories.body(name)
      if body.nil?
        status(:fail, "no such memory: #{name}")
        return "error: no memory named '#{name}' (#{@memories.available_hint})"
      end

      status(:ok, "#{name} (#{body.lines.size} lines)")
      body
    end
  end
end
