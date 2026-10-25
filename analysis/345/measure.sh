#!/bin/sh
# Issue #345: no truncation signal anywhere - finish_reason was captured by the
# streaming accumulator and then thrown away. Run from the repo root:
#   sh analysis/345/measure.sh
# BEFORE the fix (master before #345), the two greps below printed:
#   grep -rn finish_reason lib/            -> ONLY lib/llm/stream_accumulator.rb
#   grep -rn "\.finish_reason" lib/ spec/  -> nothing: the attr_reader was dead
# and `grep -rn done_reason lib/ spec/` - the NATIVE field, the one the buffered
# Ollama path would have had to read - printed nothing at all either.
# AFTER the fix each grep prints what now carries the value; design:
# doc/truncation_design.md.
set -u

echo "== finish_reason is read on BOTH paths and reaches the normalized shape =="
grep -rn "finish_reason" lib/

echo
echo "== the native field (done_reason) is read too =="
grep -rn "done_reason" lib/

echo
echo "== the harness consumes it: a non-normal end gets a console line + a log line =="
grep -n "report_finish_reason\|data\[:finish_reason\]\|cut off by the token budget" lib/harness.rb

echo
echo "== and a call that lost its arguments to the cut is not reported as malformed =="
grep -n "truncated: true\|truncated:\|NOT executed" lib/harness.rb

echo
echo "== the reader is no longer dead: a spec asserts the value mid-stream =="
grep -rn "\.finish_reason" spec/ || echo "(no hits: nothing reads StreamAccumulator#finish_reason)"
