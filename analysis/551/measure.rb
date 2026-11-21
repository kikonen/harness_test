#!/usr/bin/env ruby
# frozen_string_literal: true

# Issue #551: OVERFLOW - a tool result becomes a message so large the backend
# refuses the whole request ("request exceeds the context window ... requests are
# never truncated"), not a cut-off answer. The cap counts LINES, never BYTES, so
# output with few newlines and huge lines (base64 dumps, minified JSON, a
# one-line blob) passes the gate intact. /compact cannot save the run either: the
# summary request carries the same oversized chain, and Session#compact retains
# the oversized message in its tail.
#
# Run from a fresh clone: ruby analysis/551/measure.rb

# The truncators are copied rather than required, so this repro does not need the
# harness' UI stack (reline is not in the sandbox Gemfile).
module LineGate
  # Verbatim copy of CommandRunner#truncate (lib/command_runner.rb).
  def self.truncate(text, limit)
    lines = text.split("\n")
    return [text, false] if lines.size <= limit

    tail    = limit / 2
    head    = limit - tail
    dropped = lines.size - head - tail
    notice  = "... (output truncated: #{dropped} line(s) omitted from the " \
              "middle - raise 'limit' or narrow the command to see them)"
    [(lines.first(head) + [notice] + lines.last(tail)).join("\n"), true]
  end

  # Verbatim copy of GitRunner#truncate_output (lib/git_runner.rb).
  def self.git_output(text, limit)
    lines = text.split("\n", -1)
    return [text, false] if lines.size <= limit

    dropped = lines.size - limit
    notice  = "... (output truncated: #{dropped} more line(s) omitted - " \
              "narrow the query or raise 'limit' to see them)"
    [lines.first(limit).join("\n") + "\n" + notice, true]
  end

  # Verbatim copy of Tools::WebFetchTool#truncate_body (lib/tools/web_fetch_tool.rb).
  def self.web_body(text, limit)
    lines = text.split("\n")
    return [text, false] if lines.size <= limit

    [lines.first(limit).join("\n"), true]
  end
end

def shape(label, text, limit: 500)
  kept, truncated = LineGate.truncate(text, limit)
  puts format('%-22s in: %5d lines %10d B | out: %5d lines %10d B | cut? %s',
              label,
              text.lines.size,
              text.bytesize,
              kept.lines.size,
              kept.bytesize,
              truncated)
end

puts '== the line gate WORKS for many SHORT lines (500-line limit) =='
shape('5000 short lines', (1..5000).map { |i| "line #{i}" }.join("\n"))

puts
puts '== the #551 shape: few lines, huge ones - the gate is blind =='
shape('500 x 20KB blobs', Array.new(500) { 'A' * 20_000 }.join("\n"))
shape('1 line, 4 MB', 'x' * 4_000_000)
shape('1000 x 4KB json', Array.new(1000) { '{"k":"' + ('v' * 4000) + '"}' }.join("\n"))

puts
puts '== the same line-only gate in the other truncators =='
git = LineGate.git_output('y' * 3_000_000, 500)
puts format('git_output  1 line 3MB -> %d B kept, cut? %s', git[0].bytesize, git[1])
web = LineGate.web_body('z' * 3_000_000, 200)
puts format('web_body    1 line 3MB -> %d B kept, cut? %s', web[0].bytesize, web[1])
