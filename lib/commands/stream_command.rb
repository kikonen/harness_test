# frozen_string_literal: true

require_relative "../command"

module Commands
  # /stream - toggle streamed LLM responses: the next request's body is consumed
  # chunk by chunk and each part is shown as it arrives. The posture is the
  # harness's, saved with the session; what streaming does and does NOT change
  # (response shape, retry boundary, advisory calls): doc/streaming_design.md.
  class StreamCommand < Command
    HELP = CommandHelp.new(
      usage: "stream [on|off|status]",
      summary: "Toggle streamed LLM responses: show each part as it arrives " \
               "(saved with the session)",
      group: :model,
      forms: ["stream", "stream on", "stream off", "stream status"],
      see_also: %w[model param ctx])

    def handle(args)
      case args.to_s.strip.downcase
      when "status"
        report
      when "on"
        set_stream(true)
      when "off"
        set_stream(false)
      when "", "toggle"
        report(@harness.toggle_stream)
      else
        usage
      end
    end

    private

    def set_stream(on)
      @harness.stream = on
      report(@harness.stream_mode_label)
    end

    # label defaults to the CURRENT state (used by /stream status). A nil
    # label means the posture is off - the badge only names a non-default.
    def report(label = @harness.stream_mode_label)
      on = @harness.stream?
      @ui.puts "  [#{label || 'BUFFERED'}]"
      @ui.puts on ? "  Responses stream in: the spinner shows the answer as it " \
                  "arrives, and the spinner badge reads [STREAM]." \
                 : "  Responses are buffered: the whole answer arrives before " \
                   "it is printed (the full retry policy applies)."
      @ui.puts "  A streamed request is retried only until the first part " \
               "arrives - after that a lost stream fails the turn instead of " \
               "re-sending."
      @ui.puts "  Saved with the session (resume keeps it)."
    end

    def usage
      @ui.puts "  usage: /stream           toggle streaming (on/off)"
      @ui.puts "         /stream on|off    set it explicitly"
      @ui.puts "         /stream status    show the current posture"
    end
  end
end
