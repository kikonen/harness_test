# frozen_string_literal: true

# Backward-compat shim (issue #74): the Dialog class now lives in the `UI`
# namespace (lib/ui/dialog.rb). This file exists only so that any existing
# `require 'dialog'` / `require_relative 'dialog'` keeps resolving; it pulls
# in the canonical namespaced implementation and the top-level `Dialog`
# alias. New code should `require 'ui'` and use UI::Dialog directly.
require_relative 'ui'
