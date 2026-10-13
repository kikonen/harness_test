# frozen_string_literal: true

require_relative '../command'

module Commands
  # /retry - re-send the session message chain (after a failed request).
  #
  # issue #235: the re-send is an LLM round (spinner, tool loop, dialogs),
  # so it MUST run on a Task thread like any other prompt. Running it
  # synchronously on the main thread broke the single-thread I/O rule
  # (issue #40): no spinner was driven and any dialog blocked the console,
  # leaving it looking totally stuck even though the work was progressing
  # (only the log moved). Wrapping it in Task.run routes all console I/O
  # through the main-thread drain loop, exactly as a normal prompt does.
  class RetryCommand < Command
    def handle(_args)
      ui.puts
      error, _task = Task.run(harness: @harness, ui: @ui) do |_t|
        @harness.session_manager.retry
      end
      ui.puts "  [task error] #{error}" if error
      ui.puts
    end
  end
end
