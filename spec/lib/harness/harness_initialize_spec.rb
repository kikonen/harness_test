# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness, 'startup and construction (issue #276)' do
  include HarnessSpecSupport

  describe '#initialize logger (issue #276)' do
    it 'has a real logger from #initialize on every path' do
      fresh  = build_harness
      resume = build_harness(session_id: 'f7931611-30b4-4b4b-aec6-f7083ef2942a')

      [fresh, resume].each do |harness|
        expect(harness.logger).to be_a(Logger)
        expect(harness.instance_variable_get(:@logger)).to be_a(Logger)
      end
    end

    it 'logs under the id it was given, not under a fresh random one' do
      id      = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      harness = build_harness(session_id: id)
      harness.logger.info('startup line')

      expect(harness.locator.session_id).to eq(id)
      expect(File.read(harness.locator.session_log_path)).to include('startup line')
      # #555: a run that saved nothing mints no session dir (the log lives
      # outside sessions/), so #123's throwaway dir cannot appear at all.
      expect(saved_session_ids).to eq([])
    end

    it 'gives the LLM client the real logger, never a placeholder' do
      harness = build_harness(auto_save: false, verbose: false)

      expect(harness.client.backend.logger).to equal(harness.logger)
    end

    # The log path itself is SessionLocator's (spec/lib/session_locator_spec.rb);
    # what construction owns is that the injected logger's file exists from
    # #initialize on, with nothing asked for first (issue #276).
    it 'writes the injected logger at its per-session path (issue #113)' do
      harness = build_harness

      expect(harness.logger).to be_a(Logger)
      expect(File.file?(harness.locator.session_log_path)).to be true
    end

    it 'never writes the legacy shared .harness/harness.log' do
      harness = build_harness
      harness.logger.info('per-session only')

      expect(File.exist?(File.join(workdir, Harness::HARNESS_DIR, 'harness.log'))).to be false
    end

    it 'logs the first request without any lazy path running' do
      # The #270 failure shape, asserted against the real fix: the backend
      # logs on the first attempt of every request, and the logger it holds
      # is the one built at construction.
      harness = build_harness(auto_save: false, verbose: false,
                              base_url: 'http://127.0.0.1:1/v1', api: :openai,
                              retry_count: 1, retry_delay: 0)

      # Port 1: nothing listens. The request fails on connect, but only AFTER
      # the backend has logged its attempt - that log line is the point.
      expect {
        harness.client.chat([{ role: 'user', content: 'hi' }])
      }.to raise_error(LLMError)

      log = File.read(harness.locator.session_log_path)
      expect(log).to include('REQ: POST').and include('attempt 1/')
    end
  end

  # issue #276 / #280: a resumed run - startup OR mid-run /resume - is one
  # Harness built under the settled id, so log, history and session dir all
  # carry that single identity and no rebind exists anywhere.
  describe 'startup resume via resume_data (issue #276)' do
    def seed_saved_session(id, yolo: true, output_palette: 'basic16', stream: true,
                           markdown: false, saved_mcp: nil, foreground_job: nil)
      FileUtils.mkdir_p(File.dirname(session_path(id, SessionLocator::SESSION_FILE)))
      data = {
        session_id:    id,
        created_at:    Time.now.iso8601,
        system_prompt: 'saved prompt',
        user_prompts:  2,
        messages:      [{ role: 'system', content: 'saved prompt' },
                        { role: 'user', content: 'earlier' },
                        { role: 'assistant', content: 'reply' }],
        yolo:          yolo,
        output_palette: output_palette,
        stream:        stream,
        markdown:      markdown,
        workdir:       workdir
      }
      # A session saved before issue #405 has no mcp_connected key at all; nil
      # models that so the resume side has to tolerate its absence.
      data[:mcp_connected] = saved_mcp if saved_mcp
      # A session saved before issue #286 has no foreground key at all, which
      # the resume side reads as the default (job #0).
      data[:foreground_job] = foreground_job if foreground_job
      File.write(session_path(id, SessionLocator::SESSION_FILE), JSON.generate(data))
    end

    def saved_data(id)
      JSON.parse(File.read(session_path(id, SessionLocator::SESSION_FILE)),
                 symbolize_names: true)
    end

    it 'restores the conversation and the YOLO posture under the settled id' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, yolo: true)

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.locator.session_id).to eq(id)
      expect(harness.session.messages.map { |m| m[:content] }).to include('earlier')
      # The posture the session was saved with wins over the config initial
      # posture (#221 rule), and it is applied DURING construction - not by a
      # later resume call that would then need a logger rebind.
      expect(harness.settings.yolo?).to be(true)
      expect(harness.logger).to be_a(Logger)
      expect(harness.locator.session_log_path).to include(id)
      # Only the resumed session's directory exists (issues #123 / #135).
      expect(saved_session_ids).to eq([id])
    end

    # issue #28: the streaming posture the user chose for THIS session must
    # survive the round trip - a session they set to streamed must not come
    # back buffered (the same rule as the YOLO posture).
    it 'restores the streaming posture the session was saved with' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, stream: true)

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.settings.stream?).to be(true)
      expect(harness.settings.stream_mode_label).to eq('STREAM')
    end

    # THE regression (#464): a resumed run must follow the CURRENT rules, not the
    # prompt captured at save time. Edit harness.md AFTER the save.
    it 'rebuilds the system prompt on resume, not the saved one' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id)
      File.write(File.join(workdir, 'harness.md'), "rule added after the save\n")

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.session.system_prompt).to include('rule added after the save')
      expect(harness.session.system_prompt).not_to include('saved prompt')
      expect(harness.session.messages.first[:content]).to include('rule added after the save')
    end

    # A saved session naming a model this run's config no longer has is a stale
    # name, not a broken run: the run already resolved its own model from its own
    # config, and the resume keeps it. Raising here aborted the whole resume over
    # one stale key - and a layered resume (issue #548) asks once per saved job.
    it 'resumes on the run model when the saved model is no longer configured' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id)
      data = saved_data(id).merge(active_profile_id: 'gone-model')

      harness = build_harness(session_id: id, resume_data: data)

      expect(harness.session_manager.active_profile_name).to eq('test-model')
      expect(harness.model_config.active_profile_id).to eq('test-model')
      expect(harness.session.pending?).to be(false)
    end

    # A run with a configured profile but no default_profile_id, resuming a
    # session whose saved id names no profile: it keeps its seeded model rather
    # than aborting the resume (aborting over a stale name was the owner's crash).
    it 'resumes on its seeded model when there is no default_profile_id and the saved id is unknown' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id)
      data = saved_data(id).merge(active_profile_id: 'gone-model')

      harness = build_harness(
        session_id: id,
        resume_data: data,
        model_profiles: [{ name: 'other-model', id: 'other-model' }])

      # No selection and no default: this run has no model to resume onto, so it
      # keeps the raw seed it was built with instead of aborting the resume.
      expect(harness.model_config.active_profile_id).to be_nil
      expect(harness.model_config.base_url).to be_nil
    end

    # A session saved BEFORE streaming existed has no key at all: that is not
    # an error, it is the buffered default.
    it 'treats a session with no streaming key as buffered' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id)
      data = saved_data(id)
      data.delete(:stream)

      harness = build_harness(session_id: id, resume_data: data)

      expect(harness.settings.stream?).to be(false)
    end

    # issue #106: the markdown rendering posture travels with the session too
    # (a harness posture, like streaming). A session saved markdown-rendered
    # must not drop back to raw markdown on resume.
    it 'restores the markdown posture the session was saved with' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, markdown: true)

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.settings.markdown?).to be(true)
    end

    # A session saved BEFORE markdown rendering existed has no key at all: that
    # is not an error, it is the markdown-off default.
    it 'treats a session with no markdown key as markdown off' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id)
      data = saved_data(id)
      data.delete(:markdown)

      harness = build_harness(session_id: id, resume_data: data)

      expect(harness.settings.markdown?).to be(false)
    end

    # issue #303: the palette the session was saved with is restored during
    # construction, like the YOLO posture - a session the user set to 'none'
    # must not come back colored.
    it 'restores the output palette the session was saved with' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, output_palette: 'none')

      harness = build_harness(session_id: id, resume_data: saved_data(id),
                              output_palette: 'default')

      expect(harness.settings.output_palette.name).to eq('none')
    end

    it 'falls back to the default palette when the stored name no longer exists' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(id, output_palette: 'crayola')

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.settings.output_palette.name).to eq('default')
    end

    # issue #188: a run that changed postures but sent no prompt now saves a
    # session whose chain is JUST the system prompt. The resume side must
    # restore those postures (not choke on the empty conversation) so
    # --continue/--resume recovers them - the whole point of saving it.
    it 'restores the postures of a saved session that has no conversation yet' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      FileUtils.mkdir_p(File.dirname(session_path(id, SessionLocator::SESSION_FILE)))
      File.write(session_path(id, SessionLocator::SESSION_FILE), JSON.generate({
        session_id: id, created_at: Time.now.iso8601, system_prompt: 'saved prompt',
        messages: [{ role: 'system', content: 'saved prompt' }],
        yolo: true, stream: true, markdown: true, output_palette: 'basic16',
        workdir: workdir
      }))

      harness = build_harness(session_id: id, resume_data: saved_data(id))

      expect(harness.settings.yolo?).to be(true)
      expect(harness.settings.stream?).to be(true)
      expect(harness.settings.markdown?).to be(true)
      expect(harness.settings.output_palette.name).to eq('basic16')
      expect(harness.session.messages.map { |m| m[:role] }).to eq(['system'])
    end

    # issue #405: the session file records WHICH MCP tools its conversation had
    # (mcp_connected). The resumed run's own config decides what it can reach, so
    # the two lists can disagree - and the run must state that rather than
    # silently send a smaller tools payload. The comparison happens after this
    # run's own servers loaded, so the notes land next to its own MCP banner lines.
    describe 'MCP saved-servers comparison (issue #405)' do
      # One tool as the MCP gem reports it (the fields ToolAdapter reads).
      def fake_mcp_tool(name)
        Struct.new(:name, :description, :input_schema).new(name, 'fake tool', {})
      end

      # A connection that lists these tools on connect.
      def connected_connection(tool_names)
        conn = instance_double('Mcp::ServerConnection')
        allow(conn).to receive(:connect).and_return(
          tool_names.map { |n| fake_mcp_tool(n) }
        )
        allow(conn).to receive(:close)
        conn
      end

      # What a session saved with this server connected would carry (the shape
      # JSON round-trips, hence the string keys).
      def saved_server(name, tools)
        [{ 'name' => name, 'transport' => 'stdio', 'tools' => tools }]
      end

      # Build a resumed run whose config declares one stdio server exposing
      # declared_tools, against a session that saved saved (or none).
      def resume_with_config(id, declared_tools, saved)
        seed_saved_session(id, saved_mcp: saved)
        allow(Mcp::ServerConnection).to receive(:new)
          .and_return(connected_connection(declared_tools))

        build_harness(session_id: id, resume_data: saved_data(id),
                      mcp_servers: [{ name: 'fs', command: 'ruby', args: [], env: {} }])
      end

      it 'says nothing extra when this run provides the saved tools' do
        id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        harness = resume_with_config(id, ['ping'], saved_server('fs', ['fs.ping']))

        expect(harness.mcp_status_notes).to eq(
          ["MCP server 'fs' connected: 1 tool(s)"]
        )
      end

      it 'states it when the saved server is not declared in this run' do
        id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        harness = resume_with_config(id, ['ping'], saved_server('old', ['old.read']))

        expect(harness.mcp_status_notes)
          .to include(a_string_including(
            "old (1 tool(s) in the saved session) is not declared in this run's config"
          ))
      end

      it 'names the saved tools a connected server no longer provides' do
        id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        harness = resume_with_config(
          id, %w[ping], saved_server('fs', %w[fs.ping fs.gone])
        )

        expect(harness.mcp_status_notes)
          .to include(a_string_matching(/saved session are missing: fs\.gone/))
      end

      # A session saved before #405 has no mcp_connected key: that is the
      # nothing-to-compare case, not an error, and the run's own banner is then
      # the whole story.
      it "reports only this run's own lines for a session with no saved servers" do
        id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
        seed_saved_session(id)
        allow(Mcp::ServerConnection).to receive(:new)
          .and_return(connected_connection(['ping']))

        harness = build_harness(session_id: id, resume_data: saved_data(id),
                                mcp_servers: [{ name: 'fs', command: 'ruby', args: [], env: {} }])

        expect(harness.mcp_status_notes).to eq(["MCP server 'fs' connected: 1 tool(s)"])
      end
    end
  end

end

