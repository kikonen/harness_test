# frozen_string_literal: true

require_relative "../command"
require_relative "../command_allowlist"
require_relative "../web_host_allowlist"

module Commands
  # /clear - revoke grants. A bare /clear (or "access") is the file/dir access
  # list, exactly as it always was; the named forms revoke the OTHER consent
  # lists, which had no revocation path at all - a stored command prefix or web
  # host could only be removed by hand-editing its .yml (issue #104).
  class ClearCommand < Command
    HELP = CommandHelp.new(
      usage: "clear [list]",
      forms: [
        "clear",
        "clear access",
        "clear commands",
        "clear shell",
        "clear hosts",
        "clear all"
      ],
      summary: "Revoke grants: bare (or access) clears every file/dir grant; " \
        "commands, shell and hosts clear the run.command, shell ! and " \
        "web.fetch allowlists; all clears every one of them",
      group: :access,
      see_also: %w[grant access consent])

    FORMS = {
      "access" => :access,
      "commands" => :commands,
      "shell" => :shell,
      "hosts" => :hosts,
      "all" => :all
    }.freeze

    # Singular and plural label per allowlist, so the count line reads as
    # English rather than an appended 's'.
    LABELS = {
      commands: ["run.command prefix", "run.command prefixes"],
      shell: ["shell (!) prefix", "shell (!) prefixes"],
      hosts: ["web.fetch host grant", "web.fetch host grants"]
    }.freeze

    def handle(args)
      name = args.to_s.strip.downcase
      name = "access" if name.empty?
      return report_unknown(name) unless FORMS.key?(name)

      targets = name == "all" ? FORMS.values : [FORMS[name]]
      targets.each { |target| @ui.puts(clear_target(target)) }
    end

    private

    def report_unknown(name)
      emit_role(
        :note,
        "Unknown /clear form: #{name} " \
          "(known: #{FORMS.keys.join(', ')})")
    end

    def clear_target(target)
      case target
      when :access
        @file_list.clear
        "Access list cleared."
      when :commands
        cleared_line(CommandAllowlist.new(@file_list.workdir).clear, :commands)
      when :shell
        cleared_line(shell_allowlist.clear, :shell)
      else
        cleared_line(WebHostAllowlist.new(@file_list.workdir).clear, :hosts)
      end
    end

    def shell_allowlist
      CommandAllowlist.new(@file_list.workdir, file: CommandAllowlist::SHELL_FILENAME)
    end

    def cleared_line(count, key)
      singular, plural = LABELS[key]
      return "No #{plural} to clear." if count.zero?

      "Cleared #{count} #{count > 1 ? plural : singular}."
    end
  end
end
