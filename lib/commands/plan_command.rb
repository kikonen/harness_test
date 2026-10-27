# frozen_string_literal: true

require_relative "../command"
require_relative "../plans"

module Commands
  # /plan - the planning posture (issue #359): the model drafts and iterates a
  # stored plan before modifying code.
  #
  # ADVISORY by the owner's decision: the mode gates NO tool. It names itself
  # with the [PLAN] badge and states the expectation in every turn's instruction.
  # Phase 2 is the mode on/off only - which stored plan is "active" is a later
  # phase. Enforcement strength and the loop: doc/planning_mode_design.md.
  class PlanCommand < Command
    HELP = CommandHelp.new(
      usage: "plan [on|off|status]",
      summary: "Toggle planning mode: draft and iterate a stored plan before " \
        "editing code",
      group: :session,
      forms: ["plan", "plan on", "plan off", "plan status"],
      see_also: %w[plans memory stream])

    def handle(args)
      case args.to_s.strip.downcase
      when "status"
        report
      when "on"
        @harness.plan = true
        report
      when "off"
        @harness.plan = false
        report
      when "", "toggle"
        report(@harness.toggle_plan)
      else
        usage
      end
    end

    private

    # label defaults to the CURRENT state (used by /plan status). A nil label
    # means the posture is off - the badge only names a non-default.
    def report(label = @harness.plan_mode_label)
      @ui.puts "  [#{label || 'PLANNING OFF'}]"
      if @harness.plan?
        @ui.puts "  Planning mode is on: draft and iterate a plan with plan.add " \
          "before modifying code, and keep it in the durable store."
        @ui.puts "  [PLAN] is tagged wherever the postures are shown: the spinner " \
          "badge AND the idle prompt line (the same builder #387 unified)."
      else
        @ui.puts "  Planning mode is off: no planning expectation is stated."
      end
      @ui.puts "  Advisory mode: no tool is refused. Enforcement strength: " \
        "doc/planning_mode_design.md."
    end

    def usage
      @ui.puts "  usage: /plan           toggle planning mode (on/off)"
      @ui.puts "         /plan on|off    set it explicitly"
      @ui.puts "         /plan status    show the current posture"
    end
  end
end
