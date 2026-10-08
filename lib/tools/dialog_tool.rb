# frozen_string_literal: true

require_relative '../tool'
require_relative '../ui/dialog'

# Lets the MODEL ask the user a question (or make a choice) via a dialog.
#
# A dialog has a title (what it is about), an optional note (extra context
# or warning), and a set of options. Each option has a title, an optional
# description, and a value. The standard "Cancel" option is always present
# (the user can dismiss the dialog without choosing).
#
# Optionally the dialog allows FREE TEXT: the user may type their own
# short answer instead of picking an option: the dialog then shows an
# explicit "Other" option, and picking it prompts for the typed answer,
# which is returned to the model - good for questions that are not
# black/white. The user must explicitly pick "Other"; stray typed text
# is never taken as the answer.
#
# The user may also attach a short NOTE to any choice (e.g. "1 seems
# fine"): the chosen option's value is still returned, with the note as
# extra context on top of the selection.
#
# Optionally the dialog is a MULTI-SELECT (issue #72): the user types
# several option numbers in one line (e.g. "1 3") to pick several
# options at once; all selected values are returned to the model. Can be
# combined with free_text: picking "Other" then prompts for the answer.

# The VALUE of the selected option (or the typed free-text answer) is
# returned to the model as the tool result; a cancelled dialog returns
# the standard value ":cancelled".
module Tools

  class DialogTool < Tool
    MAX_OPTIONS = 10

    def initialize
      super(
        name: 'ui.dialog',
        description: 'Shows a dialog (question / choice) to the user and waits for their answer. ' \
                     'The dialog has a title (what it is about), an optional note (extra context or warning), ' \
                     'and a list of options; each option has a title, an optional description, and a value. ' \
                     'A standard "Cancel" option is always available to the user. ' \
                     'Optionally enables free text so the user can type their own short answer instead of ' \
                     'picking an option: the dialog then shows an explicit "Other" option, and picking it ' \
                     'prompts for the typed answer. Use this when the question is not black/white but better ' \
                     'expressed as a short note. ' \
                     'Optionally enables multi-select so the user can pick SEVERAL options at once by ' \
                     'typing their numbers in one line (e.g. "1 3"); it can be combined with free text. ' \
                     'Use this for questions where any combination of options is valid. ' \
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
              description: 'Let the user type their own short answer: the dialog shows an explicit "Other" ' \
                           'option, and picking it prompts for the typed answer. ' \
                           'Use for questions that are not black/white (e.g. "What should the error message say?").'
            },
            free_text_prompt: {
              type: 'string',
              description: 'Optional short hint used as the label of the "Other" option and shown when asking ' \
                           'for the typed answer (only relevant when free_text is true).'
            },
            multi_select: {
              type: 'boolean',
              description: 'Let the user pick several options at once by typing their numbers in one line ' \
                           '(e.g. "1 3"). The values of all selected options are returned. Can be combined ' \
                           'with free_text. Use for ' \
                           'questions where any combination of options is valid.'
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

        options << UI::Dialog::Option.new(
          title: opt_title,
          value: value,
          description: raw['description']
        )
      end

      choice = UI::Dialog.new(
        title: title,
        options: options,
        note: args['note'],
        free_text: args['free_text'] == true,
        free_text_prompt: args['free_text_prompt'],
        multi_select: args['multi_select'] == true
        # ui: nil - tools run on the Task thread, so the dialog is routed
        # through the task and the MAIN THREAD services the I/O (issue #40).
      ).show(ui: nil)

      if choice.is_a?(Array) && choice.first == UI::Dialog::FREE_TEXT
        # [FREE_TEXT, text]: the user typed their own answer.
        "free text response from the user: \"#{choice[1]}\""
      elsif choice.is_a?(Array) && choice.size == 2 && choice[1].is_a?(String)
        # [option value, note]: an option was picked with a short note on top.
        "selected: #{choice[0].inspect} (user's note: \"#{choice[1]}\")"
      elsif choice.is_a?(Array)
        # Multi-select (issue #72): two or more options were picked; the
        # dialog returns an array of their values in the order typed.
        "selected: #{choice.map(&:inspect).join(', ')}"
      elsif choice == UI::Dialog::CANCEL_VALUE
        'cancelled (the user dismissed the dialog without choosing an option)'
      else
        "selected: #{choice.inspect}"
      end
    end
  end
end
