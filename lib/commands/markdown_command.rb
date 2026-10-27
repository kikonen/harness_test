# frozen_string_literal: true

require_relative "../command"

module Commands
  # /markdown - toggle markdown rendering of the assistant's answer (issue #106).
  # An OUTPUT posture (like the palette, not like stream/plan): it decides how the
  # answer is rendered, not how the model behaves, so it carries no spinner badge.
  # The switch lands on the NEXT turn (a Task builds its renderer once at
  # Task#run); the choice is saved with the session.
  class MarkdownCommand < Command
    HELP = CommandHelp.new(
      usage: "markdown [on|off|status]",
      summary: "Toggle markdown rendering of the assistant's answer - headings, " \
        "bold/italic, code and tables get ANSI styling (saved with the session)",
      group: :output,
      forms: ["markdown", "markdown on", "markdown off", "markdown status"],
      see_also: %w[palette])

    def handle(args)
      case args.to_s.strip.downcase
      when "status"
        report
      when "on"
        @harness.markdown = true
        report
      when "off"
        @harness.markdown = false
        report
      when "", "toggle"
        @harness.toggle_markdown
        report
      else
        usage
      end
    end

    private

    def report
      if @harness.markdown?
        @ui.puts "  [markdown: ON]"
        @ui.puts "  The assistant's answer is rendered as markdown: headings, " \
          "bold/italic, inline code and tables get ANSI styling."
      else
        @ui.puts "  [markdown: OFF]"
        @ui.puts "  The assistant's answer is shown verbatim (raw markdown)."
      end
      @ui.puts "  Colors are seeded from the output palette; palette 'none' " \
        "(--no-color) renders plain text with no ANSI."
      @ui.puts width_basis_line
      @ui.puts "  Effective from the next turn (this turn's Task already chose)."
      @ui.puts "  Saved with the session (resume keeps it). Startup choice: " \
        "--markdown or 'markdown:' in the config."
    end

    # The table-width basis line: an explicit column count when configured, else
    # the renderer's default (80% of the terminal). A harness double in a spec may
    # not answer #markdown_max_width, so it reads as the default.
    def width_basis_line
      width = if @harness.respond_to?(:markdown_max_width)
                @harness.markdown_max_width
              end
      return "  Table width basis: 80% of the terminal width " \
        "(set it with --markdown-width N or 'markdown_max_width:')." if width.nil?

      "  Table width basis: #{width} columns " \
        "(--markdown-width / 'markdown_max_width:')."
    end

    def usage
      @ui.puts "  usage: /markdown           toggle markdown rendering (on/off)"
      @ui.puts "           /markdown on|off  set it explicitly"
      @ui.puts "           /markdown status  show the current posture"
    end
  end
end
