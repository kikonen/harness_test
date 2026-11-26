# frozen_string_literal: true

require 'queued_event'

# QueuedEvent: the PORO a job's EventQueue carries (issue #286 step 1). These
# specs pin the shape contract only - the queue rules live in EventQueue's own
# spec.
RSpec.describe QueuedEvent do
  describe 'shape contract' do
    it 'a payload kind carries its text' do
      ev = described_class.build(kind: :prompt, job_id: 3, payload: 'hello')

      expect(ev.kind).to eq(:prompt)
      expect(ev.job_id).to eq(3)
      expect(ev.payload).to eq('hello')
      expect(ev.block).to be_nil
      expect(ev).to be_payload_kind
      expect(ev).not_to be_block_kind
      expect(ev).not_to be_control_kind
    end

    it 'a control kind carries neither payload nor block' do
      ev = described_class.build(kind: :stop, job_id: 0)

      expect(ev).to be_control_kind
      expect(ev.payload).to be_nil
      expect(ev.block).to be_nil
    end

    it 'a block kind carries the sender-owned Proc' do
      blk = -> { :work }
      ev = described_class.build(kind: :compact, job_id: 1, block: blk)

      expect(ev).to be_block_kind
      expect(ev.block).to equal(blk)
      expect(ev.payload).to be_nil
    end
  end

  describe 'rejected shapes (programming errors, not runtime surprises)' do
    it 'rejects an unknown kind' do
      expect { described_class.build(kind: :frobnicate, job_id: 0) }
        .to raise_error(ArgumentError, /unknown queued event kind/)
    end

    it 'rejects a payload kind with no text' do
      expect { described_class.build(kind: :note, job_id: 0) }
        .to raise_error(ArgumentError, /:note event needs payload text/)
      expect { described_class.build(kind: :note, job_id: 0, payload: '  ') }
        .to raise_error(ArgumentError, /:note event needs payload text/)
    end

    it 'rejects a block kind with no Proc' do
      expect { described_class.build(kind: :retry, job_id: 0) }
        .to raise_error(ArgumentError, /:retry event needs a block/)
      expect { described_class.build(kind: :retry, job_id: 0, block: 'text') }
        .to raise_error(ArgumentError, /:retry event needs a block/)
    end

    it 'rejects a control kind smuggled with a block' do
      expect { described_class.build(kind: :stop, job_id: 0, block: -> {}) }
        .to raise_error(ArgumentError, /control event carries no payload or block/)
    end
  end

  describe 'kind classification (the queue rules read these)' do
    it 'classifies every declared kind into exactly one group' do
      groups = described_class::KINDS.map do |kind|
        [kind,
         described_class.payload_kind?(kind),
         described_class.block_kind?(kind),
         described_class::CONTROL_KINDS.include?(kind)]
      end

      groups.each do |kind, payload, block, control|
        expect([payload, block, control].count(true)).to eq(1),
          "#{kind} must be in exactly one kind group"
      end
    end
  end
end
