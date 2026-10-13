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
end
