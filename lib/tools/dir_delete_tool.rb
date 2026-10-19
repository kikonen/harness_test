# frozen_string_literal: true

require_relative "../tool"
require_relative "../file_list"

# Deletes a directory WITH ITS WHOLE TREE (issue #290): the whole tree is
# validated BEFORE a single entry is removed, one DELETE grant covers it, and
# every path removed is written to harness.log. Children are removed before
# their directory; a symlink INSIDE the tree is unlinked as a leaf and never
# followed, and a target path that is itself a symlink is refused outright
# (following it would delete a tree outside the granted path).
module Tools

  class DirDeleteTool < Tool
    def initialize(file_list, session: nil, harness: nil)
      @file_list = file_list
      # issue #170: deleted files lose their digest-cache entry.
      @session   = session
      # Read live (#harness&.logger): a mid-run /resume (#280) hands the tools a
      # NEW harness, so storing a Logger here would write to the replaced run.
      @harness   = harness
      super(
        name: "dir.delete",
        description: "Deletes a directory and, when it is not empty, its whole tree " \
                     "(every file and subdir under it). Paths outside the working " \
                     "directory require explicit user approval; the working directory " \
                     "itself can never be deleted, and a tree containing a sensitive " \
                     "subdir (.git, .harness, .env*) is refused. Deleting requires a " \
                     "DELETE access grant (its own mode, independent from read/write). " \
                     "A path that is itself a symlink is refused - unlink it with " \
                     "file.delete. Every deleted path is recorded in harness.log.",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "Path of the directory to delete (relative to the working dir)"
            }
          },
          required: ["path"]
        }
      )
    end

    def execute(args)
      path  = @file_list.resolve(args["path"])
      shown = @file_list.display_path(path)

      if @file_list.sensitive?(path)
        status(:fail, "#{shown} (blocked: sensitive path)")
        return "error: path '#{shown}' is blocked and can never be deleted"
      end

      # A symlink is deleted by file.delete: following it here would delete
      # the target's tree, which lives OUTSIDE what the grant and the log
      # describe. Checked before File.directory?, which follows the link.
      if File.symlink?(path)
        status(:fail, "#{shown} (a symlink)")
        return "error: '#{shown}' is a symlink - delete it with file.delete " \
               "(following it here would delete a tree outside the granted path)"
      end

      unless File.directory?(path)
        status(:fail, "#{shown} (not a directory)")
        return "error: '#{shown}' does not exist or is not a directory"
      end

      if path == @file_list.workdir
        status(:fail, "#{shown} (the working directory itself)")
        return "error: '#{shown}' is the working directory - it can never be deleted"
      end

      # Post-order (children before their directory) so Dir.rmdir never sees
      # a non-empty directory. Walked up front: the whole tree is validated
      # before a single entry is removed.
      entries = post_order(path)

      blocked = entries.find { |e| @file_list.sensitive?(e) }
      if blocked
        blocked_shown = @file_list.display_path(blocked)
        status(:fail, "#{shown} (blocked: contains #{blocked_shown})")
        return "error: directory '#{shown}' contains the sensitive path " \
               "'#{blocked_shown}' - nothing was deleted"
      end

      denial = grant_error(path, shown, entries)
      return denial if denial

      warn_unlogged
      files, dirs = delete_tree(entries)
      Dir.rmdir(path)
      log("deleted directory #{shown} (#{files} file(s), #{dirs} dir(s))")

      status(:ok, "#{shown} (#{files} file(s), #{dirs} dir(s) deleted)")
      "ok: directory '#{shown}' and its contents have been deleted " \
        "(#{files} file(s), #{dirs} dir(s); each path logged)"
    end

    private

    # -- Tree walk -----------------------------------------------------------

    # Children first, then each entry itself; a symlink-to-directory is a
    # leaf (unlinked, never descended into).
    def post_order(dir)
      list = []
      Dir.children(dir).sort.each do |name|
        child = File.join(dir, name)
        list.concat(post_order(child)) if real_dir?(child)
        list << child
      end
      list
    end

    def real_dir?(path)
      !File.symlink?(path) && File.directory?(path)
    end

    # -- Consent -------------------------------------------------------------

    # One grant for the whole tree. A grant that does not cover every entry
    # (a flat choice on a nested tree) is refused rather than deleting half
    # the tree, so the user can re-run and pick recursive.
    def grant_error(path, shown, entries)
      return nil if entries.all? { |e| @file_list.deletable?(e) }

      purpose = "to delete directory '#{shown}' with its contents " \
                "(#{entries.size} entries)"
      result  = @file_list.grant_access(path, :d, purpose:)
      unless Tool.granted?(result)
        return Tool.denial_error("error: delete access denied for '#{shown}'", result)
      end

      uncovered = entries.find { |e| !@file_list.deletable?(e) }
      return nil unless uncovered

      status(:fail, "#{shown} (grant does not cover the tree)")
      "error: the delete grant on '#{shown}' does not cover its contents " \
        "(#{uncovered_entry(uncovered)}) - choose the recursive grant to delete a tree"
    end

    def uncovered_entry(path)
      "#{@file_list.display_path(path)} (#{File.directory?(path) ? 'subdir' : 'file'})"
    end

    # -- Deletion ----------------------------------------------------------

    def delete_tree(entries)
      files = 0
      dirs  = 0
      entries.each do |entry|
        dir = real_dir?(entry)
        if dir
          Dir.rmdir(entry)
          dirs += 1
        else
          File.unlink(entry)
          files += 1
          @session&.file_cache&.clear(entry, workdir: @file_list.workdir)
        end
        log("deleted #{dir ? 'directory' : 'file'} #{@file_list.display_path(entry)}")
      end
      [files, dirs]
    end

    # Mandatory audit trail (issue #290): the deletion is only traceable if
    # each path lands in harness.log.
    def log(line)
      @harness&.logger&.info("dir.delete: #{line}")
    end

    # A tool built without a harness (unit specs) has nowhere to write the
    # audit trail; one console warning is enough - the entry-by-entry variant
    # would flood the terminal with one line per deleted path.
    def warn_unlogged
      return if @harness&.logger

      status(:warn, "no harness attached - deleted paths are not logged")
    end
  end
end
