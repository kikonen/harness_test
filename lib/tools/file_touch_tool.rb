# frozen_string_literal: true

require_relative "../tool"
require_relative "../file_list"

# Re-baselines a file's cached digest after an EXTERNAL change so a file.write or
# file.patch blocked by the "changed externally since last read" guard can
# proceed. It NEVER creates or modifies the file - it only reconciles the digest
# cache (issue #170; lifecycle: doc/session_file_cache_design.md).
module Tools
  class FileTouchTool < Tool
    def initialize(file_list, file_cache = nil)
      @file_list  = file_list
      # Optional digest cache: the entry this tool re-baselines. nil only for
      # specs that never had a prior read in-session (nothing to reconcile).
      @file_cache = file_cache
      super(
        name: "file.touch",
        description: "Re-baselines a file's cached digest after an external change, so " \
          "a file.write or file.patch blocked by 'changed externally since " \
          "you last read it' can proceed. Use it when you know the external " \
          "change is expected; it does NOT create or modify the file and does " \
          "not bypass a write grant. Paths are relative to the working directory.",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "Path of the file to touch (relative to the working directory)"
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
        status(:fail, "#{shown} (blocked: sensitive file)")
        return "error: file '#{shown}' is blocked and can never be touched"
      end

      unless @file_cache
        status(:fail, "#{shown} (no file cache)")
        return "error: no file cache is active - there is nothing to re-baseline"
      end

      # Reconciling a file you read: a read grant (a write grant implies it). It
      # never lets a write skip its own grant - only the digest cache is touched.
      unless @file_list.readable?(path)
        result = @file_list.grant_access(
          path, :r, purpose: "re-baseline after an external change")
        return Tool.denial_error(
          "error: access denied for '#{shown}'",
          result) unless Tool.granted?(result)
      end

      if File.file?(path)
        current = FileList.sha256(path)
        if current.nil?
          status(:fail, "#{shown} (could not read)")
          return "error: could not read '#{shown}' to re-baseline it"
        end

        cached = @file_cache.digest(path, workdir: @file_list.workdir)
        @file_cache.record(path, current, workdir: @file_list.workdir)

        if cached.nil?
          status(:ok, "#{shown} (digest recorded)")
          return "ok: recorded the current digest of '#{shown}' (no cached entry)"
        end
        if cached == current
          status(:ok, "#{shown} (unchanged)")
          return "ok: '#{shown}' is unchanged since you last read it - an external " \
            "change was not the cause of a blocked write"
        end

        status(:note, "#{shown} (re-baselined)")
        "ok: re-baselined '#{shown}' to its current digest (it had changed externally)"
      else
        if @file_cache.known?(path, workdir: @file_list.workdir)
          @file_cache.clear(path, workdir: @file_list.workdir)
          status(:note, "#{shown} (entry cleared: file gone)")
          return "ok: '#{shown}' is no longer on disk - dropped its stale cached digest"
        end

        status(:fail, "#{shown} (not found)")
        "error: file '#{shown}' is not on disk and has no cached entry to reconcile"
      end
    end
  end
end
