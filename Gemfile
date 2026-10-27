# frozen_string_literal: true

source 'https://rubygems.org'

# Gems that are default gems today but will no longer ship with Ruby
# starting from Ruby 3.5.0. Declaring them here silences the
# "will no longer be part of the default gems" warnings.
gem 'logger'
gem 'fiddle'

gem 'racc'

gem 'debug'

# Nicer object inspection for debugging: `ap` prints with indentation and
# colors, then returns the value (issue #186).
gem 'amazing_print'

# Terminal UI (issue #74 / #13): inline TUI primitives for the spinner
# and, later, the dialogs.
gem 'ratatui_ruby'

# Markdown -> ANSI RENDERER for assistant answers (issue #106), by kramdown's own
# author. Preserves inline emphasis (bold/italic/code) - the point of rendering
# markdown. Its ansi_styles are seeded from UI::Palette so colors match the
# harness' own roles; a 'none' palette strips the ANSI (see UI::MarkdownRenderer).
gem 'kramdown-ansi', '~> 0.7'

group :development do
  gem 'rspec'

  # House-rule enforcement (issue #302): the mechanical part of harness.md
  # (line length, indentation, frozen_string_literal, string literals,
  # trailing whitespace) is a cop set here rather than a habit each session
  # has to remember. Opinionated cops are disabled in .rubocop.yml.
  gem 'rubocop', '~> 1.92'
end
