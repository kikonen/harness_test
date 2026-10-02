# frozen_string_literal: true

require 'ui'
require 'stringio'

# Headless tests for the spinner's TUI renderer (issue #74): ratatui_ruby's
# test terminal works WITHOUT a real TTY (verified locally and it runs on
# ubuntu-latest CI), so we can drive draw_tui_frame directly with
# deterministic frames. These never touch a real terminal: the ratatui
# native extension is required only here, and the behavioral suite stays on
# the ANSI path and does not load it.
require 'ratatui_ruby'

RSpec.describe UI::Spinner do
  describe 'TUI renderer (headless test terminal)' do
    before do
      RatatuiRuby.init_test_terminal(80, 24, 'inline', 1)
    end

    after do
      RatatuiRuby.restore_terminal
      expect(RatatuiRuby.terminal_active?).to be(false)
    end

    it 'draws the frame, message and suffix through a ratatui paragraph' do
      spinner = described_class.new('Sending to gpt-x', 'ctx 42133/65536 (64%)')
      tui = RatatuiRuby::TUI.new
      spinner.draw_tui_frame(tui, 0)
    end

    it 'produces the exact frame text shared with the ANSI renderer' do
      spinner = described_class.new('Sending to gpt-x', 'ctx 42133/65536 (64%)')
      expect(spinner.line(0)).to eq('⠋ Sending to gpt-x... ctx 42133/65536 (64%)')
    end

    it 'renders the message only when no suffix is given' do
      spinner = described_class.new('Working')
      expect(spinner.line(1)).to eq('⠙ Working...')
    end

    it 'keeps polling events without hanging when no input is pending' do
      spinner = described_class.new('Working')
      tui = RatatuiRuby::TUI.new
      3.times { spinner.draw_tui_frame(tui, 0) } # three poll cycles, no hang
    end

    it 'receives injected key events through the test terminal queue' do
      tui = RatatuiRuby::TUI.new
      expect(tui.poll_event(timeout: 0.05)).to be_a(RatatuiRuby::Event::None)
      RatatuiRuby.inject_test_event('key', { code: 'q', modifiers: [] })
      expect(tui.poll_event(timeout: 0.5)).to be_a(RatatuiRuby::Event::Key)
    end
  end
end
