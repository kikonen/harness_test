# frozen_string_literal: true

require 'spec_helper'
require 'llm/shared'

# backend_type is the one branch in LLM::Shared: every other member is a
# constant the backends read as-is, and the constants are what the request
# builders of both backends are measured against, so they are pinned here.
RSpec.describe LLM do
  describe '.backend_type' do
    it 'selects the native Ollama backend for "ollama"' do
      expect(LLM.backend_type('ollama')).to eq(LLM::OLLAMA)
      expect(LLM.backend_type('ollama')).to be(:ollama)
    end

    it 'accepts the value with surrounding whitespace' do
      expect(LLM.backend_type('  ollama  ')).to eq(LLM::OLLAMA)
    end

    it 'falls back to the OpenAI-compatible backend for any other name' do
      expect(LLM.backend_type('openai')).to eq(LLM::OPENAI)
      expect(LLM.backend_type('openrouter')).to eq(LLM::OPENAI)
      expect(LLM.backend_type('')).to eq(LLM::OPENAI)
    end

    it 'falls back to the OpenAI-compatible backend when no api key is set' do
      expect(LLM.backend_type(nil)).to eq(LLM::OPENAI)
    end

    it 'accepts a symbol as well as a string' do
      expect(LLM.backend_type(:ollama)).to eq(LLM::OLLAMA)
      expect(LLM.backend_type(:openai)).to eq(LLM::OPENAI)
    end
  end

  describe 'backend constants' do
    it 'names the two selectable API types' do
      expect(LLM::OPENAI).to be(:openai)
      expect(LLM::OLLAMA).to be(:ollama)
    end
  end

  describe 'timeout and keep-alive constants' do
    # A tool round between two requests easily exceeds Net::HTTP's own 2s
    # idle limit, so the kept-alive socket must outlive it.
    it 'keeps an idle connection alive longer than Net::HTTP would' do
      expect(LLM::KEEP_ALIVE_TIMEOUT).to be > 2
    end

    it 'waits longer for the response than for the connection' do
      expect(LLM::DEFAULT_READ_TIMEOUT).to be > LLM::DEFAULT_OPEN_TIMEOUT
    end
  end

  describe 'retry constants' do
    it 'retries at least once (RETRY_COUNT counts the initial attempt)' do
      expect(LLM::RETRY_COUNT).to be >= 2
      expect(LLM::RETRY_DELAY).to be > 0
    end

    # Only errors that mean the request never completed are retried: a retry
    # of a completed request would send the tool call twice.
    it 'lists only transient network errors' do
      expect(LLM::RETRYABLE_ERRORS).to include(Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout)
      expect(LLM::RETRYABLE_ERRORS).not_to include(LLMError)
      expect(LLM::RETRYABLE_ERRORS).to be_frozen
    end
  end

  describe 'context window constant' do
    it 'is a window size large enough to need auto-compact accounting' do
      expect(LLM::NUM_CTX).to be > 4096
    end
  end
end
