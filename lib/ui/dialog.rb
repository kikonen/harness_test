# frozen_string_literal: true

require_relative "editor"
require_relative "text_wrap"
require "tins"

# A user dialog: title, options, and a standard always-present Cancel. The
# choice line accepts option numbers only; note colours: doc/dialog_colors_design.md;
# choice input, free text, and I/O routing: doc/dialog_design.md.
module UI
  class Dialog
    # Returned when the user picks Cancel or dismisses the dialog with EOF.
    CANCEL_VALUE = :cancelled

    # Marker for the free-text answer: returned as [FREE_TEXT, text], so callers
    # can tell it apart from a plain option value or a cancel one-line reason.
    FREE_TEXT = :free_text

    # Default label of the explicit "Additional details" option.
    FREE_TEXT_OPTION = "Additional details"

    # WHAT a note line IS (roles/hues: doc/dialog_colors_design.md). The emitter
    # states the kind, never a colour; Console#paint maps kind to a palette role.
    #   context - neutral (a purpose or explanation line).
    #   warn    - a refusal that is not a disaster match (UNSAFE, a path outside workdir).
    #   alert   - the hard floor or a dangerous model verdict (DENYLISTED:).
    #   safe    - a reassuring model verdict line.
    NOTE_KINDS = %w[context warn alert safe].freeze

    NOTE_ROLES = {
      "context" => :dialog_note,
      "warn" => :dialog_warn,
      "alert" => :dialog_alert,
      "safe" => :dialog_safe
    }.freeze

    # Line shape: head 2 spaces, title/options/choice prompt 13, note 16
    # (so a note reads as belonging to the title line above it).
    HEAD_INDENT  = "  "
    TITLE_INDENT = "             "
    NOTE_INDENT  = "                "

    # Prose wraps to the same basis as the plan/say markdown path: a fixed
    # PERCENTAGE of the detected terminal width (80 mirrors AUTO_WIDTH_PERCENT),
    # floored so a very narrow terminal stays readable. A fitting line is verbatim.
    DIALOG_WIDTH_PERCENT = 80
    MIN_DIALOG_WIDTH = 40

    # One note line + its kind. A plain String note is kind context, so existing
    # callers are unchanged.
    Note = Struct.new(:text, :kind) do
      def initialize(text, kind: "context")
        raise ArgumentError,
          "unknown dialog note kind #{kind.inspect} (available: #{NOTE_KINDS.join(', ')})" \
          unless NOTE_KINDS.include?(kind.to_s)

        super(text.to_s, kind.to_s)
      end

      # The palette role this kind maps to.
      def role
        NOTE_ROLES.fetch(kind)
      end
    end

    # A single selectable item in a dialog.
    class Option
      attr_reader :title, :description, :value

      def initialize(title:, value:, description: nil)
        raise ArgumentError, "option title must be a non-empty string" \
                            if title.to_s.strip.empty?
        raise ArgumentError, "option value must not be nil" if value.nil?

        @title       = title.to_s.strip
        @description = description&.to_s
        @value       = value
      end
    end

    attr_reader :title, :options, :notes

    # title:         what the dialog is about (required, non-empty).
    # options:       non-empty array of Option; Cancel is appended automatically
    #                (and, when free_text is on, the "Additional details" option first).
    # note:          line(s) under the title: ONE String (kind context), ONE Note,
    #                or an Array of either. The emitter states each line's kind, never a colour.
    # free_text:     let the user pick "Additional details" and type an answer,
    #                returned as [FREE_TEXT, text] alone or appended to the selection.
    # free_text_prompt: optional hint used as that option's label and shown when asking.
    # multi_select:  allow picking several options in one line ("1 3"). Without it,
    #                at most one regular option may be picked, though "Additional
    #                details" still counts alongside it; Cancel does not.
    def initialize(title:, options:, note: nil, free_text: false, free_text_prompt: nil,
                   multi_select: false, grant: false)
      raise ArgumentError, "dialog title must be a non-empty string" if title.to_s.strip.empty?
      unless options.is_a?(Array) && !options.empty?
        raise ArgumentError, "dialog requires a non-empty array of Dialog::Option"
      end
      options.each do |o|
        raise ArgumentError, "every option must be a Dialog::Option" unless o.is_a?(Option)
      end

      # A GRANT dialog can never be denied for a background job (denying it would
      # stop the job working); every other dialog kind is deniable.
      @grant = grant ? true : false

      @title   = title.to_s.strip
      @notes   = normalize_notes(note)
      @free_text = free_text ? true : false
      @free_text_prompt = free_text_prompt.to_s.strip.sub(/\Aor\s+/, "")
      options = options.dup
      if @free_text
        # The hint (when given) IS the option's label, otherwise the generic default.
        title = @free_text_prompt.empty? ? FREE_TEXT_OPTION : @free_text_prompt
        options << Option.new(title:, value: FREE_TEXT)
      end
      options << Option.new(title: "Cancel", value: CANCEL_VALUE)
      @options = options
      @multi_select = multi_select ? true : false
    end

    # True when this dialog asks for a consent GRANT (never deniable for a job).
    def grant?
      @grant
    end

    # Render the dialog and wait for a choice. Returns the selected value (bare for
    # one pick, an array for several), [FREE_TEXT, text] when only "Additional
    # details" was picked, or CANCEL_VALUE / [:cancelled, reason].
    #
    # From a Task thread this routes through the task protocol and the MAIN thread
    # serves the I/O - pass nil there (naming $stdout/$stdin from a task thread is
    # wrong-thread global stream access). With no Task, ui: must be an explicit
    # console used directly: no defaults, no global lookup.
    def show(ui: nil)
      # Guard keeps load order independent: dialog can load before task; they only
      # meet at runtime on the main thread.
      task = defined?(Task) ? Task.current : nil

      if task
        raise ArgumentError, "dialog routed through a Task: pass ui: nil" \
          unless ui.nil?

        # Post a request and block until the main thread services the dialog.
        task.request(:dialog, dialog: self)
      else
        raise ArgumentError, "no Task active: show requires an explicit ui: console" \
          if ui.nil?

        perform_direct(ui:)
      end
    end

    # Perform the dialog I/O directly on the given console - reached by show when no
    # Task is active, and by the main thread when servicing a :dialog request (on the
    # task's injected console, so output lands on the same stream the drain loop uses).
    def perform_direct(ui:)
      title_lines = @title.split("\n")
      ui.puts
      # The head is chrome, the title is in the terminal's own colour, and each note
      # line carries the KIND its emitter stated - no caller names a colour.
      ui.puts dialog_head(ui, title_lines.first)
      # A long title body re-wraps to the same percentage basis.
      dialog_wrap(title_lines[1..].join("\n"), TITLE_INDENT).each { |line| ui.puts line }

      @notes.each { |note| paint_note(ui, note).each { |line| ui.puts line } }

      @options.each_with_index do |opt, i|
        option_lines(ui, i, opt).each { |line| ui.puts line }
        if opt.description && !opt.description.strip.empty?
          # dialog_wrap already prefixes each line with the indent.
          dialog_wrap(opt.description, NOTE_INDENT).each { |line| ui.puts line }
        end
      end

      print_choice_prompt(ui)

      # The choice is one line of option numbers (or a cancel number + reason). On a
      # tty it comes from UI::Editor; otherwise a plain gets() that only dismisses on
      # a real EOF.
      draft = nil
      loop do
        res = read_choice_line(ui, draft)
        # nil = non-tty stream EOF; :eof = Ctrl-D inside the tty editor.
        return CANCEL_VALUE if res.nil? || res[:status] == :eof

        # Esc keeps what was typed as a draft for the next round - never a cancel.
        # Any other round resets it so a submitted line parses as typed, not shadowed.
        draft = res[:status] == :cancelled ? res[:text] : nil
        next if draft && !draft.to_s.strip.empty? # re-prompt with the prefill

        if res[:status] == :empty
          # Bare Enter: stale input - re-prompt without touching the draft.
          next
        end

        # A nil/blank submitted line gets bare-Enter semantics (re-prompt) rather
        # than parsing as an empty selection - the editor returns :empty for blanks,
        # but stubs and odd streams deserve the same fallback.
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

    # A note is ONE line (String = kind context), ONE Note, or an Array of either.
    # Blank lines are dropped so a computed note with a nil part prints no empty lines.
    # Array() is NOT used: a Struct answers #to_a and would splat a Note into its fields.
    def normalize_notes(note)
      return [] if note.nil?

      parts = note.is_a?(Array) ? note : [note]
      parts.flat_map do |part|
        next [] if part.nil?

        part = Note.new(part) if part.is_a?(String)
        part.text.to_s.split("\n").filter_map do |line|
          next nil if line.strip.empty?

          Note.new(line, kind: part.kind)
        end
      end
    end

    # The first line: bracket + glyph as recessive chrome, title text in the
    # terminal's own colour. The marker keeps its exact pre-colour bytes so a plain
    # console still produces the dialog it always did.
    def dialog_head(ui, title_line)
      "#{paint(ui, :marker, "#{HEAD_INDENT}[dialog] ⚠  ")}#{title_line}"
    end

    # A note wrapped to the content width; each continuation carries the note indent
    # and the role is painted per rendered line (so the palette covers every physical
    # line). A fitting note is one line - the exact pre-wrap bytes.
    def paint_note(ui, note)
      TextWrap.line(note.text, content_width(NOTE_INDENT)).map do |seg|
        "#{NOTE_INDENT}#{paint(ui, note.role, seg)}"
      end
    end

    # The NUMBER is the anchor the choice line names, so it gets its own hue (not the
    # marker gray) while the option's words stay readable content. A long title wraps:
    # the first line keeps the painted number, continuations pad to align under it.
    def option_lines(ui, index, opt)
      number = "#{index + 1})"
      pad    = " " * (TITLE_INDENT.length + number.length + 1)
      segs   = TextWrap.line(opt.title, content_width(pad))
      segs   = [""] if segs.empty?
      out    = ["#{TITLE_INDENT}#{paint(ui, :dialog_option, number)} #{segs.first}"]
      segs[1..].each { |seg| out << (pad + seg) }
      out
    end

    # Total wrap width: a fixed percentage of the terminal, floored so a very narrow
    # terminal stays readable. Same basis as UI::MarkdownRenderer::AUTO_WIDTH_PERCENT.
    def content_width(indent)
      cols  = (Tins::Terminal.columns rescue MIN_DIALOG_WIDTH)
      total = [(cols * DIALOG_WIDTH_PERCENT / 100.0).floor, MIN_DIALOG_WIDTH].max
      [total - indent.to_s.length, 1].max
    end

    # Wrap a block to its indent's content width, prefixing every line with the indent.
    def dialog_wrap(text, indent)
      TextWrap.line(text, content_width(indent)).map { |seg| "#{indent}#{seg}" }
    end

    # A console answers #paint when it has a palette; a duck-typed sink that only
    # answers puts/print gets plain text, so no dialog must know its console kind.
    def paint(ui, role, text)
      return text unless ui.respond_to?(:paint)

      ui.paint(role, text)
    end

    # Read one choice line. tty -> UI::Editor (Enter submits, bare Enter :empty,
    # Esc :cancelled with the draft intact, Ctrl-D :eof); non-tty -> gets() (nil=EOF,
    # blank=:empty, else :submitted). The "> " line is the editor prompt on tty, the
    # plain-prompt marker elsewhere. Returns {text:, status:} or nil on EOF.
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

    # True when stdin IS the process's real terminal stdin - UI::Editor's Reline path
    # attaches to $stdin, so a fake tty? stream in tests must stay on the gets() path.
    def tty_input?(ui)
      !ui.stdin.nil? && UI::Editor.is_real_tty_stdin?(ui.stdin)
    end

    # Resolve one choice line to its selection or a noted cancel, or nil when invalid
    # (already re-prompted). Accepted forms: "<n>" / "<n> <n>" (space or comma) - all
    # in range, at most one regular option unless multi-select; "<cancel n> <reason>" -
    # the one text-on-a-choice-line form. Anything else is stray input: re-prompt,
    # never select/note/cancel.
    def parse_choice_line(answer, ui)
      tokens = answer.split(/[,\s]+/).reject(&:empty?)
      if tokens.any? { |t| !t.match?(/\A\d+\z/) }
        noted = cancel_with_reason?(answer)
        return reprompt_invalid(answer, ui) if noted.nil?

        return noted # "<cancel n> <reason>"
      end

      numbers, bad = tokens.map(&:to_i).partition { |n| n >= 1 && n <= @options.size }
      unless bad.empty?
        return reprompt_invalid(bad.join(", "), ui)
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

    # The one text-on-a-choice-line form: a cancel number plus a one-line reason.
    # Returns the noted cancel, or nil when the line is not in that shape (stray input).
    def cancel_with_reason?(answer)
      m = answer.match(/\A(\d+)\s+(\D.*)\z/)
      return nil unless m

      n = m[1].to_i
      return nil unless n >= 1 && n <= @options.size
      return nil unless @options[n - 1].value == CANCEL_VALUE

      [CANCEL_VALUE, m[2]]
    end

    # Assemble the result from a parsed selection. A noted cancel rides straight
    # through. Cancel anywhere in a selection cancels - except when "Additional
    # details" is picked in the same line, where the typed reason block replaces the
    # bare cancel. Details pick enters the text block then appends [FREE_TEXT, text]
    # to the other values (empty block re-prompts, EOF cancels). One number -> bare
    # value; more -> array.
    def finalize(chosen, ui)
      if chosen.is_a?(Array) && chosen.size == 2 &&
         chosen[0] == CANCEL_VALUE && chosen[1].is_a?(String)
        return chosen # "<cancel> <one-line reason>"
      end

      values = chosen[:values]
      # Cancel anywhere in the selection cancels, UNLESS details are picked in the
      # same line - then the typed reason block replaces the bare cancel.
      if values.include?(CANCEL_VALUE) && !values.include?(FREE_TEXT)
        return CANCEL_VALUE
      end

      if values.include?(FREE_TEXT)
        detail = collect_details(ui)
        return nil_reprompt(ui) if detail.nil?
        # EOF mid-block (Ctrl-D) cancels the whole dialog - bare :cancelled, no pair.
        return CANCEL_VALUE if detail == CANCEL_VALUE

        others = values.reject { |v| v == FREE_TEXT || v == CANCEL_VALUE }
        # Cancel with nothing but details is the reason form: "4 3" -> [:cancelled, [FREE_TEXT, 'why']].
        return [CANCEL_VALUE, detail] \
          if others.empty? && values.include?(CANCEL_VALUE)

        values = others + [detail]
      end

      values.size == 1 ? values.first : values
    end

    # Ask for the typed details after the "Additional details" option. TTY: one shared
    # editor read (Enter inserts a newline, the submit key commits the whole block as
    # ONE note, Esc keeps the buffer and re-asks, Ctrl-D cancels). Non-tty: the classic
    # gets() block (blank line finishes, EOF cancels). Returns [FREE_TEXT, text], nil on
    # an empty block (re-prompt), or CANCEL_VALUE on EOF.
    def collect_details(ui)
      ui.puts
      hint = @free_text_prompt.empty? ? "type your answer" : @free_text_prompt
      if tty_input?(ui)
        ui.puts "             #{hint} (submit key to finish, Esc keeps it, Ctrl-D cancels):"
        draft = nil
        loop do
          res = UI::Editor.new(ui.stdin).read_multiline(prefill: draft)
          return CANCEL_VALUE if res.status == :eof
          # Esc and Ctrl+G both keep what the editor wrote as the draft - neither is an answer.
          if res.status == :edited
            draft = res.text.to_s
            ui.puts "             (#{res.note} - draft kept; submit key to finish)"
            next
          end
          draft = res.status == :cancelled ? res.text.to_s : nil
          next unless res.status == :submitted

          text = res.text.to_s.strip
          next if text.empty? # bare submit: re-ask (no details -> re-prompt)

          return [FREE_TEXT, text]
        end
      end
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
      ui.puts "             (no text entered - picking the option again)"
      print_choice_prompt(ui)
      nil
    end

    # Print the choice prompt with the input forms THIS dialog allows as a short list,
    # shared by the first ask and re-prompts. ui is explicit - no console default.
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
        # The Reline editor owns the keyboard; its "> " prompt is the input marker.
        return
      end

      ui.print "             > "
      ui.flush
    end

    # Reject an invalid answer (out-of-range number or stray text) and ask again.
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
