# frozen_string_literal: true

require_relative "ui"
require_relative "command_help"
require_relative "task_runner"
require_relative "ui/help_renderer"

# Shared base for the slash-command classes in lib/commands/.
#
# Commands take an explicit `ui:` object (UI::Console) so that no command
# code references $stdout/$stdin directly. A TUI can later swap the
# underlying stream for a panel/draw sink without touching any command.
#
# Includes TaskRunner (issue #235): a command that drives an LLM round
# (/retry issue #235, /compact issue #253) runs it on a Task thread via
# #run_on_task, the same shared wrapper a direct prompt uses, and prints
# through #emit_line so its lines stay on the event queue.
class Command
  include TaskRunner

  attr_reader :settings, :file_list, :ui, :help_renderer

  # Every command class declares its own HELP (a CommandHelp). /help renders it
  # from the dispatch registry, so a command that has no help entry fails loudly
  # the first time help is asked for instead of being silently missing from the
  # listing (issue #323).
  def self.help
    return const_get(:HELP) if const_defined?(:HELP, false)

    raise HarnessError, "#{name} declares no HELP (see CommandHelp)"
  end

  # Whether this command may run WHILE a turn is running (a mid-turn submit
  # dispatched on the main thread). Default true: edit mode allows all commands
  # (doc/unified_loop_design.md). A command opts OUT when it cannot run safely
  # while a turn is live: one that drives an LLM round (#run_on_task) would start
  # a nested drain loop over the single queue (double render, lost events) -
  # refused until it becomes an event to the live task - and one that rebuilds or
  # ends the whole run (exit) has no live loop to act in.
  def self.mid_turn_safe?
    true
  end

  def initialize(
    file_list:,
    ui:,
    help_renderer: nil,
    settings: nil,
    registry: nil,
    system_saver: nil,
    harness_factory: nil,
    session_id: nil
  )
    @file_list  = file_list
    @ui         = ui
    # Only /help renders it; every other command ignores it.
    @help_renderer = help_renderer
    # The run-wide config + posture/consent state (#286). Commands read the
    # resolved config through settings' named accessors (or []), never a raw
    # options bag. A posture command reads and writes it directly here.
    @settings = settings
    # The JobRegistry the run owns (#286): TaskRunner#run_on_task awaits its
    # job and TaskRunner records main-thread reports into it.
    self.registry = registry
    self.system_saver = system_saver
    # The run's HarnessFactory and the SYSTEM id its jobs save under (#548):
    # a command that adds an agent to the run needs both, and only the run
    # owner (the CLI) knows the id. Commands that do not build an agent ignore
    # them, so they stay optional keyword args.
    @harness_factory = harness_factory
    @session_id      = session_id
  end

  # A command reaches the Harness through the FOREGROUND job it acts on (#286),
  # never a global: a Harness lives INSIDE a Job, so this reads the one on the
  # job the run's registry marks foreground. A command built without a registry
  # (a unit-test double for a read-only command) gets nil. Named for the job it
  # reads off, so a later background/sub-agent harness reads the same way.
  def foreground_harness
    registry.foreground_job&.harness
  end

  # Print this command's usage on a bad argument (issue #471) from its own HELP
  # (usage + forms + form_notes), NOT a hand-aligned block. Replaces each
  # command's old private #usage. Falls back to a registry-less UI::HelpRenderer when
  # none was injected (a command built in a spec): render_inline is registry-
  # independent, so it still emits the same lines.
  def render_usage
    renderer = @help_renderer || UI::HelpRenderer.new(registry: {})
    renderer.render_inline(self.class.help).each { |line| @ui.puts line }
  end
end
