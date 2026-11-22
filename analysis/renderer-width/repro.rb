# frozen_string_literal: true

# Repro for "text wraps at ~80 columns on a wide terminal".
# The 80% rule is NOT what produces it: when the sink-based width detection
# fails, RULE_FALLBACK_WIDTH (80) is used AS the width, so no percentage is ever
# taken. From a fresh clone:
#   BUNDLE_GEMFILE=Gemfile bundle exec ruby analysis/renderer-width/repro.rb
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "io/console"
require "stringio"
require "tins/terminal"
require "ui"

def report(label, io)
  console = UI::Console.new(stdout: io, stdin: $stdin)
  renderer = UI::Renderer.new(ui: console)

  puts label
  puts "  io.tty?                    #{io.respond_to?(:tty?) ? io.tty?.inspect : 'n/a'}"
  begin
    puts "  io.winsize                 #{io.winsize.inspect}"
  rescue StandardError => e
    puts "  io.winsize                 raised #{e.class}"
  end
  puts "  UI.console.winsize         #{(IO.console.winsize rescue nil).inspect}"
  puts "  Tins::Terminal.columns     #{Tins::Terminal.columns}"
  puts "  columns_for (Renderer)     #{UI::Width.columns_for(console).inspect}"
  puts "  terminal_columns (Markdown) #{UI::Width.terminal_columns(console).inspect}"
  puts "  Renderer#width             #{renderer.width}"
  puts "  Renderer#note_width        #{renderer.note_width}"
  puts
end

report("real stdout:", $stdout)
report("pipe (StringIO):", StringIO.new)

puts "resolve(terminal: nil, fallback: 80) = " \
  "#{UI::Width.resolve(value: nil, terminal: nil, fallback: 80)} " \
  "- detection failed, so the fallback constant IS the width and 80% is never taken"
puts "resolve(terminal: 176, fallback: 80) = " \
  "#{UI::Width.resolve(value: nil, terminal: 176, fallback: 80)} " \
  "- 80% of 176 = 140, capped by MAX_PARAGRAPH_WIDTH 120"
