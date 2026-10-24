# frozen_string_literal: true

require_relative "../tool"
require_relative "../memories"

# Saves ONE memory: a durable note about this project that outlives the session
# it is written in (issue #10). Writes go to the fixed store path the harness
# owns - no FileList grant is asked for, because a memory call can name ONLY one
# note of the store and never a path. The write itself is recorded in harness.log
# by the harness' own tool-call line. Scope, caps and the consent decision:
# doc/memory_design.md.
module Tools
  class MemoryAddTool < Tool
    def initialize(memories)
      @memories = memories
      super(
        name: "memory.add",
        description: "Saves one memory: a short durable note about this " \
          "project (a decision, a gotcha, a preference, where a thing lives) " \
          "that the model and later sessions in the same project can read " \
          "back with memory.list / memory.read. Name it for what it is about. " \
          "Save what a later session would otherwise have to rediscover - not " \
          "the content of the file you are editing, which it can read itself. " \
          "Text is one fact, max #{Memories::MAX_BODY_CHARS} chars. At most " \
          "#{Memories::MAX_MEMORIES} notes exist: when the store is full this " \
          "refuses and you must consolidate (memory.read + rewrite a broader " \
          "note, memory.delete the narrow ones) before adding.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Name of the note (one path segment, e.g. consent-postures)"
            },
            text: {
              type: "string",
              description: "The note itself (markdown, one fact, max " \
                "#{Memories::MAX_BODY_CHARS} chars)"
            },
            overwrite: {
              type: "boolean",
              description: "Replace an existing note of this name (default false: " \
                "an existing name is refused so a note is never lost by accident)"
            }
          },
          required: %w[name text]
        }
      )
    end

    def execute(args)
      note = @memories.add(
        args["name"],
        args["text"],
        overwrite: args["overwrite"] == true)
      status(:ok, "#{note.name} (#{note.chars} chars)")
      "ok: saved memory '#{note.name}' (#{note.chars} chars) in #{Memories::DIR}/"
    rescue HarnessError => e
      # A refusal is returned, not raised: the message names the limit and the
      # way out, because re-sending the same call shape would fail identically.
      status(:fail, e.message[0, 80])
      "error: #{e.message}"
    end
  end
end
