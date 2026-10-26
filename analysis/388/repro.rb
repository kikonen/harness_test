# frozen_string_literal: true

# Issue #388: "Colors in dialog" - every dialog printed in one color, so the lines a
# consent decision hinges on (MODEL VERDICT, DENYLISTED) looked exactly like the
# command text and the option numbers. Run from the repo root:
#   ruby analysis/388/repro.rb
# Rationale and the design decisions: doc/dialog_colors_design.md.
#
# What is measurable WITHOUT a model server (none exists in a checkout): which dialog
# lines a palette paints, which KIND each emitter states, whether the emitter API can
# smuggle a color (it must not - a caller states WHAT a line is), and that a plain
# console still prints the pre-#388 dialog byte for byte.
#
# Exit 1 when a claim fails. EXPECTED BEFORE the fix (master 961e7e6): section 1
# reports that the sink carries no palette and the dialog states no note kind, and the
# probe stops there - there is nothing to paint with. EXPECTED AFTER: every line of
# sections 2-7 is exactly as tabulated.
require "stringio"
require "tmpdir"

require_relative "../../lib/command_allowlist"
require_relative "../../lib/command_runner"
require_relative "../../lib/file_list"
require_relative "../../lib/task"
require_relative "../../lib/ui/console"
require_relative "../../lib/ui/dialog"
require_relative "../../lib/ui/palette"

