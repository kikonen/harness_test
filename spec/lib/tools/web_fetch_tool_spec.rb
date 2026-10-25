# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/web_fetch_tool'

# A stand-in for the fetcher: the transport rules (and their real sockets) are
# tested in web_fetcher_spec.rb; this spec is about the USER side - consent,
# output budget, and what the model is told. TOP LEVEL, the house pattern for a
# spec helper class (see web_fetcher_spec.rb / base_backend_streaming_spec.rb).
class FakeFetcher
  attr_reader :fetched, :timeouts

  def initialize(outcome)
    @outcome  = outcome
    @fetched  = []
    @timeouts = []
  end

  # URL rules and the pre-consent address refusal are the REAL ones: this
  # stand-in only replaces the network call.
  def parse(url)
    WebFetcher.new.parse(url)
  end

  def literal_block(uri)
    WebFetcher.new.literal_block(uri)
  end

  def fetch(url, timeout:)
    @fetched  << url
    @timeouts << timeout
    @outcome
  end
end

RSpec.describe Tools::WebFetchTool do
  # Drive the consent dialog without real I/O: intercept Dialog#show (the tool
  # calls it with ui: nil because tools run on the Task thread) and perform the
  # interaction directly on a StringIO. Returns the rendered output so a spec can
  # assert what the user was actually shown.
  def drive_dialog(*lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  def tool_in(dir, options = {})
    described_class.new(FileList.new(workdir: dir), options)
  end

  # A tool whose host grant already exists: the fetch runs with no consent
  # round-trip, for the specs that are about OUTPUT rather than about consent.
  def granted_tool(dir, options = {})
    FileUtils.mkdir_p(File.join(dir, '.harness'))
    File.write(allowlist_file(dir), YAML.dump(['example.com']))
    tool_in(dir, options)
  end

  def allowlist_file(dir)
    File.join(dir, '.harness', WebHostAllowlist::FILENAME)
  end

  def result(body: "line1\nline2\nline3", status: 200, type: 'text/html',
             url: 'https://example.com/page', bytes: nil, redirects: 0)
    WebFetcher::Result.new(status:, content_type: type, body:, final_url: url,
                           bytes: bytes || body.bytesize, redirects:)
  end

  def with_fetcher(tool, outcome)
    fake = FakeFetcher.new(outcome)
    tool.instance_variable_set(:@fetcher, fake)
    fake
  end

  describe 'the tool contract' do
    it 'is named web.fetch and requires a url' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)

        expect(tool.name).to eq('web.fetch')
        expect(tool.parameters[:required]).to eq(['url'])
        expect(tool.parameters[:properties].keys).to eq(%i[url limit timeout])
      end
    end

    it 'tells the model about the guards and the line limit' do
      Dir.mktmpdir do |dir|
        text = tool_in(dir).to_openai[:function][:description]

        expect(text).to include('exact host')
        expect(text).to include('refused')
        expect(text).to include('context window')
      end
    end
  end

  describe 'URL rules (refused before the user is asked anything)' do
    # No dialog stub here on purpose: if the tool tried to ask, the dialog would
    # raise (no Task, no console), so a returned error string also proves the
    # refusal happened BEFORE any consent round-trip.
    it 'refuses a missing or malformed url without a dialog' do
      Dir.mktmpdir do |dir|
        out = tool_in(dir).execute('url' => '')
        expect(out).to include("must be a valid absolute http(s) URL")

        expect(tool_in(dir).execute({})).to include("must be a valid absolute http(s) URL")
        expect(tool_in(dir).execute('url' => 'ftp://example.com/a')).to include('only http and https')
      end
    end

    it 'refuses a URL with userinfo before asking the user' do
      Dir.mktmpdir do |dir|
        out = tool_in(dir).execute('url' => 'http://user:secret@example.com/')

        expect(out).to eq('error: a URL with userinfo (user:pass@host) cannot be fetched')
      end
    end

    it 'builds the private-address opt-in from the USER options only' do
      Dir.mktmpdir do |dir|
        expect(tool_in(dir).instance_variable_get(:@fetcher).guard.allow_private?).to be false
        lifted = tool_in(dir, web_fetch_allow_private: true)
        expect(lifted.instance_variable_get(:@fetcher).guard.allow_private?).to be true
      end
    end
  end

  describe 'the address guard (not grantable, not model-settable)' do
    # The literal case needs no DNS, so it is refused BEFORE any consent round-trip.
    # No dialog is stubbed here on purpose: a dialog would raise (no Task), so a
    # returned refusal also proves the user was never asked.
    it 'refuses a blocked IP literal without asking the user first' do
      Dir.mktmpdir do |dir|
        out = tool_in(dir).execute('url' => 'http://127.0.0.1:8080/x')

        expect(out).to include('127.0.0.1 is a blocked address')
        expect(out).to include('web_fetch_allow_private')
        expect(File.file?(allowlist_file(dir))).to be false
      end
    end

    # The host-name case: deciding it needs DNS, so the user is asked first, and
    # a saved grant still cannot lift the guard (a grant says only which host may
    # be ASKED for).
    it 'does not let an Always-allow lift the address guard' do
      Dir.mktmpdir do |dir|
        allow(Resolv).to receive(:getaddresses).with('local.test').and_return(['127.0.0.1'])
        # Options: Allow(1), Always allow 'local.test'(2), Cancel(3).
        drive_dialog("2\n")
        out = tool_in(dir).execute('url' => 'http://local.test:8080/x')

        expect(YAML.safe_load(File.read(allowlist_file(dir)))).to eq(['local.test'])
        expect(out).to include('which is blocked')
      end
    end
  end

  describe 'consent (the new security surface of issue #33)' do
    it 'shows the full URL and the host before anything is fetched' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)
        fake = with_fetcher(tool, result)
        stdout = drive_dialog("1\n")

        tool.execute('url' => 'https://docs.example.com/guide?x=1#frag')

        shown = stdout.string
        expect(shown).to include('https://docs.example.com/guide?x=1#frag')
        expect(shown).to include('docs.example.com')
        expect(fake.fetched).to eq(['https://docs.example.com/guide?x=1#frag'])
      end
    end

    it 'asks in every posture - a YOLO option is not reused for a URL' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)
        with_fetcher(tool, result)
        # The shell postures are a decision about shell commands (issue #221), so
        # even with yolo on, a new host must still reach the dialog.
        tool.instance_variable_set(:@options, { yolo: true })
        stdout = drive_dialog("1\n")

        tool.execute('url' => 'https://example.com/')

        expect(stdout.string).to include('[dialog]')
      end
    end

    it 'offers the grant only for the exact host' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)
        with_fetcher(tool, result)
        stdout = drive_dialog("1\n")

        tool.execute('url' => 'https://example.com/a')

        expect(stdout.string).to include("Always allow 'example.com'")
        expect(stdout.string).not_to include('example.com/*')
        expect(stdout.string).not_to include('sub.example.com')
      end
    end

    # A bare Allow is for THIS fetch only: nothing is persisted, so the same
    # host is asked about again next time.
    it 'fetches once the user allows this one URL, and saves nothing' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)
        with_fetcher(tool, result(body: 'page text'))
        drive_dialog("1\n")

        out = tool.execute('url' => 'https://example.com/')

        expect(out).to include('page text')
        expect(File.file?(allowlist_file(dir))).to be false

        # The next fetch of the same host asks again: Allow was for ONE URL.
        drive_dialog("3\n")
        out2 = tool.execute('url' => 'https://example.com/other')
        expect(out2).to start_with('error: user denied fetching example.com')
      end
    end

    it 'saves the host on Always-allow and auto-approves that host afterwards' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)
        with_fetcher(tool, result)
        # Options: Allow(1), Always allow(2), Cancel(3).
        drive_dialog("2\n")
        tool.execute('url' => 'https://example.com/a')

        expect(YAML.safe_load(File.read(allowlist_file(dir)))).to eq(['example.com'])

        # Second time: no dialog stub at all - a dialog would raise, so this also
        # proves nothing was asked.
        fake = with_fetcher(tool, result(body: 'second'))
        out = tool.execute('url' => 'https://example.com/b')
        expect(out).to include('second')
        expect(fake.fetched.size).to eq(1)
      end
    end

    it 'auto-approves from a grant saved in an earlier session' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(allowlist_file(dir), YAML.dump(['api.example.com']))

        tool = tool_in(dir)
        fake = with_fetcher(tool, result(body: 'json'))
        out = tool.execute('url' => 'https://api.example.com/v1')

        expect(out).to include('json')
        expect(fake.fetched.size).to eq(1)
      end
    end

    it 'never lets a grant reach a different host' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(allowlist_file(dir), YAML.dump(['example.com']))

        tool = tool_in(dir)
        with_fetcher(tool, result)
        # evil.example.com is not covered by the example.com grant, so it asks -
        # and here it is denied.
        drive_dialog("3\n")
        out = tool.execute('url' => 'https://evil.example.com/x')

        expect(out).to start_with('error: user denied fetching evil.example.com')
      end
    end

    it 'returns a plain denial when the user cancels' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)
        with_fetcher(tool, result)
        drive_dialog("3\n")

        out = tool.execute('url' => 'https://example.com/')
        expect(out).to eq('error: user denied fetching example.com')
      end
    end

    it 'forwards the denial note so the model can see why' do
      Dir.mktmpdir do |dir|
        tool = tool_in(dir)
        fake = with_fetcher(tool, result)
        drive_dialog("3 that domain is not related to this task\n")

        out = tool.execute('url' => 'https://example.com/')

        expect(out).to start_with('error: user denied fetching example.com')
        expect(out).to include('user\'s note: "that domain is not related to this task"')
        expect(fake.fetched).to eq([])
      end
    end
  end

  describe 'the output budget (a page goes straight into the context window)' do
    it 'reports the status, content type, final URL and byte count before the body' do
      Dir.mktmpdir do |dir|
        tool = granted_tool(dir)
        with_fetcher(tool, result(body: "a\nb", type: 'application/json', bytes: 42))

        out = tool.execute('url' => 'https://example.com/api')

        expect(out).to start_with("status: 200\ncontent-type: application/json\n")
        expect(out).to include('url: https://example.com/page')
        expect(out).to include('bytes: 42')
        expect(out).to include("--- body ---\na\nb")
        expect(out).not_to include('truncated')
      end
    end

    it 'keeps a body within the default line limit whole' do
      Dir.mktmpdir do |dir|
        body = Array.new(200) { |i| "line #{i}" }.join("\n")
        tool = granted_tool(dir)
        with_fetcher(tool, result(body:))

        out = tool.execute('url' => 'https://example.com/')

        expect(out).not_to include('truncated')
        expect(out.split("\n").count { |l| l.start_with?('line ') }).to eq(200)
      end
    end

    it 'truncates a longer body and says how to see the rest' do
      Dir.mktmpdir do |dir|
        body = Array.new(500) { |i| "line #{i}" }.join("\n")
        tool = granted_tool(dir)
        with_fetcher(tool, result(body:))

        out = tool.execute('url' => 'https://example.com/', 'limit' => 10)

        expect(out.split("\n").count { |l| l.start_with?('line ') }).to eq(10)
        expect(out).to include('output truncated: showing the first 10 lines')
        expect(out).to include("raise 'limit'")
      end
    end

    it 'caps the limit the model may ask for' do
      Dir.mktmpdir do |dir|
        body = Array.new(2500) { |i| "line #{i}" }.join("\n")
        tool = granted_tool(dir)
        with_fetcher(tool, result(body:))

        out = tool.execute('url' => 'https://example.com/', 'limit' => 999_999)

        expect(out).to include('showing the first 2000 lines')
        expect(out.split("\n").count { |l| l.start_with?('line ') }).to eq(2000)
      end
    end

    it 'falls back to the default limit for a junk limit' do
      Dir.mktmpdir do |dir|
        body = Array.new(300) { |i| "line #{i}" }.join("\n")
        tool = granted_tool(dir)
        with_fetcher(tool, result(body:))

        out = tool.execute('url' => 'https://example.com/', 'limit' => 'ten')

        expect(out).to include('showing the first 200 lines')
      end
    end

    it 'names the redirect hops it followed' do
      Dir.mktmpdir do |dir|
        tool = granted_tool(dir)
        with_fetcher(tool, result(redirects: 2))

        out = tool.execute('url' => 'https://example.com/start')

        # The model asked for /start and got the page of another URL, so the
        # hop count belongs in what the model reads, not only in the status line.
        expect(out).to include('redirects: 2')
        expect(out).to include('url: https://example.com/page')
      end
    end

    it 'says nothing about redirects when there were none' do
      Dir.mktmpdir do |dir|
        tool = granted_tool(dir)
        with_fetcher(tool, result(redirects: 0))

        expect(tool.execute('url' => 'https://example.com/')).not_to include('redirects')
      end
    end
  end

  describe 'a fetch that failed' do
    it 'returns the fetcher error unchanged' do
      Dir.mktmpdir do |dir|
        tool = granted_tool(dir)
        with_fetcher(tool, 'error: could not connect to example.com: 1.2.3.4 (ConnectionRefused: refused)')

        out = tool.execute('url' => 'https://example.com/')

        expect(out).to start_with('error: could not connect to example.com')
      end
    end

    it 'leaves a trace in the session log for a failed fetch' do
      Dir.mktmpdir do |dir|
        tool = granted_tool(dir)
        logger = instance_double('logger')
        harness = instance_double('harness', logger:)
        tool.instance_variable_set(:@harness, harness)
        with_fetcher(tool, 'error: could not resolve example.com')

        expect(logger).to receive(:warn).with(/web.fetch failed \(example.com\)/)
        tool.execute('url' => 'https://example.com/')
      end
    end

    it 'reports the timeout the fetcher was given' do
      Dir.mktmpdir do |dir|
        tool = granted_tool(dir)
        fake = with_fetcher(tool, result)

        tool.execute('url' => 'https://example.com/', 'timeout' => 30)

        expect(fake.timeouts).to eq([30])
      end
    end
  end
end
