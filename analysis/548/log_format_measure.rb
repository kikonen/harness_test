# frozen_string_literal: true

# Issue #548 (session layers) / #286 (job model): measurements behind the
# single-harness.log decision. Runs from a fresh clone; writes only into its own
# directory. Verified on Ruby 4.0.7 / logger.rb v1.7.0, x64-mingw-ucrt.

require "logger"
require "fileutils"

OUT  = __dir__
N    = 200
BIG  = "X" * 200
PAD  = "!E!job-0!INFO #{BIG}\n".bytesize
LOGS = %w[one_logger two_loggers thread_name progname delimiter multiline]

# Logger.new appends to an existing path, so each run must start from a clean
# directory or the counts double.
LOGS.each do |name|
  FileUtils.rm_f(File.join(OUT, "#{name}.log"))
end

def header(text)
  puts "\n== #{text} =="
end

def stamp(job)
  lambda do |sev, _dt, _prog, msg|
    "!E!#{job}!#{sev} #{msg}\n"
  end
end

def hammer(loggers, times)
  loggers.map { |lg| Thread.new { times.times { lg.info(BIG) } } }.each(&:join)
end

def read_lines(name)
  File.readlines(File.join(OUT, "#{name}.log")).drop(1)
end

def count_job(lines, tag)
  lines.count { |l| l.include?(tag) }
end

# 1. One Logger object, several threads, one path: nothing is lost.
one = Logger.new(File.join(OUT, "one_logger.log"))
one.formatter = lambda do |sev, _dt, _p, _m|
  job = Thread.current[:harness_job] || "-"
  "!E!#{job}!#{sev} #{BIG}\n"
end
[0, 3].map do |id|
  Thread.new do
    Thread.current[:harness_job] = "job-#{id}"
    N.times { one.info(BIG) }
  end
end.each(&:join)

single = read_lines("one_logger")
header("ONE Logger, two threads, thread-local job stamp")
puts "writes #{2 * N}  lines #{single.size}"
puts "job-0 #{count_job(single, 'job-0')}  job-3 #{count_job(single, 'job-3')}"

# 2. Two Logger objects on the same path: writes are lost.
l1 = Logger.new(File.join(OUT, "two_loggers.log"))
l2 = Logger.new(File.join(OUT, "two_loggers.log"))
l1.formatter = stamp("job-0")
l2.formatter = stamp("job-3")
mutex  = l1.instance_variable_get(:@log_mutex)
shared = mutex.equal?(l2.instance_variable_get(:@log_mutex))
hammer([l1, l2], N)

raw  = File.binread(File.join(OUT, "two_loggers.log"))
both = raw.lines
header("TWO Loggers, same path")
puts "shared @log_mutex #{shared}"
puts "writes #{2 * N}  lines #{both.size}"
puts "bytes #{raw.bytesize} of #{2 * N * PAD} expected"
puts "job-0 #{count_job(both, 'job-0')}  job-3 #{count_job(both, 'job-3')}"

# 3. Thread identity: name works on the calling thread, is nil in a nested one.
named = Logger.new(File.join(OUT, "thread_name.log"))
named.formatter = lambda do |sev, _dt, _p, msg|
  "!E!#{Thread.current.name.inspect}!#{sev} #{msg}\n"
end
Thread.current.name = "main-job-0"
Thread.new do
  Thread.current.name = "job-3"
  named.info "parent thread"
  Thread.new { named.info "nested thread" }.join
end.join
named.info "main thread"
header("Thread.current.name visibility")
read_lines("thread_name").each { |l| puts l }

# 4. Logger#progname reaches the formatter as the third proc argument.
pg = Logger.new(File.join(OUT, "progname.log"))
pg.formatter = lambda do |sev, _dt, prog, msg|
  "!E!#{prog}!#{sev} #{msg}\n"
end
pg.progname = "job-7"
pg.info "via logger.progname"
pg.info("via-call-progname") { "via block form" }
header("Logger#progname channel")
read_lines("progname").each { |l| puts l }

# 5. A payload that CONTAINS a line-start delimiter is read as a new event.
delim = Logger.new(File.join(OUT, "delimiter.log"))
delim.formatter = stamp("job-3")
body = "fetched page body\n!E!job-0!INFO this line is DATA\nend"
delim.warn body
events = read_lines("delimiter").count { |l| l.start_with?("!E!") }
header("Delimiter inside payload (naive line parser)")
puts "expected 1 event, parser sees #{events}"

# 6. Today's real breakage: a multi-line message loses its header on continuations.
multi = Logger.new(File.join(OUT, "multiline.log"))
multi.formatter = lambda do |sev, dt, _p, msg|
  "#{dt.strftime('%Y-%m-%d %H:%M:%S')} [#{sev}] #{msg}\n"
end
multi.warn "shell command failed:\nline2\nline3"
mb     = read_lines("multiline")
headed = mb.count { |l| l.match(/^\d{4}-/) }
header("Current SessionLogger format, multi-line message")
puts "lines #{mb.size}  headed #{headed}  unheaded #{mb.size - headed}"
