# frozen_string_literal: true

require_relative 'tool'

class ToolRegistry
  attr_reader :tools

  def initialize
    @tools = {}
  end

  def register(tool)
    @tools[tool.name] = tool
    self
  end

  def get(name)
    @tools[name]
  end

  # All tool names, sorted alphabetically (stable ordering for prompt caching).
  def names
    @tools.keys.sort
  end

  # Tools sorted by name (stable ordering for prompt caching).
  def sorted_tools
    @tools.values.sort_by(&:name)
  end

  def to_openai
    sorted_tools.map(&:to_openai)
  end

  def empty?
    @tools.empty?
  end

  # Group tools by namespace, each group sorted alphabetically.
  # Returns an array of [namespace, [Tool, ...]] pairs, sorted by namespace.
  def grouped
    @tools.values
          .group_by(&:namespace)
          .sort_by { |ns, _| ns }
          .map { |ns, tools| [ns, tools.sort_by(&:name)] }
  end

  # Generate a compact, stable tool list for the system prompt.
  # Grouped by namespace, alphabetical within each group.
  # Example output:
  #   file: add, copy, delete, list, patch, read, rename, search, sha, write
  #   dir:  create, delete
  #   ui:   notify
  #   time: now
  def tool_list
    grouped.map do |ns, tools|
      "#{ns}: #{tools.map(&:short_name).join(', ')}"
    end.join("\n")
  end

  # Search tools by name or description (case-insensitive substring match).
  # Returns an array of matching Tool objects, sorted by name.
  def search(query)
    q = query.to_s.downcase.strip
    return sorted_tools if q.empty?

    sorted_tools.select do |t|
      t.name.downcase.include?(q) || t.description.downcase.include?(q)
    end
  end
end
