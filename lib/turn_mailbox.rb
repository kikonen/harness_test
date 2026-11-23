# frozen_string_literal: true

require_relative "tool"

# The mid-turn note and save-request mailbox (issue #582), extracted from
# Harness so the turn, SessionManager and the main thread all talk to this
# object instead of reaching into the harness. Written by the main thread and
# read-and-cleared on the JOB's own thread; every cross-thread touch takes the
# mutex or the write can be lost.
class TurnMailbox
  # The console line naming WHY a mid-turn note could not be applied (:late -
  # the answer was already being written; :leftover - the turn that received it
  # died before any request could take it).
  NOTE_DISCARD_MESSAGES = {
    late: "arrived too late to steer this answer - it was NOT sent to the model. " \
      "Send it again if you still mean it.",
    leftover: "was left over from your previous turn and never reached the model - " \
      "it is NOT applied. Send it again if you still mean it."
  }.freeze

  def initialize(logger)
    @logger         = logger
    @lock           = Mutex.new
    @user_note      = nil
    @save_requested = false
  end

  def request_save
    @lock.synchronize { @save_requested = true }
  end

  def save_requested?
    @lock.synchronize { @save_requested == true }
  end

  # Consume a save request set on another thread (nil when there is none).
  def take_save_request
    @lock.synchronize do
      next nil unless @save_requested

      @save_requested = false
      true
    end
  end

  # Consume the in-flight note (the latest line won; nil when there is none).
  def take_user_note
    @lock.synchronize do
      note = @user_note
      @user_note = nil
      note
    end
  end

  # Only one note is in flight: the latest line wins.
  def user_note_text=(text)
    note = text.to_s.strip
    @lock.synchronize do
      @user_note = note.empty? ? nil : note
    end
  end

  # A note still pending when a turn ends is dropped here, not injected into
  # the next prompt as a phantom mid-turn note - only a finished turn can tell
  # a late note from a usable one.
  def discard_pending_user_note(kind)
    note = take_user_note
    return nil if note.nil?

    @logger.warn "user mid-turn note discarded (#{kind}): #{note}"
    Tool.push_status(
      label: "note",
      verdict: :warn,
      # It must also name WHICH note, or the user can't tell which line to resend.
      message: "#{NOTE_DISCARD_MESSAGES.fetch(kind)} The note was: #{note}")
    note
  end
end
