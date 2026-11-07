# frozen_string_literal: true

require "fileutils"

require_relative "sensitive_files"

# The harness' own store for binary artifacts a tool produced (issue #449).
#
# WHY IT IS HARNESS STATE AND NOT tmp/: a session records the PATH of the
# artifact it was given, and tmp/ is per-machine scratch that is gone in the
# next session (the project rule). Under .harness/ the reference a saved session
# points at survives alongside the session file that names it, and the bytes
# can never be committed by accident.
#
# The MODEL writes nothing here: the harness writes it and hands the model the
# workdir-relative path. .harness/ is a sensitive path, so the model reaches
# these files with the shell (a consented run.command), not with the file tools
# - doc/sensitive_paths_design.md. The result text says so, because a model
# that blindly calls file.read on it would get a denial it cannot explain.
#
# One directory per session id: blobs belong to the run that produced them, and
# a resumed run (same id, issue #276) finds its own again.
class ImageStore
  DEFAULT_DIR = ".harness/content"

  # A name comes from a remote server's tools/list, so it is not trusted text:
  # every other character becomes "_", which also stops ".." or a separator
  # from turning a spill into a write outside the store.
  NAME_CHARS = /[^a-zA-Z0-9._-]/

  attr_reader :dir

  def initialize(workdir, dir: DEFAULT_DIR)
    @workdir = File.expand_path(workdir)
    @dir     = dir.to_s
    @count   = 0
  end

  def relative_dir
    @dir
  end

  # Write one blob; returns its workdir-relative path, or nil when the write
  # failed (a failed spill must not break a turn - the caller then reports the
  # image as dropped, which is the truth).
  def save(server:, tool:, mime_type:, bytes:)
    @count += 1
    stem = "#{sanitize(server)}_#{sanitize(tool)}"
    ext  = extension(mime_type)
    path = File.join(@workdir, @dir, "#{stem}_#{@count}#{ext}")
    FileUtils.mkdir_p(File.dirname(path))
    # A resumed run reuses this session's dir with @count back at 0, so its
    # first spill would land on a blob from the earlier run (issue #276); skip
    # any taken index so a new spill never clobbers a path a saved session names.
    while File.exist?(path)
      @count += 1
      path = File.join(@workdir, @dir, "#{stem}_#{@count}#{ext}")
    end
    File.binwrite(path, bytes.to_s)
    relative_path(path)
  rescue StandardError
    nil
  end

  # True when a stored path is harness state the file tools will not open. The
  # caller uses it to say so in the text the model reads, instead of letting it
  # discover a denial it cannot explain.
  def harness_state?(relative_path)
    SensitiveFiles.sensitive?(relative_path.to_s)
  rescue StandardError
    false
  end

  private

  def relative_path(path)
    path.sub(/\A#{Regexp.escape(@workdir)}/, "").sub(%r{\A/}, "")
  end

  def sanitize(text)
    text.to_s.gsub(NAME_CHARS, "_")[0, 40]
  end

  # ".png" for "image/png". Anything that is not a plain image subtype gets
  # ".bin": a name like "shot_1.octetstream" or "shot_1.vnd.microsoft.icon"
  # would misdescribe the artifact the model was told about.
  def extension(mime_type)
    top, subtype = mime_type.to_s.split("/", 2)
    return ".bin" unless top == "image" && subtype.to_s.match?(/\A[a-zA-Z0-9]+\z/)

    ".#{subtype}"
  end
end
