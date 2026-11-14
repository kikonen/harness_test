# frozen_string_literal: true

# Issue #286 phase 0: the registry holds a flat list of jobs, each with its OWN
# buffer, and one buffer is the active foreground one. Run from the repo root:
#   ruby analysis/286/repro.rb
#
# What is measurable WITHOUT a registry (none exists): the key that decides
# whether two jobs writing the same (origin, type) stream can be told apart.
# The owner's shape (2026-11-14) is one buffer per job, so the job is supplied by
# WHICH buffer a cell lives in and the key stays (origin, type) inside it. A
# single shared buffer is the shape that cannot express it - the two writes land
# in the same cell and their text is concatenated.
#
# Measured on master bf9938e:
#   shared buffer, key [origin, type]      -> ONE cell, text merged - COLLAPSED
#   one buffer per job, same key           -> TWO cells, text kept separate
#   tasks_kept                             -> read by HarnessConfig, enforced nowhere
require_relative "../../lib/output_buffer"
require_relative "../../lib/harness_config"

STREAM = [:session_manager, :response].freeze

def grow(buffer, text)
  buffer.put(type: :response, origin: :session_manager, content: text, mode: :append)
end

shared = OutputBuffer.new
grow(shared, "answer from job 1")
grow(shared, "answer from job 2")

puts "shared buffer, key [origin, type]: #{shared.head.size} cell " \
  "-> #{shared.head.size == 1 ? 'COLLAPSED' : 'separate'}"
puts "  content: #{shared.cell(*STREAM).content.inspect}"

per_job = [OutputBuffer.new, OutputBuffer.new]
grow(per_job[0], "answer from job 1")
grow(per_job[1], "answer from job 2")

puts "one buffer per job: #{per_job.sum { |b| b.head.size }} cells -> separate"
per_job.each_with_index do |buffer, i|
  puts "  job #{i + 1}: #{buffer.cell(*STREAM).content.inspect}"
end

config = HarnessConfig.new(output: { tail_memory: 200, tasks_kept: 2 })
puts "tasks_kept read by config: #{config.output_tasks_kept.inspect} (enforced nowhere)"
puts "limits each buffer enforces itself: " \
  "max_memory=#{shared.max_memory}, max_saved=#{shared.max_saved}"
