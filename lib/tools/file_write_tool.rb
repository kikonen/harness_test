# frozen_string_literal: true

require_relative "../tool"
require_relative "../file_list"
require_relative "../file_text"
require "fileutils"

# Writes a COMPLETE file. An existing file keeps its own line-ending style (read
# from its bytes); see FileText and doc/file_editing_design.md.
module Tools

  class FileWriteTool < Tool
    def initialize(file_list, session = nil)
      @file_list = file_list
      # issue #170: optional Session - when given, writes are checked
      # against the digest cache (external-change detection) and record
      # the new digest on success. nil only for specs that never had a
      # prior read in-session (nothing to detect).
      @session   = session
      super(
        name: "file.write",
        description: "Writes content to a file. " \
                     "Paths are relative to the harness working directory. " \
                     "The content must be the COMPLETE file content. " \
                     "An existing file keeps its own line-ending style; content " \
                     "carrying the other style is normalized to it. " \
                     "If the file may have been modified EXTERNALLY since you last read it " \
                     "(you can tell, e.g. from a git diff or another tool's output), re-read " \
                     "it with file.read first so the write is based on fresh content.",
        parameters: {
          type: "object",
          properties: {
            path:    { type: "string", description: "Path to the file to write (relative to the working directory)" },
            content: { type: "string", description: "Complete content to write to the file" }
          },
          required: ["path", "content"]
        }
      )
    end

    def execute(args)
      path    = @file_list.resolve(args["path"])
      shown   = @file_list.display_path(path)
      content = args["content"]

      unless @file_list.writable?(path)
        result = @file_list.grant_access(path, :w)
        return Tool.denial_error("error: access denied for '#{shown}'", result) unless Tool.granted?(result)
      end

      # issue #170: external-change detection. If the file exists and was
      # read in this session, the on-disk digest must still match what we
      # cached - otherwise someone (or something) changed it OUTSIDE us.
      # This is deliberately NOT a concurrency lock: only changes the
      # harness did not make itself are flagged.
      if @session && File.file?(path)
        current = FileList.sha256(path)
        cached  = @session.file_cache.digest(path, workdir: @file_list.workdir)
        if cached && current != cached
          status(:fail, "#{shown} (externally changed since last read)")
          return "error: '#{shown}' has changed externally since you last read it. " \
                 "Re-read the file with file.read, or report the external change " \
                 "with file.touch if you know what happened."
        end
      end

      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless dir == "."

      # An EXISTING file keeps its own line-ending style (read from its bytes);
      # a new file follows the content's majority style.
      existing = File.file?(path) ? FileText.from_disk(path) : nil
      model    = FileText.from_text(content)
      separator = existing ? existing.separator : model.separator
      notes = []
      notes << FileText.repair_note(model, separator) if FileText.dirty?(model)
      notes << "previous bytes were not valid UTF-8 and are now UTF-8" if existing&.lossy
      note = notes.empty? ? "" : " (#{notes.join('; ')})"
      status(:note, "#{shown}#{note}") if notes.any?
      FileText.write(path, model.text, separator)

      # issue #170: our own write refreshes the cache (the file is now in
      # the exact state we wrote it).
      if @session
        sha = FileList.sha256(path)
        @session.file_cache.record(path, sha, workdir: @file_list.workdir) if sha
      end

      status(:ok, "#{shown} (#{content.length} chars)")
      "ok: wrote #{content.length} chars to #{shown}#{note}"
    end
  end
end
