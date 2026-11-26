# frozen_string_literal: true

require_relative "queued_event"

# EventQueue: one job's event queue (issue #286 step 2; design:
# doc/unified_loop_design.md). Two zones:
#
# - INBOX: a Thread::Queue - the cross-thread arrival channel (post is legal
#   from any thread; pop blocks with a timeout).
# - STAGED: a plain Array - the worker-owned working window. Ruby's
#   Thread::Queue has no peek (measured), so peeking, per-kind processing
#   windows, the note-overrides-note admission rule and discard-up-to-:stop
#   all live on the staged array, never on the inbox.
#
# Ownership: post is thread-safe; admit/peek/dispatch/discard belong to the
# worker thread. pending_kinds answers the main thread's posting questions
# without exposing the staged array itself.
class EventQueue
  # A staged event is processable in the current window when the worker may
  # run it NOW: control kinds always (they end work), payload and block kinds
  # only inside the windows the caller declares.
  def initialize
    @inbox  = Thread::Queue.new
    @staged = []
  end

  # Thread-safe arrival. Returns the event so a poster can keep the reference.
  def post(event)
    @inbox << event
    event
  end

  # Block until one event arrives (or the timeout passes) and move it into the
  # staged array. Returns the admitted event, or nil on timeout.
  def admit_next(timeout: nil)
    begin
      event = @inbox.pop(true)
    rescue ThreadError
      event = @inbox.pop(false, timeout:)
      return nil if event.nil?
    end
    @staged << event
    event
  end

  # Drain everything already arrived (non-blocking) and admit it. Returns the
  # count admitted - the worker calls this before deciding what to run.
  def admit_arrived
    admitted = 0
    loop do
      event = @inbox.pop(true)
      @staged << event
      admitted += 1
    rescue ThreadError
      break
    end
    admitted
  end

  # The next staged event that is processable in the window of kinds the worker
  # currently accepts (control kinds are always processable). nil when nothing
  # staged qualifies - the rest stays staged, in arrival order.
  def peek_processable(accepted_kinds: [])
    @staged.find do |event|
      event.control_kind? || accepted_kinds.include?(event.kind)
    end
  end

  # Remove one staged event from the array (the dispatch step takes it out of
  # the window). Returns the event, or nil when it was not staged.
  def dispatch(event)
    @staged.delete(event)
  end

  # Discard staged work up to and INCLUDING the first event of +kind+ (the
  # :stop rule: work queued before a stop is dead, events after it survive).
  # Returns the discarded events.
  def discard_up_to(kind)
    index = @staged.index { |event| event.kind == kind }
    return [] if index.nil?

    @staged.slice!(0..index)
  end

  # Kinds currently staged (duplicates kept, arrival order): the main thread's
  # posting-rule snapshot. A fresh array, so the caller cannot touch the queue.
  def pending_kinds
    @staged.map(&:kind)
  end

  def staged_size
    @staged.size
  end

  def inbox_empty?
    @inbox.empty?
  end

  def staged_empty?
    @staged.empty?
  end
end
