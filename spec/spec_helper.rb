# frozen_string_literal: true

# Spec helper: load the harness library from lib/.
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'ui/console'
require 'ui/dialog'
require 'file_list'
require 'harness'
require 'session'
require 'tools/dialog_tool'

RSpec.configure do |config|
  # Keep specs deterministic and independent of execution order.
  config.order = :random
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end