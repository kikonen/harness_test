# frozen_string_literal: true

require_relative "job"

# A request event: a main-thread command's ask to a LIVE turn (#286 increment 4).
# It travels as the loop's :__request__ control type with this class's KIND, so a
# command never hand-builds a control envelope. The loop routes it onto the
# worker's own delivery queue - the channel WORK and STOP already use, so the
# Thread::Queue is the synchronization and no mailbox flag or mutex is needed.
# The worker parks on it and the next turn runs the work. Fire-and-forget: unlike
# a dialog request there is no reply to answer.
class RequestEvent
  KIND = :compact

  def self.request?(msg)
    msg[:kind] == KIND
  end

  def self.deliver?(item)
    item.is_a?(Hash) && item[:type] == :__request__ && item[:kind] == KIND
  end
end
