# frozen_string_literal: true

# Issue #378: a streamed request's delta callback reads the @stream_preview IVAR,
# so a delta delivered after the request's own ensure cleared it calls record on
# nil. Run from the repo root:
#   ruby analysis/378/repro.rb
# Uses the REAL Harness#call_llm -> request_chain path with a stub client that
# keeps the on_delta the backend was handed WITHOUT calling it - exactly what a
# transport does while it still has a delta to deliver (a killed/aborted turn, a
# decoder flush after the response returned).
# Expected BEFORE the fix (master aa28d4c):
#   REPRODUCED: NoMethodError: undefined method 'record' for nil
#   frame: .../lib/harness.rb:766:in 'block in Harness#request_chain'   (exit 1)
# Expected AFTER the fix:
#   NO ERROR - the callback holds THIS request's preview object           (exit 0)
#   and stream_preview_line stays nil (a late delta cannot resurrect a tail)
require "fileutils"
require "tmpdir"

require_relative "../../lib/harness"

# Records the callback the harness handed the backend; never calls it itself.
class CallbackKeeper
  attr_reader :delta_callback

  def chat(_messages, **kwargs)
    @delta_callback = kwargs[:on_delta]
    { choices: [{ message: { content: "answer", reasoning: nil } }] }
  end
end

workdir = Dir.mktmpdir("issue-378")
at_exit { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

file_list = FileList.new([], workdir:)
harness   = Harness.new(
  { system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE, stream: true }, file_list)
client = CallbackKeeper.new
harness.instance_variable_set(:@client, client)
harness.session.add_user("go")

harness.call_llm # the streamed request ran and its ensure cleared @stream_preview

puts "after the request: stream_preview_line = #{harness.stream_preview_line.inspect}"
puts "the backend was handed a callback? #{!client.delta_callback.nil?}"

begin
  client.delta_callback.call({ content: "late delta" })
rescue NoMethodError => e
  puts "REPRODUCED: #{e.class}: #{e.message}"
  puts "frame     : #{e.backtrace.find { |l| l.include?('harness.rb') }}"
  exit 1
end

tail_after = harness.stream_preview_line
puts "NO ERROR - the callback holds this request's preview object"
puts "stream_preview_line after the late delta: #{tail_after.inspect}"

if tail_after.nil?
  puts "RESULT: FIX HOLDS - no raise, and no tail resurrected for the reader"
  exit 0
end

puts "RESULT: A late delta resurrected a finished request's tail"
exit 1
