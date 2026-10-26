#!/bin/sh
# Issue #246: "could compact be just started based in top of cached context".
# Run from the repo root:
#   sh analysis/246/measure.sh
# The harness-side half (is each advisory fork a byte-identical extension of the
# request it follows, chain AND tools payload) is measured by repro.rb and needs
# no model server:
#   ruby analysis/246/repro.rb
# This script shows WHERE each fork is built, WHERE the cache-hit fields are read,
# prints what a real session's harness.log already proved, and then asks a LIVE
# server the one question this checkout cannot answer (no server: 127.0.0.1:11434
# and :8080 are refused).
set -u

echo "== the single source of the tool definitions every request sends =="
grep -n "def tools_payload" -A 3 lib/harness.rb

echo
echo "== the three advisory forks and what each sends =="
grep -n "tools: @harness.tools_payload" lib/session_manager.rb
grep -n "data = client.chat(fork" lib/safety_check.rb
grep -n "tools: tools_payload, logger:" lib/harness.rb
grep -n "tools: harness_tools" lib/command_runner.rb

echo "== a compact request adds ONE message to the prompt it follows =="
grep -n "Do NOT call any tools" lib/session_manager.rb

echo
echo "== the fields a cache hit would show are already parsed and printed =="
grep -n "cached_tokens" lib/llm/usage_stats.rb
grep -n "prompt_eval_cached_count" lib/llm/ollama_backend.rb
grep -n "cached_tokens" lib/llm/openai_backend.rb

echo
echo "== what a real session's harness.log already proved (pre-fix code) =="
cat <<'EOF'
  In-loop compaction, read out of a live session log (OpenAI-compatible server):

    22:02:18 RESP: ... 113587 -> 738 tokens            (the turn's own round)
    22:02:18 REQ: POST .../v1/chat/completions (359048 bytes, attempt 1/3)
    22:03:40 RESP: ... 107347 -> 1976 tokens  [INFO] in-loop compaction: 259 -> 4
               timings: {"cache_n": 0, "prompt_n": 107347, "prompt_ms": 59016.3}
    22:03:40 REQ: POST .../v1/chat/completions (33413 bytes, streaming)
    22:03:47 RESP: ... 8312 -> 107 tokens              (the post-compact turn)

  The summary call prefilled 107 347 tokens with ZERO reuse: 59.0 s inside an
  82.2 s request, while the 4-message chain that followed prefilled in 6.9 s.
  Reproduce it from any session log:

    grep -a -B 4 -a "in-loop compaction:\|session compacted:" .harness/sessions/<id>/harness.log
    grep -a "RESP:.*cached" .harness/sessions/<id>/harness.log

  A cached_tokens / prompt_eval_cached_count of 0 on a large prompt is the
  signature of a cold re-prefill; "N cached" on the stats line is the same number.
EOF

echo
echo "== the live question: does the extension actually reuse the KV cache? =="
BASE=${OLLAMA_BASE:-http://127.0.0.1:11434}
if ! ruby -rsocket -e 'TCPSocket.new("127.0.0.1", 11434).close' 2>/dev/null; then
  echo "  no server answering at $BASE - SKIPPED (this is the expected output in a"
  echo "  checkout; the measurement belongs on a box with ollama/llama.cpp running)"
  exit 0
fi

cat <<'EOF'
  A server answers. Send these four requests against ONE model in sequence and
  read prompt_eval_count / prompt_eval_cached_count (or prompt_tokens /
  prompt_tokens_details.cached_tokens on /v1) from each - the harness prints the
  same pair as "N cached" on the stats line and in the RESP: log line:

  1. a long first request: chain + tools.
  2. the SAME chain plus ONE trailing user message, SAME tools -> the cached count
     should rise to nearly the whole prompt. This is what a compact is now.
  3. the same extension, tools OMITTED -> if the cached count collapses, the
     tools region was part of the prefix and the fix is what mattered.
  4. the same extension with message 0 dropped (what compact did before #246) ->
     the cached count should collapse too.

  Compare 2 against 3 and 4. If 2 shows no cache reuse either, the prefix is not
  what the server keys on and #246 stays open: the remaining harness-side
  difference to test next is the buffered path building a fresh KeepAliveHTTP per
  call (BaseBackend#chat_buffered) while the streamed path reuses one.
EOF
