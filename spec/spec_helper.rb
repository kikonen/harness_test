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

RSpec.configure do |config|
  # Specs assert exact WRAPPED text, so the width they wrap at must be a spec
  # fact, never the machine's. The machine-dependent hop is Tins' last-resort
  # answer (this box reports 176, CI reports something else), so it is pinned -
  # at 176, the width the suite was written against (renderer_spec: "the default
  # basis at a 176-col terminal is 120"). Detection itself stays live: a spec
  # about detection (width_spec, spinner_spec) must still see a StringIO answer
  # nil. A spec wanting another terminal stubs UI::Width itself.
  SPEC_TERMINAL_COLUMNS = 176
  Tins::Terminal.define_singleton_method(:columns) { SPEC_TERMINAL_COLUMNS }

  # Keep specs deterministic and independent of execution order.
  config.order = :random
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
