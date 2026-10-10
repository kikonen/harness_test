# frozen_string_literal: true

require_relative 'editor'

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
# CHOICE INPUT (issue #72): the choice line is OPTION NUMBERS ONLY -
# bare "1", several numbers in one line ("1 3" or "1,3") when the dialog
# allows it, or the cancel number plus a one-line reason
# ("5 no, and because X"). Single-select IS multi-select with one number:
# any text on the choice line that is NOT "<cancel> <reason>" is stray
# input (a paste accident) and re-prompts - it is NEVER a selection, a
# note, or a cancel (issue #155). There are no per-option inline notes.
#
# CHOICE-LINE EDITING (issue #198 phase 2): on a TTY the single-line
# choice read goes through UI::Editor (the same Reline editor the steering
# note uses), so every in-turn stdin read shares ONE code path: Enter
# submits the line, a bare Enter re-prompts (same as the blank-line skip),
# Esc keeps what was typed as a draft prefilled on the next re-prompt - it
# NEVER cancels (cancel is explicit, issue #155) - and Ctrl-D on an empty
# line cancels the dialog like EOF. Non-tty streams take the plain gets()
# path with exactly the same behavior as before this change (pipes in
# specs, dumb terminals). The multi-line "Additional details" block stays
# gets()-based: its blank-line-finish / Ctrl-D-cancel semantics are a
# different beast from a single-line read.
#
# A dialog can allow ADDITIONAL DETAILS: when free_text is enabled the
# dialog gets an explicit numbered "Additional details" option (the
# FREE_TEXT option), selectable ALONE, alongside other options, or
# alongside Cancel ("2 3 4" = options 2+3 with a note; "5 4" = cancel
# with a reason). Picking it enters a MULTI-LINE text block: type or
# paste as many lines as you want, finish with a BLANK line; Ctrl-D (EOF)
# cancels the whole dialog. An empty block re-prompts the choice. The
# typed details ride along with the selection as [FREE_TEXT, text]
# appended to the result, so possible return values are: the bare value,
# an array of values (multi picks), [FREE_TEXT, text],
# [value, [FREE_TEXT, text]], [:cancelled, 'reason'], or
# [:cancelled, [FREE_TEXT, 'reason']].
#
# CANCEL IS ALWAYS EXPLICIT (issue #155): only picking the cancel option
# (alone or in a selection), an attached "<cancel number> <note>" line, or
# EOF decides a dialog by cancelling it.
#
# An out-of-range option number (e.g. "5" when only 1..4 exist) is
# rejected with an explanatory line and the dialog re-prompts, so a
# mistyped choice is never silently reinterpreted as something else
# (issue #73). Dismissing with EOF still cancels.
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
#     # => :file_only, or CANCEL_VALUE (or with details, e.g.
#     #    [:cancelled, [UI::Dialog::FREE_TEXT, 'why not']])
module UI
  class Dialog
    # Standard value returned when the user picks the cancel option (or
    # dismisses the dialog with EOF).
    CANCEL_VALUE = :cancelled

    # Sentinel marker for the free-text "additional details" answer. The
    # typed details are returned as [FREE_TEXT, 'the typed text'], so
    # callers can tell them apart from plain option values (which are
    # returned as-is) and from a cancel one-line reason (a plain String).
    FREE_TEXT = :free_text

    # Default title of the explicit "Additional details" option appended
    # to free_text dialogs.
    FREE_TEXT_OPTION = 'Additional details'

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
    #          enabled, the explicit "Additional details" option).
    # note:    optional context line(s) shown under the title (e.g. a
    #          warning, or an explanation of why the dialog was asked).
    # free_text: let the user type their own answer by selecting the
    #            explicit "Additional details" option; the typed text is
    #            returned as [FREE_TEXT, text], alone or appended to the
    #            selected values - including with Cancel.
    # free_text_prompt: optional hint used as the label of the "Additional
    #            details" option and shown when asking for the typed
    #            answer.
    # multi_select: allow picking several options at once (their numbers
    #            in one line, e.g. "1 3"). Without it, a selection line
    #            may name at most ONE regular option: "Additional details"
    #            still counts alongside it ("option X but blaa blaa"),
    #            but Cancel does not (Cancel + anything else re-prompts;
    #            cancel is explicit). One pick returns the bare value;
    #            two or more return an array of values.
    def initialize(title:, options:, note: nil, free_text: false, free_text_prompt: nil,
                   multi_select: false)
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
        # The explicit "Additional details" option: the hint (when given)
        # IS the option's label, otherwise the generic default.
        title = @free_text_prompt.empty? ? FREE_TEXT_OPTION : @free_text_prompt
        options << Option.new(title: title, value: FREE_TEXT)
      end
      options << Option.new(title: 'Cancel', value: CANCEL_VALUE)
      @options = options
      @multi_select = multi_select ? true : false
    end

    # Render the dialog and wait for the user's choice on stdin.
    # Returns the VALUE of the selected option (bare for a single pick,
    # an ARRAY for two or more picks), the typed details as
    # [FREE_TEXT, text] when only "Additional details" was selected, or
    # CANCEL_VALUE / [:cancelled, reason] when the user cancels. The
    # details pair rides along with any selection - see the class docs
    # for all possible shapes.
    #
    # Single-thread I/O rule (issue #40): when called from within a Task
    # thread (Thread.current[:harness_task] is set), this routes through
    # the task's request/response protocol and the MAIN THREAD services
    # the I/O with the task's injected console (Task.run owns it). In that
    # case pass nil - a caller on a task thread must NOT name $stdout/
    # $stdin at all, since that would be direct global stream access from
    # the wrong thread. When no Task is active (CLI main thread, tests),
    # the ui object is used DIRECTLY and must be exactly the console the
    # caller wants to use - deliberately no defaults and no global lookup:
    # a dialog never silently talks to some stream nobody passed in.
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

      # The choice is ONE line of option numbers (or a cancel number plus
      # a one-line reason). On a tty the line comes from UI::Editor (see
      # read_choice_line); on non-tty streams it is a plain gets() with
      # the classic skip-blanks semantics, and only a real EOF dismisses
      # the dialog without an answer.
      draft = nil
      loop do
        res = read_choice_line(ui, draft)
        # nil = non-tty stream EOF; :eof = Ctrl-D inside the tty editor.
        return CANCEL_VALUE if res.nil? || res[:status] == :eof

        # Esc: keep what was typed as a draft for the next round - it is
        # NEVER a cancel (issue #155: cancel is always explicit). Any other
        # round resets it so a submitted line is parsed as typed, not
        # shadowed by a stale draft.
        draft = res[:status] == :cancelled ? res[:text] : nil
        next if draft && !draft.to_s.strip.empty? # re-prompt with the prefill

        if res[:status] == :empty
          # Bare Enter: stale input (an extra Enter while the prompt was
          # sent) - re-prompt without touching the draft.
          next
        end

        # .to_s + empty skip: a nil/blank submitted line gets bare-Enter
        # semantics (re-prompt) instead of crashing or parsing as an
        # empty selection - the editor returns :empty for blanks, but
        # stubs and odd streams deserve the same fallback.
        answer = res[:text].to_s.strip
        next if answer.empty?
        chosen = parse_choice_line(answer, ui)
        next if chosen.nil?               # invalid line: re-prompted
        result = finalize(chosen, ui)
        next if result.nil?               # empty details block: re-prompt
        return result
      end
    end

    private

    # issue #198 phase 2: read one choice line. tty -> UI::Editor (Reline:
    # Enter submits, bare Enter is :empty, Esc is :cancelled with the
    # draft intact, Ctrl-D is :eof); non-tty -> gets() (nil => EOF, blank
    # => :empty, otherwise :submitted). The `> ` line printed above is the
    # editor's prompt on tty (Reline's PROMPT) and the plain-prompt
    # marker elsewhere. Returns {text:, status:} or nil on EOF.
    def read_choice_line(ui, draft)
      stdin = ui.stdin
      return stdin.gets.then do |line|
        if line.nil?
          nil
        elsif line.chomp.strip.empty?
          { text: nil, status: :empty }
        else
          { text: line.chomp, status: :submitted }
        end
      end unless tty_input?(ui)

      UI::Editor.new(stdin).read(prompt: UI::Editor::DIALOG_PROMPT, prefill: draft)
        .then { |r| { text: r.text, status: r.status } }
    end

    # True when the console's stdin IS the process's real terminal stdin -
    # UI::Editor's Reline path attaches to $stdin, so a fake tty? stream in
    # tests must stay on the dumb gets() path (issue #202 bug class).
    def tty_input?(ui)
      !ui.stdin.nil? && UI::Editor.is_real_tty_stdin?(ui.stdin)
    end

    # Resolve one choice line to its selection or a noted cancel, or nil
    # when the line was invalid (already re-prompted). Forms accepted:
    #   * "<n>" / "<n> <n> ..." (spaces or commas) - option numbers; all
    #     must be in range, and at most one regular option may be picked
    #     in a non-multi-select dialog (option + "Additional details"
    #     still works there).
    #   * "<cancel n> <reason>" - cancel plus a one-line reason; the ONE
    #     text-on-a-choice-line form (issue #79 denial feedback).
    # Anything else is stray input (paste accident) - re-prompt, never
    # select / note / cancel (issues #155 / #72).
    def parse_choice_line(answer, ui)
      tokens = answer.split(/[,\s]+/).reject(&:empty?)
      if tokens.any? { |t| !t.match?(/\A\d+\z/) }
        noted = cancel_with_reason?(answer)
        return reprompt_invalid(answer, ui) if noted.nil?

        return noted                       # "<cancel n> <reason>"
      end

      numbers, bad = tokens.map(&:to_i).partition { |n| n >= 1 && n <= @options.size }
      unless bad.empty?
        return reprompt_invalid(bad.join(', '), ui)
      end

      if !@multi_select
        regular = numbers.reject { |n| @options[n - 1].value == FREE_TEXT }
        if regular.uniq.size > 1
          reprompt("pick one option only (this dialog is not multi-select)", ui)
          return nil
        end
      end

      seen = {}
      numbers.each_with_object({ values: [] }) do |n, acc|
        next if seen[n]

        seen[n] = true
        acc[:values] << @options[n - 1].value
      end
    end

    # The ONE text-on-a-choice-line form (issue #79 denial feedback): a
    # cancel number followed by a one-line reason. Returns the noted
    # cancel, or nil when the line is not in that shape (stray input).
    def cancel_with_reason?(answer)
      m = answer.match(/\A(\d+)\s+(\D.*)\z/)
      return nil unless m

      n = m[1].to_i
      return nil unless n >= 1 && n <= @options.size
      return nil unless @options[n - 1].value == CANCEL_VALUE

      [CANCEL_VALUE, m[2]]
    end

    # Assemble the dialog result from a parsed selection:
    #   * a noted cancel -> [:cancelled, 'reason'] (from parse) or
    #     [:cancelled, [FREE_TEXT, 'reason']] (cancel + details below).
    #   * plain cancel -> :cancelled.
    #   * "Additional details" among the picks -> enter the multi-line
    #     text block, then append [FREE_TEXT, text] to the other values
    #     (the selections keep working - issue #72). An empty block
    #     re-prompts; an EOF inside it cancels the whole dialog.
    #   * one number -> the bare value; more -> array of values.
    def finalize(chosen, ui)
      if chosen.is_a?(Array) && chosen.size == 2 &&
         chosen[0] == CANCEL_VALUE && chosen[1].is_a?(String)
        return chosen                     # "<cancel> <one-line reason>"
      end

      values = chosen[:values]
      # Cancel anywhere in the selection cancels the dialog (issue #155):
      # a mixed "1 4" or a bare cancel both return plain :cancelled.
      # Exception: details picked in the SAME line (e.g. "3 4") - the
      # typed reason block replaces the bare cancel (issue #72).
      if values.include?(CANCEL_VALUE) && !values.include?(FREE_TEXT)
        return CANCEL_VALUE
      end

      if values.include?(FREE_TEXT)
        detail = collect_details(ui)
        return nil_reprompt(ui) if detail.nil?
        # EOF mid-block (Ctrl-D inside the text block) cancels the whole
        # dialog - bare :cancelled, no details pair.
        return CANCEL_VALUE if detail == CANCEL_VALUE

        others = values.reject { |v| v == FREE_TEXT || v == CANCEL_VALUE }
        # Cancel with nothing but details is the reason form:
        # "4 3" -> [:cancelled, [FREE_TEXT, 'why']].
        return [CANCEL_VALUE, detail] \
          if others.empty? && values.include?(CANCEL_VALUE)

        values = others + [detail]
      end

      values.size == 1 ? values.first : values
    end

    # Ask for the typed additional details after the user selected the
    # "Additional details" option. Multi-line text block: type or paste
    # as many lines as you want, finish with a BLANK line; Ctrl-D (EOF)
    # cancels the whole dialog. Returns [FREE_TEXT, text], nil when the
    # block was empty (the dialog re-prompts), or CANCEL_VALUE on EOF.
    def collect_details(ui)
      ui.puts
      hint = @free_text_prompt.empty? ? 'type your answer' : @free_text_prompt
      ui.puts "             #{hint} (blank line to finish, Ctrl-D cancels):"
      lines = []
      loop do
        line = ui.gets
        return CANCEL_VALUE if line.nil?

        text = line.chomp
        break if text.strip.empty?

        lines << text.rstrip
      end

      detail = lines.join("\n").strip
      return nil if detail.empty?

      [FREE_TEXT, detail]
    end

    # Re-prompt after an empty details block (selection discarded).
    def nil_reprompt(ui)
      ui.puts
      ui.puts '             (no text entered - picking the option again)'
      print_choice_prompt(ui)
      nil
    end

    # Print the "Choice:" prompt with the allowed input forms as a short
    # list under it (one line each, only what THIS dialog allows) instead
    # of one long run-on sentence. Shared by the first ask and the
    # re-prompts after an invalid choice. ui is passed explicitly - there
    # is deliberately no console default.
    def print_choice_prompt(ui)
      forms = []
      if @multi_select
        forms.push('"1 3"           several numbers in one line (space or comma)')
      end
      details_no = @options.index { |o| o.value == FREE_TEXT }
      if @free_text && details_no
        form = "#{details_no + 1}                + typed details (multi-line)"
        forms << form
      end
      forms << "#{@options.size} <one line>    cancel + reason"
      ui.puts "             Choice (1..#{@options.size}):"
      forms.each { |f| ui.puts "               - #{f}" }
      if tty_input?(ui)
        # issue #198 phase 2: the Reline editor owns the keyboard; its
        # prompt ("> ") replaces this line as the input marker.
        return
      end

      ui.print '             > '
      ui.flush
    end

    # Reject an invalid answer (out-of-range option number or stray text)
    # and ask again (issues #73 / #155). The user can still dismiss the
    # dialog with EOF.
    def reprompt_invalid(number, ui)
      reprompt("invalid choice #{number} (valid: 1..#{@options.size})", ui)
      nil
    end

    def reprompt(message, ui)
      ui.puts
      ui.puts "             #{message}"
      print_choice_prompt(ui)
      nil
    end
  end
end
