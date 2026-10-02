# frozen_string_literal: true

# Backward-compat shim (issue #74): the Spinner class now lives in the `UI`
# namespace (lib/ui/spinner.rb). This file exists only so that any existing
# `require 'spinner'` / `require_relative 'spinner'` keeps resolving; it pulls
# in the canonical namespaced implementation and the top-level `Spinner`
# alias. New code should `require 'ui'` and use UI::Spinner directly.
require_relative 'ui'
