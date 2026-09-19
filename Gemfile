# frozen_string_literal: true

# Gemfile — dependency management for the harness via Bundler.
#
# The harness currently runs on the Ruby standard library only (net/http,
# json, optparse, fileutils, ...). As the project grows and needs external
# gems, declare them here and run `bundle install`. `run.sh` launches the
# harness through `bundle exec`, so any gem listed below will be available.
#
# Usage:
#   bundle install          # install/update gems from this file
#   bundle exec ruby harness.rb ...   # (run.sh already does this)

source 'https://rubygems.org'

# Pin the Ruby version the project is developed against (optional but
# recommended). Uncomment and adjust to match your environment.
# ruby '>= 3.0'

# -- Runtime dependencies -------------------------------------------------
# Add external gems the harness needs at runtime here, e.g.:
#
# gem 'faraday'
# gem 'typhoeus'
#
# (Nothing is required yet — the harness uses only the standard library.)

# -- Development / test dependencies --------------------------------------
# group :development, :test do
#   gem 'rspec'
#   gem 'rubocop'
# end
