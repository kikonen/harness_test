# frozen_string_literal: true

# -- Tool system ----------------------------------------------------------

class Tool
  attr_reader :name, :description, :parameters

  # The verdict IS the type the drain loop renders. Names are verdict-neutral
  # because the emitters are not only tools (shell runner, grant reports).
  STATUS_TYPES = {
    ok: :status_ok,
    fail: :status_fail,
    warn: :status_warn,
    note: :status_note,
    same: :status_same,
    info: :status_info
  }.freeze

  def initialize(name:, description:, parameters:)
    @name        = name
    @description = description
    @parameters  = parameters
  end

  # Extract the namespace from a dot-notation tool name.
  # e.g. "file.read" → "file", "ui.notify" → "ui"
  # If no dot is present, the entire name is the namespace.
  def namespace
    @name.include?(".") ? @name.split(".").first : @name
  end

  # The tool's short name within its namespace.
  # e.g. "file.read" → "read", "ui.notify" → "notify"
  def short_name
    @name.include?(".") ? @name.split(".").last : @name
  end

  def execute(args_hash)
    raise NotImplementedError, "#{self.class}#execute not implemented"
  end

  def self.status_type(verdict)
    STATUS_TYPES.fetch(verdict) do
      raise ArgumentError,
        "unknown status verdict #{verdict.inspect} " \
          "(available: #{STATUS_TYPES.keys.join(', ')})"
    end
  end

  # Single-thread I/O rule (issue #40): never a stream write, no task active =
  # no-op. The label travels as the event's ORIGIN so the buffer entry alone is
  # enough to re-render the line.
  def self.push_status(label:, verdict:, message:)
    task = defined?(Task) ? Task.current : nil
    return nil unless task

    task.push_event(type: status_type(verdict), origin: label.to_s, content: message.to_s)
  end

  # Status line of THIS tool: the label is the tool's own name.
  def status(verdict, message = "")
    self.class.push_status(label: name, verdict:, message:)
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
      type: "function",
      function: {
        name: @name,
        description: @description,
        parameters: @parameters
      }
    }
  end
end
