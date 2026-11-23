# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness, 'turn support: waits, stores, web.fetch, MCP wiring' do
  include HarnessSpecSupport

  describe '#call_llm streaming posture (issue #28)' do
    def scripted(harness, client)
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')
      harness
    end

    def tool_round(id)
      { content: nil,
        tool_calls: [{ id: id,
                       function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
    end

    it 'asks for a buffered response when the posture is off' do
      client = fake_scripted_client([{ content: 'final' }])
      h = scripted(build_harness, client)

      h.call_llm

      expect(client.stream_flags).to eq([false])
      expect(client.on_deltas).to eq([nil])
    end

    it 'asks for a streamed response and a delta callback when the posture is on' do
      client = fake_scripted_client([{ content: 'final' }])
      h = scripted(build_harness(stream: true), client)

      h.call_llm

      expect(client.stream_flags).to eq([true])
      expect(client.on_deltas.first).to respond_to(:call)
    end

    # A mid-turn /stream toggle must apply to the NEXT request, not the one
    # already in flight: the posture is read inside the loop, once per
    # request. The client flips it after its FIRST call, so the second
    # request of the same turn must carry the new value.
    it 'reads the posture per request, so a toggle applies to the next one' do
      client = fake_scripted_client([tool_round('c1'), { content: 'final' }])
      h = scripted(build_harness, client)
      client.after_call = -> { h.settings.toggle_stream }

      h.call_llm

      expect(client.stream_flags).to eq([false, true])
    end

    # The live tail belongs to ONE request: an answer that already finished
    # must not leak into the next request's spinner line.
    it 'clears the live preview once a request ends' do
      client = fake_scripted_client([{ content: 'final' }])
      h = scripted(build_harness(stream: true), client)

      h.call_llm

      expect(h.stream_preview_line).to be_nil
    end

    # The delta callback is held by the TRANSPORT, which can still have a delta
    # to deliver after this request's ensure cleared the ivar. Capturing the
    # ivar meant such a delta called record on nil (issue #378 - the crash #376
    # could not trace): the callback must hold THIS request's preview object.
    it 'a delta delivered after the request ended cannot raise, and shows no tail' do
      client = instance_double('client')
      captured = nil
      allow(client).to receive(:chat) do |_messages, **kwargs|
        captured = kwargs[:on_delta]
        { choices: [{ message: { content: 'answer', reasoning: nil } }] }
      end
      h = scripted(build_harness(stream: true), client)

      h.call_llm
      expect(h.stream_preview_line).to be_nil
      expect(captured).to respond_to(:call)

      expect { captured.call({ content: 'late delta' }) }.not_to raise_error
      # The late delta published into ITS OWN preview object: the reader sees
      # nothing, so a finished request's tail cannot come back.
      expect(h.stream_preview_line).to be_nil
    end

    # The same clearing on the FAILURE path: a request that died mid-stream
    # would otherwise leave a partial answer's tail set, and the next request
    # (a /retry, or the next turn) would show text from an answer that never
    # completed.
    it 'clears the live preview when the request fails' do
      client = instance_double('client')
      # The block signature must accept every keyword the harness passes
      # (tools: too) - a narrow one raises ArgumentError inside the stub.
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta]&.call({ content: 'half an answer' })
        raise LLMError, "stream lost"
      end
      h = scripted(build_harness(stream: true), client)

      expect { h.call_llm }.to raise_error(LLMError, 'stream lost')
      expect(h.stream_preview_line).to be_nil
    end

    # The suffix callable the spinner evaluates every frame is the harness's,
    # so it is asserted DURING the request (the only moment a tail exists):
    # the client plays a delta, and the suffix the request announced reads it.
    it 'shows the newest streamed text in the spinner suffix while streaming' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'arriving text' })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'arriving text' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).to eq('arriving text')
    end

    # issue #368: while a tool call streams, no text is arriving, so a line built
    # from the (frozen) tail reads as a dead connection. The phase names the tool.
    it 'names the tool call the model is writing instead of the frozen tail' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'I will write the file' })
        kwargs[:on_delta].call({ tool_call_names: ['file.write'] })
        # The argument fragment carries no name - the phase must still be known.
        kwargs[:on_delta].call({ tool_call_names: ['file.write'] })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'I will write the file' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).to eq("writing tool call: file.write #{h.context_indicator_live}")
    end

    # The reason the phase line carries NO rate: no text is arriving to measure,
    # and a rate computed over that window decays frame by frame - the exact
    # "the connection is dying" reading the phase exists to replace.
    it 'shows no tok/s rate during the tool-call phase' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'x' * 80 })
        sleep 0.2
        kwargs[:on_delta].call({ content: 'y' * 80 })
        kwargs[:on_delta].call({ tool_call_names: ['file.write'] })
        sleep 0.5 # a real pause, so a rate WOULD have been measurable if shown
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'done' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).not_to include('tok/s')
      expect(seen).to start_with('writing tool call: file.write')
    end

    it 'falls back to the context estimate when nothing is streaming' do
      h = build_harness
      h.session.add_user('a' * 400)

      expect(h.request_wait_suffix.call).to eq(h.context_indicator_live)
    end
  end

  # issue #285: a tok/s rate on the spinner line. While a streamed answer is
  # arriving it is measured from the deltas themselves; for the waits where no
  # text has arrived yet (prefill, or a buffered request) it is the rate of the
  # request that last completed. Nothing is ever invented: with no measurement
  # the segment simply is not there.
  describe '#request_wait_suffix live rate (issue #285)' do
    # A client that answers instantly. The harness's own clock over an instant
    # call is under its noise floor, so a client-timed rate only appears when
    # the usage carries no server measurement AND the request took real time
    # (see the slow client below).
    def rate_client(usage)
      client = instance_double('client')
      allow(client).to receive(:chat)
        .and_return({ choices: [{ message: { content: 'done', reasoning: nil } }], usage: })
      client
    end

    def one_request(h)
      h.session.add_user('go')
      h.call_llm
      h
    end

    it 'shows no rate before any request has completed' do
      h = build_harness
      h.session.add_user('go')

      expect(h.last_rate_segment).to be_nil
      expect(h.request_wait_suffix.call).to eq(h.context_indicator_live)
    end

    # No conversation AND no completed request: the suffix resolves to NOTHING,
    # not an empty segment (the spinner's contract for "no suffix").
    it 'shows no suffix at all when there is nothing measured' do
      expect(build_harness.request_wait_suffix.call).to be_nil
    end

    it 'shows the server-reported rate of the request that just finished' do
      h = build_harness
      h.instance_variable_set(:@client, rate_client(
        { prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
          completion_tokens_per_second: 31.4 }
      ))
      one_request(h)

      # Server-measured, so NO '~'; tagged because it describes the PREVIOUS
      # request, not the one the spinner is currently waiting for.
      expect(h.last_rate_segment).to eq('31.4 tok/s (last)')
      expect(h.request_wait_suffix.call).to end_with('31.4 tok/s (last)')
    end

    it "marks a rate the harness timed itself with '~'" do
      h = build_harness
      # No server number at all: the harness's own seconds are the only source,
      # and they are measured over the whole request (prefill included), so the
      # number is labeled as not the server's.
      h.record_last_rate({ prompt_tokens: 500, completion_tokens: 100 }, 4.0)

      expect(h.last_rate_segment).to eq('~25 tok/s (last)')
    end

    it 'shows the newest text plus its live rate while an answer is streaming' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        # Two short deltas with a real gap between them: 25 characters is 7
        # estimated tokens over ~0.35s, just above the noise floor - and short
        # enough that the WHOLE answer fits the 60-char tail (no ellipsis).
        kwargs[:on_delta].call({ content: 'hello there ' })
        sleep 0.35
        kwargs[:on_delta].call({ content: 'arriving text' })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'done' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      # The tail first, then the rate its own text arrived at ('~' because the
      # token count is estimated from characters), and no "(last)" tag: this
      # rate describes the request in flight.
      # The spinner number is the width-stable form (issue #364): one decimal
      # always, and a leading space under 100 - so the pattern allows the pad
      # column rather than assuming the measured rate happens to be wide.
      expect(seen).to match(/\Ahello there arriving text ~ ?\d+\.\d tok\/s\z/)
    end

    it 'shows only the tail while the text is too short to measure yet' do
      h = build_harness(stream: true)
      seen = nil
      client = instance_double('client')
      allow(client).to receive(:chat) do |_messages, **kwargs|
        kwargs[:on_delta].call({ content: 'hi' })
        seen = h.request_wait_suffix.call
        { choices: [{ message: { content: 'done' } }], usage: {} }
      end
      h.instance_variable_set(:@client, client)
      h.session.add_user('go')

      h.call_llm

      expect(seen).to eq('hi')
    end

    # A resumed session's saved per-request performance (#251) IS a server
    # measurement, so the recent rate is available on the FIRST request after
    # the resume - no request needed in this process first.
    it 'restores the recent rate from a saved session' do
      id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      FileUtils.mkdir_p(File.dirname(session_path(id, SessionLocator::SESSION_FILE)))
      File.write(session_path(id, SessionLocator::SESSION_FILE), JSON.generate({
        session_id: id, created_at: Time.now.iso8601, system_prompt: 'saved prompt',
        messages: [{ role: 'system', content: 'saved prompt' },
                   { role: 'user', content: 'earlier' }],
        last_stats: { elapsed_seconds: 5.0, iterations: 1,
                      usage: { prompt_tokens: 1000, completion_tokens: 50 },
                      prompt_tokens: 1000,
                      performance: { completion_tokens_per_second: 27.8,
                                     completion_tokens: 50 } }
      }))
      data = JSON.parse(File.read(session_path(id, SessionLocator::SESSION_FILE)), symbolize_names: true)

      harness = build_harness(session_id: id, resume_data: data)

      expect(harness.last_rate_segment).to eq('27.8 tok/s (last)')
    end

    # A rate was measured against ONE server. /model points the run at another,
    # so keeping the number would show a speed that describes nothing this run
    # is about to do.
    it 'drops the recent rate when the model is switched' do
      h = build_harness(model_profiles: [
        { name: 'one', num_ctx: 65_536 },
        { name: 'two', num_ctx: 32_768 }
      ])
      h.record_last_rate({ completion_tokens: 100, completion_tokens_per_second: 31.4 }, 4.0)
      expect(h.last_rate_segment).to eq('31.4 tok/s (last)')

      h.session_manager.switch_profile('two')

      expect(h.last_rate_segment).to be_nil
      expect(h.request_wait_suffix.call).to eq(h.context_indicator_live)
    end

    # Issue #364: the number the SPINNER draws is width-stable (see
    # UsageStats.format_stable_rate), so a rate under 100 keeps its column and
    # a frame that changes the rate cannot shift the posture badge after it.
    # Only the spinner asks for it: a log line names the same rate unpadded.
    it 'pads the rate number on the spinner line, not in the log form' do
      h = build_harness
      h.record_last_rate({ completion_tokens: 20, completion_tokens_per_second: 9.0 }, 4.0)

      expect(h.last_rate_segment).to eq('9 tok/s (last)')
      expect(h.last_rate_segment(pad: true)).to eq(' 9.0 tok/s (last)')
      expect(h.request_wait_suffix.call).to end_with(' 9.0 tok/s (last)')
    end

    # A spinner suffix must never be an empty segment: the leading pad belongs
    # to the number, not to the separator the spinner adds before the suffix.
    it 'keeps the padded rate behind the context indicator on one line' do
      h = build_harness
      h.session.add_user('a' * 400)
      h.record_last_rate({ completion_tokens: 20, completion_tokens_per_second: 9.0 }, 4.0)

      expect(h.request_wait_suffix.call)
        .to eq("#{h.context_indicator_live}  9.0 tok/s (last)")
    end
  end

  describe 'the skills store (issue #12, #286)' do
    # The store is built in build_tool_registry from the run's workdir and handed
    # straight to the tools; Harness no longer holds it (#286), so read it via a tool.
    def skills_store(h)
      h.tool_registry.get('skills.list').instance_variable_get(:@skills)
    end

    it 'points at .harness/skills under this run\'s workdir' do
      h = build_harness

      expect(skills_store(h).dir).to eq(File.join(workdir, '.harness', 'skills'))
      expect(skills_store(h).exist?).to be false
      expect(skills_store(h).all).to eq([])
    end

    it 'registers skills.list and skills.read over that same loader' do
      h = build_harness
      list = h.tool_registry.get('skills.list')
      read = h.tool_registry.get('skills.read')

      expect(list).not_to be_nil
      expect(read).not_to be_nil
      # Both tools read the SAME store instance built once in build_tool_registry.
      expect(read.instance_variable_get(:@skills)).to equal(list.instance_variable_get(:@skills))
      expect(skills_store(h).dir).to eq(File.join(workdir, '.harness', 'skills'))
    end
  end

  describe '#sandbox_gemfile (issue #340)' do
    # The harness seeds the scaffold at construction (the model's file tools
    # cannot write the sensitive .harness/), so a fresh run already has it.
    it 'points at .harness/sandbox/Gemfile under this run\'s workdir and seeds it' do
      h = build_harness

      expect(h.sandbox_gemfile).to be_a(SandboxGemfile)
      expect(h.sandbox_gemfile.dir).to eq(File.join(workdir, '.harness', 'sandbox'))
      expect(h.sandbox_gemfile.gemfile_path).to eq(
        File.join(workdir, '.harness', 'sandbox', 'Gemfile'))
      expect(h.sandbox_gemfile.exist?).to be true
      # The seed is a COPY of the repo template, not text baked into the source.
      expect(File.read(h.sandbox_gemfile.gemfile_path))
        .to eq(File.read(SandboxGemfile::STARTER_TEMPLATE_FILE))
    end

    # A fresh seed's outcome is logged, so a seed that could NOT lock (a gem
    # absent here) is visible at startup instead of surfacing later as a mid-run
    # LoadError. The top-level stub makes the locked branch deterministic here.
    it 'logs the locked branch when the offline lock succeeded' do
      h = build_harness

      expect(File.read(h.session_log_path)).to include('ruby sandbox seeded and locked offline')
    end

    # The unlocked branch (a starter gem absent on the box) is the same seed
    # outcome with the opposite tail - proven by flipping the same stub.
    it 'logs the unlocked branch when the offline lock failed' do
      allow_any_instance_of(SandboxGemfile).to receive(:lock_seeded?).and_return(false)
      h = build_harness

      expect(File.read(h.session_log_path)).to include('ruby sandbox seeded')
      expect(File.read(h.session_log_path)).to include('offline lock failed')
    end

    # A model-managed Gemfile is never re-locked or overwritten on a later launch:
    # ensure_starter! early-returns :existing, so no seed line appears. The floor
    # resync is the one addition it makes - here the model's own single-quote
    # style is what survives, unchanged, above the appended defaults.
    it 'leaves an existing sandbox untouched on a later launch' do
      FileUtils.mkdir_p(File.join(workdir, '.harness', 'sandbox'))
      File.write(File.join(workdir, '.harness', 'sandbox', 'Gemfile'), "gem 'mine'\n")

      h = build_harness
      text = File.read(h.sandbox_gemfile.gemfile_path)
      expect(text).to start_with("gem 'mine'\n")
      expect(text).to include("gem 'mine'")
      expect(text.scan(/gem 'mine'/).size).to eq(1)
      expect(File.read(h.session_log_path)).not_to include('ruby sandbox seeded')
    end
  end

  # issue #279: sessions.search is registered in every run and reads THIS run's
  # SessionLocator (the single place that knows where sessions live), so the
  # model can find a saved session by content. Read-only: no resume, no delete.
  describe 'sessions.search (issue #279)' do
    it 'is registered in every run over the run\'s own locator' do
      h    = build_harness
      tool = h.tool_registry.get('sessions.search')

      expect(tool).to be_a(Tools::SessionsSearchTool)
      expect(h.tool_registry.names).to include('sessions.search')
      expect(tool.instance_variable_get(:@locator).workdir).to eq(workdir)
    end

    it 'finds a saved session by its message content through the registry' do
      id   = 'aaaaaaaa-bbbb-cccc-dddd-111111111111'
      dir  = File.join(workdir, '.harness', 'sessions', id)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'session.json'),
                 JSON.generate(session_id: id, workdir:,
                               messages: [{ role: 'user', content: 'refactor the parser' }]))

      out = build_harness.tool_registry.get('sessions.search')
                  .execute('query' => 'refactor')

      expect(out).to include(id)
      expect(out).to include('refactor the parser')
    end
  end

  # Issue #10: the store is a stateless reader over the on-disk dir, built once
  # in build_tool_registry and handed to every memory tool as the SAME object, so
  # the tools cannot disagree about which notes exist. Harness no longer holds it
  # (#286): read it via a tool.
  describe 'the memories store (issue #10, #286)' do
    def memories_store(h)
      h.tool_registry.get('memory.list').instance_variable_get(:@memories)
    end

    it 'points at .harness/memories under this run\'s workdir' do
      h = build_harness

      expect(memories_store(h).dir).to eq(File.join(workdir, '.harness', 'memories'))
      expect(memories_store(h).exist?).to be false
      expect(memories_store(h).all).to eq([])
    end

    it 'registers the four memory tools over that same store' do
      h = build_harness
      tools = %w[memory.list memory.read memory.add memory.delete].map { |n| h.tool_registry.get(n) }

      expect(tools.compact.size).to eq(4)
      tools.each do |tool|
        expect(tool.instance_variable_get(:@memories)).to equal(memories_store(h))
      end
    end

    # The store holds over SESSIONS, so it is NOT session state: it is never
    # serialized into session.json, and a note saved under one id is readable by
    # a harness built under a different id in the same workdir.
    it 'holds notes over a different session id in the same workdir' do
      first = build_harness
      first.tool_registry.get('memory.add').execute('name' => 'cross-session', 'text' => 'a fact')

      later = build_harness
      expect(later.session.session_id).not_to eq(first.session.session_id)
      expect(memories_store(later).body('cross-session')).to eq('a fact')
      expect(later.tool_registry.get('memory.read').execute('name' => 'cross-session')).to eq('a fact')
    end

    # A memory write is recorded in harness.log by the harness' own tool-call
    # line - the same record every other tool change gets, nothing extra to keep
    # in sync.
    it 'records a memory write in this session\'s harness.log' do
      h = build_harness
      h.send(:execute_tool_call, {
        id: 'c1',
        function: { name: 'memory.add', arguments: JSON.generate(name: 'logged-note', text: 'a fact') }
      })

      log = File.read(h.session_log_path)
      expect(log).to include("tool memory.add → ok: saved memory 'logged-note'")
      expect(memories_store(h).body('logged-note')).to eq('a fact')
    end

    # issue #435: the config 'max_memories:' cap reaches the store this run
    # builds, so a project can raise or lower its note cap without a code change.
    it 'threads the max_memories option into the store' do
      capped = build_harness(max_memories: 4)

      expect(memories_store(capped).max_memories).to eq(4)
      # The four memory tools all read the SAME store object the registry built.
      %w[memory.add memory.list].each do |name|
        tool = capped.tool_registry.get(name)
        expect(tool.instance_variable_get(:@memories)).to equal(memories_store(capped))
      end
    end

    it 'leaves the built-in default cap when no max_memories option is set' do
      expect(memories_store(build_harness).max_memories).to eq(Memories::MAX_MEMORIES)
    end
  end

  # Issue #33: web.fetch is the harness' only outbound network call outside the
  # LLM client, so its wiring is worth asserting: the tool must see THIS run's
  # options (the private-address key is a user posture) and THIS run's workdir
  # (that is where the host grants are saved).
  describe 'web.fetch (issue #33)' do
    it 'is registered in every run' do
      h = build_harness

      expect(h.tool_registry.get('web.fetch')).to be_a(Tools::WebFetchTool)
      expect(h.tool_registry.names).to include('web.fetch')
    end

    it 'reads this run\'s settings and its FileList, not copies' do
      h = build_harness
      tool = h.tool_registry.get('web.fetch')

      expect(tool.instance_variable_get(:@settings)).to equal(h.settings)
      expect(tool.instance_variable_get(:@workdir)).to eq(workdir)
      expect(tool.instance_variable_get(:@logger)).to equal(h.logger)
    end

    it 'refuses a private address with no config, whatever the model asks' do
      h = build_harness
      tool = h.tool_registry.get('web.fetch')

      # A literal IP: the guard decides it without DNS, so it is refused before
      # any consent (a dialog would raise here - no Task - and none is needed).
      out = tool.execute('url' => 'http://127.0.0.1:9/x')

      expect(out).to include('127.0.0.1 is a blocked address')
    end

    # The refusal is visible in this session's harness.log, like every other
    # tool verdict: a network call that never happened still leaves a trace.
    it 'records a refused fetch in this session\'s harness.log' do
      h = build_harness
      h.send(:execute_tool_call, {
        id: 'c1',
        function: { name: 'web.fetch', arguments: JSON.generate(url: 'http://127.0.0.1:9/x') }
      })

      log = File.read(h.session_log_path)
      expect(log).to include("tool web.fetch → error: 127.0.0.1 is a blocked address")
    end
  end

  # issue #451: file.image is the disk producer that feeds the SAME image spine
  # web.fetch and the MCP adapter feed. It is wired over the run's own FileList
  # (the read-grant rules file.read uses), not a copy.
  describe 'file.image (issue #451)' do
    it 'is registered over this run\'s FileList' do
      h = build_harness
      expect(h.tool_registry.get('file.image')).to be_a(Tools::FileImageTool)
      expect(h.tool_registry.names).to include('file.image')
      expect(h.tool_registry.get('file.image').instance_variable_get(:@file_list)).to equal(h.file_list)
    end
  end

  # issue #48: MCP client wiring. Opt-in (no mcp_servers: = no MCP code path),
  # a failed server degrades to a status note, a tool name that collides with a
  # built-in is skipped, and the connections are closed on shutdown. The real
  # gem/subprocess is never touched here: ServerConnection is stubbed.
  describe 'MCP wiring (issue #48)' do
    # A stand-in for one MCP tool object the gem hands back (name/description/
    # input_schema are the three fields ToolAdapter reads).
    FakeMcpTool = Struct.new(:name, :description, :input_schema)

    def fake_connection(tools)
      conn = instance_double('Mcp::ServerConnection')
      allow(conn).to receive(:connect).and_return(tools)
      allow(conn).to receive(:close)
      conn
    end

    def server_entry(name: 'fs', command: 'ruby')
      { name: name, id: name, command: command, args: [], env: {} }
    end

    it 'runs no MCP code path when no servers are configured' do
      allow(Mcp::ServerConnection).to receive(:new)
      h = build_harness

      expect(h.mcp_status_notes).to eq([])
      expect(Mcp::ServerConnection).not_to have_received(:new)
    end

    it 'registers a server\'s tools under the "<server>.<tool>" namespace' do
      tools = [FakeMcpTool.new('read_file', 'Read a file',
                               { 'properties' => { 'path' => { 'type' => 'string' } },
                                 'required' => ['path'] })]
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection(tools))
      h = build_harness(mcp_servers: [server_entry])

      adapter = h.tool_registry.get('fs.read_file')
      expect(adapter).to be_a(Mcp::ToolAdapter)
      expect(h.mcp_status_notes).to include('MCP server \'fs\' connected: 1 tool(s)')
    end

    it 'skips a tool whose name collides with a built-in and reports it' do
      tools = [FakeMcpTool.new('read', 'Would shadow file.read', {})]
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection(tools))
      h = build_harness(mcp_servers: [server_entry(name: 'file')])

      # The built-in file.read is untouched; the colliding MCP tool is not added.
      expect(h.tool_registry.get('file.read')).to be_a(Tools::FileReadTool)
      expect(h.mcp_status_notes).to include(
        "skipped MCP tool 'file.read' (name collides with a built-in tool)"
      )
      # The note is logged once, with the same text the banner shows.
      expect(File.read(h.session_log_path))
        .to include("skipped MCP tool 'file.read' (name collides with a built-in tool)")
    end

    it 'degrades to a status note when a server fails to start' do
      conn = instance_double('Mcp::ServerConnection')
      allow(conn).to receive(:connect).and_raise(Errno::ENOENT, 'no such server')
      allow(conn).to receive(:close)
      allow(Mcp::ServerConnection).to receive(:new).and_return(conn)
      h = build_harness(mcp_servers: [server_entry(name: 'down')])

      # The half-spawned subprocess is closed and the run continues without it.
      expect(conn).to have_received(:close)
      expect(h.mcp_status_notes.first).to include("MCP server 'down' failed to start")
      expect(h.mcp_status_notes.first).to include('Errno::ENOENT')
      expect(h.tool_registry.names).not_to include(a_string_matching(/^down\./))
    end

    it 'closes every connection on close_mcp' do
      tools = [FakeMcpTool.new('ping', 'Ping', {})]
      conn = fake_connection(tools)
      allow(Mcp::ServerConnection).to receive(:new).and_return(conn)
      h = build_harness(mcp_servers: [server_entry])

      h.close_mcp

      expect(conn).to have_received(:close)
    end

    it 'an MCP tool call forwards to the connection and normalizes the result' do
      tools = [FakeMcpTool.new('echo_tool', 'Echo', { 'properties' => {}, 'required' => [] })]
      conn  = fake_connection(tools)
      allow(conn).to receive(:call_tool).with('echo_tool', { 'message' => 'hi' })
                                        .and_return('echo: hi')
      allow(Mcp::ServerConnection).to receive(:new).and_return(conn)
      h = build_harness(mcp_servers: [server_entry])

      result = h.send(:execute_tool_call, {
        id: 'c1',
        function: { name: 'fs.echo_tool', arguments: JSON.generate(message: 'hi') }
      })
      expect(result).to eq('echo: hi')
    end
    # Standing constraint: MCP tools reach the model through tools_payload (the
    # per-request tool definitions), NEVER by being written into the system
    # prompt file. The harness must not write config/system_prompt.txt, and the
    # session's system prompt must not name an MCP tool.
    it 'exposes MCP tools in tools_payload, never in the system prompt' do
      tools = [FakeMcpTool.new('read_file', 'Read a file', {})]
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection(tools))
      h = build_harness(mcp_servers: [server_entry])

      payload_names = h.tools_payload.map { |t| t[:function][:name] }
      expect(payload_names).to include('fs.read_file')
      # The prompt the model was seeded with carries no MCP tool name.
      expect(h.session.system_prompt).not_to include('fs.read_file')
      # The built-in prompt file is read-only to the harness: it is never written.
      prompt_path = Harness::DEFAULT_SYSTEM_PROMPT_FILE
      before = File.read(prompt_path)
      h.tools_payload
      expect(File.read(prompt_path)).to eq(before)
    end
  end
end
