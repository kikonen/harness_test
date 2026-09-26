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
class GitApplyTool < GitRunner
  def initialize(file_list)
    @file_list = file_list
    super(
      name: 'git.apply',
      description: 'Applies a unified diff patch to the working tree (like `git apply`). ' \
                   'Provide the full unified diff (with --- / +++ / @@ hunks). ' \
                   'Use dry_run to validate without applying. ' \
                   'Unlike file.patch, no sha is required and multiple files are supported.',
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

    dry_run   = args['dry_run'] == true
    three_way = args['three_way'] == true

    # Applying a patch modifies files: every file the diff touches must be
    # writable. Missing grants are requested one by one (the user can grant
    # a parent directory recursively, which may cover several targets at once).
    targets = touched_files(diff).map { |rel| resolve_path(rel) }
    targets.each do |target|
      next if @file_list.writable?(target)

      result = @file_list.grant_access(target, :w)
      return "error: write access denied for '#{@file_list.display_path(target)}'" \
             unless result == :granted
    end

    Tempfile.create(['harness_git_apply', '.diff']) do |tmp|
      # Normalize to LF - git apply expects consistent line endings.
      tmp.write(diff.gsub("\r\n", "\n"))
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
        puts "  [git.apply] ✗ #{msg}"
        $stdout.flush
        return msg
      end

      applied = result[:stdout].strip
      label   = dry_run ? 'validated (dry run)' : 'applied'
      puts "  [git.apply] ✓ #{label}"
      $stdout.flush
      note = applied.empty? ? '' : "\n#{applied}"
      dry_run ? "ok: patch is valid (dry run, nothing changed)#{note}" \
              : "ok: patch applied to the working tree#{note}"
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