# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'reline'
require 'cli'

# issue #189: the startup banner shows the session id and where its log is
# written, so the user can find harness.log without guessing.
#
# issue #276: the rest of this file covers the bootstrap ORDER - the session
# id is resolved before the Harness is constructed, so the log file, the
# history file and the session directory are all created under ONE id.

RSpec.describe CLI do
  let(:workdir) { Dir.mktmpdir }
  let(:ui) { instance_double(UI::Console) }
  let(:options) do
    {
      workdir:   workdir,
      base_url:  'http://localhost:11434/v1',
      model:     'test-model',
      system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE
    }
  end

  def build_cli
    described_class.new(options, ui)
  end

  # run reads the idle prompt through PromptReader; a #run spec that only
  # checks the banner stubs it so the loop exits at once (read => nil).
  def stub_prompt_reader
    reader = instance_double(PromptReader, read: nil)
    allow(PromptReader).to receive(:new).and_return(reader)
  end

  # Seed a saved session in the issue #207 layout (issue #276) so a resume has
  # something real to resolve: <sessions>/<id>/session.json. active_model is
  # nil by default - the "use whatever the config default is" state - because
  # these specs are about identity, not model profiles.
  def seed_saved_session(id, model: nil, yolo: false)
    dir  = File.join(workdir, '.harness', 'sessions', id)
    FileUtils.mkdir_p(dir)
    data = {
      session_id:    id,
      created_at:    Time.now.iso8601,
      system_prompt: 'saved system prompt',
      user_prompts:  3,
      messages:      [{ role: 'system', content: 'saved system prompt' },
                      { role: 'user', content: 'earlier prompt' },
                      { role: 'assistant', content: 'earlier reply' }],
      active_model:  model,
      yolo:          yolo,
      workdir:       workdir
    }
    File.write(File.join(dir, 'session.json'), JSON.generate(data))
    dir
  end

  def session_dirs
    dir = File.join(workdir, '.harness', 'sessions')
    Dir.exist?(dir) ? Dir.children(dir).sort : []
  end

  # issue #276: identity is resolved before anything derived from it is
  # constructed, so on EVERY startup path the log file, the history file and
  # the session directory all sit under the same single id.
  describe 'identity-first bootstrap (issue #276)' do
    it 'a fresh run puts log, history and session dir under its own id' do
      cli  = build_cli
      id   = cli.harness.session.session_id

      expect(session_dirs).to eq([id])
      expect(File.file?(cli.harness.session_log_path)).to be true
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', id, 'harness_history')
      )
    end

    it '--resume puts log, history and session dir under the RESUMED id' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(saved)

      cli = described_class.new(options.merge(resume: saved[0, 8]), ui)
      id  = cli.harness.session.session_id

      expect(id).to eq(saved)
      # Issue #135's symptom: a second (throwaway) directory for the fresh
      # random id the run threw away. There is no longer a fresh id to throw.
      expect(session_dirs).to eq([saved])
      expect(File.file?(cli.harness.session_log_path)).to be true
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', saved, 'harness_history')
      )
    end

    it '--continue resolves the newest saved session before constructing' do
      older = '11111111-2222-3333-4444-555555555555'
      newer = '66666666-7777-8888-9999-000000000000'
      seed_saved_session(older)
      seed_saved_session(newer)
      File.utime(Time.now - 60, Time.now - 60,
                 File.join(workdir, '.harness', 'sessions', older, 'session.json'))

      cli = described_class.new(options.merge(continue: true), ui)

      expect(cli.harness.session.session_id).to eq(newer)
      # Same single id for log, history and the session dir - and only the two
      # REAL sessions exist (no third one minted for this run).
      expect(session_dirs).to eq([older, newer])
      expect(cli.harness.session_log_path)
        .to eq(File.join(workdir, '.harness', 'sessions', newer, 'harness.log'))
      expect(File.file?(cli.harness.session_log_path)).to be true
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', newer, 'harness_history')
      )
    end

    it 'a typo in --resume raises BEFORE any session directory exists' do
      expect {
        described_class.new(options.merge(resume: 'deadbeef'), ui)
      }.to raise_error(HarnessError, /no saved session matching 'deadbeef'/)

      # Nothing was built under a random id on the way to the failure.
      expect(session_dirs).to eq([])
    end

    it '--list-sessions lists from the locator without constructing a Harness' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(saved)
      allow(ui).to receive(:puts)

      # issue #299: initialize records the listing mode and returns BEFORE
      # setup, so no Harness is built and no session dir is minted; #run
      # dispatches the listing and returns the exit status the entry point
      # turns into exit. No SystemExit around CLI.new any more.
      cli = described_class.new(options.merge(list_sessions: true, model: nil), ui)
      expect(cli.harness).to be_nil
      expect(cli.run).to eq(0)

      expect(ui).to have_received(:puts).with(/Saved sessions \(1\)/)
      expect(ui).to have_received(:puts).with(/#{Regexp.escape(saved)}/)
      # Listing used to mint a fresh random id on the way (a Harness was
      # constructed to read JSON files). It must not create any session dir.
      expect(session_dirs).to eq([saved])
    end
  end

  describe '#session_log_path_display' do
    it 'is the per-session log path relative to the workdir' do
      cli = build_cli
      id  = cli.harness.session.session_id

      expect(cli.send(:session_log_path_display))
        .to eq(File.join('.harness', 'sessions', id, 'harness.log'))
    end
  end

  # issue #282: the heavy construction lives in #setup, so it can be RUN
  # AGAIN with a different id (the shape issue #280 needs for a mid-run
  # /resume: build a FRESH Harness instead of mutating the live one). The
  # identity-first order (#276) is now the order INSIDE setup.
  describe '#setup (issue #282)' do
    it 'a second setup with a resume id builds a FRESH Harness under that id' do
      saved = 'aabbccdd-1111-2222-3333-444444444444'
      seed_saved_session(saved)

      cli    = build_cli
      before = cli.harness
      built  = cli.setup(resume_id: saved)

      expect(built).to be_a(Harness)
      expect(built).not_to equal(before)
      expect(built.session.session_id).to eq(saved)
      # Every holder is repointed at the fresh object (the repoint #280 needs).
      expect(cli.harness).to equal(built)
      expect(cli.commands.harness).to equal(built)
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', saved, 'harness_history')
      )
    end

    # The identity-first guarantee, asserted through setup: the id is resolved
    # BEFORE Harness.new, so a bad id cannot leave a half-built run behind -
    # the previous Harness, history file and commands are still in place.
    it 'a failing setup resolves the id before constructing anything' do
      cli    = build_cli
      before = cli.harness
      before_history = cli.history
      before_commands = cli.commands

      expect {
        cli.setup(resume_id: 'deadbeef')
      }.to raise_error(HarnessError, /no saved session matching 'deadbeef'/)

      expect(cli.harness).to equal(before)
      expect(cli.history).to equal(before_history)
      expect(cli.commands).to equal(before_commands)
    end

    # A re-run must never mint a throwaway id (issues #123 / #135): the id
    # this run owns is kept, whatever the startup flags were.
    it 'setup without a resume id keeps the id this run already owns' do
      cli = build_cli                    # fresh run: its own random id
      id  = cli.harness.session.session_id

      cli.setup
      expect(cli.harness.session.session_id).to eq(id)
      expect(session_dirs).to eq([id])
    end

    it 'setup without a resume id keeps a --continue id too' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(saved)

      cli = described_class.new(options.merge(continue: true), ui)
      expect(cli.harness.session.session_id).to eq(saved)

      cli.setup
      expect(cli.harness.session.session_id).to eq(saved)
      expect(session_dirs).to eq([saved])
    end
  end

  # issue #280: a mid-run /resume re-runs #setup (through the on_resume action
  # injected into the CommandHandler) and the WHOLE run is rebuilt under the
  # resumed id - nothing of the replaced run is patched in place.
  describe 'mid-run /resume (issue #280)' do
    # A saved session WITH grants, so the resumed run has something to restore
    # onto its own FileList.
    def seed_saved_session_with_grants(id)
      dir  = File.join(workdir, '.harness', 'sessions', id)
      FileUtils.mkdir_p(dir)
      data = {
        session_id:    id,
        created_at:    Time.now.iso8601,
        system_prompt: 'saved system prompt',
        user_prompts:  2,
        messages:      [{ role: 'system', content: 'saved system prompt' },
                        { role: 'user', content: 'earlier prompt' }],
        yolo:          true,
        workdir:       workdir,
        access:        { both:  { files: ['lib/foo.rb'], dirs: [], flat_dirs: [] },
                         read:  { files: [], dirs: ['spec/lib'], flat_dirs: [] },
                         write: { files: [], dirs: [], flat_dirs: [] },
                         delete: { files: [], dirs: [], flat_dirs: [] } }
      }
      File.write(File.join(dir, 'session.json'), JSON.generate(data))
    end

    def log_path(id)
      File.join(workdir, '.harness', 'sessions', id, 'harness.log')
    end

    # ResumeCommand reports through the UI (the run's own console).
    before { allow(ui).to receive(:puts) }

    it 'rebuilds the run under the resumed id and repoints every holder' do
      saved  = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session_with_grants(saved)
      cli       = build_cli
      old       = cli.harness
      first_id  = cli.harness.session.session_id
      old_fl    = cli.file_list
      old_cmds  = cli.commands
      old_hist  = cli.history

      cli.commands.handle("/resume #{saved[0, 8]}")

      # Identity: the whole run is the saved session's now.
      expect(cli.session_id).to eq(saved)
      expect(cli.harness).not_to equal(old)
      expect(cli.harness.session.session_id).to eq(saved)
      contents = cli.harness.session.messages.map { |m| m[:content] }
      expect(contents).to include('earlier prompt')
      expect(cli.harness.yolo?).to be(true)
      # Holders repointed (Task.harness comes from CommandHandler#harness at
      # every run_on_task, so this is the one wiring that matters).
      expect(cli.commands).not_to equal(old_cmds)
      expect(cli.commands.harness).to equal(cli.harness)
      expect(cli.history).not_to equal(old_hist)
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', saved, 'harness_history')
      )
      # No throwaway id: only the run's first session and the resumed one.
      expect(session_dirs).to eq([first_id, saved].sort)
      # The resume is reported on the NEW session's log (#113 was about the
      # log following the id; now the log is simply built under it).
      expect(File.read(log_path(saved))).to include('session resumed')
      # Grants restored onto a FileList of its own.
      expect(cli.file_list).not_to equal(old_fl)
      expect(cli.harness.file_list).to equal(cli.file_list)
      stored = cli.file_list.accessible_paths
      expect(stored[:both][:files]).to eq([File.expand_path('lib/foo.rb', workdir)])
      expect(stored[:read][:dirs]).to eq([File.expand_path('spec/lib', workdir)])
      # The resumed session was saved with YOLO ON, and since #274 the same
      # posture covers file access too - so coverage must not be confused with
      # the restored grants above: local/ is outside it even here.
      expect(cli.harness.yolo?).to be(true)
      expect(cli.file_list.writable?('lib/other.rb')).to be true
      expect(cli.file_list.writable?('local/notes.md')).to be false
    end

    it 'closes the replaced run\'s logger and gives the fresh one its own client' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session_with_grants(saved)
      cli   = build_cli
      old   = cli.harness
      before = File.read(log_path(old.session.session_id))

      cli.commands.handle("/resume #{saved}")

      # The old logdev is closed: a late write cannot append to it.
      old.logger.info('late write to the replaced session')
      expect(File.read(log_path(old.session.session_id))).to eq(before)
      # A fresh client built under the resumed id, logging to the fresh logger
      # (the #197 wiring - the backend holds the logger - with no setter).
      expect(cli.harness.client).not_to equal(old.client)
      expect(cli.harness.client.backend.logger).to equal(cli.harness.logger)
      expect(cli.harness.session_log_path).to eq(log_path(saved))
    end
  end

  # issue #221 review (bug 2): the shell consent posture is stated in the
  # startup banner so the run's approval behavior is visible from the first
  # line (YOLO ON must never look like "nothing ever asks").
  describe 'startup banner - command consent posture' do
    it 'names the MANUAL posture and how to change it' do
      cli = build_cli
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/^Command consent: MANUAL - unapproved commands ask/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #303: the palette this run renders with is a fact about the run,
    # so it is named in the banner next to the consent posture.
    it 'names the output palette and how to switch it' do
      cli = build_cli
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/^Output palette: default \(\/palette <name> switches it\)/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    it 'names YOLO with the disaster floor still asking' do
      cli = build_cli
      stub_prompt_reader
      cli.harness.yolo = true

      expected = 'Command consent: YOLO - unapproved commands run ' \
                 'without asking; disaster commands still ask'
      expect(ui).to receive(:puts)
        .with(expected)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end
  end

  describe '#run' do
    it 'prints the session id and its log path in the banner' do
      cli = build_cli
      id  = cli.harness.session.session_id
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/Session: #{Regexp.escape(id)} \(log: .*harness\.log\)/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #341: a rules file that is not valid UTF-8 now LOADS (bad bytes
    # replaced) instead of crashing the run, so the banner has to say the
    # repair out loud - the prompt the model got is not byte-for-byte harness.md.
    it 'reports a repaired harness.md in the banner' do
      File.binwrite(File.join(workdir, 'harness.md'), "rule caf\xe9 keep 90 cols\n")
      cli = build_cli
      stub_prompt_reader

      expect(ui).to receive(:puts).with(
        '  [harness.md repaired: 1 invalid byte replaced - harness.md is not valid UTF-8]'
      ).ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #48: a declared MCP server that failed to start (or a tool whose name
    # collided) is reported in the banner, so the run never silently pretends its
    # MCP tools are available.
    it 'reports MCP status notes in the banner' do
      cli = build_cli
      allow(cli.harness).to receive(:mcp_status_notes).and_return(
        ["MCP server 'fs' failed to start (RuntimeError: boom)"]
      )
      stub_prompt_reader

      expect(ui).to receive(:puts).with(
        "  [mcp] MCP server 'fs' failed to start (RuntimeError: boom)"
      ).ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #298: run installs the resolved editor command on the shared
    # UI::Editor once, so every multiline read honours Ctrl+G. With nothing set
    # the global stays nil and Ctrl+G is left exactly as Reline has it.
    it 'installs the resolved editor command on UI::Editor' do
      opts = options.merge(editor: 'nvim -R')
      cli  = described_class.new(opts, ui)
      allow(ui).to receive(:puts)
      stub_prompt_reader

      cli.run

      expect(UI::Editor.external_editor).to eq('nvim -R')
    end

    it 'leaves UI::Editor.external_editor nil when no editor is configured' do
      cli = build_cli
      allow(ui).to receive(:puts)
      stub_prompt_reader

      cli.run

      expect(UI::Editor.external_editor).to be_nil
    end
  end
end
