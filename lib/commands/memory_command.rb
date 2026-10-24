# frozen_string_literal: true

require_relative "../command"
require_relative "../memories"

module Commands
  # /memory - list the project's memories, or print one note's body.
  #
  # The same data the model sees through memory.list / memory.read: one reader
  # (Memories) behind both sides, so what the owner inspects and what the model
  # reads cannot drift apart (the same shape as /skills). Issue #10.
  class MemoryCommand < Command
    HELP = CommandHelp.new(
      usage: "memory [name]",
      forms: ["memory", "memory <name>"],
      summary: "List the project's memories (#{Memories::DIR}/), " \
        "or print one note's body",
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
        @ui.puts "No memories stored (#{memories.dir})."
        @ui.puts "The model saves one with memory.add(name:, text:); " \
          "the file is #{Memories::DIR}/<name>.md."
        return
      end

      @ui.puts "Memories (#{all.size}/#{Memories::MAX_MEMORIES} notes, " \
        "#{Memories::MAX_BODY_CHARS} chars max each):"
      all.each { |m| @ui.puts "  #{m.name} - #{m.description} (#{m.chars} chars)" }
      @ui.puts "Show one with: /memory <name>"
    end

    def show_memory(requested)
      name = memories.normalize_name(requested)
      if name.nil?
        @ui.puts "[error] a memory name is one path segment: #{requested}"
        return
      end

      body = memories.body(name)
      if body.nil?
        @ui.puts "[error] no memory named '#{name}' (#{available_hint})"
        return
      end

      rule = "-" * [1, 60 - name.length].max
      @ui.puts "--- #{name} (#{Memories::DIR}) #{rule}"
      body.each_line { |line| @ui.print line }
      @ui.puts unless body.end_with?("\n")
    end

    def available_hint
      names = memories.names
      names.empty? ? "no memories stored" : names.join(", ")
    end
  end
end