GRAY   = "\e[38;5;240m"
BROWN  = "\e[38;5;130m"
RED    = "\e[31m"
GREEN  = "\e[32m"
RESET  = "\e[0m"
ESCAPE = /\e\[[0-9;]*m/

# The dialog's own line shapes (indent + text) so every expectation names a LINE.
HEAD_MARK = "  [dialog] \u26A0  "
NOTE_AT   = "                "
OPTION_AT = "             "
TITLE     = "The model is requesting to run a shell command:"
DENY_BODY = "well-known disaster, auto-approval refused in every posture; " \
  "this Allow is one-off"

# The two accessors CommandRunner asks a harness for.
SilentHarness = Struct.new(:output_palette, :logger)

INERT     = %q{echo "sudo rm /data"}
SAFE_TXT  = "safe: the rm/sudo strings are inert quoted data, never executed"
DANGER    = "dangerous: sh -c executes the quoted payload mkfs.ext4 /dev/sda1"

failures = []

def record_failure(list, message)
  list << message
  puts "         FAIL: #{message}"
end

# The dialog's own three line shapes, so a failure report shows the dialog lines only.
DIALOG_SHAPES = [HEAD_MARK, NOTE_AT, OPTION_AT].freeze

def report_lines(capture)
  capture.split("\n").each do |line|
    next unless DIALOG_SHAPES.any? { |shape| line.include?(shape) }

    puts "    #{line.inspect}"
  end
end

# Asserts a dialog line is EXACTLY these bytes (or starts with them, when the line ends
# in a resolved absolute path this probe cannot know). A color may only wrap the run it
# belongs to, so a line either matches byte for byte or the claim fails.
def expect_line(list, capture, expected, label, prefix: false)
  line = capture.split("\n").find { |l| prefix ? l.start_with?(expected) : l == expected }
  if line.nil?
    puts "  #{label}: NO SUCH LINE (expected #{expected.inspect})"
    report_lines(capture)
    list << "#{label}: no such line (#{expected.inspect})"
  else
    puts "  #{label}: #{line.inspect}"
  end
end

# Asserts NO dialog line carries escape bytes (the plain half of the contract).
def expect_no_paint(list, capture, label)
  painted = capture.split("\n").select { |l| l.match?(ESCAPE) }
  if painted.empty?
    puts "  #{label}: no escape bytes anywhere"
  else
    puts "  #{label}: #{painted.size} painted line(s)"
    painted.each { |l| puts "    #{l.inspect}" }
    list << "#{label}: escape bytes present (#{painted.first.inspect})"
  end
end

# A TOOL-path consent dialog on a console we can read: real stdin, nothing stubbed.
# palette: decides whether the sink paints at all, so the same runner drives both
# halves of the probe (colored, and byte-for-byte plain).
def consent_dialog(dir, command, options, answer, palette)
  stdout  = StringIO.new
  console = UI::Console.new(stdout:, stdin: StringIO.new("#{answer}\n"), palette:)
  runner  = CommandRunner.new(
    FileList.new([], workdir: dir),
    options,
    harness: SilentHarness.new(nil, nil),
    ui: console,
    list: :tool)

  [runner.run(command), stdout.string]
end

# A FRESH hash per run: CommandRunner#safety_verdict_for is one-shot for a pre-batched
# verdict (it drops the entry on first read), so re-using one hash would leave the
# second dialog verdict-less - the probe's bug, not the code's.
def verdict_options(command, verdict)
  { command_safety_check: true, safety_verdicts: { command => verdict } }
end

puts "== 1. The API: a caller states WHAT a line is, never how it looks =="

dialog_kwargs = UI::Dialog.instance_method(:initialize).parameters.map(&:last)
leak          = dialog_kwargs & %i[palette renderer color palette_name]
puts "  UI::Dialog.new keywords: #{dialog_kwargs.inspect}"
if leak.empty?
  puts "  no palette / renderer keyword on a dialog"
else
  record_failure(failures, "a caller can hand presentation to a dialog: #{leak.inspect}")
end

console_kwargs = UI::Console.instance_method(:initialize).parameters.map(&:last)
puts "  UI::Console.new keywords: #{console_kwargs.inspect}"

has_kinds = UI::Dialog.const_defined?(:NOTE_KINDS)
has_palette = console_kwargs.include?(:palette)
puts "  note kinds on the dialog: #{has_kinds ? UI::Dialog::NOTE_KINDS.inspect : 'NONE'}"
puts "  palette on the sink:      #{has_palette}"

unless has_kinds && has_palette
  record_failure(
    failures,
    "the dialog states no note kind and/or the sink carries no palette")
  puts
  puts "BEFORE THE FIX: nothing can paint a dialog line, so sections 2-7 cannot run."
  puts "FAILURES (#{failures.size}):"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end

%w[context warn alert safe].each do |kind|
  record_failure(failures, "kind #{kind} is missing") unless UI::Dialog::NOTE_KINDS.include?(kind)
end
begin
  UI::Dialog::Note.new("x", kind: RED)
  record_failure(failures, "a raw SGR code was accepted as a note kind")
rescue ArgumentError => e
  puts "  a color is not a kind: #{e.message[0, 44]}"
end

painted_sink = UI::Console.new(stdout: StringIO.new, palette: UI::Palette.new("default"))
plain_sink   = UI::Console.new(stdout: StringIO.new)
record_failure(
  failures,
  "the console answers no #paint, so a dialog has nothing to ask") \
  unless painted_sink.respond_to?(:paint)
record_failure(failures, "a console without a palette must return the text unchanged") \
  if plain_sink.paint(:dialog_alert, "x") != "x"
puts "  Console#paint is a no-op with no palette"

puts
puts "== 2. Example 2: a dangerous verdict + the hard floor (default palette) =="
Dir.mktmpdir do |dir|
  command = "sh -c \"mkfs.ext4 /dev/sda1\""
  _r, out = consent_dialog(
    dir,
    command,
    verdict_options(command, DANGER),
    "2",
    UI::Palette.new("default"))
  label = CommandAllowlist.disaster_label(command)

  expect_line(failures, out, "#{GRAY}#{HEAD_MARK}#{RESET}#{TITLE}", "marker = chrome")
  expect_line(
    failures,
    out,
    "#{NOTE_AT}#{RED}MODEL VERDICT (advisory): #{DANGER}#{RESET}",
    "dangerous verdict = alert")
  expect_line(
    failures,
    out,
    "#{NOTE_AT}#{RED}DENYLISTED: #{label} - #{DENY_BODY}#{RESET}",
    "DENYLISTED = alert")
  expect_line(
    failures,
    out,
    "#{OPTION_AT}#{GRAY}1)#{RESET} Allow",
    "option number = chrome")
  expect_line(
    failures,
    out,
    "#{OPTION_AT}#{GRAY}2)#{RESET} Cancel",
    "cancel number = chrome")
  expect_line(failures, out, "#{OPTION_AT}$ #{command}", "command text = plain")
end

puts
puts "== 3. The owner's example 1: a safe verdict must NOT read like a dangerous one =="
Dir.mktmpdir do |dir|
  _r, out = consent_dialog(
    dir,
    INERT,
    verdict_options(INERT, SAFE_TXT),
    "2",
    UI::Palette.new("default"))

  expect_line(
    failures,
    out,
    "#{NOTE_AT}#{GREEN}MODEL VERDICT (advisory): #{SAFE_TXT}#{RESET}",
    "safe verdict = green")
  expect_line(
    failures,
    out,
    "#{NOTE_AT}#{RED}DENYLISTED: sudo - #{DENY_BODY}#{RESET}",
    "DENYLISTED stays red")
end

puts
puts "== 4. UNSAFE (a refusal that is NOT the hard floor) reads as warn =="
Dir.mktmpdir do |dir|
  _r, out = consent_dialog(dir, "echo hi > tmpfile", {}, "2", UI::Palette.new("default"))
  unsafe = "UNSAFE: redirect to file (\"> tmpfile\") cannot be auto-approved"

  expect_line(failures, out, "#{NOTE_AT}#{BROWN}#{unsafe}#{RESET}", "UNSAFE = warn")
end

puts
puts "== 5. The ROUTED dialog (task thread) colors from the CONSOLE, not a renderer =="
puts "   harness: nil, so the TURN has no palette - any color came from the sink"
Dir.mktmpdir do |dir|
  stdout  = StringIO.new
  console = UI::Console.new(
    stdout:,
    stdin: StringIO.new("2\n"),
    palette: UI::Palette.new("default"))
  list = FileList.new(workdir: dir)
  error, = Task.run(harness: nil, ui: console) do |_t|
    list.grant_access("../outside.txt", :r, purpose: "to read the config")
  end
  out = stdout.string

  record_failure(failures, "Task.run reported an error: #{error.inspect}") if error
  expect_line(
    failures,
    out,
    "#{GRAY}#{HEAD_MARK}#{RESET}Access requested (read access): ",
    "marker (routed)",
    prefix: true)
  expect_line(
    failures,
    out,
    "#{NOTE_AT}#{BROWN}WARNING: this path is OUTSIDE the working directory - " \
      "granting access may be a sandbox escape.#{RESET}",
    "outside-workdir WARNING = warn")
  expect_line(
    failures,
    out,
    "#{NOTE_AT}to read the config",
    "purpose note = context, plain")
end

puts
puts "== 6. A plain console prints the pre-#388 dialog byte for byte =="
Dir.mktmpdir do |dir|
  _r, colored = consent_dialog(
    dir,
    INERT,
    verdict_options(INERT, SAFE_TXT),
    "2",
    UI::Palette.new("default"))
  _r, plain   = consent_dialog(dir, INERT, verdict_options(INERT, SAFE_TXT), "2", nil)
  _r, none    = consent_dialog(
    dir,
    INERT,
    verdict_options(INERT, SAFE_TXT),
    "2",
    UI::Palette.new("none"))

  [
    "#{HEAD_MARK}#{TITLE}\n",
    "#{OPTION_AT}$ #{INERT}\n",
    "#{NOTE_AT}MODEL VERDICT (advisory): #{SAFE_TXT}\n",
    "#{NOTE_AT}DENYLISTED: sudo - #{DENY_BODY}\n",
    "#{OPTION_AT}1) Allow\n",
    "#{OPTION_AT}2) Cancel\n"
  ].each do |shape|
    record_failure(failures, "plain dialog no longer prints #{shape.inspect}") \
      unless plain.include?(shape)
  end
  expect_no_paint(failures, plain, "no palette")
  expect_no_paint(failures, none, "palette none")

  if colored.gsub(ESCAPE, "") == plain
    puts "  a color changed the hue only, never the text"
  else
    record_failure(failures, "a colored dialog printed different TEXT than a plain one")
  end
end

puts
puts "== 7. Palettes: context unpainted everywhere, basic16 inside the 16-color band =="
%w[default basic16 none].each do |name|
  palette = UI::Palette.new(name)
  record_failure(failures, "#{name} paints the context kind") \
    unless palette.color_for(:dialog_note).nil?
  next if name == "none" # none paints nothing, in every role

  %w[dialog_warn dialog_alert dialog_safe].each do |role|
    code = palette.color_for(role.to_sym)
    record_failure(failures, "#{name} has no #{role}") if code.nil?
    next unless name == "basic16"
    next if code.to_s.match?(/\A3[0-7]\z/)

    record_failure(failures, "basic16 #{role} leaves the 16-color band: #{code.inspect}")
  end
end
puts "  context = terminal color in every palette; hues in default + basic16"
puts "  none paints no role at all: #{UI::Palette.new('none').color_for(:dialog_alert).inspect}"

puts
if failures.empty?
  puts "ALL CLAIMS HOLD: a dialog states WHAT a line is; the console decides the hue."
  exit 0
end

puts "FAILURES (#{failures.size}):"
failures.each { |f| puts "  - #{f}" }
exit 1
