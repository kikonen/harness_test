# frozen_string_literal: true

require_relative '../tool'
require_relative '../file_list'
require 'fileutils'

module Tools

  class FileWriteTool < Tool
    def initialize(file_list, options, session = nil)
      @file_list = file_list
      @options   = options
      # issue #170: optional Session - when given, writes are checked
      # against the digest cache (external-change detection) and record
      # the new digest on success. nil only for specs that never had a
      # prior read in-session (nothing to detect).
      @session   = session
      super(
        name: 'file.write',
        description: 'Writes content to a file. ' \
                     'Paths are relative to the harness working directory. ' \
                     'The content must be the COMPLETE file content. ' \
                     'If the file may have been modified EXTERNALLY since you last read it ' \
                     '(you can tell, e.g. from a git diff or another tool\'s output), re-read ' \
                     'it with file.read first so the write is based on fresh content.',
        parameters: {
          type: 'object',
          properties: {
            path:    { type: 'string', description: 'Path to the file to write (relative to the working directory)' },
            content: { type: 'string', description: 'Complete content to write to the file' }
          },
          required: ['path', 'content']
        }
      )
    end

    def execute(args)
      path    = @file_list.resolve(args['path'])
      shown   = @file_list.display_path(path)
      content = args['content']

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
          Tool.puts "  [file.write] ✗ #{shown} (externally changed since last read)"
          return "error: '#{shown}' has changed externally since you last read it. " \
                 'Re-read the file with file.read, or report the external change ' \
                 'with file.touch if you know what happened.'
        end
      end

      if @options[:dry_run]
        Tool.puts "  [file.write] ~ #{shown} (dry run, #{content.length} chars)"
        return "DRY RUN: would write #{content.length} chars to #{shown}"
      end

      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless dir == '.'
      File.write(path, content)

      # issue #170: our own write refreshes the cache (the file is now in
      # the exact state we wrote it).
      if @session
        sha = FileList.sha256(path)
        @session.file_cache.record(path, sha, workdir: @file_list.workdir) if sha
      end

      Tool.puts "  [file.write] ✓ #{shown} (#{content.length} chars)"
      "ok: wrote #{content.length} chars to #{shown}"
    end
  end
end
