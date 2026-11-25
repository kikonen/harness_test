# frozen_string_literal: true

require 'spec_helper'
require 'turn_mailbox'
require 'session_logger'

RSpec.describe TurnMailbox do
  def mailbox
    TurnMailbox.new(SessionLogger.build(File::NULL))
  end

  describe 'save requests' do
    it 'consumes a save request once' do
      box = mailbox
      box.request_save

      expect(box.save_requested?).to be true
      expect(box.take_save_request).to be true
      expect(box.take_save_request).to be_nil
    end
  end

  describe 'notes' do
    it 'keeps only the latest note' do
      box = mailbox
      box.user_note_text = 'first'
      box.user_note_text = 'second'

      expect(box.take_user_note).to eq('second')
      expect(box.take_user_note).to be_nil
    end

    it 'discards a pending note with a status line' do
      box = mailbox
      box.user_note_text = 'too late'
      box.discard_pending_user_note(:late)

      expect(box.take_user_note).to be_nil
    end
  end
end
