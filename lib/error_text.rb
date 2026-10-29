# frozen_string_literal: true

# Shared formatting for reporting an exception. The console/outbox carry the
# one-line label; the session log carries the label plus the backtrace. A task
# thread owns no console (single-thread I/O rule), so why it logs the raise to
# the session log instead: doc/task_design.md.
module ErrorText
  # "Class: message" - the single line safe to interleave with turn output.
  def self.label(error)
    "#{error.class.name}: #{error.message}"
  end

  # The backtrace as text. Array(nil) is [], so a raise with no recorded
  # backtrace gets a placeholder rather than an empty tail.
  def self.backtrace(error)
    lines = Array(error.backtrace)
    lines.empty? ? "(no backtrace)" : lines.join("\n")
  end

  # msg + ": " + label on one line (the caller passes the bare message; the
  # separator belongs here), then the backtrace on the next - what the log
  # records for a raise.
  def self.detailed(error, msg = nil)
    head = msg ? "#{msg}: #{label(error)}" : label(error)
    "#{head}\n#{backtrace(error)}"
  end
end
