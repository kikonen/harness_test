# frozen_string_literal: true

require "fileutils"

require_relative "session_locator"
require_relative "sensitive_files"

# Where the full text of a tool result too large for the conversation goes
# (issue #551). Design: doc/tool_output_budget_design.md.
#
# The chain keeps a bounded preview plus this path; the full result is filed in
# the session's OWN directory, under the job that produced it:
#   .harness/sessions/<id>/jobs/<job>/results/<tool>-<seq>.txt
#
# A session dir is harness state, so FileList blocks it for the model's file tools
# (only .harness/skills and a scratch zone are exempt - SensitiveFiles::SENSITIVE_DIRS
# matches every component). The model's recovery route is therefore the SHELL (a
# pipe through head/tail, which is exactly what narrows an oversized dump), and the
# path is named so the USER can open the file.
class ResultSpill
  # Spill files one job keeps (issue #551 spill-dir growth, issue #595). A spill
  # is only reachable while the conversation still names its path, so a window
  # this wide never cuts a spill a live turn could still read; the prune runs at
  # compaction, which is when the previews citing the oldest ones leave the chain.
  DEFAULT_KEEP = 50

  # Prefix a spill read's result carries so the result guard can tell the read is
  # already capped: re-fitting it would spill the spill and log a cap the model
  # never got. The guard strips it before the text enters the chain.
  ALREADY_CAPPED_MARK = "spilled tool output, already capped: "

  SPILL_DIR = "results"

  def initialize(locator, job_id: 0, dir: SPILL_DIR, keep: DEFAULT_KEEP)
    @locator    = locator
    @job_id     = job_id
    @dir        = dir
    @keep       = keep.to_i
  end

  attr_reader :job_id

  # Writes `text` under the job's results dir and returns the working-dir-relative
  # path.
  def write(tool_name, seq, text)
    dir  = File.join(@locator.job_dir(@job_id), @dir)
    name = "#{safe_name(tool_name)}-#{seq}.txt"
    path = File.join(dir, name)
    FileUtils.mkdir_p(dir)
    File.write(path, text.to_s)
    @locator.relative_path(path)
  end

  # Drop this job's oldest spill files, keeping the newest +keep+ (issue #551
  # spill-dir growth, issue #595). Ordered by the sequence number in the name -
  # mtime ties within a fast run, and a resumed run appends to the same dir, so
  # the number is the only reliable order. Returns the paths removed.
  def prune
    dir = File.join(@locator.job_dir(@job_id), @dir)
    return [] unless File.directory?(dir)
    return [] if @keep <= 0 # 0 or negative disables the window

    entries = Dir.glob(File.join(dir, "*.txt")).filter_map do |path|
      seq = File.basename(path)[/-(\d+)\.txt\z/, 1]
      seq && [path, seq.to_i]
    end
    return [] if entries.size <= @keep

    oldest = entries.sort_by { |_path, seq| seq }.first(entries.size - @keep)
    removed = oldest.map(&:first)
    removed.each { |path| FileUtils.rm_f(path) }
    removed
  rescue SystemCallError
    # A failed prune must not break the turn that triggered it; the dir simply
    # keeps growing until the next prune.
    []
  end

  # True when a model-supplied path names one of this job's spill files: the file
  # tools cannot open a session dir, so the tool that spilled answers the read
  # itself (Harness#read_spilled_result). The prefix is built from THIS job's own
  # paths, and a name carrying ".." is refused rather than resolved.
  def covers?(path)
    rel = path.to_s
    return false if rel.empty? || rel.include?("..")

    rel == prefix || rel.start_with?("#{prefix}/")
  end

  # A path inside this job's results dir that no longer exists: the spill window
  # removed it (or it was never written). Without this a pruned path falls through
  # to the normal file-tool route and reports "access denied", which reads as a
  # permission problem rather than what happened.
  def pruned?(path)
    return false unless covers?(path)

    !File.file?(File.join(@locator.workdir, path))
  end

  private

  def prefix
    @locator.relative_path(@locator.job_dir(@job_id)) + "/#{@dir}"
  end

  def safe_name(tool_name)
    tool_name.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")
  end
end
