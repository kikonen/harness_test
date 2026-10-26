# frozen_string_literal: true

# Issue #246: "could compact be just started based in top of cached context".
# Run from the repo root:
#   ruby analysis/246/repro.rb
# What is measurable WITHOUT a model server (none exists in a checkout): whether
# an advisory fork request is a byte-identical EXTENSION of the request the
# harness just sent. A prefix cache matches the RENDERED prompt from token 0, and
# a chat template renders the tool definitions into it, so each fork is judged on
# two axes: the message chain AND the tools payload. Both must match.
# Sections are named exactly as the specs name them: #compact_session
# (end-of-turn), #check_inloop_compaction (mid-turn), SafetyCheck.run.
# Expected BEFORE the fix (master f105463):
#   #compact_session:            chain NO (message 0 sliced off), tools NO
#   #check_inloop_compaction:    chain NO, tools NO
#   SafetyCheck.run:             chain YES, tools NO
#   RESULT: PREFIX LOST - exit 1
# Expected with only the chain half fixed (branch HEAD before the tools half):
#   all three chains YES, all three tools NO - RESULT: PREFIX LOST, exit 1
# Expected AFTER both halves:
#   every fork: chain YES and tools == the live turn's payload - exit 0
# The server-side half (does a prefix actually reuse the KV cache) needs a live
# server: see measure.sh.
require "fileutils"
require "json"
require "tmpdir"

require_relative "../../lib/harness"
require_relative "../../lib/safety_check"

# Records every chat call's chain and tools payload; returns a canned answer.
class ChainRecorder
  attr_reader :calls

  def initialize(answer = "SUMMARY TEXT")
    @calls  = []
    @answer = answer
  end

  def chat(messages, tools: nil, **_kwargs)
    @calls << { messages: messages.map(&:dup), tools: }
    { choices: [{ message: { content: @answer } }] }
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

harness.session.add_user("first instruction")
harness.session.add_assistant("first answer")
harness.session.add_user("second instruction")
harness.session.add_assistant("second answer")
harness.session.add_user("third instruction")

# The live turn's request, exactly as Harness#call_llm builds it: the session's
# chain plus the harness's tool payload. Everything below is judged against THIS.
live_msgs = harness.session.messages.map(&:dup)
# tools_payload is this fix's name for what the live turn sends; the pre-fix
# call_llm built the same payload inline, so the comparison runs on either.
live_tools = if harness.respond_to?(:tools_payload)
               harness.tools_payload
             else
               harness.tool_registry.to_openai
             end
if live_tools.nil?
  puts "RESULT: the harness registered no tools - nothing to compare (exit 2)"
  exit 2
end

def report(label, call, reference, live_tools)
  msgs  = call[:messages]
  pre   = msgs.first(reference.size) == reference
  tools = call[:tools] == live_tools
  puts "  #{label}"
  puts format(
    "    messages: %d, message 0 role=%s, %d B body",
    msgs.size,
    msgs[0][:role],
    JSON.generate(msgs).bytesize)
  puts format(
    "    tools:    %s",
    call[:tools].nil? ? "none sent" : "#{call[:tools].size} definitions")
  verdict = ->(flag) { flag ? "YES" : "NO" }
  puts "    chain extends the request it follows, byte for byte?  #{verdict[pre]}"
  puts "    tools == the live turn's payload?                       #{verdict[tools]}"
  [pre, tools]
end

puts "live turn: #{live_msgs.size} messages, message 0 role=#{live_msgs[0][:role]} " \
  "(#{live_msgs[0][:content].size} chars), body #{JSON.generate(live_msgs).bytesize} B " \
  "tools #{live_tools.size} definitions #{JSON.generate(live_tools).bytesize} B"
puts

results = {}

# 1. #compact_session (end-of-turn): /compact, auto-compact, retry.
#    Pinned by spec/lib/session_manager_spec.rb:
#      "sends the FULL chain to the summary call, system message included"
#      "sends the live tools payload on the summary call"
#    and spec/lib/harness_spec.rb (the whole turn, summary fork included):
#      "sends it on the in-loop summary call too"
recorder = ChainRecorder.new
harness.instance_variable_set(:@client, recorder)
harness.session_manager.compact_session
results["#compact_session"] = report(
  "#compact_session (end-of-turn)",
  recorder.last,
  live_msgs,
  live_tools)

# The mid-tool-loop state. check_inloop_compaction runs at the TOP of an
# iteration, right after a round's tool results were appended; the consent
# dialog fires later in the same iteration, when the chain ends on an assistant
# message whose tool_calls have no results yet.
tool_round_chain = live_msgs + [
  {
    role: "assistant",
    content: nil,
    tool_calls: [{ id: "c1", function: { name: "file.read", arguments: "{}" } }]
  },
  { role: "tool", tool_call_id: "c1", content: "file contents" }
]

