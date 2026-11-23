# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness, 'settings, postures and mode labels' do
  include HarnessSpecSupport

  describe '#output_palette (issue #303)' do
    it 'resolves to the default palette when the option is absent' do
      expect(build_harness.settings.output_palette.name).to eq('default')
    end

    it 'resolves a configured name to that palette' do
      expect(build_harness(output_palette: 'basic16').settings.output_palette.name).to eq('basic16')
      expect(build_harness(output_palette: 'none').settings.output_palette.name).to eq('none')
    end

    it 'rejects an unknown name when the creator applies it, before any LLM call' do
      expect { build_harness(output_palette: 'crayola') }
        .to raise_error(HarnessError, /unknown output palette/)
    end
  end

  # issue #224 follow-up: the session-level command consent posture
  # (MANUAL / AUTO-APPROVE), set from config and always visible in the spinner
  # via the mode badge.
  describe '#command_safety_auto_approve / mode label (issue #224 follow-up)' do
    it 'defaults to MANUAL when the option is absent' do
      harness = build_harness(command_safety_check: true)

      expect(harness.settings.command_safety_auto_approve).to be(false)
      expect(harness.settings.command_mode_label).to eq('MANUAL')
      expect(harness.settings.command_safety_auto_approve_effective?).to be(false)
    end

    it 'starts in AUTO-APPROVE when the option is set (config default)' do
      harness = build_harness(command_safety_check: true,
                              command_safety_auto_approve: true)

      expect(harness.settings.command_mode_label).to eq('AUTO-APPROVE')
      expect(harness.settings.command_safety_auto_approve_effective?).to be(true)
    end

    it 'labels the posture MANUAL with the check off (issue #221 review)' do
      # The label is always present: with the check off nothing is
      # auto-approved, so the honest label is MANUAL - an empty spinner
      # badge read as "no posture", which is bug 2/3.
      harness = build_harness(command_safety_check: false,
                              command_safety_auto_approve: true)

      expect(harness.settings.command_mode_label).to eq('MANUAL')
      expect(harness.settings.command_safety_auto_approve_effective?).to be(false)
    end

    it 'AUTO-APPROVE is only labeled when the check is on' do
      # command_safety_auto_approve without command_safety_check auto-approves
      # nothing, so the posture label must say MANUAL, not AUTO-APPROVE.
      harness = build_harness(command_safety_check: false,
                              command_safety_auto_approve: true)

      expect(harness.settings.command_mode_label).to eq('MANUAL')
    end

    it 'coerces the setter to a boolean' do
      harness = build_harness(command_safety_check: true)
      harness.settings.command_safety_auto_approve = 'yes'
      expect(harness.settings.command_safety_auto_approve).to be(false)
      harness.settings.command_safety_auto_approve = true
      expect(harness.settings.command_safety_auto_approve).to be(true)
    end
  end

  # issue #221: the YOLO posture (the consent-fatigue fix). Like #224's
  # mode it is a USER-side consent switch (the model cannot turn it on) -
  # but unlike it, YOLO is persisted with the session (SessionManager
  # specs cover the round trip) and it wins over the AUTO-APPROVE/MANUAL
  # pair in the mode label (YOLO means no consent check at all).
  describe '#yolo? / toggle_yolo / mode label (issue #221)' do
    it 'defaults to off' do
      harness = build_harness

      expect(harness.settings.yolo?).to be(false)
    end

    it 'starts ON when the yolo option is set (config initial posture)' do
      harness = build_harness(yolo: true)

      expect(harness.settings.yolo?).to be(true)
      expect(harness.settings.command_mode_label).to eq('YOLO')
    end

    it 'YOLO wins over AUTO-APPROVE / MANUAL in the mode label' do
      harness = build_harness(command_safety_check: true,
                              command_safety_auto_approve: true, yolo: true)

      expect(harness.settings.command_mode_label).to eq('YOLO')
    end

    it 'YOLO keeps its label even with the safety check off' do
      harness = build_harness(command_safety_check: false, yolo: true)

      expect(harness.settings.command_mode_label).to eq('YOLO')
    end

    it 'toggle_yolo flips the posture and returns the new label' do
      harness = build_harness

      expect(harness.settings.toggle_yolo).to eq('YOLO ON')
      expect(harness.settings.yolo?).to be(true)
      expect(harness.settings.toggle_yolo).to eq('YOLO OFF')
      expect(harness.settings.yolo?).to be(false)
    end

    it 'coerces the setter to a boolean (truthy junk stays OFF)' do
      harness = build_harness

      harness.settings.yolo = 'yes'
      expect(harness.settings.yolo?).to be(false)
      harness.settings.yolo = true
      expect(harness.settings.yolo?).to be(true)
    end

    # issue #274: the same posture gates FILE access, so Harness wires its
    # reader into the FileList it was handed. A lambda, not a boolean copy.
    it 'wires the YOLO posture live into the file list' do
      harness = build_harness

      expect(harness.file_list.posture).to be_a Proc
      expect(harness.file_list.readable?('lib/a.rb')).to be(false)

      harness.settings.toggle_yolo
      expect(harness.file_list.readable?('lib/a.rb')).to be(true)
      expect(harness.file_list.writable?('lib/a.rb')).to be(true)
      expect(harness.file_list.deletable?('lib/a.rb')).to be(true)

      harness.settings.toggle_yolo
      expect(harness.file_list.readable?('lib/a.rb')).to be(false)
    end

    it 'leaves the owner space and sensitive paths outside the coverage' do
      harness = build_harness(yolo: true)
      list = harness.file_list

      expect(list.readable?('local/notes.md')).to be(false)
      expect(list.readable?('.git/config')).to be(false)
      expect(list.readable?('.harness/session.json')).to be(false)
      expect(list.readable?('analysis/274/repro.rb')).to be(true)
    end

    it 'wires the session logger as the posture audit logger' do
      harness = build_harness(yolo: true)

      expect(harness.file_list.audit_logger).to equal(harness.logger)
    end

    it 'never stores a grant from the posture (a resume cannot inherit it)' do
      harness = build_harness(yolo: true)
      harness.file_list.readable?('lib/a.rb')

      expect(harness.file_list.accessible_paths[:read]).to eq(
        { files: [], dirs: [], flat_dirs: [] }
      )
    end
  end

  # issue #208: the session is the working chain. When a turn dies mid-loop
  # (connection loss after the LLM answer of round N), every round already
  # made - assistant tool_calls AND tool results - must remain in the
  # SESSION, so /retry resumes from that exact point instead of replaying
  # the prompt from zero. Before this fix the trail lived only in a local
  # dup and was garbage-collected with the failed call.

  describe '#stream? / mode label / toggle (issue #28)' do
    it 'defaults to buffered when the option is absent' do
      harness = build_harness

      expect(harness.settings.stream?).to be(false)
      expect(harness.settings.stream_mode_label).to be_nil
    end

    it 'starts streaming when the option is set (config key)' do
      harness = build_harness(stream: true)

      expect(harness.settings.stream?).to be(true)
      expect(harness.settings.stream_mode_label).to eq('STREAM')
    end

    it 'labels only the non-default posture (buffered gets no spinner tag)' do
      harness = build_harness
      harness.settings.stream = true
      expect(harness.settings.stream_mode_label).to eq('STREAM')

      harness.settings.stream = false
      expect(harness.settings.stream_mode_label).to be_nil
    end

    it 'toggle_stream flips the posture and returns the new label' do
      harness = build_harness

      expect(harness.settings.toggle_stream).to eq('STREAM')
      expect(harness.settings.stream?).to be(true)
      expect(harness.settings.toggle_stream).to be_nil
      expect(harness.settings.stream?).to be(false)
    end

    it 'coerces the setter to a boolean' do
      harness = build_harness
      harness.settings.stream = 'yes'

      expect(harness.settings.stream?).to be(false)
    end
  end

  # issue #359: the planning posture. Advisory by the owner's decision - it
  # gates no tool; it names itself (the [PLAN] badge). Harness state (like
  # stream), not conversation state.
  describe '#plan? / mode label / toggle (issue #359)' do
    it 'defaults to planning off when the option is absent' do
      harness = build_harness

      expect(harness.plan?).to be(false)
      expect(harness.plan_mode_label).to be_nil
    end

    it 'starts planning when the option is set (config key)' do
      harness = build_harness(plan: true)

      expect(harness.plan?).to be(true)
      expect(harness.plan_mode_label).to eq('PLAN')
    end

    it 'labels only the non-default posture (off gets no spinner tag)' do
      harness = build_harness
      harness.plan = true
      expect(harness.plan_mode_label).to eq('PLAN')

      harness.plan = false
      expect(harness.plan_mode_label).to be_nil
    end

    it 'toggle_plan flips the posture and returns the new label' do
      harness = build_harness

      expect(harness.toggle_plan).to eq('PLAN')
      expect(harness.plan?).to be(true)
      expect(harness.toggle_plan).to be_nil
      expect(harness.plan?).to be(false)
    end

    it 'coerces the plan setter to a boolean' do
      harness = build_harness
      harness.plan = 'yes'

      expect(harness.plan?).to be(false)
    end
  end

  # issue #106: the markdown rendering posture. An OUTPUT posture (like the
  # palette, not like stream/plan): it decides how the answer is rendered, so it
  # carries NO spinner badge. Harness state, not conversation state.
  describe '#markdown? / toggle (issue #106)' do
    it 'defaults to markdown off when the option is absent' do
      harness = build_harness

      expect(harness.settings.markdown?).to be(false)
    end

    it 'starts markdown on when the option is set (config key)' do
      harness = build_harness(markdown: true)

      expect(harness.settings.markdown?).to be(true)
    end

    it 'toggle_markdown flips the posture and returns the new state' do
      harness = build_harness

      expect(harness.settings.toggle_markdown).to eq('MARKDOWN ON')
      expect(harness.settings.markdown?).to be(true)
      expect(harness.settings.toggle_markdown).to eq('MARKDOWN OFF')
      expect(harness.settings.markdown?).to be(false)
    end

    it 'coerces the markdown setter to a boolean' do
      harness = build_harness
      harness.settings.markdown = 'yes'

      expect(harness.settings.markdown?).to be(false)

      harness.settings.markdown = true
      expect(harness.settings.markdown?).to be(true)
    end
  end

  # issue #106: the table-width basis. Config-derived for the whole run (read
  # when a Task builds its renderer, like the palette) - NOT a live toggle like
  # the markdown on/off posture. nil = the renderer's default (80% of terminal).
  describe '#markdown_max_width (issue #106)' do
    it 'is nil when the option is absent (the renderer picks 80% of the terminal)' do
      expect(build_harness.settings.markdown_max_width).to be_nil
    end

    it 'reads an explicit column count from options' do
      expect(build_harness(markdown_max_width: 120).settings.markdown_max_width).to eq(120)
    end
  end

end

