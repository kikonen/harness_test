#!/bin/sh
# Issue #246: "could compact be just started based in top of cached context".
# Run from the repo root:
#   sh analysis/246/measure.sh
# The harness-side half (is the compact summary call a byte-identical prefix of
# the request it follows) is measured by repro.rb and needs no model server:
#   ruby analysis/246/repro.rb
# This script shows WHERE the two compact chains are built, WHERE the cache-hit
# fields would be read, and then asks a LIVE server the one question this
# checkout cannot answer (no server: 127.0.0.1:11434 / :8080 are refused).
set -u

echo "== both compact paths build the summary chain as messages[1..] =="
grep -n "messages\[1\.\.\]" lib/session_manager.rb
grep -n "conversation is expected WITHOUT the system message" lib/session_manager.rb

echo
echo "== the system message itself is NOT discarded from the session =="
grep -n "system_message" lib/session.rb

echo
echo "== the fork the harness already sends is documented as a cache hit =="
grep -n "the fork's prefix IS the main prefix" doc/safety_check_design.md

echo
echo "== and the fields a cache hit would show are already parsed and printed =="
grep -n "cached_tokens" lib/llm/usage_stats.rb
grep -n "prompt_eval_cached_count" lib/llm/ollama_backend.rb
grep -n "cached_tokens" lib/llm/openai_backend.rb

echo
echo "== the live question: does a prefix-extension of the chain reuse the KV cache? =="
BASE=${OLLAMA_BASE:-http://127.0.0.1:11434}
if ! ruby -rsocket -e 'TCPSocket.new("127.0.0.1", 11434).close' 2>/dev/null; then
  echo "  no server answering at $BASE - SKIPPED (this is the expected output in a"
  echo "  checkout; the measurement belongs on a box with ollama/llama.cpp running)"
  exit 0
fi

cat <<'EOF'
  A server answers. Run this twice and read prompt_eval_count /
  prompt_eval_cached_count from each response (the harness prints the same pair
  as "N cached" on the stats line and in the RESP: log line):

  1. send a long first request, then a second request whose messages are the
     first request's EXACT chain plus one new user message -> the cached count
     should rise to nearly the whole prompt.
  2. same, but the second request drops message 0 (what compact does today) ->
     compare the cached count. If it collapses to ~0, the summary call prefills
     cold and #246's premise is confirmed.
  3. repeat with tools SENT vs tools OMITTED on both requests (the payload the
     live turn sends but neither fork sends - issue #238). If omitting the
     tools changes the cached count, no fork is cheap while the tools differ,
     and #238 must be settled before #246 can pay off.
EOF
