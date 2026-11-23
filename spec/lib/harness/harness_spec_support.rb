# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'spec_helper'
require "harness"
require 'job_registry'

# Shared scaffolding for the split Harness specs (spec/lib/harness/*_spec.rb).
# Included by each scoped file; the per-example workdir and the SandboxGemfile
# stub are RSpec hooks, so they live in the module body.
module HarnessSpecSupport
  extend RSpec::SharedContext
  # An un-started Task is enough to capture Task.emit events: a Task now always
  # runs on a registry + job (#286), so build the smallest real one (one main job)
  # and drain its queue like the real drain loop does.
  def emit_task
    registry = JobRegistry.new
    job = registry.add_job(kind: :main)
    Task.new(registry:, job:)
  end

  let(:workdir) { Dir.mktmpdir('harness-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  # Every fresh seed would otherwise spawn a real `bundle lock` subprocess
  # (~1s each x ~160 build_harness calls) AND make the wiring asserts depend
  # on which gems the runner box happens to have. Stub it to a fixed value;
  # the real offline lock is proven by real subprocess in sandbox_gemfile_spec.
  before { allow_any_instance_of(SandboxGemfile).to receive(:lock_seeded?).and_return(true) }

  # Fake LLM client shared by the call_llm coverage below: records every
  # message chain it is called with and answers from a SCRIPTED queue.
  # Each item is either a tool round (a hash with :tool_calls), a final
  # answer ({ content: }), or :fail (raises LLMError - simulating a lost
  # connection mid-turn, issue #208). Anything left in the queue at the end
  # defaults to a final 'done' answer.
  class FakeScriptedClient
    # Mirrors LLMClient#chat: the caller decides per request whether the
    # response streams (issue #28), so the streaming kwargs are accepted.
    # @calls records the chain; @stream_flags / @on_deltas record what each
    # request was given, so a spec can assert WHICH posture was used.
    attr_reader :calls, :stream_flags, :on_deltas, :tool_payloads

    # Optional hook run after each call, so a spec can change harness state
    # BETWEEN the requests of one turn (e.g. a mid-turn /stream toggle).
    attr_accessor :after_call

    def initialize(responses = [{ content: 'done', reasoning: nil }])
      @calls        = []
      @stream_flags = []
      @on_deltas    = []
      @tool_payloads = []
      @responses = responses
    end

    def chat(messages, tools: nil, timeout: nil, stream: false, on_delta: nil)
      @calls << messages.map { |m| m.dup }
      @stream_flags << stream
      @on_deltas   << on_delta
      @tool_payloads << tools
      response = @responses.shift || { content: 'done' }
      raise LLMError, 'connection lost mid-turn' if response == :fail

      message = response.is_a?(Hash) ? response : { content: 'done' }
      # finish_reason is a top-level part of the normalized shape (issue #345),
      # so a scripted response names it the way the backends return it.
      finish = message.is_a?(Hash) ? message.delete(:finish_reason) : nil
      result = { choices: [{ message: message.merge(reasoning: nil) }],
                 usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }
      result[:finish_reason] = finish if finish
      # The hook runs AFTER the answer is built, so a spec can flip harness
      # state between this request and the next one of the same turn.
      @after_call&.call
      result
    end
  end

  def build_harness(options = {})
    file_list = FileList.new([], workdir: workdir)
    # system_file points at the built-in default so the base prompt file is
    # resolved (issue #223); num_ctx fixed so context indicators are stable.
    opts = { system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE,
             num_ctx: 65_536 }.merge(options)
    # session_id / resume_data are constructor keywords (issue #276: the id is
    # settled before the Harness exists), not LLM options, so they are pulled
    # out of the options hash and passed where they belong.
    session_id  = opts.delete(:session_id)
    resume_data = opts.delete(:resume_data)
    # Per-connection model values (num_ctx/base_url/api/...) belong to a model
    # PROFILE, not to settings (#286). A spec that pins them gets a single
    # profile declaring them, named for the model it asks for, so the Harness
    # seeds its ModelConfig exactly as a config-resolved run does. A spec that
    # already supplies model_profiles is left alone.
    add_seed_profile(opts)
    # Mirror CLI: SystemSettings is resolved from the run's options (the posture/
    # consent state lives there now) and passed to the Harness. For a resumed run
    # the four session-persisted postures are applied over it by
    # Harness#apply_resume_state (SystemSettings#restore_persisted), so the saved
    # choice wins over the config (#221); the config-only flags stay as resolved.
    Harness.new(file_list, settings: SystemSettings.from_options(opts),
                        session_id: session_id, resume_data: resume_data)
  end

  # The per-connection model values a spec pins, folded into one profile so the
  # Harness seeds ModelConfig the way a config-resolved run does (#286).
  PER_CONNECTION_KEYS = %i[
    num_ctx base_url api token vision max_tokens num_predict reasoning_effort
    temperature top_p top_k min_p presence_penalty repeat_penalty
  ].freeze

  def add_seed_profile(opts)
    return if opts.key?(:model_profiles)

    requested = opts[:model] || 'test-model'
    declared  = PER_CONNECTION_KEYS.select { |k| opts.key?(k) }
    return if declared.empty?

    profile = { name: requested, id: requested }
    declared.each { |k| profile[k == :base_url ? :url : k] = opts[k] }
    opts[:model_profiles] = [profile]
    opts[:active_profile_id]   = requested
    (declared + %i[base_url model]).each { |k| opts.delete(k) }
  end

  # The on-disk path of a session id in this spec's workdir (#207 layout).
  def session_path(id, name = SessionLocator::SESSION_LOG_FILE)
    File.join(workdir, SessionLocator::SESSIONS_DIR, id, name)
  end

  def saved_session_ids
    Dir.children(File.join(workdir, SessionLocator::SESSIONS_DIR))
  end

  # A harness whose client plays a scripted response sequence (see
  # FakeScriptedClient) - the call_llm specs use it to drive multi-
  # round tool loops and mid-loop failures.
  def build_harness_with_responses(responses = [{ content: 'done', reasoning: nil }], options = {})
    h = build_harness(options)
    h.instance_variable_set(:@client, FakeScriptedClient.new(responses))
    h
  end

  # A module-nested class is not lexically visible from an including example
  # group, so specs build the fake through this method instead.
  def fake_scripted_client(responses = [{ content: 'done', reasoning: nil }])
    FakeScriptedClient.new(responses)
  end

  def seed_usage(harness, prompt_tokens)
    harness.session.add_user('hello')
    harness.session.add_assistant('hi')
    harness.session.record_stats(usage: { prompt_tokens: prompt_tokens, total_tokens: prompt_tokens + 867 })
  end

  def drained_lines(task)
    lines = []
    loop do
      m = task.poll(0); break unless m
      lines << m[:content]
    end
    lines
  end

end
