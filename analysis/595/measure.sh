#!/bin/sh
# Issue #595: count a session's spill files per producing tool, from a fresh clone.
# Usage: sh analysis/595/measure.sh [session_dir]   (default: this project's own session)
set -e
dir=${1:-.harness/sessions/f7931611-30b4-4b4b-aec6-f7083ef2942a}
echo "session: $dir"
for results in "$dir"/jobs/*/results; do
  [ -d "$results" ] || continue
  echo "--- $results"
  echo "files: $(ls "$results" | wc -l)  bytes: $(du -sb "$results" | cut -f1)"
  ls "$results" | sed 's/-[0-9]*\.txt$//' | sort | uniq -c | sort -rn
done
