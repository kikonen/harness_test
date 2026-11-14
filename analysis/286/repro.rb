# frozen_string_literal: true

# Issue #286 phase 0: the registry layer is where the task part of the head key
# and the 'output: tasks_kept' cap first get real enforcement. Run from the repo
# root: ruby analysis/286/repro.rb
#
# What is measurable WITHOUT a TaskManager (none exists): the head key already
# accepts exactly the two parts it has today, so the shape the registry must add
# is provable in isolation. One OutputBuffer per retained Job is the shape the
# registry cannot express today - two live tasks with the SAME (origin, type)
# stream collapse into ONE cell, which is exactly what the task part of the key
# is for.
#
# Expected today (master bf9938e):
#   key is [origin, type]      -> two jobs, same origin+type, ONE cell - COLLAPSED
#   tasks_kept                 -> read by HarnessConfig, enforced nowhere
# Expected at the registry layer (phase 1):
#   key is [job, origin, type] -> two cells, one per job - NOT collapsed
require_relative "../../lib/output_buffer"
require_relative "../../lib/harness_config"

buffer = OutputBuffer.new

buffer.put(
  type: :response,
  origin: :session_manager,
  content: "answer from job 1",
  mode: :append)
buffer.put(
  type: :response,
  origin: :session_manager,
  content: "answer from job 2",
  mode: :append)

cells = buffer.head
collapsed = cells.size == 1 ? "COLLAPSED" : "separate"
puts "head key today: #{cells.map { |c| [c.origin, c.type] }.inspect}"
puts "cells for two live jobs: #{cells.size} -> #{collapsed}"
puts "merged content: #{cells.first.content.inspect} (both jobs' text in one stream)"

config = HarnessConfig.new(output: { tail_memory: 200, tasks_kept: 2 })
puts "config reads tasks_kept: #{config.output_tasks_kept.inspect}"
puts "limits the buffer enforces itself: " \
  "max_memory=#{buffer.max_memory}, max_saved=#{buffer.max_saved}"
