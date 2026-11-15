# frozen_string_literal: true

# The requester: the object that asks the main thread for something and blocks on
# its own inbox for the answer. Design: doc/task_model_design.md.
module Requester
  # Task is checked FIRST so every existing pin that stubs Task.current holds.
  def self.current
    (defined?(Task) ? Task.current : nil) || Thread.current[:harness_sub_agent]
  end

  # An input event that arrives while a request is unanswered must queue BEHIND
  # the answer, so the job is marked awaiting until the answer lands.
  def request(type, **payload)
    job&.mark_awaiting(true)
    push_event(type: :__request__, kind: type, **payload)
    reply = inbox.pop
    if reply.equal?(Job::STOP)
      raise "requester was stopped while waiting for response to '#{type}'"
    end

    reply
  end

  # Main thread only. The awaiting flag clears WITH the answer, so a request is
  # never answered after an input event has already been delivered to the inbox.
  def respond(value)
    job&.mark_awaiting(false)
    inbox << value
  end

  # Implemented by Task and SubAgent: the job the requester runs for, the inbox an
  # answer is delivered to, and the way out to the ONE queue.
  def job
    raise NotImplementedError, "#{self.class}#job not implemented"
  end

  def inbox
    job.inbox
  end

  def push_event(**event)
    raise NotImplementedError, "#{self.class}#push_event not implemented"
  end
end
