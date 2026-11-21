# frozen_string_literal: true

require_relative "../tool"
require_relative "../file_list"
require_relative "../text_normalizer"
require_relative "../output_budget"

module Tools

  class FileReadTool < Tool
    # spill_reader: an object with read_spilled_result(path) (the run's Harness),
    # or nil. A tool result too large for the conversation is spilled into the
    # session dir, which FileList blocks as harness state, so the owner answers
    # a spill read (issue #551).
    # byte_budget: the largest file returned whole; a bigger one comes back as a
    # head+tail byte slice. nil = OutputBudget::DEFAULT_RESULT_BYTES.
    def initialize(file_list, file_cache = nil, spill_reader: nil, byte_budget: nil)
      @file_list = file_list
      # issue #170: optional digest cache - when given, files read by the model
      # are recorded in it (external-change detection for later write/patch).
      # nil is only used by specs that never write.
      @file_cache   = file_cache
      @spill_reader = spill_reader
      @byte_budget  = byte_budget || OutputBudget::DEFAULT_RESULT_BYTES
      super(
        name: "file.read",
        description: "Reads the contents of a file. " \
                     "Paths are relative to the harness working directory. " \
                     "Returns the full file content. A file larger than the " \
                     "byte budget returns its first and last bytes with the " \
                     "middle named - search it, or read a narrower file, for " \
                     "the rest.",
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

      # A spilled tool result lives in the session dir, which FileList blocks as
      # harness state - no grant can make it readable through the normal route,
      # so the owner is asked BEFORE the grant dialog (issue #551).
      if @spill_reader && File.file?(path) && (spilled = @spill_reader.read_spilled_result(path))
        status(:ok, "#{shown} (spilled tool output)")
        return clean_text(spilled)
      end

      unless @file_list.readable?(path)
        result = @file_list.grant_access(path, :r)
        return Tool.denial_error("error: access denied for '#{shown}'", result) unless Tool.granted?(result)
      end

      unless File.file?(path)
        status(:fail, "#{shown} (not found)")
        return "error: file not found: #{shown}"
      end

      # The pre-read size gate (issue #551): an oversized file is never loaded
      # whole, so one read cannot blow up this tool's string, harness.log, or
      # the chain. Same head+tail rule the byte budget uses, applied to BYTES.
      if File.size(path) > @byte_budget
        content, total = OutputBudget.read_capped(path, limit: @byte_budget)
        record_digest(path)
        status(:warn, "#{shown} (#{total} bytes - capped to #{@byte_budget})")
        return clean_text(content)
      end

      # issue #257: a file on disk can hold bytes that are not valid UTF-8
      # (or a code page tagged by Encoding.default_external). Reading it raw
      # leaves the string byte-invalid, so the gsub below - and everything
      # downstream (JSON session save, the console) - raises. Normalize at
      # this read boundary so every consumer sees valid UTF-8.
      content = clean_text(File.read(path))

      # issue #170: remember what the model just read so a later write/patch
      # can detect EXTERNAL changes (the cache is part of the session's
      # persistence).
      record_digest(path)

      status(:ok, shown)

      content
    end

    private

    # Normalization at the read boundary plus LF line endings (issue #257).
    def clean_text(text)
      TextNormalizer.normalize(text).gsub("\r\n", "\n")
    end

    def record_digest(path)
      return unless @file_cache

      sha = FileList.sha256(path)
      @file_cache.record(path, sha, workdir: @file_list.workdir) if sha
    end
  end
end
