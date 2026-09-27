# frozen_string_literal: true

# A generic user dialog: a title (what it is about), a set of options,
# and a standard "Cancel" option that is ALWAYS present.
#
# Each option has a title, an optional description, and a value. The
# value of the selected option is returned to the caller; selecting the
# standard cancel option (or dismissing with EOF / invalid input)
# returns Dialog::CANCEL_VALUE.
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
#   choice = dialog.show  # => :file_only, :dir_recursive, or :cancelled
class Dialog
  # Standard value returned when the user picks the cancel option (or
  # dismisses the dialog with EOF / an invalid answer).
  CANCEL_VALUE = :cancelled

  # A single selectable item in a dialog.
  class Option
    attr_reader :title, :description, :value

    def initialize(title:, value:, description: nil)
      raise ArgumentError, 'option title must be a non-empty string' if title.to_s.strip.empty?
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
  def initialize(title:, options:, note: nil)
    raise ArgumentError, 'dialog title must be a non-empty string' if title.to_s.strip.empty?
    unless options.is_a?(Array) && !options.empty?
      raise ArgumentError, 'dialog requires a non-empty array of Dialog::Option'
    end
    options.each do |o|
      raise ArgumentError, 'every option must be a Dialog::Option' unless o.is_a?(Option)
    end

    @title   = title.to_s.strip
    @note    = note&.to_s
    @options = options + [Option.new(title: 'Cancel', value: CANCEL_VALUE)]
  end

  # Render the dialog and wait for the user's choice on $stdin.
  # Returns the VALUE of the selected option, or CANCEL_VALUE when the
  # user cancels (or the input is invalid / stdin is closed).
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

    print "             Choice (1..#{@options.size}): "
    $stdout.flush

    answer = $stdin.gets.to_s.chomp.strip

    idx = answer.to_i - 1
    opt = @options[idx] if answer.match?(/\A\d+\z/) && idx >= 0 && idx < @options.size

    opt ? opt.value : CANCEL_VALUE
  end
end
