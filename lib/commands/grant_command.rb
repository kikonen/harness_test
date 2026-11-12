# frozen_string_literal: true

require_relative "../command"
require_relative "../command_allowlist"
require_relative "../web_host_allowlist"

module Commands
  # /grant - show all current grants: file/dir access grants (read, write,
  # delete), command allowlist prefixes and web.fetch host grants. Replaces the
  # constant grant display that used to be printed above every prompt (issue
  # #101). A host grant is security state, so it belongs here too (issue #33).
  class GrantCommand < Command
    HELP = CommandHelp.new(
      usage: "grant",
      summary: "Show every current grant: file/dir access per mode and both " \
        "command allowlists (run.command and shell !) plus web.fetch hosts, all " \
        "separately",
      group: :access,
      see_also: %w[clear access consent shell])

    def handle(_args)
      access = @file_list.accessible_paths
      labels = { both: "Read + write", read: "Read only", write: "Write only", delete: "Delete" }

      %i[both read write delete].each do |mode|
        items = store_items(access[mode])
        next if items.empty?

        emit_list(
          title: "#{labels[mode]}:",
          kind: :table,
          columns: %i[number path annotation],
          items:,
          origin: "grant")
      end

      # YOLO's file coverage is a POSTURE, not a stored grant (issue #274): it is
      # shown here because /grant is where a user checks what a run is allowed to
      # touch, and a posture that auto-approves silently must never be invisible.
      # It is not part of the access lists above because a session saves and
      # restores those - a posture must never persist into a resumed grant.
      if @file_list.respond_to?(:posture_active?) && @file_list.posture_active?
        scope = @file_list.posture_scope
        # Name the dirs the posture actually leaves asking (issue #385), not a
        # hardcoded local/ - the list is configurable.
        protected = @file_list.protected_dirs.map { |dir| "#{dir}/" }.join(", ")
        except = protected.empty? ? "sensitive paths" : "sensitive paths and #{protected}"
        emit_role(:note,
"Posture (YOLO): read, write and delete cover " \
  "#{scope}/ (except #{except}) - not a stored grant")
      end

      tool_list = CommandAllowlist.new(@file_list.workdir).prefixes
      shell_list = CommandAllowlist.new(@file_list.workdir,
                                        file: CommandAllowlist::SHELL_FILENAME)
                             .prefixes
      hosts = WebHostAllowlist.new(@file_list.workdir).hosts

      unless hosts.empty?
        # issue #474: a 1-field bullet list emitted as STRUCTURE (the host is
        # one field per item), not a fused "  - host" string. UI::Renderer#bullet_row
        # reproduces the old line byte-for-byte. The footer states an indent
        # LEVEL (not baked spaces) so a variable-width sink indents it too.
        emit_list(
          title: "Hosts for web.fetch (exact hosts only):",
          items: hosts.map { |host| { value: host } },
          columns: [:value],
          footer: [{ text: "revoke with: /clear hosts", indent: 1 }],
          origin: "grant")
      end

      if tool_list.empty? && shell_list.empty?
        emit_role(:note, "Commands: (none allowed)")
        return
      end

      unless tool_list.empty?
        emit_list(
          title: "Commands for run.command:",
          items: tool_list.map { |p| { value: p } },
          columns: [:value],
          footer: [{ text: "revoke with: /clear commands", indent: 1 }],
          origin: "grant")
      end
      unless shell_list.empty?
        emit_list(
          title: "Commands for shell (!):",
          items: shell_list.map { |p| { value: p } },
          columns: [:value],
          footer: [{ text: "revoke with: /clear shell", indent: 1 }],
          origin: "grant")
      end
    end

    private

    # One row per stored grant, in the order files, recursive dirs, flat dirs. The
    # ordinal is the row's position in that order, so it is a field the payload
    # carries rather than a number the emitter bakes into a string.
    def store_items(section)
      items = []

      section[:files].each do |f|
        items << {
          number: items.size + 1,
          path: @file_list.display_path(f),
          annotation: ""
        }
      end

      section[:dirs].each do |d|
        # The standing grant is on the working directory, whose display form is
        # "."; "./" reads as noise, so name it.
        label = d == @file_list.workdir ? "the working directory" \
                                        : "#{@file_list.display_path(d)}/"
        items << { number: items.size + 1, path: label, annotation: "(recursive)" }
      end

      (section[:flat_dirs] || []).each do |d|
        items << {
          number: items.size + 1,
          path: "#{@file_list.display_path(d)}/",
          annotation: "(dir only)"
        }
      end

      items
    end
  end
end
