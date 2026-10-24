# frozen_string_literal: true

require_relative "../tool"
require_relative "../memories"

# Removes ONE memory (issue #10). Deleting a note is not a file delete: it takes
# no DELETE grant because the argument is a note NAME, never a path, and the
# removal is recorded in harness.log by the harness' own tool-call line.
module Tools
  class MemoryDeleteTool < Tool
    def initialize(memories)
      @memories = memories
      super(
        name: "memory.delete",
        description: "Removes one stored memory by NAME (not a path). Use it " \
          "when a note has turned out to be wrong or is superseded by a " \
          "broader one - a stale memory is worse than none, because a later " \
          "session reads it as fact. Takes no DELETE grant; the removal is " \
          "recorded in harness.log.",
        parameters: {
          type: "object",
          properties: {
            name: { type: "string", description: "Name of the memory to remove" }
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

      removed = @memories.delete(name)
      if removed.nil?
        status(:fail, "no such memory: #{name}")
        return "error: no memory named '#{name}' (#{@memories.available_hint})"
      end

      status(:ok, "#{removed} removed")
      "ok: removed memory '#{removed}' (#{@memories.count} left)"
    end
  end
end
