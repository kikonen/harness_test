# frozen_string_literal: true

require_relative "../command"
require_relative "../ui/palette"
require_relative "../ui/renderer"
require_relative "../ui/dialog"

module Commands
  # /palette [name|status] - show or switch the rendered-output palette for this
  # session. The switch lands on the NEXT turn (a Task builds its renderer once
  # at Task#run); the choice is saved with the session. Validation is not here -
  # it is Harness#output_palette=. Rules: doc/output_rendering_design.md.
  class PaletteCommand < Command
    HELP = CommandHelp.new(
      usage: "palette [name|status]",
      summary: "Show or switch the output palette for this session " \
        "(default | basic16 | none); saved with the session",
      group: :output,
      forms: ["palette", "palette status", "palette <name>"],
      see_also: %w[help])

    # [type, content, bracket label] - a status role's label travels in the
    # origin, and the renderer supplies the indent.
    SAMPLE = [
      [:step_label, 1, nil],
      [:plan, "inspect the drain loop first", nil],
      [:tool_plan, "file.read, file.search", nil],
      [:status_ok, "lib/foo.rb", "file.read"],
      [:status_fail, "lib/bar.rb (not found)", "file.read"],
      [:error, "hunk at old-line 42 did not apply", nil],
      [:response, "Done. The answer keeps its own formatting.", nil]
    ].freeze

    # Reported grouped by KIND so the list is readable, not one long run.
    ROLE_GROUPS = [
      ["turn roles", UI::Renderer::LABELS.keys],
      ["status roles", UI::Renderer::STATUS_TYPES],
      ["marker roles", %i[marker rule]],
      ["dialog roles", [:dialog_option] + UI::Dialog::NOTE_ROLES.values],
      ["note roles", %i[system stats compact]]
    ].freeze

    def handle(args)
      arg = args.to_s.strip.downcase
      case arg
      when "", "status"
        report
      else
        set(arg)
      end
    end

    private

    def set(name)
      previous = @harness.output_palette&.name
      @harness.output_palette = name
      current = @harness.output_palette

      # Same shape as /yolo: the bare bracketed label is the ack.
      changed = current.name != previous
      label   = changed ? "(was #{previous || 'none'})" : "(unchanged)"
      @ui.puts "  [palette: #{current.name}] #{label}"
      @ui.puts "  Effective from the next turn (this turn's Task already chose)."
      print_roles(current)
      print_sample(current)
      @ui.puts "  Saved with the session (resume keeps it). Startup choice:"
      @ui.puts "  -p/--palette NAME or 'output_palette:' in the config."
    end

    def report
      current = @harness.output_palette
      @ui.puts "Output palette: #{current ? current.name : 'none'}"
      print_roles(current)
      print_sample(current)
      @ui.puts "Switch with /palette <name>; available: " \
        "#{UI::Palette.names.join(', ')}"
      @ui.puts "  basic16 - codes stay inside 30..37 (a 16-color-only terminal)"
      @ui.puts "  none    - no color at all (what --no-color selects)"
    end

    # What the palette actually paints, so the names are not guesswork.
    def print_roles(palette)
      ROLE_GROUPS.each do |heading, roles|
        painted = roles.filter_map do |role|
          code = palette&.color_for(role)
          code.nil? ? nil : "#{role}=#{code}"
        end
        shown = painted.empty? ? "(terminal color)" : painted.join(" ")
        @ui.puts "  #{heading}: #{shown}"
      end
      @ui.puts "  plain roles: model answer, tool notes, command output"
      @ui.puts "  dialog kind context: the terminal's own color (content, not chrome)"
    end

    # Rendered through the SAME UI::Renderer the drain loop uses, so the
    # preview is the real thing and not a hand-built approximation.
    def print_sample(palette)
      renderer = UI::Renderer.new(palette:)
      SAMPLE.each do |type, content, origin|
        line = renderer.line(type:, content:, origin:)
        # A boundary or status line already carries its own shape; a labeled
        # role gets the sample's own indent.
        shaped = origin || UI::Renderer::BOUNDARY_ROLES.include?(type)
        @ui.puts(shaped ? line : "  #{line}")
      end
    end
  end
end
