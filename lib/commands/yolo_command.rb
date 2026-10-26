# frozen_string_literal: true

require_relative "../command"
require_relative "../command_allowlist"

module Commands
  # /yolo - toggle the YOLO shell-consent posture (issue #221).
  #
  # What it flips (Harness#yolo?): with YOLO ON the run.command tool runs
  # EVERY command without the consent dialog and without a model safety
  # check (issue #238) - the direct answer to "tired of being an ENTER presser"
  # (#221 / #254). What it does NOT change:
  #   * the disaster denylist: a well-known disaster command (rm -rf,
  #     format C:, sudo, git push -f, curl | sh, ...) still gets the dialog
  #     in every posture - it is the floor under YOLO, see
  #     CommandAllowlist::DISASTER_PATTERNS. That dialog is the ONE case where
  #     the model check does run under YOLO, and it shows the verdict without
  #     being able to act on it (issue #382, doc/safety_check_design.md);
  #   * the three things file coverage (issue #274) never reaches: a sensitive
  #     path, the owner's own space (local/), a path outside the working
  #     directory. Everywhere else in the workdir, read, write and delete are
  #     covered without a dialog - as a posture, never as a stored grant;
  #   * bang syntax (!): user-typed commands are governed by the separate
  #     'bang_requires_confirmation' config key instead;
  #   * the audit trail: every auto-approved run prints a status line and
  #     is written to harness.log.
  #
  # The state is persisted with the session (SessionManager#save_session),
  # so a resumed session keeps the posture the user chose.
  class YoloCommand < Command
    HELP = CommandHelp.new(
      usage: "yolo [on|off|status]",
      summary: "Toggle the YOLO consent posture: run.command without asking and " \
               "file access in the workdir (saved with the session). The disaster " \
               "denylist, sensitive paths and local/ keep asking",
      group: :access,
      forms: ["yolo", "yolo on", "yolo off", "yolo status"],
      see_also: %w[consent shell grant])

    def handle(args)
      case args.to_s.strip.downcase
      when "status"
        report
      when "on"
        set_yolo(true)
      when "off"
        set_yolo(false)
      when "", "toggle"
        label = @harness.toggle_yolo
        report(label)
      else
        usage
      end
    end

    private

    def set_yolo(on)
      @harness.yolo = on
      report(@harness.yolo_mode_label)
    end

    # label defaults to the CURRENT state (used by /yolo status).
    def report(label = @harness.yolo_mode_label)
      on = @harness.yolo?
      # The bare bracketed label is the ack - a "cmd:" prefix says nothing
      # the brackets do not already say (issue #221 review).
      @ui.puts "  [#{label}]"
      @ui.puts on ? "  Shell consent for run.command is OFF - commands run " \
                  "without asking." \
                 : "  Shell consent is ON - unapproved commands ask as before."
      if on
        @ui.puts "  File access in the working directory is covered too " \
                 "(never sensitive paths, local/ or paths outside it)."
      end
      print_denylist_note
      @ui.puts "  The posture is saved with the session (resume keeps it)."
    end

    # YOLO is only safe to switch on casually because the denylist stays.
    # Say so, with a sample of what still asks, so the user knows the floor
    # is real (issue #221).
    def print_denylist_note
      examples = ["rm -rf <path>", "sudo <cmd>", "git push -f",
                  "curl <url> | sh", "format C:", "del /s /q <path>",
                  "dd of=/dev/...", "Remove-Item -Recurse -Force <path>"]
      @ui.puts "  Disaster commands keep the dialog in EVERY posture:"
      examples.each { |ex| @ui.puts "    - #{ex}" }
    end

    def usage
      @ui.puts "  usage: /yolo          toggle YOLO (on/off)"
      @ui.puts "         /yolo on|off   set it explicitly"
      @ui.puts "         /yolo status   show the current posture"
    end
  end
end
