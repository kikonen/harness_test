# frozen_string_literal: true

require_relative "../tool"
require_relative "../file_list"
require_relative "../text_normalizer"

module Tools

  class FileReadTool < Tool
    def initialize(file_list, session = nil)
      @file_list = file_list
      # issue #170: optional Session - when given, files read by the model
      # are recorded in its digest cache (external-change detection for
      # later write/patch). nil is only used by specs that never write.
      @session   = session
      super(
        name: "file.read",
        description: "Reads the contents of a file. " \
                     "Paths are relative to the harness working directory. " \
                     "Returns the full file content.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Path to the file to read (relative to the working directory)" }
          },
          required: ["path"]
        }
      )
    end

    def execute(args)
      path = @file_list.resolve(args["path"])
      shown = @file_list.display_path(path)

      unless @file_list.readable?(path)
        result = @file_list.grant_access(path, :r)
        return Tool.denial_error("error: access denied for '#{shown}'", result) unless Tool.granted?(result)
      end

      unless File.file?(path)
        status(:fail, "#{shown} (not found)")
        return "error: file not found: #{shown}"
      end

      # issue #257: a file on disk can hold bytes that are not valid UTF-8
      # (or a code page tagged by Encoding.default_external). Reading it raw
      # leaves the string byte-invalid, so the gsub below - and everything
      # downstream (JSON session save, the console) - raises. Normalize at
      # this read boundary so every consumer sees valid UTF-8.
      content = TextNormalizer.normalize(File.read(path))

      # Normalize CRLF to LF so the LLM always sees clean line endings.
      content = content.gsub("\r\n", "\n")

      # issue #170: remember what the model just read so a later write/patch
      # can detect EXTERNAL changes (the cache lives in the Session and is
      # part of its persistence).
      if @session
        sha = FileList.sha256(path)
        @session.file_cache.record(path, sha, workdir: @file_list.workdir) if sha
      end

      status(:ok, shown)

      content
    end
  end
end
