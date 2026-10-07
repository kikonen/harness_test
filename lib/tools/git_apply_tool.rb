# frozen_string_literal: true

require 'tempfile'

require_relative '../git_runner'

# Applies a unified diff patch to the working tree (git apply).
# The model provides the diff text; it is written to a temporary file
# and passed to `git apply`. By default this only touches the working
# tree (not the index), mirroring the behavior of `file.patch` but
# using git's own robust patch engine.
#
# Options:
#   dry_run  - validate with `git apply --check` without applying
#   three_way - if the direct apply fails, retry with a 3-way merge
#               (requires the blob objects to be present in the repo)
#
# issue #170: takes an optional trailing `session` argument - when given,
# patched files are checked against the digest cache (external-change
# detection) and their new digests are recorded on success.
# issue #171: the diff is normalized before git sees it (CRLF -> LF and
# trailing whitespace stripped from every line), which absorbs the two
# most common model output quirks. Hunk line numbers are treated as
# hints by git itself, so small numbering mistakes are tolerated too.
# issue #22: structurally broken diffs (no hunk at all, or hunks without
# any file header) fail up front with an actionable message instead of
# the generic "does not match the working tree" error.
module Tools

  class GitApplyTool < GitRunner
    def initialize(file_list, session = nil)
      @file_list = file_list
      @session   = session
      super(
        name: 'git.apply',
        description: 'Applies a unified diff patch to the working tree (like `git apply`). ' \
                     'Provide the full unified diff (with --- / +++ / @@ hunks). ' \
                     'Use dry_run to validate without applying. ' \
                     'Unlike file.patch, multiple files can be patched in a single call. ' \
                     'Hunk line numbers and stray trailing whitespace are tolerated.',
        parameters: {
          type: 'object',
          properties: {
            diff:      { type: 'string',  description: 'Unified diff to apply (standard format with --- / +++ / @@ hunks)' },
            dry_run:   { type: 'boolean', description: 'Validate the patch with `git apply --check` without applying it (default false)' },
            three_way: { type: 'boolean', description: 'If a direct apply fails, retry with a 3-way merge (default false)' }
          },
          required: ['diff']
        }
      )
    end

    def execute(args)
      diff = args['diff'].to_s
      return 'error: \'diff\' is required' if diff.strip.empty?

      # issue #22: catch structurally broken diffs before git sees them.
      bad = structural_error(diff)
      return bad if bad

      dry_run   = args['dry_run'] == true
      three_way = args['three_way'] == true

      files = touched_files(diff)

      # Applying a patch modifies files: every file the diff touches must be
      # writable. Missing grants are requested one by one (the user can grant
      # a parent directory recursively, which may cover several targets at once).
      targets = files.map { |rel| resolve_path(rel) }
      targets.each do |target|
        next if @file_list.writable?(target)

        result = @file_list.grant_access(target, :w)
        return Tool.denial_error(
          "error: write access denied for '#{@file_list.display_path(target)}'", result
        ) unless Tool.granted?(result)
      end

      if files.any?
        Tool.puts "  [git.apply] #{dry_run ? 'would patch' : 'patching'}: #{files.join(', ')}"
      end

      # issue #170: external-change detection (see file.write /
      # file.patch) - the on-disk digest of every known file must still
      # match what we cached, otherwise a re-read is needed first.
      guard = external_change_guard(files)
      return guard if guard

      Tempfile.create(['harness_git_apply', '.diff']) do |tmp|
        # issue #171: normalize before git sees the diff - consistent LF
        # line endings and no trailing whitespace on any line (a common
        # model output quirk that would otherwise hard-fail context lines).
        tmp.write(normalize_diff(diff))
        tmp.flush

        result = run_git('git', 'apply', *apply_flags(dry_run), tmp.path)

        # `git apply` is atomic (nothing is changed when a hunk fails), so
        # a 3-way retry after a failure is always safe.
        if result[:status] != 0 && three_way && !dry_run
          result = run_git('git', 'apply', *apply_flags(false, true), tmp.path)
        end

        if result[:status] != 0
          detail = result[:stderr].strip.empty? ? result[:stdout].strip : result[:stderr].strip
          msg = "error: git apply failed (exit #{result[:status]}): #{detail.lines.first&.strip || 'no error message'}"
          msg += '. The patch does not match the working tree - check the context lines and retry, or use file.patch per file.'
          Tool.puts "  [git.apply] ✗ #{msg}"
          return "#{msg}\nfiles: #{files.join(', ')}" if files.any?
          msg
        end

        # issue #170: our own patch refreshes the cache.
        record_cache(files) unless dry_run

        applied = result[:stdout].strip
        label   = dry_run ? 'validated (dry run)' : 'applied'
        Tool.puts "  [git.apply] ✓ #{label} (#{files.join(', ')})" if files.any?
        Tool.puts "  [git.apply] ✓ #{label}" unless files.any?
        note = applied.empty? ? '' : "\n#{applied}"
        files_note = files.any? ? " [#{files.join(', ')}]" : ''
        dry_run ? "ok: patch is valid (dry run, nothing changed)#{files_note}#{note}" \
                : "ok: patch applied to the working tree#{files_note}#{note}"
      end
    end

    private

    def apply_flags(check, three_way = false)
      flags = []
      flags << '--check' if check
      flags << '--3way'  if three_way
      # Be lenient about whitespace (a common model output quirk).
      flags << '--whitespace=nowarn'
      flags
    end

    # issue #22: pre-validate the diff's structure so the model gets an
    # actionable message for inputs git would reject outright. Returns an
    # error string, or nil when the structure looks plausible and git can
    # be trusted to judge content:
    #   - no '@@' line at all -> "No valid patches in input"
    #   - hunks but no file headers (--- / +++ / diff --git) ->
    #     "patch fragment without header at line N"
    def structural_error(diff)
      text = diff.gsub("\r\n", "\n")
      if text.scan(/^@@ /).empty?
        'error: the diff contains no hunks (no "@@ -x,y +a,b @@" lines). ' \
          'Provide the full unified diff, or use file.patch for a single file.'
      elsif touched_files(text).any?
        nil
      else
        'error: the diff has hunks but no file headers. Each hunk must be ' \
          'preceded by a "--- a/<file>" and "+++ b/<file>" line (a full ' \
          '"diff --git" header is also fine). For single-file edits, ' \
          'file.patch is more forgiving.'
      end
    end

    # issue #171: normalize a model-produced diff before handing it to
    # git: CRLF -> LF (git apply expects consistent line endings) and
    # trailing whitespace stripped from every line, so stray spaces in
    # context lines do not hard-fail the match (a common model quirk).
    def normalize_diff(diff)
      diff.gsub("\r\n", "\n")
          # Strip trailing whitespace before each newline; a blank context
          # line ("" or " ") is left empty either way, and the file's own
          # final newline is preserved.
          .gsub(/[ \t]+\n/, "\n")
    end
    # issue #170: external-change detection (same rule as file.write and
    # file.patch) - every touched file that has a cached digest must still
    # match the on-disk bytes, otherwise someone changed it outside us.
    # Returns an error string for the first offending file, else nil.
    def external_change_guard(files)
      return nil unless @session && files.any?

      files.each do |rel|
        path = resolve_path(rel)
        next unless File.file?(path)

        current = FileList.sha256(path)
        cached  = @session.file_cache.digest(path, workdir: workdir)
        next unless cached && current != cached

        shown = @file_list.display_path(path)
        Tool.puts "  [git.apply] ✗ #{shown} (externally changed since last read)"
        return "error: '#{shown}' has changed externally since you last read it. " \
               'Re-read the file with file.read, or report the external change ' \
               'with file.touch if you know what happened.'
      end
      nil
    end

    # issue #170: our own patch refreshes the cache for every touched
    # file (new files get an entry; missing ones are left alone).
    def record_cache(files)
      return unless @session

      files.each do |rel|
        path = resolve_path(rel)
        next unless File.file?(path)

        sha = FileList.sha256(path)
        @session.file_cache.record(path, sha, workdir: workdir) if sha
      end
    end

    # Extracts the list of files a unified diff touches, from its
    # "diff --git a/x b/y" / "--- a/x" / "+++ b/y" header lines.
    # Returns workdir-relative paths (deduplicated). "/dev/null"
    # entries (new/deleted files) are skipped - the other side of the
    # pair still names the real file.
    def touched_files(diff)
      diff.gsub("\r\n", "\n").lines.map do |line|
        m = line.match(/\A(?:diff --git a\/\S+ b\/|\+\+\+ b\/)(\S+)/)
        m && m[1] != '/dev/null' ? m[1] : nil
      end.compact.uniq
    end
  end
end
