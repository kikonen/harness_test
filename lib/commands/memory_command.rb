# frozen_string_literal: true

require_relative "../command"
require_relative "../memories"
require_relative "store_listing"

module Commands
  # /memory - list the project's memories, or print one note's body.
  #
  # The same data the model sees through memory.list / memory.read: one reader
  # (Memories) behind both sides, so what the owner inspects and what the model
  # reads cannot drift apart (the same shape as /skills). Issue #10.
  #
  # The listing is a :table with its own number column and an entry opens by name
  # or by that number (#474, increment 20); the row/selector/rule shape is shared
  # with /plans through StoreListing. The MODEL SIDE is unchanged: a tool result is
  # :text and is never rendered, so the ordinal there would be a position the model
  # could misread - the number is the owner-side listing's.
  class MemoryCommand < Command
    include StoreListing

    HELP = CommandHelp.new(
      usage: "memory [name|N]",
      forms: ["memory", "memory <name>", "memory <N>"],
      summary: "List the project's memories (#{Memories::DIR}/), " \
        "or print one note's body by name or by its number",
      group: :session,
      see_also: %w[skills session])

    def handle(args)
      name = args.to_s.strip

      return list_memories if name.empty?

      show_memory(name)
    end

    private

    def memories
      @harness.memories
    end

    def list_memories
      all = memories.all
      if all.empty?
        # The empty-state guidance is contiguous prose -> ONE note call.
        emit_role(
          :note,
          [
            "No memories stored (#{memories.dir}).",
            "The model saves one with memory.add(name:, text:); " \
              "the file is #{Memories::DIR}/<name>.md."
          ])
        return
      end

      emit_list(
        title: "Memories (#{all.size}/#{memories.max_memories} notes, " \
          "#{Memories::MAX_BODY_CHARS} chars max each):",
        kind: :table,
        columns: %i[number name description chars],
        items: listing_rows(all),
        footer: ["Show one with: /memory <name>  or  /memory <N>"],
        origin: "memory")
    end

    def show_memory(requested)
      all = memories.all
      index = list_index(requested, all.size)

      if index
        entry = all[index]
        return show_body(
          store_rule(Memories::DIR, entry.name, index),
          memories.body(entry.name))
      end

      name = memories.normalize_name(requested)
      if name.nil?
        emit_status(
          label: "memory",
          verdict: :fail,
          message: "a memory name is one path segment, or a memory number: #{requested}")
        return
      end

      body = memories.body(name)
      if body.nil?
        emit_status(
          label: "memory",
          verdict: :fail,
          message: "no memory named '#{name}' (#{available_hint})")
        return
      end

      show_body(store_rule(Memories::DIR, name, nil), body)
    end

    def available_hint
      names = memories.names
      names.empty? ? "no memories stored" : names.join(", ")
    end
  end
end
