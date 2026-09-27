# frozen_string_literal: true

# A generic user dialog: a title (what it is about), a set of options,
# and a standard "Cancel" option that is ALWAYS present.
#
# Each option has a title, an optional description, and a value. The
# value of the selected option is returned to the caller; selecting the
# standard cancel option (or dismissing with EOF) returns
# Dialog::CANCEL_VALUE.
#
# A dialog can also allow FREE TEXT: when free_text is enabled the user
# may type their own short answer instead of picking a number, and that
# text is returned to the caller verbatim.
#
# The user may always attach a short NOTE to any choice: they type the
# option number, whitespace, then the note (e.g. "1 seems fine"). The
# dialog returns [value, 'seems fine'] so the selection is not lost.
# A plain number (no note) still returns the bare value, so existing
# callers keep working unchanged.
#
#   dialog = Dialog.new(
#     title: 'Access requested (write access): lib/foo.rb',
#     options: [
#       Dialog::Option.new(title: 'Allow this file only', value: :file_only),
#       Dialog::Option.new(title: 'Allow directory: lib/ (recursive)',
#                          value: :dir_recursive,
#                          description: 'covers every file under lib/')
#     ]
#   )
#   choice = dialog.show  # => :file_only, [:file_only, 'note'], or :cancelled
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
  # options: non-empty array of Dialog::Option; the standard cancel
  #          option is appended automatically.
  # note:    optional context line(s) shown under the title (e.g. a
  #          warning, or an explanation of why the dialog was asked).
  # free_text: allow the user to type their own short answer instead of
  #            picking an option (returned as [FREE_TEXT, text]).
  # free_text_prompt: optional hint shown to the user about what kind of
  #            free-text answer is expected.
  def initialize(title:, options:, note: nil, free_text: false, free_text_prompt: nil)
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
  end

  # Render the dialog and wait for the user's choice on $stdin.
  # Returns the VALUE of the selected option, [FREE_TEXT, text] when the
  # user types their own answer (free_text dialogs only), or CANCEL_VALUE
  # when the user cancels (or stdin is closed).
  #
  # The user may attach a short note to ANY choice by typing
  # "<number> <note>" (e.g. "1 seems fine"): the dialog then returns
  # [option value, 'seems fine'] instead of the bare value - the note is
  # extra context on top of the selection, never a replacement for it.
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

    if @free_text
      hint = @free_text_prompt.to_s.strip
      hint = 'type a short free-text answer' if hint.empty?
      print "             Choice (1..#{@options.size}, <number> + note, or #{hint}): "
    else
      print "             Choice (1..#{@options.size}, or <number> + short note): "
    end
    $stdout.flush

    # Skip blank lines: they are usually stale input (e.g. the user
    # pressed Enter an extra time while sending the prompt, and that
    # newline is still sitting in stdin). Only a real EOF dismisses the
    # dialog without an answer.
    loop do
      line = $stdin.gets
      break if line.nil?

      answer = line.chomp.strip
      next if answer.empty?

      # "<number> <note>": option selected PLUS a free note on top.
      m = answer.match(/\A(\d+)\s+(.*)\z/m)
      if m
        idx = m[1].to_i - 1
        if idx >= 0 && idx < @options.size
          return [@options[idx].value, m[2].strip]
        end

        # Out-of-range number: not a valid choice. Fall through - free text
        # when allowed (the whole line is the answer), cancel otherwise.
      end

      # Plain number: the option's value, unchanged.
      if answer.match?(/\A\d+\z/)
        idx = answer.to_i - 1
        return @options[idx].value if idx >= 0 && idx < @options.size
      end

      # Not a valid option number: free text when allowed, cancel otherwise.
      return @free_text ? [FREE_TEXT, answer] : CANCEL_VALUE
    end
    CANCEL_VALUE
  end
end