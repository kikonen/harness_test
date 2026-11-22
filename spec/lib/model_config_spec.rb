# frozen_string_literal: true

require 'spec_helper'
require 'model_config'
require 'system_settings'

# A profile carries a model: (#572) - the model its endpoint is asked for, never
# its id or display name. These specs pin what a ModelConfig seeds, switches and
# keeps when a profile is applied.
RSpec.describe ModelConfig do
  def settings(options)
    SystemSettings.from_options(options)
  end

  describe '.from_settings' do
    it 'seeds the model from the profile the run selected' do
      config = described_class.from_settings(
        settings(model_profiles: [{ id: 'local', url: 'http://host.test/v1', model: 'local-model' }],
                 active_profile_id: 'local'))

      expect(config.model).to eq('local-model')
      expect(config.active_profile_name).to eq('local')
      expect(config.base_url).to eq('http://host.test/v1')
    end

    # A config default leaves the SELECTION nil so a session saves nil and a
    # later change of the default still applies; HarnessFactory is what writes
    # the resolved default into a job's own ModelConfig.
    it 'leaves the selection nil when only the config default is set' do
      config = described_class.from_settings(
        settings(model_profiles: [{ id: 'default', url: 'http://host.test/v1', model: 'default-model' }],
                 default_profile_id: 'default'))

      expect(config.active_profile_id).to be_nil
      expect(config.base_url).to eq('http://host.test/v1')
    end

    it 'leaves the model nil with no profiles and no selection' do
      config = described_class.from_settings(settings({}))

      expect(config.model).to be_nil
      expect(config.active_profile_id).to be_nil
      expect(config.active_profile_name).to be_nil
      expect(config.base_url).to be_nil
    end
  end

  describe '#apply_profile' do
    it 'writes the profile model:' do
      config = described_class.new({ active_profile_id: 'old' })
      config.apply_profile({ id: 'new', url: 'http://host.test/v1', model: 'new-model' })

      expect(config.model).to eq('new-model')
      expect(config.active_profile_id).to eq('new')
      expect(config.base_url).to eq('http://host.test/v1')
    end

    # A switch takes the endpoint from the profile it switched to, not from the
    # previous model's server (every profile carries its own url, #556).
    it 'points the endpoint at the new profile url' do
      config = described_class.new({ base_url: 'http://first.test/v1' })
      config.apply_profile({ id: 'second', url: 'http://second.test/v1', model: 'second-model' })

      expect(config.base_url).to eq('http://second.test/v1')
      expect(config.active_profile_id).to eq('second')
      expect(config.model).to eq('second-model')
    end
  end
end
