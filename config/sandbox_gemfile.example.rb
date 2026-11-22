# frozen_string_literal: true

# The DEFAULT project Ruby sandbox (issue #340). Harness copies this file to
# .harness/sandbox/Gemfile on a FRESH seed only - an existing sandbox is the
# run's own and is never overwritten. That copy is plain text, so edit it here
# to change what a new run starts with. Run scripts through it with:
#   BUNDLE_GEMFILE=.harness/sandbox/Gemfile bundle exec ruby script.rb
# Add a gem on demand with `bundle add <gem>` (versioned: `bundle add <gem>
# --version ">= 1.19"`) and re-resolve with `bundle install`.
#
# A gem listed here must already be on the box or a fresh seed cannot offline-lock.
# reline and fiddle are listed because they stopped being Ruby default gems, and
# the whole list is what requiring lib/**.rb actually needs.
source "https://rubygems.org"

gem "csv"
gem "json"
gem "rexml"
gem "logger"
gem "racc"
gem "base64"
gem "fiddle"
gem "reline"
