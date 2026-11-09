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
      see_also: %w[model param ctx],
      form_notes: {
        "stream" => "toggle streaming (on/off)",
        "stream on" => "set it explicitly",
        "stream off" => "set it explicitly",
        "stream status" => "show the current posture"
      })

    def handle(args)
      case args.to_s.strip.downcase
      when "status"
        report
      when "on"
        @harness.stream = true
        report
      when "off"
        @harness.stream = false
        report
      when "", "toggle"
        report(@harness.toggle_stream)
      else
        render_usage
      end
    end

    private

    # label defaults to the CURRENT state (used by /stream status). A nil
    # label means the posture is off - the badge only names a non-default.
    def report(label = @harness.stream_mode_label)
      emit_role(:ack, label || "BUFFERED")
      # The whole report body is contiguous prose -> ONE note call, one paragraph
      # per array entry. No aligned-column block here to keep verbatim.
      paras = if @harness.stream?
                [
                  "Responses stream in: the spinner shows the answer " \
                    "as it arrives with the rate it is arriving at, and [STREAM] " \
                    "is tagged wherever the postures are shown: the spinner badge " \
                    "AND the idle prompt line (issue #387).",
                  "A streamed request is retried only until the first part " \
                    "arrives - after that a lost stream fails the turn instead " \
                    "of re-sending."
                ]
              else
                [
                  "Responses are buffered: the whole answer arrives " \
                    "before it is printed (the full retry policy applies)."
                ]
              end
      paras += [
        "The spinner also shows a tok/s rate: the live rate " \
          "while an answer streams, else the rate of the request that last " \
          "completed (issue #285); '~' marks one the harness estimated, not the " \
          "server.",
        "Saved with the session (resume keeps it)."
      ]
      emit_role(:note, paras)
    end
  end
end
