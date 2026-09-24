# frozen_string_literal: true

# -- Tool system ----------------------------------------------------------

class Tool
  attr_reader :name, :description, :parameters

  def initialize(name:, description:, parameters:)
    @name        = name
    @description = description
    @parameters  = parameters
  end

  # Extract the namespace from a dot-notation tool name.
  # e.g. "file.read" → "file", "ui.notify" → "ui"
  # If no dot is present, the entire name is the namespace.
  def namespace
    @name.include?('.') ? @name.split('.').first : @name
  end

  # The tool's short name within its namespace.
  # e.g. "file.read" → "read", "ui.notify" → "notify"
  def short_name
    @name.include?('.') ? @name.split('.').last : @name
  end

  def execute(args_hash)
    raise NotImplementedError, "#{self.class}#execute not implemented"
  end

  def to_openai
    {
      type: 'function',
      function: {
        name: @name,
        description: @description,
        parameters: @parameters
      }
    }
  end
end
