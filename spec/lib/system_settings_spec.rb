# frozen_string_literal: true

require 'spec_helper'
require 'system_settings'

RSpec.describe SystemSettings do
  def build(options = {})
    described_class.from_options(options)
  end

  describe 'posture defaults (no options)' do
    it 'starts every posture at the conservative default' do
      s = build

      expect(s.yolo?).to be(false)
      expect(s.stream?).to be(false)
      expect(s.markdown?).to be(false)
      expect(s.command_safety_auto_approve).to be(false)
      expect(s.denylist_safe_approve?).to be(false)
      expect(s.output_palette.name).to eq('default')
    end

    it 'coerces truthy junk to OFF (only a literal true is ON)' do
      s = build(yolo: 'yes', stream: 1, markdown: 'true')

      expect(s.yolo?).to be(false)
      expect(s.stream?).to be(false)
      expect(s.markdown?).to be(false)
    end
  end

  describe 'output_palette (issue #303)' do
    it 'resolves a configured name to that palette' do
      expect(build(output_palette: 'basic16').output_palette.name).to eq('basic16')
      expect(build(output_palette: 'none').output_palette.name).to eq('none')
    end

    it 'rejects an unknown name at resolution' do
      expect { build(output_palette: 'crayola') }
        .to raise_error(HarnessError, /unknown output palette/)
    end

    it 'validates every write route through the same name check' do
      s = build
      expect { s.output_palette = 'crayola' }
        .to raise_error(HarnessError, /unknown output palette/)
      s.output_palette = 'none'
      expect(s.output_palette.name).to eq('none')
    end
  end

  describe 'command consent posture (#221 / #224 / #389)' do
    it 'labels MANUAL with nothing armed' do
      s = build(command_safety_check: true)

      expect(s.command_mode_label).to eq('MANUAL')
      expect(s.command_safety_auto_approve_effective?).to be(false)
    end

    it 'labels AUTO-APPROVE only when the check is on' do
      armed = build(command_safety_check: true, command_safety_auto_approve: true)
      off   = build(command_safety_check: false, command_safety_auto_approve: true)

      expect(armed.command_mode_label).to eq('AUTO-APPROVE')
      expect(armed.command_safety_auto_approve_effective?).to be(true)
      expect(off.command_mode_label).to eq('MANUAL')
      expect(off.command_safety_auto_approve_effective?).to be(false)
    end

    it 'YOLO wins over AUTO-APPROVE / MANUAL in the label' do
      s = build(command_safety_check: true, command_safety_auto_approve: true, yolo: true)

      expect(s.command_mode_label).to eq('YOLO')
    end

    it 'coerces the auto-approve setter to a boolean' do
      s = build
      s.command_safety_auto_approve = 'yes'
      expect(s.command_safety_auto_approve).to be(false)
      s.command_safety_auto_approve = true
      expect(s.command_safety_auto_approve).to be(true)
    end

    it 'carries the denylist-safe override as config-only state (#389)' do
      expect(build(denylist: true).denylist_safe_approve?).to be(false)
      s = build(command_safety_denylist_safe_approve: true)
      expect(s.denylist_safe_approve?).to be(true)
      # The override is NOT a third posture: it never changes the mode label.
      expect(s.command_mode_label).to eq('MANUAL')
    end
  end

  describe 'toggles return the new mode label' do
    it 'toggle_yolo flips and reports YOLO ON / OFF' do
      s = build

      expect(s.toggle_yolo).to eq('YOLO ON')
      expect(s.yolo?).to be(true)
      expect(s.toggle_yolo).to eq('YOLO OFF')
      expect(s.yolo?).to be(false)
    end

    it 'toggle_stream reports the badge only when ON, nil when OFF' do
      s = build

      expect(s.toggle_stream).to eq('STREAM')
      expect(s.stream_mode_label).to eq('STREAM')
      expect(s.toggle_stream).to be_nil
      expect(s.stream_mode_label).to be_nil
    end

    it 'toggle_markdown reports MARKDOWN ON / OFF (no badge posture)' do
      s = build

      expect(s.toggle_markdown).to eq('MARKDOWN ON')
      expect(s.markdown?).to be(true)
      expect(s.toggle_markdown).to eq('MARKDOWN OFF')
      expect(s.markdown?).to be(false)
    end

  end

  # Invariant #221: a resumed run's session-persisted postures win over the
  # config they were resolved from, and a key the session never carried keeps
  # its config value. The config-only flags are never touched by a resume.
  describe '#restore_persisted (resume precedence #221)' do
    it 'applies the saved postures over the resolved config' do
      s = build(yolo: false, stream: false, markdown: false, output_palette: 'default')
      s.restore_persisted({ yolo: true, stream: true, markdown: true, output_palette: 'none' })

      expect(s.yolo?).to be(true)
      expect(s.stream?).to be(true)
      expect(s.markdown?).to be(true)
      expect(s.output_palette.name).to eq('none')
    end

    it 'leaves a posture the session does not carry at its config value' do
      s = build(yolo: true, output_palette: 'basic16')
      # A session saved before markdown/palette existed has no key at all.
      s.restore_persisted({})

      expect(s.yolo?).to be(true)
      expect(s.output_palette.name).to eq('basic16')
    end

    it 'falls back to the default for a stored palette name this build lacks' do
      s = build(output_palette: 'default')
      s.restore_persisted({ output_palette: 'crayola' })

      expect(s.output_palette.name).to eq('default')
    end

    it 'never touches the config-only flags (auto-approve, denylist)' do
      s = build(command_safety_auto_approve: true,
                command_safety_denylist_safe_approve: true)
      s.restore_persisted({ command_safety_auto_approve: false })

      expect(s.command_safety_auto_approve).to be(true)
      expect(s.denylist_safe_approve?).to be(true)
    end
  end

  # The static model catalogue now lives here (#286): it is fixed config, but
  # read live off the shared @options so a profile switch that touches options
  # after construction is still seen (no stale snapshot).
  describe 'model catalogue (static config, issue #286)' do
    it 'is empty when no profiles are configured' do
      s = build

      expect(s.model_profiles).to eq([])
      expect(s.default_model).to be_nil
      expect(s.find_profile('anything')).to be_nil
    end

    it 'finds a profile by its label or its raw model id' do
      s = build(model_profiles: [{ name: 'local', model: 'qwen' }], default_model: 'local')

      expect(s.model_profiles.size).to eq(1)
      expect(s.default_model).to eq('local')
      expect(s.find_profile('local')[:model]).to eq('qwen')
      expect(s.find_profile('qwen')[:name]).to eq('local')
    end
  end
end
