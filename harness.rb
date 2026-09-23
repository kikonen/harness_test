# frozen_string_literal: true
#
# harness.rb — interactive AI edit harness. Any OpenAI-compatible server.
# Supports tool calling (iterative), file editing via tools, and direct prompts.
#
# Usage:
#   ruby harness.rb -m qwen2.5-coder:32b
#   ruby harness.rb -m my-model --base-url http://192.168.1.10:8000/v1 --token sk-abc123
#   ruby harness.rb -m my-model -f src/app.rb -f lib/util.rb
#   ruby harness.rb -m my-model -d /path/to/project -f src/app.rb
#   ruby harness.rb -m my-model --resume ab12cd34
#   HARNESS_TOKEN=sk-abc123 ruby harness.rb -m gpt-4o
#
# All file access (allowed file list, /file command, file tools, log and
# history files) is relative to the working directory (-d / --workdir,
# default: the current directory).
#
# The session (conversation + file list) is auto-saved to .sessions/ on
# exit; the resume command is printed. Resume it with -r / --resume <id>.

LOG_FILE = ENV['HARNESS_LOG_FILE'] || 'harness.log'

require 'debug'

require_relative 'lib/cli'

# -- Entry point ----------------------------------------------------------

begin
  CLI.new.run
rescue HarnessError => e
  puts "Error: #{e.message}"
  exit 1
rescue Interrupt
  puts "\nGoodbye."
  exit 0
end
