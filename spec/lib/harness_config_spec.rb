# frozen_string_literal: true

require 'spec_helper'
require 'harness_config'

RSpec.describe HarnessConfig do
  describe '#auto_save_enabled (issue #107)' do
    it 'defaults to true when the key is absent' do
      expect(described_class.new({}).auto_save_enabled).to be(true)
    end

    it 'honours an explicit true' do
      expect(described_class.new('auto_save' => true).auto_save_enabled).to be(true)
    end

    it 'honours an explicit false' do
      expect(described_class.new('auto_save' => false).auto_save_enabled).to be(false)
    end

    it 'treats non-boolean values as disabled' do
      expect(described_class.new('auto_save' => 'no').auto_save_enabled).to be(false)
      expect(described_class.new('auto_save' => nil).auto_save_enabled).to be(true)
    end

    it 'includes the auto_save key in the default template' do
      expect(described_class::DEFAULT_TEMPLATE).to include('auto_save: true')
    end
  end
end
