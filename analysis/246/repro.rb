# frozen_string_literal: true

# Issue #246: "could compact be just started based in top of cached context".
# Run from the repo root:
#   ruby analysis/246/repro.rb
# What is measurable WITHOUT a model server (none exists in a checkout): the
# harness-side half of a prompt-prefix cache hit - is the compact summary call a
# byte-identical PREFIX of the request it follows. The server-side half (does a
# prefix actually reuse the KV cache) needs a live server: see measure.sh.
# Expected BEFORE the fix (master f105463; both compact paths sent messages[1..]):
#   the compact summary call: 6 messages, message 0 role=user, 603-byte body
#   a byte-identical prefix of the live chain? NO (first differing index 0)
#   RESULT: PREFIX LOST - compact re-prefills the whole conversation cold (exit 1)
# Expected AFTER the fix (the summary call gets the full chain):
#   the compact summary call: 7 messages, message 0 role=system
#   a byte-identical prefix of the live chain? YES
#   RESULT: PREFIX KEPT - the summary call is the live chain + the instruction (exit 0)
# The tools half stays NO in both: neither fork sends the live turn's tools
# payload. That is issue #238's question, reported here but not what this repro
# passes or fails on.
require "fileutils"
require "json"
require "tmpdir"

require_relative "../../lib/harness"
require_relative "../../lib/safety_check"

# Records every chat call's chain and tools payload; returns a canned summary.
class ChainRecorder
  attr_reader :calls

  def initialize
    @calls = []
  end

  def chat(messages, tools: nil, **_kwargs)
    @calls << { messages: messages.map(&:dup), tools: }
    { choices: [{ message: { content: "SUMMARY TEXT" } }] }
  end

  def last = @calls.last
end

workdir = Dir.mktmpdir("issue-246")
at_exit { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

# harness.md rides into the workdir so the system message measured here is the
# one this project actually sends, not the bare base prompt.
rules = File.expand_path("../../harness.md", __dir__)
FileUtils.copy_file(rules, File.join(workdir, "harness.md")) if File.file?(rules)

file_list = FileList.new([], workdir:)
harness   = Harness.new({ system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE }, file_list)
recorder  = ChainRecorder.new
harness.instance_variable_set(:@client, recorder)

harness.session.add_user("first instruction")
harness.session.add_assistant("first answer")
harness.session.add_user("second instruction")
harness.session.add_assistant("second answer")
harness.session.add_user("third instruction")

live_chain = harness.session.messages.map(&:dup)
live_tools = harness.tool_registry.empty? ? nil : harness.tool_registry.to_openai
live_body  = JSON.generate(live_chain)

harness.session_manager.compact_session

summary_call = recorder.last
summary_msgs = summary_call[:messages]

# The compact summary call is a prefix-extension of the live chain when its first
# live_chain.size messages are byte-identical to it (the instruction rides on the
# end). A prompt-prefix cache matches from token 0, so only a prefix is cheap.
prefix  = summary_msgs.first(live_chain.size) == live_chain
shared  = [summary_msgs.size, live_chain.size].min
diff_at = (0...shared).find { |i| summary_msgs[i] != live_chain[i] }

sys_chars = live_chain[0][:content].size
est       = (sys_chars / Session::EST_CHARS_PER_TOKEN.to_f).ceil
window    = harness.options[:num_ctx] || LLMClient::NUM_CTX
pct       = (est.to_f / window * 100).round(1)

puts "== the live turn's request (what Harness#call_llm hands the transport) =="
puts "  messages: #{live_chain.size}, message 0 role=#{live_chain[0][:role]}"
puts "  message 0 size: #{sys_chars} chars"
puts "  request body: #{live_body.bytesize} bytes"
if live_tools
  tools_bytes = JSON.generate(live_tools).bytesize
  puts "  tools: #{live_tools.size} definitions, #{tools_bytes} bytes"
else
  puts "  tools: none"
end

puts
puts "== the compact summary call =="
puts "  messages: #{summary_msgs.size}, message 0 role=#{summary_msgs[0][:role]}"
puts "  request body: #{JSON.generate(summary_msgs).bytesize} bytes"
puts "  tools: #{summary_call[:tools].nil? ? 'nil (none sent)' : 'sent'}"
puts "  a byte-identical prefix of the live chain? #{prefix ? 'YES' : 'NO'}"
unless prefix
  roles = "#{summary_msgs[diff_at][:role]} vs #{live_chain[diff_at][:role]}"
  puts "  first differing index: #{diff_at} (roles: #{roles})"
end

puts
puts "== what including message 0 costs (the trade #246 asks about) =="
puts "  system message: ~#{est} est tokens of a #{window} window (#{pct}%)"
reserved = Session::COMPACT_RESERVED_TOKENS
puts "  headroom the summary call already reserves: #{reserved} tokens"
tools_est = (JSON.generate(live_tools).size / 4.0).ceil
puts "  the tools payload alone: ~#{tools_est} est tokens"

puts
puts "== the OTHER fork the harness already sends (the half issue #238 owns) =="
safety_fork     = SafetyCheck.truncate_for_check(live_chain)
safety_recorder = ChainRecorder.new
SafetyCheck.run(safety_recorder, live_chain, ["ls"], logger: nil)
fork_prefix = safety_fork.first(live_chain.size) == live_chain
fork_tools  = safety_recorder.last[:tools] == live_tools
fork_state  = fork_prefix ? "YES" : "NO"
tools_state = fork_tools ? "YES" : "NO (tools: nil)"
puts "  SafetyCheck fork a prefix of the chain? #{fork_state} (#{safety_fork.size} msgs)"
puts "  fork carries the live turn's tools payload? #{tools_state}"

puts
if prefix
  puts "RESULT: PREFIX KEPT - the summary call is the live chain plus the"
  puts "        instruction, so a prefix cache can reuse the whole prompt."
  puts "        Caveat unchanged: neither fork sends the tools payload (#238)."
  exit 0
end

puts "RESULT: PREFIX LOST - the compact summary call drops message 0, so it is a"
puts "        different prompt, not a longer one, and re-prefills cold."
exit 1
