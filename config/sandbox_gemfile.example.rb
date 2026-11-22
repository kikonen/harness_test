# frozen_string_literal: true

# Project Ruby sandbox (issue #340): run a script through it with
#   BUNDLE_GEMFILE=.harness/sandbox/Gemfile bundle exec ruby script.rb
# Add a gem with `bundle add <gem>` (versioned: `bundle add <gem>
# --version ">= 1.19"`) and re-resolve with `bundle install`.
#
# These gems must already be on the box or the bundle cannot offline-lock.
# reline and fiddle are here because they stopped being Ruby default gems. A
# script that requires anything under lib/ also reaches kramdown-ansi, tins and
# nokogiri. The same text is both the repo default (copied on a FRESH seed only)
# and this run's own sandbox, which the harness never overwrites.
source "https://rubygems.org"

gem "csv"
gem "json"
gem "rexml"
gem "logger"
gem "racc"
gem "base64"
gem "fiddle"
gem "reline"
