# frozen_string_literal: true

# -- UI::Dialog ---------------------------------------------------------------
#
# A generic user dialog (issue #74 / #13): a title (what it is about), a set
# of options, and a standard "Cancel" option that is ALWAYS present. Second
# primitive of the namespaced UI library; public API is unchanged from the
# previous top-level Dialog.
#
# Each option has a title, an optional description, and a value. The
# value of the selected option is returned to the caller; selecting the
# standard cancel option (or dismissing with EOF) returns
# CANCEL_VALUE.
#
# A dialog can also allow FREE TEXT: when free_text is enabled the user
# may type their own short answer instead of picking a number, and that
# text is returned to the caller verbatim.
#
# The user may attach a short NOTE to a choice by typing its option
# number, whitespace, then the note (e.g. "1 seems fine"). By default
# the dialog accepts notes on ANY choice and returns
# [option value, 'seems fine'] so the context is not lost. Grant-style
# dialogs (access confirmation) pass note_on_cancel_only: true, since a
# granted choice is final and only a denial carries meaningful feedback
# (issue #79): there, notes are kept only on the cancel choice (e.g.
# "3 no, and because X" -> [CANCEL_VALUE, 'no, and because X']) and
# ignored on other choices (bare value returned). A plain number (no
# note) always returns the bare value.
#
# Multi-select dialogs (multi_select: true) accept several
# option numbers in one line, separated by spaces and/or commas (e.g.
# "1 3" or "1,3"). One selection returns the bare value; two or more
# return an ARRAY of the selected values in the order typed. In
# multi-select mode a note is only kept on the cancel choice; any other
# "<number> <text>" line cancels. EOF still cancels the whole dialog.
#
# An out-of-range option number (e.g. "5" when only 1..4 exist) is
# rejected with an explanatory line and the dialog re-prompts, so a
# mistyped choice is never silently reinterpreted as free text
# (issue #73). Dismissing with EOF still cancels.
#
#   dialog = UI::Dialog.new(
#     title: 'Access requested (write access): lib/foo.rb',
#     options: [
#       UI::Dialog::Option.new(title: 'Allow this file only', value: :file_only),
#       UI::Dialog::Option.new(title: 'Allow directory: lib/ (recursive)',
#                              value: :dir_recursive,
#                              description: 'covers every file under lib/')
#     ]
#   )
#   choice = dialog.show  # => :file_only, [:file_only, 'note'], or :cancelled
module UI
  class Dialog
    # Standard value returned when the user picks the cancel option (or
    # dismisses the dialog with EOF).
    CANCEL_VALUE = :cancelled

    # Sentinel marker for free-text answers. A free-text response is
    # returned as [FREE_TEXT, 'the typed text'], so callers can tell it
    # apart from a plain option value (which is returned as-is).
    FREE_TEXT = :free_text

    # A single selectable item in a dialog.
    class Option
      attr_reader :title, :description, :value

      def initialize(title:, value:, description: nil)
        raise ArgumentError, 'option title must be a non-empty string' \
                            if title.to_s.strip.empty?
        raise ArgumentError, 'option value must not be nil' if value.nil?

        @title       = title.to_s.strip
        @description = description&.to_s
        @value       = value
      end
    end

    attr_reader :title, :options

    # title:   what the dialog is about (required, non-empty).
    # options: non-empty array of Option; the standard cancel option is
    #          appended automatically.
    # note:    optional context line(s) shown under the title (e.g. a
    #          warning, or an explanation of why the dialog was asked).
    # free_text: allow the user to type their own short answer instead of
    #            picking an option (returned as [FREE_TEXT, text]).
    # free_text_prompt: optional hint shown to the user about what kind of
    #            free-text answer is expected.
    # note_on_cancel_only: restrict notes to the cancel choice only (grant
    #            dialogs, issue #79). Default false: notes on any choice.
    # multi_select: allow selecting several options in one line by typing
    #            their numbers separated by spaces and/or commas (e.g.
    #            "1 3" or "1,3"). One selection returns the bare value;
    #            two or more return an array of values.
    def initialize(title:, options:, note: nil, free_text: false, free_text_prompt: nil,
                   note_on_cancel_only: false, multi_select: false)
      raise ArgumentError, 'dialog title must be a non-empty string' if title.to_s.strip.empty?
      unless options.is_a?(Array) && !options.empty?
        raise ArgumentError, 'dialog requires a non-empty array of Dialog::Option'
      end
      options.each do |o|
        raise ArgumentError, 'every option must be a Dialog::Option' unless o.is_a?(Option)
      end

      @title   = title.to_s.strip
      @note    = note&.to_s
      @free_text = free_text ? true : false
      @free_text_prompt = free_text_prompt.to_s.strip.sub(/\Aor\s+/, '')
      @options = options + [Option.new(title: 'Cancel', value: CANCEL_VALUE)]
      @note_on_cancel_only = note_on_cancel_only ? true : false
      @multi_select = multi_select ? true : false
    end

    # Render the dialog and wait for the user's choice on $stdin.
    # Returns the VALUE of the selected option, [FREE_TEXT, text] when the
    # user types their own answer (free_text dialogs only), or CANCEL_VALUE
    # when the user cancels (or stdin is closed).
    #
    # The user may attach a short note to a choice by typing
    # "<number> <note>" (e.g. "1 seems fine"): the dialog then returns
    # [option value, 'seems fine'] instead of the bare value - the note is
    # extra context on top of the selection, never a replacement for it.
    # With note_on_cancel_only (grant dialogs, issue #79) notes are kept
    # only on the cancel choice; on other choices the bare value is returned.
    # Multi-select dialogs accept several numbers in one line: "1 3" or
    # "1,3" - one selection returns the bare value, two or more return an
    # array of the selected values in the order typed.
    #
    # An out-of-range option number is rejected with an explanatory line
    # and the dialog asks again (issue #73).
    def show
      title_lines = @title.split("\n")
      puts
      puts "  [dialog] ⚠  #{title_lines.first}"
      title_lines[1..].each { |line| puts "             #{line}" }

      if @note && !@note.strip.empty?
        @note.split("\n").each { |line| puts "                #{line}" }
      end

      @options.each_with_index do |opt, i|
        puts "             #{i + 1}) #{opt.title}"
        if opt.description && !opt.description.strip.empty?
          puts "                #{opt.description}"
        end
      end

      print_choice_prompt

      # Skip blank lines: they are usually stale input (e.g. the user
      # pressed Enter an extra time while sending the prompt, and that
      # newline is still sitting in stdin). Only a real EOF dismisses the
      # dialog without an answer.
      loop do
        line = $stdin.gets
        break if line.nil?

        answer = line.chomp.strip
        next if answer.empty?

        # Multi-select: "1 3", "1,3" or "1 3, 5" - several option numbers
        # in one line. Returns nil when the line was invalid
        # and the dialog re-prompted.
        if @multi_select && answer.match?(/\A\d+(?:[,\s]+\d+)+\z/)
          chosen = handle_multi_select(answer)
          next if chosen.nil?
          return chosen
        end

        # "<number> <note>": an option selected PLUS a free note on top.
        # Grant dialogs (note_on_cancel_only, issue #79) keep the note only
        # for a denial - a grant/selection is final there.
        m = answer.match(/\A(\d+)\s+(.*)\z/m)
        if m
          idx = m[1].to_i - 1
          if idx >= 0 && idx < @options.size
            value = @options[idx].value
            # Multi-select mode: notes are only meaningful on the cancel
            # choice; any other selection-with-text cancels.
            return CANCEL_VALUE if @multi_select && value != CANCEL_VALUE
            keep_note = !@note_on_cancel_only || value == CANCEL_VALUE
            return keep_note ? [value, m[2].strip] : value
          end

          # Out-of-range number: it was clearly meant as an option
          # selection, so reject it and re-prompt instead of silently
          # treating it as free text (issue #73).
          reprompt_invalid(m[1])
          next
        end

        # Plain number: the option's value, unchanged.
        if answer.match?(/\A\d+\z/)
          idx = answer.to_i - 1
          return @options[idx].value if idx >= 0 && idx < @options.size

          reprompt_invalid(answer)
          next
        end

        # Not a valid option number: free text when allowed, cancel otherwise.
        return @free_text ? [FREE_TEXT, answer] : CANCEL_VALUE
      end
      CANCEL_VALUE
    end

    # Resolve a multi-select answer ("1 3", "1,3") to the selected values.
    # One selection returns the bare value; two or more return an array in
    # the order typed. Any out-of-range number rejects the whole line.
    def handle_multi_select(answer)
      numbers = answer.split(/\s*,\s*|\s+/).map(&:to_i)
      if numbers.any? { |n| n < 1 || n > @options.size }
        bad = numbers.reject { |n| (1..@options.size).cover?(n) }
        reprompt_invalid(bad.join(', '))
        return nil
      end

      values = numbers.map { |n| @options[n - 1].value }
      if values.include?(CANCEL_VALUE)
        CANCEL_VALUE
      else
        values.size == 1 ? values.first : values
      end
    end

    private

    # Print the "Choice (...)" prompt line (shared by the first ask and
    # re-prompts after an invalid choice).
    def print_choice_prompt
      note_hint = @note_on_cancel_only ? 'cancel + short note' : '<number> + short note'
      multi_hint = @multi_select ? 'or several numbers like "1 3" to select many' : ''
      if @free_text
        hint = @free_text_prompt.to_s.strip
        hint = 'type a short free-text answer' if hint.empty?
        print "             Choice (1..#{@options.size},#{multi_hint} #{note_hint}, or #{hint}): "
      else
        print "             Choice (1..#{@options.size},#{multi_hint} or #{note_hint}): "
      end
      $stdout.flush
    end

    # Reject an out-of-range option number and ask again (issue #73).
    # The user can still dismiss the dialog with EOF.
    def reprompt_invalid(number)
      puts
      puts "             invalid choice #{number} (valid: 1..#{@options.size})"
      print_choice_prompt
    end
  end
end

# Backward-compatible top-level alias (issue #74): existing call sites that
# still reference the old flat `Dialog` keep working unchanged. New code
# should use UI::Dialog.
Dialog = UI::Dialog unless defined?(Dialog)
