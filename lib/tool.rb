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

  # True if a FileList#grant_access result means access was granted.
  def self.granted?(result)
    result == :granted
  end

  # Build the "access denied" error string returned to the model when the
  # user declines a grant dialog. If the user attached a short note to
  # their denial (e.g. "no, and because X") it is included verbatim so
  # the model can see the feedback and adapt instead of blindly retrying.
  def self.denial_error(message, result = nil)
    note = result.is_a?(Hash) ? result[:note] : nil
    return "#{message} (user's note: \"#{note}\")" if note

    message
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
