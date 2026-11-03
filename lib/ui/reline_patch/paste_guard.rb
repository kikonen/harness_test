# frozen_string_literal: true

# Shared paste guard for the Enter and LF submit patches: the last time a
# paste was observed. Any Enter/LF inside or just after a paste inserts a
# newline instead of submitting. Design: doc/editor_input_design.md.
module UI
  module RelinePatch
    module PasteGuard
      GRACE = 0.05

      @last_seen = nil

      class << self
        def mark
          @last_seen = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def clear!
          @last_seen = nil
        end

        def recent?
          return false if @last_seen.nil?

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          now - @last_seen < GRACE
        end
      end
    end
  end
end
