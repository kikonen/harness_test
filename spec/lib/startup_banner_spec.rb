# frozen_string_literal: true

require 'spec_helper'
require 'startup_banner'
require 'system_settings'
require 'session_locator'

RSpec.describe StartupBanner do
  let(:ui) { instance_double(UI::Console) }
  let(:workdir) { Dir.mktmpdir }
  let(:file_list) { FileList.new([], workdir: workdir) }

  def banner(settings: SystemSettings.from_options({}), resumed: false, registry: nil, harness: nil)
    described_class.new(
      ui: ui, settings: settings, file_list: file_list,
      harness: harness, registry: registry, resumed: resumed,
      locator: SessionLocator.new(workdir, session_id: 'abc123'))
  end

  describe '#consent_posture_display' do
    it 'names MANUAL when nothing is armed' do
      s = SystemSettings.from_options(command_safety_check: true)

      expect(banner(settings: s).send(:consent_posture_display))
        .to start_with('MANUAL - unapproved commands ask')
    end

    it 'names YOLO with the disaster floor still asking' do
      s = SystemSettings.from_options(yolo: true)

      expect(banner(settings: s).send(:consent_posture_display))
        .to eq('YOLO - unapproved commands run without asking; disaster commands still ask')
    end

    it 'appends the denylist relaxation only when that floor is relaxed' do
      s = SystemSettings.from_options(command_safety_denylist_safe_approve: true)
      text = banner(settings: s).send(:consent_posture_display)

      expect(text).to start_with('MANUAL')
      expect(text).to include('denylist + "safe:" also runs without asking')
    end
  end

  describe '#file_access_display' do
    it 'names the standing grant when grant_workdir is on' do
      text = banner.send(:file_access_display)

      expect(text).to start_with('standing grant on ')
      expect(text).to include('read, write and delete inside')
    end

    it 'names per-path consent when grant_workdir is off' do
      s = SystemSettings.from_options(grant_workdir: false)

      expect(banner(settings: s).send(:file_access_display))
        .to start_with('per-path consent - every file and directory asks')
    end
  end

  describe '#session_log_path_display' do
    it 'is the per-session log path relative to the workdir' do
      expect(banner.send(:session_log_path_display))
        .to eq(File.join('.harness', 'sessions', 'abc123', 'harness.log'))
    end
  end

  describe '#print_resume_replay' do
    it 'prints nothing when the tail is empty' do
      buffer = double('buffer', replay_tail: [])
      registry = double('registry', foreground_buffer: buffer)

      expect(ui).not_to receive(:puts)
      banner(registry: registry).send(:print_resume_replay)
    end

    it 'draws the tail between two block rules under a header' do
      entry  = OutputBuffer::Entry.new(type: :user, origin: :user, content: 'do the thing')
      buffer = double('buffer', replay_tail: [entry])
      registry = double('registry', foreground_buffer: buffer)

      lines = []
      allow(ui).to receive(:puts) { |line = nil| lines << line }
      banner(registry: registry).send(:print_resume_replay)

      header = lines.index { |l| l.to_s.start_with?('Resumed output') }
      rule   = lines.index { |l| l.to_s.match?(/\A-+\z/) }
      expect(header).not_to be_nil
      expect(rule).not_to be_nil
      expect(lines).to include(a_string_matching(/do the thing/))
      expect(header).to be > rule
    end
  end

  describe '#print ordering (issue #553)' do
    it 'draws the replay before the banner on a resumed run' do
      entry  = OutputBuffer::Entry.new(type: :user, origin: :user, content: 'do the thing')
      buffer = double('buffer', replay_tail: [entry])
      registry = double('registry', foreground_buffer: buffer)
      harness = double('harness')
      allow(harness).to receive(:rules_repair_note).and_return(nil)
      allow(harness).to receive(:mcp_status_notes).and_return([])
      allow(harness).to receive(:logger).and_return(double(info: nil))
      allow(harness).to receive(:session_manager).and_return(
        double(active_profile_name: 'm', target_display: 't'))
      allow(harness).to receive(:model_config).and_return(double(base_url: 'u'))

      expect(ui).to receive(:puts).with(/^Resumed output/).ordered
      expect(ui).to receive(:puts).with(/^Harness ready/).ordered
      expect(ui).to receive(:puts).at_least(:once)

      banner(resumed: true, registry: registry, harness: harness).print
    end

    # issue #527: the pid is printed because the case it serves is a run that has to
    # be killed from outside, so it belongs with the other run-identity facts.
    it 'prints the process id after the session line' do
      harness = double('harness')
      allow(harness).to receive(:rules_repair_note).and_return(nil)
      allow(harness).to receive(:mcp_status_notes).and_return([])
      allow(harness).to receive(:logger).and_return(double(info: nil))
      allow(harness).to receive(:session_manager).and_return(
        double(active_profile_name: 'm', target_display: 't'))
      allow(harness).to receive(:model_config).and_return(double(base_url: 'u'))

      lines = []
      allow(ui).to receive(:puts) { |line = nil| lines << line }
      banner(harness: harness).print

      session_line = lines.index { |l| l.to_s.start_with?('Session: abc123') }
      expect(lines[session_line + 1]).to eq("Process: #{Process.pid}")
    end

    it 'skips the replay when resume_replay_on_startup is false' do
      entry  = OutputBuffer::Entry.new(type: :user, origin: :user, content: 'do the thing')
      buffer = double('buffer', replay_tail: [entry])
      registry = double('registry', foreground_buffer: buffer)
      s = SystemSettings.from_options(resume_replay_on_startup: false)
      harness = double('harness')
      allow(harness).to receive(:rules_repair_note).and_return(nil)
      allow(harness).to receive(:mcp_status_notes).and_return([])
      allow(harness).to receive(:logger).and_return(double(info: nil))
      allow(harness).to receive(:session_manager).and_return(
        double(active_profile_name: 'm', target_display: 't'))
      allow(harness).to receive(:model_config).and_return(double(base_url: 'u'))

      allow(ui).to receive(:puts)
      banner(resumed: true, registry: registry, harness: harness, settings: s).print

      expect(ui).not_to have_received(:puts).with(/^Resumed output/)
      expect(ui).to have_received(:puts).with(/^Harness ready/)
    end
  end
end
