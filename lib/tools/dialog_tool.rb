# frozen_string_literal: true

require "json"
require_relative "../tool"
require_relative "../ui/dialog"

# Lets the MODEL ask the user a question (or make a choice) via a dialog.
#
# A dialog has a title (what it is about), an optional note (extra context
# or warning), and a set of options. Each option has a title, an optional
# description, and a value. The standard "Cancel" option is always present
# (the user can dismiss the dialog without choosing).
#
# EVERY model-asked dialog gets the "Additional details" option (issue #72):
# picking it (alone or alongside other options) enters a multi-line text
# block; the typed text rides along with the selection. The user may also
# pick Cancel plus one line of reason ("4 no, and because X").
#
# Optionally the dialog is a MULTI-SELECT (issue #72): the user types
# several option numbers in one line (e.g. "1 3") to pick several
# options at once; all selected values are returned to the model.

# The VALUE of the selected option (or the typed free-text answer) is
# returned to the model as the tool result; a cancelled dialog returns
# the standard value ":cancelled".
module Tools

  class DialogTool < Tool
    MAX_OPTIONS = 10

    def initialize
      super(
        name: "ui.dialog",
        description: "Shows a dialog (question / choice) to the user and waits for their answer. " \
                     "The dialog has a title (what it is about), an optional note (extra context or warning), " \
                     "and a list of options; each option has a title, an optional description, and a value. " \
                     'A standard "Cancel" option is always available to the user. ' \
                     'The dialog always includes an "Additional details" option so the user can type ' \
                     "their own answer alongside or instead of picking options. " \
                     "Optionally enables multi-select so the user can pick SEVERAL options at once by " \
                     'typing their numbers in one line (e.g. "1 3"). ' \
                     "Use this for questions where any combination of options is valid. " \
                     "The VALUE of the selected option (or the typed free-text answer) is returned to you; " \
                     'if the user cancels, you get ":cancelled". Use this to ask the user for a decision, ' \
                     "a preference, or clarification when you cannot decide on your own.",
        parameters: {
          type: "object",
          properties: {
            title: {
              type: "string",
              description: 'What the dialog is about (required), e.g. "Which Ruby version should I target?"'
            },
            note: {
              type: "string",
              description: "Optional extra context or warning shown under the title."
            },
            options: {
              type: "array",
              description: "The choices for the user (1..#{MAX_OPTIONS} options). The standard cancel option is added automatically.",
              items: {
                type: "object",
                properties: {
                  title: { type: "string", description: 'Short label of the option, e.g. "Allow" or "Ruby 3.3"' },
                  description: { type: "string", description: "Optional one-line explanation shown under the title" },
                  value: {
                    type: ["string", "number", "boolean"],
                    description: "The value returned to you when this option is selected (must be a JSON string, number, or boolean)"
                  }
                },
                required: ["title", "value"]
              }
            },
            free_text_prompt: {
              type: "string",
              description: 'Optional short hint used as the label of the "Additional details" option. ' \
                           "The dialog always allows typed details; this just customises the label."
            },
            multi_select: {
              type: "boolean",
              description: "Let the user pick several options at once by typing their numbers in one line " \
                           '(e.g. "1 3"). The values of all selected options are returned. ' \
                           "Use for questions where any combination of options is valid."
            }
          },
          required: ["title", "options"]
        }
      )
    end

    def execute(args)
      title = args["title"]
      if title.nil?
        return "error: 'title' is required (pass a non-empty title)"
      end

      title = title.to_s.strip
      if title.empty?
        return "error: 'title' must be a non-empty string"
      end

      normalized = normalize_options(args["options"])
      return normalized if normalized.is_a?(String)

      raw_options = normalized

      if raw_options.empty?
        return "error: 'options' must be a non-empty array"
      end
      if raw_options.size > MAX_OPTIONS
        return "error: too many options (max #{MAX_OPTIONS})"
      end

      options = []
      raw_options.each_with_index do |raw, i|
        opt = normalize_option(raw)
        unless opt.is_a?(Hash)
          return "error: option #{i + 1} must be an object with 'title' and 'value'"
        end

        unless opt.key?("title")
          return "error: option #{i + 1} is missing a 'title' (needs both title and value)"
        end

        opt_title = opt["title"].to_s.strip
        if opt_title.empty?
          return "error: option #{i + 1} needs a non-empty 'title'"
        end

        unless opt.key?("value")
          return "error: option #{i + 1} is missing a 'value' (needs both title and value)"
        end

        value = opt["value"]
        if value.nil? || (value.is_a?(String) && value.empty?)
          return "error: option #{i + 1} needs a 'value' (non-empty string, number, or boolean)"
        end

        options << UI::Dialog::Option.new(
          title: opt_title,
          value:,
          description: opt["description"]
        )
      end

      choice = UI::Dialog.new(
        title:,
        options:,
        note: args["note"],
        free_text: true,
        free_text_prompt: args["free_text_prompt"],
        multi_select: args["multi_select"] == true
        # ui: nil - tools run on the Task thread, so the dialog is routed
        # through the task and the MAIN THREAD services the I/O (issue #40).
      ).show(ui: nil)

      format_choice(choice)
    end

    private

    # The model sometimes re-encodes the options array as a JSON string; parse
    # that form instead of rejecting it, and name any other non-array by its
    # actual shape so the model fixes the real field instead of its title.
    def normalize_options(raw_options)
      return raw_options if raw_options.is_a?(Array)

      if raw_options.is_a?(String)
        begin
          parsed = JSON.parse(raw_options)
        rescue JSON::ParserError
          return "error: 'options' was sent as a string that is not a JSON array"
        end
        return parsed if parsed.is_a?(Array)
      end

      "error: 'options' must be a non-empty array"
    end

    # An option that arrived double-encoded as a JSON object string is parsed
    # into the object it stands for; anything else stays so the caller reports
    # it as not an option object.
    def normalize_option(raw)
      return raw unless raw.is_a?(String)

      begin
        parsed = JSON.parse(raw)
      rescue JSON::ParserError
        return raw
      end
      parsed.is_a?(Hash) ? parsed : raw
    end

    def format_choice(choice)
      ft = UI::Dialog::FREE_TEXT
      cv = UI::Dialog::CANCEL_VALUE

      if choice == cv
        "cancelled (the user dismissed the dialog without choosing an option)"
      elsif choice.is_a?(Array) && choice.size == 2 &&
            choice[0] == cv && choice[1].is_a?(String)
        # [:cancelled, 'one-line reason']
        "cancelled (user's note: \"#{choice[1]}\")"
      elsif choice.is_a?(Array) && choice.size == 2 &&
            choice[0] == cv && choice[1].is_a?(Array) && choice[1][0] == ft
        # [:cancelled, [FREE_TEXT, text]] - cancel + details block
        "cancelled (user's details: \"#{choice[1][1]}\")"
      elsif choice.is_a?(Array) && choice.size == 2 && choice[0] == ft
        # [FREE_TEXT, text]: only "Additional details" was picked.
        "free text response from the user: \"#{choice[1]}\""
      elsif choice.is_a?(Array) && choice.last.is_a?(Array) &&
            choice.last.size == 2 && choice.last[0] == ft
        # [v1, v2, ..., [FREE_TEXT, text]]: selections + details.
        vals = choice[0..-2].map(&:inspect).join(", ")
        "selected: #{vals} (user's details: \"#{choice.last[1]}\")"
      elsif choice.is_a?(Array)
        # Multi-select without details: array of values.
        "selected: #{choice.map(&:inspect).join(', ')}"
      else
        "selected: #{choice.inspect}"
      end
    end
  end
end
