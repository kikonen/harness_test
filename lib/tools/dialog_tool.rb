# frozen_string_literal: true

require_relative '../tool'
require_relative '../dialog'

# Lets the MODEL ask the user a question (or make a choice) via a dialog.
#
# A dialog has a title (what it is about), an optional note (extra context
# or warning), and a set of options. Each option has a title, an optional
# description, and a value. The standard "Cancel" option is always present
# (the user can dismiss the dialog without choosing).
#
# Optionally the dialog allows FREE TEXT: the user may type their own
# short answer instead of picking an option. The typed text is returned
# to the model as the response - good for questions that are not black/white.
#
# The user may also attach a short NOTE to any choice (e.g. "1 seems fine"):
# the chosen option's value is still returned, with the note as extra context.
#
# The VALUE of the selected option (or the typed free-text answer) is
# returned to the model as the tool result; a cancelled dialog returns
# the standard value ":cancelled".
module Tools

  class Tools::DialogTool < Tool
    MAX_OPTIONS = 10

    def initialize
      super(
        name: 'ui.dialog',
        description: 'Shows a dialog (question / choice) to the user and waits for their answer. ' \
                     'The dialog has a title (what it is about), an optional note (extra context), ' \
                     'and a list of options; each option has a title, an optional description, and a value. ' \
                     'A standard "Cancel" option is always available to the user. ' \
                     'Optionally enables free text so the user can type their own short answer instead of ' \
                     'picking an option - use this when the question is not black/white but better ' \
                     'expressed as a short note. ' \
                     'The VALUE of the selected option (or the typed free-text answer) is returned to you; ' \
                     'if the user cancels, you get ":cancelled". Use this to ask the user for a decision, ' \
                     'a preference, or clarification when you cannot decide on your own.',
        parameters: {
          type: 'object',
          properties: {
            title: {
              type: 'string',
              description: 'What the dialog is about (required), e.g. "Which Ruby version should I target?"'
            },
            note: {
              type: 'string',
              description: 'Optional extra context or warning shown under the title.'
            },
            options: {
              type: 'array',
              description: "The choices for the user (1..#{MAX_OPTIONS} options). The standard cancel option is added automatically.",
              items: {
                type: 'object',
                properties: {
                  title: { type: 'string', description: 'Short label of the option, e.g. "Allow" or "Ruby 3.3"' },
                  description: { type: 'string', description: 'Optional one-line explanation shown under the title' },
                  value: {
                    type: ['string', 'number', 'boolean'],
                    description: 'The value returned to you when this option is selected (must be a JSON string, number, or boolean)'
                  }
                },
                required: ['title', 'value']
              }
            },
            free_text: {
              type: 'boolean',
              description: 'Also let the user type their own short answer instead of picking an option. ' \
                           'Use for questions that are not black/white (e.g. "What should the error message say?").'
            },
            free_text_prompt: {
              type: 'string',
              description: 'Optional hint shown to the user about what kind of free-text answer is expected ' \
                           '(only relevant when free_text is true). Do not start it with "or" - the prompt already includes the conjunction.'
            }
          },
          required: ['title', 'options']
        }
      )
    end

    def execute(args)
      title = args['title'].to_s.strip
      if title.empty?
        return "error: 'title' must be a non-empty string"
      end

      raw_options = args['options']
      unless raw_options.is_a?(Array) && !raw_options.empty?
        return "error: 'options' must be a non-empty array"
      end
      if raw_options.size > MAX_OPTIONS
        return "error: too many options (max #{MAX_OPTIONS})"
      end

      options = []
      raw_options.each do |raw|
        unless raw.is_a?(Hash)
          return "error: every option must be an object with 'title' and 'value'"
        end

        opt_title = raw['title'].to_s.strip
        if opt_title.empty?
          return "error: every option needs a non-empty 'title'"
        end

        value = raw['value']
        if value.nil? || (value.is_a?(String) && value.empty?)
          return "error: every option needs a 'value' (non-empty string, number, or boolean)"
        end

        options << Dialog::Option.new(
          title: opt_title,
          value: value,
          description: raw['description']
        )
      end

      choice = Dialog.new(
        title: title,
        options: options,
        note: args['note'],
        free_text: args['free_text'] == true,
        free_text_prompt: args['free_text_prompt']
      ).show

      if choice.is_a?(Array) && choice.first == Dialog::FREE_TEXT
        # [FREE_TEXT, text]: the user typed their own answer.
        "free text response from the user: \"#{choice[1]}\""
      elsif choice.is_a?(Array)
        # [option value, note]: an option was picked with a short note on top.
        "selected: #{choice[0].inspect} (user's note: \"#{choice[1]}\")"
      elsif choice == Dialog::CANCEL_VALUE
        'cancelled (the user dismissed the dialog without choosing an option)'
      else
        "selected: #{choice.inspect}"
      end
    end
  end
end
