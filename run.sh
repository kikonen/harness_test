#!/usr/bin/env bash
# Launcher: runs the harness from the caller's current directory (the
# working directory), regardless of where this script lives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .env lives next to this script (it holds HARNESS_MODEL etc.); fall back
# to the caller's CWD if there is no .env in the script directory.
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
elif [ -f .env ]; then
  set -a
  . .env
  set +a
fi

# Non-interactive shells may not have rbenv set up (no shims on PATH).
export RBENV_DIR="$SCRIPT_DIR"
if [ -d "$HOME/.rbenv/bin" ]; then
  export PATH="$HOME/.rbenv/bin:$PATH"
fi
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# bundle exec looks for the Gemfile in the CWD; point it at the one
# that lives next to this script so it works from any directory.
if [ -f "$SCRIPT_DIR/Gemfile" ]; then
  export BUNDLE_GEMFILE="$SCRIPT_DIR/Gemfile"
fi

exec bundle exec ruby "$SCRIPT_DIR/harness.rb" \
     --verbose \
     "$@"
