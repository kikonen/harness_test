# frozen_string_literal: true

require 'spec_helper'
require 'harness_config'

RSpec.describe HarnessConfig do
  # The template is the repo file config/config.example.yml (issue #215
  # follow-up): no embedded copy in the code to drift from it.
  let(:template) { File.read(described_class::TEMPLATE_FILE) }

  describe '#auto_save_enabled (issue #107)' do
    it 'defaults to true when the key is absent' do
      expect(described_class.new({}).auto_save_enabled).to be(true)
    end

    it 'honours an explicit true' do
      expect(described_class.new(auto_save: true).auto_save_enabled).to be(true)
    end

    it 'honours an explicit false' do
      expect(described_class.new(auto_save: false).auto_save_enabled).to be(false)
    end

    it 'treats non-boolean values as disabled' do
      expect(described_class.new(auto_save: 'no').auto_save_enabled).to be(false)
      expect(described_class.new(auto_save: nil).auto_save_enabled).to be(true)
    end

    it 'includes the auto_save key in the default template' do
      expect(template).to include('auto_save: true')
    end
  end

  describe '#double_enter_submit_enabled (issue #198)' do
    it 'defaults to false when the key is absent (Enter never submits)' do
      expect(described_class.new({}).double_enter_submit_enabled).to be(false)
      expect(described_class.new(double_enter_submit: nil)
                             .double_enter_submit_enabled).to be(false)
    end

    it 'honours an explicit true (opt-in double-Enter submit)' do
      expect(described_class.new(double_enter_submit: true)
                             .double_enter_submit_enabled).to be(true)
    end

    it 'mentions the key in the default template (commented out)' do
      expect(template).to include('double_enter_submit')
    end
  end

  describe '#compact_reserved_tokens (issue #151)' do
    it 'defaults to nil when the key is absent (built-in default applies)' do
      expect(described_class.new({}).compact_reserved_tokens).to be_nil
    end

    it 'reads the compact.reserved_tokens key' do
      cfg = described_class.new(compact: { reserved_tokens: 16_384 })
      expect(cfg.compact_reserved_tokens).to eq(16_384)
    end

    it 'includes reserved_tokens in the default template' do
      expect(template).to include('reserved_tokens: 8192')
    end
  end

  describe '#max_tool_iterations (issue #226)' do
    it 'defaults to nil when the key is absent (built-in default applies)' do
      expect(described_class.new({}).max_tool_iterations).to be_nil
    end

    it 'reads the max_tool_iterations key' do
      expect(described_class.new(max_tool_iterations: 42).max_tool_iterations).to eq(42)
    end

    it 'coerces an integer-valued string to an integer' do
      expect(described_class.new(max_tool_iterations: '42').max_tool_iterations).to eq(42)
    end

    it 'raises on a non-integer value' do
      expect { described_class.new(max_tool_iterations: 'many') }
        .to raise_error(HarnessError, /expected an integer/)
    end

    it 'mentions the key in the default template' do
      expect(template).to include('max_tool_iterations')
    end
  end

  describe '#output_palette_name (issue #303)' do
    it 'defaults to nil when the key is absent (the default palette applies)' do
      expect(described_class.new({}).output_palette_name).to be_nil
    end

    it 'reads the output_palette key as a name' do
      expect(described_class.new(output_palette: 'basic16').output_palette_name).to eq('basic16')
    end

    it 'treats a blank value as absent' do
      expect(described_class.new(output_palette: '   ').output_palette_name).to be_nil
    end

    it 'mentions the key in the default template' do
      expect(template).to include('output_palette')
    end
  end

  describe '#editor_command (issue #298)' do
    it 'is nil when the key is absent (Ctrl+G stays Reline\'s own key)' do
      expect(described_class.new({}).editor_command).to be_nil
    end

    it 'reads the editor key as a command string' do
      expect(described_class.new(editor: 'nvim -R').editor_command).to eq('nvim -R')
    end

    it 'treats a blank value as absent' do
      expect(described_class.new(editor: '   ').editor_command).to be_nil
    end

    it 'mentions the key in the default template' do
      expect(template).to include('editor:')
      expect(template).to include('HARNESS_EDITOR')
    end
  end

  describe '#system_prompt_file (issue #223)' do
    it 'defaults to nil when the key is absent (built-in default file is used)' do
      expect(described_class.new({}).system_prompt_file).to be_nil
    end

    it 'reads the system_prompt_file key' do
      expect(described_class.new(system_prompt_file: 'prompts/my.txt')
                            .system_prompt_file).to eq('prompts/my.txt')
    end

    it 'normalises a blank value to nil' do
      expect(described_class.new(system_prompt_file: '   ').system_prompt_file).to be_nil
    end
  end
  describe '#command_safety_check (issue #224)' do
    it 'defaults to disabled when the key is absent' do
      expect(described_class.new({}).command_safety_check_enabled).to be false
    end

    it 'reads the command_safety_check key' do
      expect(described_class.new(command_safety_check: true)
                            .command_safety_check_enabled).to be true
    end

    it 'treats any non-true value as disabled' do
      expect(described_class.new(command_safety_check: 'yes').command_safety_check_enabled)
        .to be(false)
    end
  end

  describe '#command_safety_auto_approve (issue #224 follow-up)' do
    it 'defaults to disabled when the key is absent (MANUAL consent)' do
      expect(described_class.new({}).command_safety_auto_approve_enabled)
        .to be(false)
    end

    it 'reads the command_safety_auto_approve key' do
      expect(described_class.new(command_safety_auto_approve: true)
                            .command_safety_auto_approve_enabled).to be(true)
    end

    it 'mentions the key in the default template (commented out)' do
      expect(template).to include('command_safety_auto_approve')
    end
  end

  # issue #389: command_safety_auto_approve as ONE enum key for both relaxations
  # (manual | safe | denylist | safe_denylist), with a legacy true/false still
  # read as safe/manual and the separate denylist boolean ORed in. An
  # unrecognised value is a config error - a posture must never fall back
  # silently in either direction.
  describe '#command_safety_auto_approve enum (issue #389)' do
    it 'defaults to manual when the key is absent (floor stays absolute)' do
      cfg = described_class.new({})
      expect(cfg.command_safety_auto_approve_enabled).to be(false)
      expect(cfg.command_safety_denylist_safe_approve_enabled).to be(false)
    end

    it 'reads each mode into its two halves' do
      {
        'manual'        => [false, false],
        'safe'          => [true,  false],
        'denylist'      => [false, true],
        'safe_denylist' => [true,  true]
      }.each do |mode, (approve, denylist)|
        cfg = described_class.new(command_safety_auto_approve: mode)
        expect(cfg.command_safety_auto_approve_enabled).to be(approve), mode
        expect(cfg.command_safety_denylist_safe_approve_enabled).to be(denylist), mode
      end
    end

    it 'reads a legacy boolean: true = safe, false = manual' do
      legacy = described_class.new(command_safety_auto_approve: true)
      expect(legacy.command_safety_auto_approve_enabled).to be(true)
      expect(legacy.command_safety_denylist_safe_approve_enabled).to be(false)
      manual = described_class.new(command_safety_auto_approve: false)
      expect(manual.command_safety_auto_approve_enabled).to be(false)
    end

    it 'accepts the mode name case- and whitespace-insensitively' do
      cfg = described_class.new(command_safety_auto_approve: ' Safe_Denylist ')
      expect(cfg.command_safety_auto_approve_enabled).to be(true)
      expect(cfg.command_safety_denylist_safe_approve_enabled).to be(true)
    end

    it 'raises on an unrecognised mode rather than falling back silently' do
      expect { described_class.new(command_safety_auto_approve: 'yes') }
        .to raise_error(HarnessError, /command_safety_auto_approve must be one of/)
    end

    it 'ORs the separate denylist boolean into the enum (two-key style works)' do
      cfg = described_class.new(command_safety_auto_approve: 'safe',
                                command_safety_denylist_safe_approve: true)
      expect(cfg.command_safety_auto_approve_enabled).to be(true)
      expect(cfg.command_safety_denylist_safe_approve_enabled).to be(true)
    end

    it 'keeps the denylist half off when the separate key is not a literal true' do
      cfg = described_class.new(command_safety_denylist_safe_approve: 'yes')
      expect(cfg.command_safety_denylist_safe_approve_enabled).to be(false)
    end

    it 'mentions the key in the default template (commented out)' do
      expect(template).to include('command_safety_denylist_safe_approve')
    end
  end

  describe 'model profile api key (issue #197)' do
    it 'reads the api key from a model profile' do
      cfg = described_class.new(models: [
        { name: 'oll', url: 'http://localhost:11434',
          model: 'qwen', api: 'ollama' }
      ])
      expect(cfg.models.first[:api]).to eq('ollama')
    end

    it 'leaves api nil when the key is absent (client defaults to openai)' do
      cfg = described_class.new(models: [
        { name: 'open', url: 'http://localhost:11434/v1', model: 'qwen' }
      ])
      expect(cfg.models.first[:api]).to be_nil
    end
  end

  # issue #221: the two consent-posture keys. YOLO is opt-in (default OFF -
  # the harness never assumes the user wants consent removed); bang
  # confirmation defaults to ON (today's behavior) and is turned off
  # explicitly.
  describe '#yolo_enabled? / #bang_requires_confirmation? (issue #221)' do
    it 'defaults yolo to off and bang confirmation to on' do
      cfg = described_class.new({})
      expect(cfg.yolo_enabled?).to be(false)
      expect(cfg.bang_requires_confirmation?).to be(true)
    end

    it 'reads the yolo key' do
      expect(described_class.new(yolo: true).yolo_enabled?).to be(true)
      # A truthy junk value must not enable YOLO (same coercion as everywhere
      # else in consent state).
      expect(described_class.new(yolo: 'yes').yolo_enabled?).to be(false)
      expect(described_class.new(yolo: nil).yolo_enabled?).to be(false)
    end

    it 'reads the bang_requires_confirmation key' do
      expect(described_class.new(bang_requires_confirmation: false)
                            .bang_requires_confirmation?).to be(false)
      expect(described_class.new(bang_requires_confirmation: true)
                            .bang_requires_confirmation?).to be(true)
      # nil = key absent = the ON default (only an explicit false disables).
      expect(described_class.new(bang_requires_confirmation: nil)
                            .bang_requires_confirmation?).to be(true)
      expect(described_class.new(bang_requires_confirmation: 'no')
                            .bang_requires_confirmation?).to be(false)
    end

    it 'mentions both keys in the default template (commented out)' do
      expect(template).to include('yolo:')
      expect(template).to include('bang_requires_confirmation')
    end
  end

  # issue #28: the streaming posture. Opt-in (default OFF): a server or proxy
  # that mishandles a streamed response must keep working with no config at
  # all. A profile's own key is tri-state so it can OVERRIDE the global one in
  # either direction.
  describe '#streaming_enabled? / profile streaming key (issue #28)' do
    it 'defaults to off' do
      expect(described_class.new({}).streaming_enabled?).to be(false)
    end

    it 'reads the global streaming key' do
      expect(described_class.new(streaming: true).streaming_enabled?).to be(true)
      # Truthy junk does not enable it (same coercion as every other posture).
      expect(described_class.new(streaming: 'yes').streaming_enabled?).to be(false)
      expect(described_class.new(streaming: nil).streaming_enabled?).to be(false)
    end

    it 'reads a profile streaming key' do
      cfg = described_class.new(models: [{ name: 'a', streaming: true }])

      expect(cfg.models.first[:streaming]).to be(true)
    end

    # nil means "this profile says nothing", so the global key decides; false
    # means "this profile opts out", so it overrides a global true.
    it 'leaves the profile key nil when absent, and false when set false' do
      cfg = described_class.new(models: [
        { name: 'silent' },
        { name: 'off', streaming: false },
        { name: 'on', streaming: true }
      ])

      expect(cfg.models.map { |m| m[:streaming] }).to eq([nil, false, true])
    end

    it 'mentions the key in the default template (commented out)' do
      expect(template).to include('streaming')
    end
  end

  # issue #33: web.fetch may not connect to a private / loopback / link-local
  # address unless the USER asked for it. It is a user-side posture like yolo:
  # no tool argument reaches it.
  describe '#web_fetch_allow_private? (issue #33)' do
    it 'defaults to off' do
      expect(described_class.new({}).web_fetch_allow_private?).to be(false)
    end

    it 'reads the key' do
      expect(described_class.new(web_fetch_allow_private: true).web_fetch_allow_private?).to be(true)
      expect(described_class.new(web_fetch_allow_private: false).web_fetch_allow_private?).to be(false)
      # Truthy junk does not enable it (same coercion as every other posture).
      expect(described_class.new(web_fetch_allow_private: 'yes').web_fetch_allow_private?).to be(false)
      expect(described_class.new(web_fetch_allow_private: nil).web_fetch_allow_private?).to be(false)
    end

    it 'mentions the key in the default template (commented out)' do
      expect(template).to include('web_fetch_allow_private')
      # The template must say what it does NOT lift, or it reads as a general
      # "allow local network" switch.
      expect(template).to include('link-local')
      expect(template).to include('Opt-in')
    end
  end
end
