#!/bin/sh
# Issue #345: no truncation signal anywhere - finish_reason is captured by the
# streaming accumulator and then thrown away. Evidence is grep-based, so this
# script is the repro (no ruby probe needed).
# Run from the repo root: sh analysis/345/measure.sh
set -u

echo "== finish_reason appears only in the accumulator and its spec =="
grep -rn finish_reason lib/

echo
echo "== the attr_reader is never called anywhere =="
grep -rn "\.finish_reason" lib/ spec/ \
  || echo "(no hits: nothing reads StreamAccumulator#finish_reason)"