# 2. #check_inloop_compaction (mid-turn). A snapshot is taken BEFORE the call:
#    the reference must be the chain as it was SENT, not what compaction left
#    behind (the method replaces the array in place).
#    Pinned by spec/lib/session_manager_spec.rb:
#      "summarizes the FULL chain, drops the verbatim tail, and syncs the session"
#      "sends the live tools payload on the in-loop summary call"
sent_chain = tool_round_chain.map(&:dup)
recorder2  = ChainRecorder.new
harness.instance_variable_set(:@client, recorder2)
ran = harness.session_manager.check_inloop_compaction(sent_chain, 100_000)
puts "  #check_inloop_compaction #{ran ? 'ran' : 'REFUSED (no summary call was made)'}"
results["#check_inloop_compaction"] =
  if ran
    report(
      "#check_inloop_compaction (mid-turn)",
      recorder2.last,
      tool_round_chain,
      live_tools)
  else
    [false, false]
  end

# 3. SafetyCheck.run: the fork the two callers build today, from the chain shape
#    the dialog actually sees. Its reference is the TRUNCATED chain - the
#    unresolved assistant tool_calls message is not part of any request the
#    server has ever seen, so the fork extends the last COMPLETE round.
#    Pinned by spec/lib/safety_check_spec.rb:
#      "forwards the caller tools payload to chat unchanged"
#    and spec/lib/harness_spec.rb:
#      "sends one check request with the live tool payload, forked from the chain"
dialog_chain = tool_round_chain + [
  {
    role: "assistant",
    content: nil,
    tool_calls: [{ id: "c2", function: { name: "run.command", arguments: "{}" } }]
  }
]
fork_reference = SafetyCheck.truncate_for_check(dialog_chain)
recorder3      = ChainRecorder.new
begin
  SafetyCheck.run(recorder3, dialog_chain, ["ls"], tools: live_tools, logger: nil)
rescue ArgumentError
  # The pre-fix SafetyCheck.run had no tools: keyword at all - the fork could
  # not have carried the payload even if a caller wanted it to.
  SafetyCheck.run(recorder3, dialog_chain, ["ls"], logger: nil)
end
fork_call = recorder3.last
results["SafetyCheck.run"] = report(
  "SafetyCheck.run (the safety fork)",
  fork_call,
  fork_reference,
  live_tools)

# What a compact request adds on top of the prompt it follows (the cost #246
# asks about): the instruction is one user message, and the tools region is the
# same payload the live turn already sent.
added = recorder.last[:messages].last[:content]
puts
puts "what a compact request adds on top of the prompt it follows:"
puts "  1 user message, #{added.size} chars (the summarization instruction)"
puts "  plus the SAME #{live_tools.size} tool definitions the live turn sends"

# Token accounting, with the harness' own estimate gap shown for THIS chain:
# estimate_tokens counts message CONTENT only, so it never sees the tools region
# the server tokenizes.
est       = harness.session.estimate_tokens(live_msgs)
sys_est   = (live_msgs[0][:content].size / Session::EST_CHARS_PER_TOKEN.to_f).ceil
tools_b   = JSON.generate(live_tools).size
tools_est = (tools_b / Session::EST_CHARS_PER_TOKEN.to_f).ceil
window    = LLMClient::NUM_CTX
trigger   = harness.session.compact_trigger(
  window,
  Session::AUTO_COMPACT_THRESHOLD,
  reserved_tokens: Session::COMPACT_RESERVED_TOKENS)
puts
puts "token accounting around the compact trigger (window #{window}):"
trigger_pct = Session::AUTO_COMPACT_THRESHOLD
reserved    = Session::COMPACT_RESERVED_TOKENS
puts "  trigger: #{trigger} tokens = min(#{trigger_pct}% of window, " \
  "window - #{reserved} reserved)"
puts "  the server's prompt_tokens is the WHOLE rendered prompt"
puts "    (system + tools + messages) and is what context_used compares to the trigger"
puts "  estimate_tokens of the live chain: ~#{est} est tokens (content only)"
puts "    the #{tools_b} B tools region (~#{tools_est} est tokens) is invisible to it"
puts format("  the system message alone: ~%d est tokens", sys_est)

kept = results.values.all? { |pre, tools| pre && tools }
puts
if kept
  puts "RESULT: PREFIX KEPT - every advisory fork is the chain it follows plus"
  puts "        its own trailing question, with the live turn's tool definitions."
  puts "        Whether the server then reuses its KV cache is measure.sh's question."
  exit 0
end

failed = results.filter_map do |name, (pre, tools)|
  next if pre && tools

  "#{name} (chain #{pre ? 'ok' : 'MISMATCH'}, tools #{tools ? 'ok' : 'MISMATCH'})"
end
puts "RESULT: PREFIX LOST - #{failed.join('; ')}"
exit 1
