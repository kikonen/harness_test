# frozen_string_literal: true

require 'spec_helper'
require 'model_config'
require 'system_settings'

# A model profile has ONE identity: its name is both the selection key and the
# id the endpoint is asked for (#556 - the second identity, the profile's own
# 'model:' key, is what let a run carry a model with no endpoint until the
# request itself blew up). These specs pin what a ModelConfig seeds, switches
# and keeps when a profile is applied.
RSpec.describe ModelConfig do
  def settings(options)
    SystemSettings.from_options(options)
  end

  describe '.from_settings' do
    it 'names the model after the profile the run selected' do
      config = described_class.from_settings(
        settings(model_profiles: [{ name: 'local', url: 'http://host.test/v1' }],
                 active_profile_id: 'local'))

      expect(config.active_profile_name).to eq('local')
      expect(config.base_url).to eq('http://host.test/v1')
    end

    # A config default leaves the SELECTION nil so a session saves nil and a
    # later change of the default still applies; HarnessFactory is what writes
    # the resolved default name into a job's own ModelConfig.
    it 'leaves the model nil when only the config default is set' do
      config = described_class.from_settings(
        settings(model_profiles: [{ name: 'default', url: 'http://host.test/v1' }],
                 default_profile_id: 'default'))

      expect(config.active_profile_id).to be_nil
      expect(config.base_url).to eq('http://host.test/v1')
    end

    it 'carries no model value of its own' do
      config = described_class.from_settings(
        settings(model_profiles: [{ name: 'local', url: 'http://host.test/v1' }]))

      expect(config).not_to respond_to(:model)
    end

    it 'leaves the model nil with no profiles and no selection' do
      config = described_class.from_settings(settings({}))

      expect(config.active_profile_id).to be_nil
      expect(config.active_profile_name).to be_nil
      expect(config.base_url).to be_nil
    end
  end

  describe '#apply_profile' do
    it 'writes the profile name as the model' do
      config = described_class.new({ active_profile_id: 'old' })
      config.apply_profile({ name: 'new', url: 'http://host.test/v1' })

      expect(config.active_profile_id).to eq('new')
      expect(config.base_url).to eq('http://host.test/v1')
    end

    # A profile declaring no url says nothing about the endpoint: a switch that
    # silently pointed at the previous model's server would send the new model's
    # id to the wrong host.
    it 'leaves the endpoint alone when the profile declares no url' do
      config = described_class.new({ base_url: 'http://first.test/v1' })
      config.apply_profile({ name: 'second', id: 'second' })

      expect(config.base_url).to eq('http://first.test/v1')
      expect(config.active_profile_id).to eq('second')
    end
  end
end
