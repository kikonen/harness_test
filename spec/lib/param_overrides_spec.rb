# frozen_string_literal: true

require 'spec_helper'
require 'param_overrides'

# issue #219: session-level overrides for the adjustable LLM parameters.
# The override object owns the adjustable-parameter set, value parsing, the
# effective/default lookup, and re-application onto the shared options hash
# (which the LLM call and the compact trigger both read).
RSpec.describe ParamOverrides do
  # A profile like the ones SessionManager hands over: a hash of the active
  # model profile's values (nil keys mean "the profile leaves it unset", so
  # the server default applies).
  def profile(value: { reasoning_effort: 'medium', num_ctx: 65_536 })
    value
  end

  def build(opts = {}, prof: profile)
    described_class.new(opts, profile: -> { prof })
  end

  describe '#set / #effective (issue #219)' do
    it 'sets a session override that wins over the profile value' do
      opts = { reasoning_effort: 'medium' }
      po   = build(opts)

      po.set('reasoning_effort', 'low')

      expect(po.effective(:reasoning_effort)).to eq('low')
      expect(opts[:reasoning_effort]).to eq('low')
      expect(po.overridden?(:reasoning_effort)).to be(true)
    end

    it 'parses numeric parameters to their type' do
      opts = { num_ctx: 65_536 }
      po   = build(opts)

      po.set('num_ctx', '32768')

      expect(po.effective(:num_ctx)).to eq(32_768)
      expect(opts[:num_ctx]).to eq(32_768)
    end

    it 'accepts off for reasoning_effort (server default / no reasoning)' do
      opts = { reasoning_effort: 'medium' }
      po   = build(opts)

      po.set('reasoning_effort', 'off')

      expect(po.effective(:reasoning_effort)).to eq('off')
      expect(opts[:reasoning_effort]).to eq('off')
    end

    it 'reports the profile value when there is no override' do
      opts = { reasoning_effort: 'medium' }
      po   = build(opts)

      expect(po.effective(:reasoning_effort)).to eq('medium')
      expect(po.overridden?(:reasoning_effort)).to be(false)
    end

    it 'returns nil (server default) when neither override nor profile sets it' do
      opts = {}
      po   = build(opts, prof: profile(value: { reasoning_effort: nil }))

      expect(po.effective(:reasoning_effort)).to be_nil
      expect(po.reasoning_effort_display).to eq('off')
    end
  end

  describe '#set default (reset to the profile value)' do
    it 'removes the override and restores the profile value' do
      opts = { reasoning_effort: 'medium' }
      po   = build(opts)
      po.set('reasoning_effort', 'low')

      result = po.set('reasoning_effort', 'default')

      expect(po.effective(:reasoning_effort)).to eq('medium')
      expect(opts[:reasoning_effort]).to eq('medium')
      expect(po.overridden?(:reasoning_effort)).to be(false)
      expect(result).to include('reset')
    end
  end

  describe '#parse_value' do
    it 'raises HarnessError for a value the type cannot hold' do
      po = build({})

      expect { po.set('num_ctx', 'not-a-number') }
        .to raise_error(HarnessError, /invalid value for num_ctx/)
    end

    it 'raises HarnessError for an unknown parameter' do
      po = build({})

      expect { po.set('bogus', '1') }
        .to raise_error(HarnessError, /unknown parameter 'bogus'/)
    end
  end

  describe '#restore! (issue #219: keep winning after a profile change)' do
    it 're-applies overrides on top of freshly-applied profile values' do
      opts  = { reasoning_effort: 'medium' }
      po    = build(opts)
      po.set('reasoning_effort', 'low')

      # Simulate a /model switch: the profile resets the option.
      opts[:reasoning_effort] = 'high'

      po.restore!

      expect(opts[:reasoning_effort]).to eq('low')
      expect(po.effective(:reasoning_effort)).to eq('low')
    end
  end

  describe '#load / #to_h (issue #219: persist and restore with the session)' do
    it 'round-trips the overrides and re-applies them' do
      opts  = { reasoning_effort: 'medium' }
      po    = build(opts)
      po.set('reasoning_effort', 'low')
      po.set('num_ctx', '32768')

      # Simulate a save: to_h -> (JSON string keys) -> a fresh object.
      stored = JSON.parse(JSON.generate(po.to_h))
      fresh  = build({ reasoning_effort: 'high', num_ctx: 65_536 })
      fresh.load(stored)

      expect(fresh.overridden?(:reasoning_effort)).to be(true)
      expect(fresh.overridden?(:num_ctx)).to be(true)
      expect(fresh.effective(:reasoning_effort)).to eq('low')
      expect(fresh.effective(:num_ctx)).to eq(32_768)

      fresh.restore!
      expect(fresh.options[:reasoning_effort]).to eq('low')
      expect(fresh.options[:num_ctx]).to eq(32_768)
    end

    it 'tolerates a missing or malformed persisted hash' do
      po = build({})
      expect(po.load(nil)).to be_nil
      expect(po.overridden?(:reasoning_effort)).to be(false)
    end
  end

  describe '#display_value' do
    it 'shows off for an explicitly-unset reasoning effort and default for nil' do
      po = build({})
      expect(po.display_value('off')).to eq('off')
      expect(po.display_value(nil)).to eq('default')
      expect(po.display_value('low')).to eq('low')
    end
  end

  # issue #219: /param and /model share this listing, so the format must be
  # identical for both. It shows the config/profile value when a parameter is
  # not overridden (not just the overridden ones), and marks overrides.
  describe '#list_display (issue #219: shared by /param and /model)' do
    # The line for a given key (whitespace-tolerant).
    def line_for(lines, key)
      lines.find { |line| line.include?(key + ' ') }
    end

    it 'lists every parameter with the config value when not overridden' do
      po = build({ reasoning_effort: 'medium', num_ctx: 65_536 },
                 prof: profile(value: { reasoning_effort: 'medium', num_ctx: 65_536 }))

      lines = po.list_display

      expect(lines.first).to start_with('Model parameters')
      expect(line_for(lines, 'reasoning_effort')).to include('medium')
      expect(line_for(lines, 'num_ctx')).to include('65536')
      expect(lines).not_to include('(override)')
    end

    it 'shows the overridden value and marks it when a session override is set' do
      po = build({ reasoning_effort: 'medium' },
                 prof: profile(value: { reasoning_effort: 'medium' }))
      po.set('reasoning_effort', 'low')

      lines = po.list_display
      line  = line_for(lines, 'reasoning_effort')

      expect(line).to include('low')
      expect(line).to include('(override)')
    end
  end
end
