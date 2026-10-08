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
# A dialog can also allow FREE TEXT: when free_text is enabled the dialog
# gets an EXPLICIT numbered "Other" option (FREE_TEXT_OPTION), and picking
# it prompts for the typed answer, which is returned as [FREE_TEXT, text].
# In single-select mode typing "<Other number> <text>" on one line gives
# the answer directly.
# Bare typed text without selecting that option is NEVER treated as an
# answer - like any other stray input it re-prompts, so a pasted line can
# never be mistaken for a free-text answer.
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
# "<number> <text>" line re-prompts (it is never taken as a selection or
# a cancel). A multi-select dialog can combine with
# free_text (issue #72): selecting the "Other" option - alone or mixed in
# the selection - then prompts for the typed answer, which is returned as
# [FREE_TEXT, text]. EOF still cancels the whole dialog.
#
# An out-of-range option number (e.g. "5" when only 1..4 exist) is
# rejected with an explanatory line and the dialog re-prompts, so a
# mistyped choice is never silently reinterpreted as something else
# (issue #73). Dismissing with EOF still cancels.
#
# CANCEL IS ALWAYS EXPLICIT (issue #155): only picking the cancel option,
# an attached "<cancel number> <note>" line, or EOF decides a dialog by
# cancelling it. ANY other non-numeric input - including pasted text - is
# rejected with an explanatory line and the dialog re-prompts, so stray
# keystrokes can never cause an accidental denial.
#
# Single-thread I/O rule (issue #40): when called from within a Task
# thread, `show` routes the entire dialog interaction through the task's
# request/response protocol so that stdin/stdout are used only on the
# main thread - and callers MUST pass nil for the ui then, since naming
# $stdout/$stdin from a task thread would be direct global stream access
# from the wrong thread. When no Task is active (tests, direct CLI
# commands), an explicit ui: object (a UI::Console) is REQUIRED and used
# directly.
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
#   choice = dialog.show                     # inside a Task thread: routed
#   choice = dialog.show(ui: console)        # no task: direct I/O on it
#     # => :file_only, [:file_only, 'note'], or :cancelled
module UI
  class Dialog
    # Standard value returned when the user picks the cancel option (or
    # dismisses the dialog with EOF).
    CANCEL_VALUE = :cancelled

    # Sentinel marker for free-text answers. A free-text response is
    # returned as [FREE_TEXT, 'the typed text'], so callers can tell it
    # apart from a plain option value (which is returned as-is).
    FREE_TEXT = :free_text

    # Default title of the explicit free-text ("Other") option appended
    # to free_text dialogs.
    FREE_TEXT_OPTION = 'Other (type your own answer)'

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
    #          appended automatically (and before it, when free_text is
    #          enabled, the explicit "Other" free-text option).
    # note:    optional context line(s) shown under the title (e.g. a
    #          warning, or an explanation of why the dialog was asked).
    # free_text: let the user type their own short answer by picking the
    #            explicit "Other" option (returned as [FREE_TEXT, text]).
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
      options = options.dup
      if @free_text
        # The explicit "Other" option: the hint (when given) IS the
        # option's label, otherwise the generic default.
        title = @free_text_prompt.empty? ? FREE_TEXT_OPTION : @free_text_prompt
        options << Option.new(title: title, value: FREE_TEXT)
      end
      options << Option.new(title: 'Cancel', value: CANCEL_VALUE)
      @options = options
      @note_on_cancel_only = note_on_cancel_only ? true : false
      @multi_select = multi_select ? true : false
    end

    # Render the dialog and wait for the user's choice on stdin.
    # Returns the VALUE of the selected option, [FREE_TEXT, text] when the
    # user picks the "Other" option (free_text dialogs only), or CANCEL_VALUE
    # when the user cancels (or stdin is closed).
    #
    # Single-thread I/O rule (issue #40): when called from within a Task
    # thread (Thread.current[:harness_task] is set), this routes through
    # the task's request/response protocol and the MAIN THREAD services the
    # I/O with the task's injected console (Task.run owns it). In that case
    # pass nil - a caller on a task thread must NOT name $stdout/$stdin at
    # all, since that would be direct global stream access from the wrong
    # thread. When no Task is active (CLI main thread, tests), the ui
    # object is used DIRECTLY and must be exactly the console the caller
    # wants to use - deliberately no defaults and no global lookup: a
    # dialog never silently talks to some stream nobody passed in.
    def show(ui: nil)
      # Guard keeps the load order independent: dialog can be loaded before
      # task (they only meet at runtime on the main thread).
      task = defined?(Task) ? Task.current : nil
      if task
        raise ArgumentError, 'dialog routed through a Task: pass ui: nil' \
          unless ui.nil?

        # Route through the main thread: post a request and block until
        # the main thread processes the dialog and responds.
        task.request(:dialog, dialog: self)
      else
        raise ArgumentError, 'no Task active: show requires an explicit ui: console' \
          if ui.nil?

        perform_direct(ui: ui)
      end
    end

    # Perform the dialog I/O directly on the given console (the original
    # implementation). Called either by `show` when no Task is active
    # (the console's streams), or by the main thread when servicing a
    # :dialog request from a task (the task's injected console, so output
    # lands on the SAME stream the drain loop renders to - no default).
    def perform_direct(ui:)
      title_lines = @title.split("\n")
      ui.puts
      ui.puts "  [dialog] ⚠  #{title_lines.first}"
      title_lines[1..].each { |line| ui.puts "             #{line}" }

      if @note && !@note.strip.empty?
        @note.split("\n").each { |line| ui.puts "                #{line}" }
      end

      @options.each_with_index do |opt, i|
        ui.puts "             #{i + 1}) #{opt.title}"
        if opt.description && !opt.description.strip.empty?
          ui.puts "                #{opt.description}"
        end
      end

      print_choice_prompt(ui)

      # Skip blank lines: they are usually stale input (e.g. the user
      # pressed Enter an extra time while sending the prompt, and that
      # newline is still sitting in stdin). Only a real EOF dismisses the
      # dialog without an answer.
      loop do
        line = ui.gets
        break if line.nil?

        answer = line.chomp.strip
        next if answer.empty?

        # Multi-select: the whole line is selection input ("1 3", "1,2",
        # "3 my answer", "4 no, because X"). Anything invalid - including
        # stray text - re-prompts; only the cancel number cancels.
        if @multi_select
          chosen = handle_multi_line(answer, ui)
          next if chosen.nil?
          return chosen
        end

        # "<number> <note>": an option selected PLUS a free note on top.
        # Grant dialogs (note_on_cancel_only, issue #79) keep the note only
        # for a denial - a grant/selection is final there.
        m = answer.match(/\A(\d+)\s+(.*)\z/m)
        if m
          idx = m[1].to_i - 1
          if out_of_range?(idx)
            reprompt_invalid(m[1], ui)
            next
          end

          value = @options[idx].value
          if value == FREE_TEXT
            # "Other" with text on the same line ("3 my answer") is taken
            # as the answer directly.
            return [FREE_TEXT, m[2].strip]
          end
          keep_note = !@note_on_cancel_only || value == CANCEL_VALUE
          return keep_note ? [value, m[2].strip] : value
        end

        # Plain number: the option's value, unchanged.
        if answer.match?(/\A\d+\z/)
          idx = answer.to_i - 1
          if !out_of_range?(idx) && @options[idx].value != FREE_TEXT
            return @options[idx].value
          end

          # Bare pick of the "Other" option: ask for the typed answer.
          unless out_of_range?(idx)
            return prompt_free_text(ui) if @options[idx].value == FREE_TEXT
          end

          reprompt_invalid(answer, ui)
          next
        end

        # Not a valid option number: never an answer and never a cancel -
        # stray input (including pasted text) re-prompts so a mistake can
        # not be mistaken for a choice (issue #155). Only the explicit
        # "Other" option leads to free-text input. EOF still cancels.
        reprompt_invalid(answer, ui)
        next
      end
      CANCEL_VALUE
    end

    # Resolve a multi-select line to its result, or nil when the line was
    # invalid (the dialog re-prompted). The whole line is selection input
    # so "1 2", "3 my answer" and "4 no, because X" all work in one line;
    # a line that does not START with a number is stray input (issue #155).
    def handle_multi_line(answer, ui)
      return reprompt_invalid(answer, ui) unless answer.match?(/\A\d/)

      first, rest = answer.split(/\s+/, 2)
      idx = first.to_i - 1
      if out_of_range?(idx)
        return reprompt_invalid(first, ui)
      end

      value = @options[idx].value
      # Picking "Other": the rest of the line (when present and not a
      # number) is the typed answer; otherwise ask for it.
      if value == FREE_TEXT
        if rest && !rest.match?(/\A\d/)
          return [FREE_TEXT, rest.strip]
        end
        return prompt_free_text(ui)
      end

      # The rest of the line is either more selections ("2 3"), a note on
      # the cancel choice ("4 no, because X"), or stray text (re-prompt -
      # never a cancel).
      if value == CANCEL_VALUE
        return [value, rest.strip] unless rest.nil? || rest.strip.empty?
        return value
      end

      # Anything beyond the first number that is not (more) numbers is
      # stray text: a note only on the cancel choice, a free-text answer
      # only after "Other". Re-prompt in every other case - never treat
      # it as a selection or a cancel (issue #155).
      unless rest.nil? || rest.match?(/\A\d+(?:[,\s]+\d+)*\z/)
        return reprompt_invalid(answer, ui)
      end

      numbers = "#{first} #{rest}".to_s.split(/\s*,\s*|\s+/).compact.map(&:to_i)
      if numbers.any? { |n| n < 1 || n > @options.size }
        bad = numbers.reject { |n| (1..@options.size).cover?(n) }
        reprompt_invalid(bad.join(', '), ui)
        return nil
      end

      values = numbers.map { |n| @options[n - 1].value }
      # Picking "Other" mixed in makes the typed answer THE answer; an
      # explicit cancel anywhere in the selection cancels the dialog.
      return prompt_free_text(ui) if values.include?(FREE_TEXT)
      return CANCEL_VALUE if values.include?(CANCEL_VALUE)
      values.size == 1 ? values.first : values
    end

    private

    def out_of_range?(idx)
      idx < 0 || idx >= @options.size
    end

    # Ask for the typed free-text answer after the user picked the
    # explicit "Other" option. Returns [FREE_TEXT, text]; EOF cancels.
    def prompt_free_text(ui)
      ui.puts
      hint = @free_text_prompt.empty? ? 'type your short answer' : @free_text_prompt
      ui.print "             #{hint}: "
      ui.flush

      loop do
        line = ui.gets
        return CANCEL_VALUE if line.nil?

        text = line.chomp.strip
        next if text.empty?

        return [FREE_TEXT, text]
      end
    end

    # Print the "Choice (...)" prompt line (shared by the first ask and
    # re-prompts after an invalid choice). ui is passed explicitly -
    # there is deliberately no console default.
    def print_choice_prompt(ui)
      note_hint = @note_on_cancel_only ? 'cancel + short note' : '<number> + short note'
      multi_hint = @multi_select ? 'or several numbers like "1 3" to select many' : ''
      free_hint = @free_text ? ', or pick the "Other" option to type your own answer' : ''
      ui.print "             Choice (1..#{@options.size}#{multi_hint}#{free_hint}, #{note_hint}): "
      ui.flush
    end

    # Reject an invalid answer (out-of-range option number or stray text)
    # and ask again (issues #73 / #155). The user can still dismiss the
    # dialog with EOF.
    def reprompt_invalid(number, ui)
      ui.puts
      ui.puts "             invalid choice #{number} (valid: 1..#{@options.size})"
      print_choice_prompt(ui)
      nil
    end
  end
end
