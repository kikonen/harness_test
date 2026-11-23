# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness do
  include HarnessSpecSupport

  describe '#session_log_path (issue #113)' do
    it 'resolves to .harness/sessions/<session-id>/harness.log' do
      harness = build_harness

      expected = File.join(workdir, Harness::HARNESS_DIR,
                           'sessions', harness.session.session_id,
                           Harness::SESSION_LOG_FILE)
      expect(harness.session_log_path).to eq(expected)
    end

    it 'creates the log file at the per-session path during #initialize' do
      harness = build_harness

      # issue #276: the id is settled BEFORE this object is built, so the
      # logger is built in #initialize - the file exists from construction
      # on, without anything having to ask for the logger first.
      expect(harness.logger).to be_a(Logger)
      expect(File.file?(harness.session_log_path)).to be true
    end

    it 'does not write to the legacy shared .harness/harness.log' do
      harness = build_harness
      harness.logger.info('per-session only')

      expect(File.exist?(File.join(workdir, Harness::HARNESS_DIR, 'harness.log'))).to be false
    end
  end

  # issue #276 replaced the #123 / #270 deferral machinery: the session id is
  # resolved before construction, so the logger and the client are built once,
  # under the id this run owns. There is no lazy accessor and no placeholder
  # a consumer could hold.
end

