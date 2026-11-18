# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ui/palette'
require 'system_settings'
require 'commands/palette_command'

# issue #303: /palette switches the rendered-output palette mid-session and
# the choice travels with the session. The command only talks to
# SystemSettings#output_palette / #output_palette= (#286): use the real one,
# which resolves and validates the same way Harness does.
RSpec.describe Commands::PaletteCommand do
  def build_settings(name = nil)
    SystemSettings.new(output_palette: name)
  end

  def run_command(args = '', settings = build_settings)
    io = StringIO.new
    described_class.new(settings: settings, file_list: nil,
                        ui: UI::Console.new(stdout: io)).handle(args)
    io.string
  end

  describe 'with no argument (/palette)' do
    it 'reports the current palette name' do
      expect(run_command('', build_settings('basic16'))).to include('Output palette: basic16')
    end

    it 'lists the names it accepts' do
      out = run_command

      expect(out).to include('default, basic16, none')
      expect(out).to include('/palette <name>')
    end

    it 'accepts /palette status as the same view' do
      out = run_command('status', build_settings('basic16'))

      expect(out).to include('Output palette: basic16')
      # 'status' is reserved: it must never be treated as a palette name.
      expect(out).not_to include('unknown output palette')
    end

    it 'names which roles the palette colors and which stay plain' do
      out = run_command('', build_settings('default'))

      # A :table (#474): group, role and code are three named cells, so a
      # `role=code` pair is no longer one fused sub-string.
      expect(out).to include('│ turn roles   │ plan          │ 34               │')
      expect(out).to include('│ turn roles   │ warn          │ 38;5;130         │')
      expect(out).to include('│ status roles │ status_ok     │ 32               │')
      expect(out).to include('│ marker roles │ marker        │ 38;5;240         │')
      expect(out).to include('model answer, tool notes, command output')
    end

    # issue #388: the dialog note kinds are palette roles too, so the four hues
    # a consent dialog can print are listed (context is deliberately absent -
    # it is named on the plain-roles line instead).
    it 'lists the dialog note roles the palette colors' do
      out = run_command('', build_settings('default'))

      expect(out).to include('│ dialog roles │ dialog_option │ 36               │')
      expect(out).to include('│ dialog roles │ dialog_warn   │ 38;5;130         │')
      expect(out).to include('│ dialog roles │ dialog_alert  │ 31               │')
      expect(out).to include('│ dialog roles │ dialog_safe   │ 32               │')
      expect(out).to include('dialog kind context')
    end

    # Pinned as row prefixes: the cell padding is kramdown's, so at the 80-column
    # basis the description wraps and only the row start is width-stable.
    it 'prints the palette-name legend as a table' do
      out = run_command('', build_settings('none'))

      expect(out).to include(
        "│ name    │ description",
        "│ basic16 │ codes stay inside 30..37",
        "│ none    │ no color at all (what --no-color selects)"
      )
    end

    it 'shows a sample line so the change is visible without a new turn' do
      out = run_command('', build_settings('default'))

      expect(out).to include("\e[34mplan:  inspect the drain loop first\e[0m")
      expect(out).to include("\e[36mstep 1\e[0m")
    end

    it 'the sample shows the answer boundary the real renderer gives it' do
      out = run_command('', build_settings('none'))

      expect(out).to include("#{'-' * 36} model #{'-' * 37}")
      expect(out).to include("Done. The answer keeps its own formatting.")
    end

    it 'the none palette paints nothing in the sample either' do
      out = run_command('', build_settings('none'))

      # Every role's code cell falls back to the terminal's own color, and the
      # sample carries no escape bytes at all.
      role_count = Commands::PaletteCommand::ROLE_GROUPS.sum { |(_heading, roles)| roles.size }
      expect(out.scan(/\(terminal color\)/).size).to eq(role_count)
      expect(out).not_to include("\e[")
    end
  end

  describe 'switching (/palette <name>)' do
    it 'changes the settings palette and acks with the new label' do
      settings = build_settings('default')
      out = run_command('basic16', settings)

      expect(settings.output_palette.name).to eq('basic16')
      expect(out).to include('[palette: basic16] (was default)')
    end

    it 'says unchanged when the same palette is set again' do
      out = run_command('default', build_settings('default'))

      expect(out).to include('[palette: default] (unchanged)')
      expect(out).not_to include('was')
    end

    it 'accepts a name in any case (/palette NONE)' do
      settings = build_settings('default')
      run_command('NONE', settings)

      expect(settings.output_palette.name).to eq('none')
    end

    it 'says the choice is saved with the session' do
      expect(run_command('none')).to include('Saved with the session (resume keeps it)')
    end

    it 'rejects an unknown name with the available list' do
      expect { run_command('crayola') }
        .to raise_error(HarnessError, /unknown output palette/)
    end

    it 'leaves the palette untouched when the name is rejected' do
      settings = build_settings('basic16')
      begin
        run_command('crayola', settings)
      rescue HarnessError
        nil
      end

      expect(settings.output_palette.name).to eq('basic16')
    end
  end
end
