# frozen_string_literal: true

# The `UI` module namespaces the harness's terminal-UI primitives (issue
# #74 / #13): a single, encapsulated home for the scattered puts/print/
# $stdin I/O, in contrast to a flat top-level namespace. Each primitive
# lives in its own file under lib/ui/, mirrored by spec/lib/ui/.
#
# Spinner is the first primitive; Dialog and friends are expected to join
# this namespace next.
module UI; end

require_relative 'ui/spinner'
