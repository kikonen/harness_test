# frozen_string_literal: true

# A queued event: the unit of work a job's EventQueue carries (issue #286,
# doc/unified_loop_design.md). It is a PORO - kind + payload or kind + block -
# so the queue can reason about it: kind drives admission, ordering, override
# and discard rules; nothing can be reasoned about a bare Ruby block, which is
# why a block rides INSIDE this value instead of being the item itself.
#
# Two shapes:
# - payload kinds are pipeline verbs the worker itself knows how to run
#   (:prompt text, :note text, :stop, :shutdown);
# - block kinds are sender-owned behaviour (:compact, :retry): the sender
#   states WHAT to do, the worker decides WHEN it is legal to do it.
class QueuedEvent
  # Pipeline verbs: the payload carries the text; :stop/:shutdown carry none.
  PAYLOAD_KINDS = %i[prompt note].freeze
  # Control verbs: end-of-work signals, no payload, no block.
  CONTROL_KINDS = %i[stop shutdown].freeze
  # Sender-owned behaviour: the block carries it.
  BLOCK_KINDS = %i[compact retry].freeze

  KINDS = (PAYLOAD_KINDS + CONTROL_KINDS + BLOCK_KINDS).freeze

  Event = Struct.new(:kind, :job_id, :payload, :block, keyword_init: true) do
    def payload_kind?
      PAYLOAD_KINDS.include?(kind)
    end

    def control_kind?
      CONTROL_KINDS.include?(kind)
    end

    def block_kind?
      BLOCK_KINDS.include?(kind)
    end
  end

  # One queued event. The shape rules are the queue's contract: a payload kind
  # carries text, a block kind carries a Proc, a control kind carries neither.
  # A block kind given a non-Proc (or a payload kind given no text) is a
  # programming error, raised here rather than discovered at dispatch time.
  def self.build(kind:, job_id:, payload: nil, block: nil)
    unless KINDS.include?(kind)
      raise ArgumentError, "unknown queued event kind #{kind.inspect}"
    end

    if payload_kind?(kind) && payload.to_s.strip.empty?
      raise ArgumentError, "a :#{kind} event needs payload text"
    end

    if block_kind?(kind) && !block.is_a?(Proc)
      raise ArgumentError, "a :#{kind} event needs a block"
    end

    if control_kind?(kind) && (!payload.nil? || !block.nil?)
      raise ArgumentError, "a :#{kind} control event carries no payload or block"
    end

    Event.new(kind:, job_id:, payload:, block:)
  end

  def self.payload_kind?(kind)
    PAYLOAD_KINDS.include?(kind)
  end

  def self.block_kind?(kind)
    BLOCK_KINDS.include?(kind)
  end

  def self.control_kind?(kind)
    CONTROL_KINDS.include?(kind)
  end
end
