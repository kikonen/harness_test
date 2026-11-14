# frozen_string_literal: true

# Issue #286 phase 0: the registry holds a flat list of jobs, each with its OWN
# buffer, and one buffer is the active foreground one. Run from the repo root:
#   ruby analysis/286/repro.rb
#
# What is measurable WITHOUT a registry (none existed): the key that decides
# whether two jobs writing the same (origin, type) stream can be told apart.
# The owner's shape (2026-11-14) is one buffer per job, so the job is supplied by
# WHICH buffer a cell lives in and the key stays (origin, type) inside it. A
# single shared buffer is the shape that cannot express it - the two writes land
# in the same cell and their text is concatenated.
#
# Measured on master bf9938e:
#   shared buffer, key [origin, type]      -> ONE cell, text merged - COLLAPSED
#   one buffer per job, same key           -> TWO cells, text kept separate
# Measured on feature/286-registry-design (increment 1, first runtime):
#   tasks_kept                             -> enforced by Registry#retain
#   fan-in to ONE registry queue           -> cross-job order is push order, and
#     each event lands in the buffer the event names, so the same key over two
#     jobs stays two cells through the queue too

require_relative "../../lib/output_buffer"
require_relative "../../lib/harness_config"
require_relative "../../lib/registry"

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

config = HarnessConfig.new(output: { tasks_kept: 2 })
puts "tasks_kept read by config: #{config.output_tasks_kept.inspect} " \
  "-> enforced by Registry#retain (its first consumer)"

registry = Registry.new(tasks_kept: config.output_tasks_kept)
main = registry.add_job(kind: :main)
child = registry.add_job(kind: :sub_agent, requested_by: main)

# Fan-in: both jobs push onto the ONE queue, so the order they pushed is the
# order the poller reads - cross-job order is defined without a per-job pipe.
child.push_event(
  type: :response, origin: :session_manager, content: "answer from job 1", mode: :append)
main.push_event(
  type: :response, origin: :session_manager, content: "answer from job 2", mode: :append)

order = []
while (event = registry.poll(0))
  order << event[:job]
  registry.record(event)
end

puts "fan-in order (push order): #{order.inspect}"
[main, child].each do |job|
  puts "  job ##{job.id} buffer cell: #{job.buffer.cell(*STREAM).content.inspect}"
end

# Retention: the finished foreground job occupies one slot and is never itself
# dropped, so the two newest finished jobs fill what is left.
3.times { registry.add_job(kind: :command, requested_by: main).finish }
survivors = registry.jobs.select(&:finished?).map(&:id)
puts "retained after 3 finished commands with tasks_kept=2: " \
  "#{registry.jobs.map(&:id).inspect} (finished survive: #{survivors.inspect})"

puts "limits each buffer enforces itself: " \
  "max_memory=#{shared.max_memory}, max_saved=#{shared.max_saved}"
