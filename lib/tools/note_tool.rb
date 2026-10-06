# frozen_string_literal: true

require_relative '../tool'

module Tools

  # Records a short fact in the model's own context (issue #138). The full
  # grant list used to be dumped into EVERY user prompt, but what the model
  # actually needs is the transient delta - e.g. "lib/ was just made
  # writeable" - recorded once, right after it happens. The harness tells
  # the USER about the grant on the console; the MODEL records the fact in
  # its own context (the note stays in the tool call for the rest of the
  # session), so it costs tokens only when a grant actually occurred.
  class NoteTool < Tool
    def initialize
      super(
        name: 'ui.note',
        description: 'Records a short note about the current task in your own context, to remember it for the rest of the session. Use it right after a file/dir access grant was made (the tool result says so), stating which path was granted for what mode (read / write / delete) and the granularity (file, dir only, recursive). Keep it to one factual line. Do NOT use it for anything else.',
        parameters: {
          type: 'object',
          properties: {
            text: { type: 'string', description: 'The note text (one factual line)' }
          },
          required: ['text']
        }
      )
    end

    def execute(args)
      text = args['text'].to_s.strip
      return 'error: empty note' if text.empty?

      "ok: noted #{text.length} chars"
    end
  end
end
