# frozen_string_literal: true

require_relative "../tool"
require_relative "../memories"

# Lists the project's stored memories: name, one-line description, and how many
# of the available slots are used. A note's BODY is never listed here - that is
# memory.read's job (issue #10).
module Tools
  class MemoryListTool < Tool
    def initialize(memories)
      @memories = memories
      super(
        name: "memory.list",
        description: "Lists this project's stored memories (name + one-line " \
          "description each) and how many of the available slots " \
          "are used. Memories are notes the harness kept from " \
          "EARLIER sessions in this project, so list them before " \
          "rediscovering something already known. Read one with " \
          "memory.read(name).",
        parameters: {
          type: "object",
          properties: {},
          required: []
        }
      )
    end

    def execute(_args)
      notes = @memories.all
      if notes.empty?
        status(:info, "no memories stored")
        return "no memories stored (#{Memories::DIR}/ is empty) - " \
          "save one with memory.add(name:, text:)"
      end

      status(:info, "#{notes.size}/#{Memories::MAX_MEMORIES} memories")
      lines = notes.map { |m| "#{m.name} - #{m.description}" }
      "Memories (#{notes.size}/#{Memories::MAX_MEMORIES}), read one with " \
        "memory.read:\n#{lines.join("\n")}"
    end
  end
end
