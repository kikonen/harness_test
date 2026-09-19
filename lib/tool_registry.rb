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

  def to_openai
    @tools.values.map(&:to_openai)
  end

  def empty?
    @tools.empty?
  end

  def list
    @tools.values.map { |t| "  #{t.name} — #{t.description}" }.join("\n")
  end
end
