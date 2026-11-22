# frozen_string_literal: true

# Spec helper: load the harness library from lib/.
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'tins/terminal'
require 'ui/console'
require 'ui/dialog'
require 'file_list'
require 'harness'
require 'session'
require 'tools/dialog_tool'

# The terminal width specs wrap at. Specs assert exact WRAPPED text, so that
# width must be a spec fact, never the machine's: Tins' last-resort answer is
# this box's real terminal (176 here, something else in CI), so a wrapped spec
# could pass locally and fail in CI. 176 is the width the suite was written
# against (renderer_spec: "the default basis at a 176-col terminal is 120").
# Detection itself stays live - a spec about detection (width_spec, spinner_spec)
# must still see a StringIO answer nil. A spec wanting another terminal stubs
# UI::Width itself.
SPEC_TERMINAL_COLUMNS = 176
Tins::Terminal.define_singleton_method(:columns) { SPEC_TERMINAL_COLUMNS }

RSpec.configure do |config|
  # Keep specs deterministic and independent of execution order.
  config.order = :random
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
