# frozen_string_literal: true

source "https://rubygems.org"

# Gems that are default gems today but will no longer ship with Ruby
# starting from Ruby 3.5.0. Declaring them here silences the
# "will no longer be part of the default gems" warnings.
gem "logger"
gem "fiddle"

gem "racc"

gem "debug"

# Nicer object inspection for debugging: `ap` prints with indentation and
# colors, then returns the value (issue #186).
gem "amazing_print"

# Terminal UI (issue #74 / #13): inline TUI primitives for the spinner
# and, later, the dialogs.
gem "ratatui_ruby"

# Markdown -> ANSI RENDERER for assistant answers (issue #106), by kramdown"s own
# author. Preserves inline emphasis (bold/italic/code) - the point of rendering
# markdown. Its ansi_styles are seeded from UI::Palette so colors match the
# harness" own roles; a "none" palette strips the ANSI (see UI::MarkdownRenderer).
gem "kramdown-ansi" #, "~> 0.7"
gem "kramdown"
gem "tins"
gem "unicode-emoji"

#gem "reverse_markdown"
#gem "tty-markdown"

# MCP client (issue #48): the official Model Context Protocol Ruby SDK. Used ONLY
# when the user declares mcp_servers: in the config - the gem is required lazily
# (see Harness#load_mcp_tools), so a run with no MCP servers never loads it.
gem "mcp", "~> 1.8"

# The mcp gem"s client requires base64, which stopped being a default gem in
# Ruby 3.4 - without it `require "mcp"` raises LoadError under bundler.
gem "base64"

# The mcp gem"s CLIENT HTTP transport (issue #402) needs faraday the same lazy
# way: MCP::Client::HTTP#require_faraday!. faraday is NOT a declared dependency
# of mcp 1.8.2 (only json_schemer is), so without this line a url entry in
# mcp_servers: fails at connect, and not with the gem's own LoadError hint - the
# NameError for the unresolved Faraday constant in its rescue clauses fires
# first (measured on mcp 1.8.2 / ruby 4.0.7: "uninitialized constant
# MCP::Client::HTTP::Faraday"). A stdio-only setup never loads it, so listing
# it costs one entry in the bundle, not a startup path.
gem "faraday", ">= 2.0"

group :development do
  gem "rspec"

  # House-rule enforcement (issue #302): the mechanical part of harness.md
  # (line length, indentation, frozen_string_literal, string literals,
  # trailing whitespace) is a cop set here rather than a habit each session
  # has to remember. Opinionated cops are disabled in .rubocop.yml.
  gem "rubocop", "~> 1.92"

  # Parallel test runner (issue #396): the whole suite across processes. Local-only
  # - CI stays serial (its runners have 2 cores, so the gain there is small).
  # Reached through bare `bin/rspec`, not the raw executable: the gem assumes a
  # bin/rspec binstub is RUBY and ours is bash (bin/rspec sets
  # PARALLEL_TESTS_EXECUTABLE for that reason).
  gem "parallel_tests", "~> 5.8"
end
