# frozen_string_literal: true

require_relative "output_budget"
require_relative "result_spill"

# Answers a read of a spill file (issue #551, cut off from Harness in #582).
# A session dir is blocked for the file tools, so the tool that spilled asks
# THIS object instead of the harness that owns the session. The spill is read
# through a callable so the job dir is resolved when the read happens, not when
# the tool was registered.
class SpillReader
  def initialize(file_list:, result_spill:, output_result_bytes:)
    @file_list           = file_list
    @result_spill        = result_spill
    @output_result_bytes = output_result_bytes
  end

  # nil when the path is not one of this job's spill files.
  def read_spilled_result(path)
    spill = @result_spill.call
    rel = @file_list.relative_path(@file_list.resolve(path))
    return nil unless rel && spill.covers?(rel)

    ResultSpill::ALREADY_CAPPED_MARK +
      OutputBudget.read_capped(@file_list.resolve(path), limit: @output_result_bytes)[0]
  rescue SystemCallError => e
    "error: cannot read #{path} (#{e.message})"
  end
end
