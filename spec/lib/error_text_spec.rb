# frozen_string_literal: true

require 'spec_helper'
require 'error_text'

RSpec.describe ErrorText do
  # A real exception, with its own backtrace recorded at the raise point.
  def raised
    raise ArgumentError, 'bad value'
  rescue StandardError => e
    e
  end

  describe '.label' do
    it 'is the bare "Class: message" line' do
      expect(described_class.label(raised)).to eq('ArgumentError: bad value')
    end
  end

  describe '.backtrace' do
    it 'joins the recorded frames onto separate lines' do
      expect(described_class.backtrace(raised)).to include('error_text_spec.rb')
      expect(described_class.backtrace(raised)).not_to include("\n\n")
    end

    it 'shows a placeholder when no backtrace was recorded' do
      e = RuntimeError.new('no trace')
      allow(e).to receive(:backtrace).and_return(nil)

      expect(described_class.backtrace(e)).to eq('(no backtrace)')
    end
  end

  describe '.detailed' do
    it 'renders msg + ": " + label, then the backtrace on the next line' do
      line = described_class.detailed(raised, 'task thread raised')

      expect(line).to start_with("task thread raised: ArgumentError: bad value\n")
      expect(line).to include('error_text_spec.rb')
    end

    it 'omits the separator when no msg is given' do
      line = described_class.detailed(raised)

      expect(line).to start_with("ArgumentError: bad value\n")
    end
  end
end
