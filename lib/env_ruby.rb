# frozen_string_literal: true

require "bundler"
require_relative "text_normalizer"
require_relative "command_runner"

# Reports what a MODEL-SCRIPT can require: the CHILD ruby run.command spawns
# (unbundled, issue #185), never this harness' bundle, and never a promise about
# a per-machine install set. Spawn/kill rules and rationale: doc/env_ruby_design.md.
class EnvRuby
  # The probe is the script argument of `ruby -e <script>`, passed through an
  # ARGV ARRAY (no shell, so no quoting hazard; a stdin pipe would not survive
  # the unbundled spawn on Windows). It prints a TAB-separated, machine-parseable
  # report; the child ruby answers about its OWN view (Gem enumerates exactly what
  # a bare `require` would find in that process).
  PROBE_SCRIPT = <<~'PROBE'
    begin
      require "rbconfig"
      default_dir = Gem.default_dir
      user_dir    = Gem.user_dir
      specs       = Gem::Specification.map do |spec|
        kind = if spec.default_gem?
                 "stdlib"
               elsif spec.full_gem_path.to_s.start_with?(default_dir.to_s)
                 "ruby"
               elsif spec.full_gem_path.to_s.start_with?(user_dir.to_s)
                 "user"
               else
                 "other"
               end
        [spec.name, spec.version.to_s, kind]
      end
      puts "RUBY\t#{RUBY_VERSION}\t#{RbConfig.ruby}"
      puts "BUNDLER\t#{defined?(Bundler) && Bundler.respond_to?(:loaded?) && Bundler.loaded? ? 'yes' : 'no'}"
      puts "RUBYLIB\t#{RbConfig::CONFIG['rubylibdir']}"
      puts "DEFAULT_DIR\t#{default_dir}"
      puts "USER_DIR\t#{user_dir}"
      puts "SPECS\t#{specs.size}"
      specs.sort.each { |name, version, kind| puts "GEM\t#{name}\t#{version}\t#{kind}" }
    rescue => e
      puts "ERROR\t#{e.class}: #{e.message}"
    end
  PROBE

  # Bound the probe: a `ruby -e` that runs a fixed script always exits, but a
  # wedged ruby (or a wedged gem index) must never block the caller, exactly like
  # an arbitrary run.command (issue #202). Kept short - the probe is a lookup.
  TIMEOUT_SECONDS = 15

  KINDS = %w[stdlib ruby user other].freeze

  # The kind labels, explained once for whoever reads the report.
  KIND_NOTES = {
    "stdlib" => "ships with Ruby itself - importing it always works",
    "ruby" => "inside this Ruby's own gem home",
    "user" => "installed for this user (gem install --user-install)",
    "other" => "installed elsewhere (GEM_PATH)"
  }.freeze

  # workdir: the directory the probe child ruby runs in, so a GEM_PATH or a
  # bundle config relative to the project is resolved the way the model's own
  # `ruby script.rb` (run from the harness workdir) would resolve it.
  def initialize(workdir)
    @workdir = workdir
  end

  # Run the probe and return the parsed report:
  #   { error:, ruby:, exe:, bundler:, rubylib:, default_dir:, user_dir:,
  #     count:, gems: [ {name:, version:, kind:} ] }
  # `gems` is sorted by name and keeps EVERY installed spec (a gem can appear
  # twice at two versions, one per install location - that is a fact the caller
  # should see, not silently de-duplicated away).
  def probe
    output, status = run_probe
    if status == :timeout
      return { error: "the probe child ruby timed out after #{TIMEOUT_SECONDS}s" }
    end
    return { error: error_for(output) } unless output.strip.start_with?("RUBY")

    parse(output)
  end

  # Format a probe report for a reader. With query tokens it answers "is there a
  # gem for X?" per token (versions shown). With none it gives the header, a
  # per-kind count, and a full alphabetized name scan (versions dropped so the
  # whole set fits one call - query again for a gem's exact version). Always
  # returns a single String (a tool result / printed block), never an array.
  def format(report, query: [])
    return report[:error] if report[:error]

    tokens = Array(query).map { |token| token.to_s.strip.downcase }.reject(&:empty?)
    return (header_lines(report) + full_scan_lines(report)).join("\n") if tokens.empty?

    header_lines(report).concat(query_lines(report, tokens)).join("\n")
  end

  private

  def run_probe
    out_r, out_w = IO.pipe
    pid = spawn_probe(out_w)
    out_w.close

    output = +"".dup.force_encoding(Encoding::BINARY)
    reader = Thread.new do
      Thread.current.report_on_exception = false
      loop { output << out_r.readpartial(64 * 1024).dup.force_encoding(Encoding::BINARY) }
    rescue IOError # EOFError is an IOError subclass, so it is covered too
      nil
    end

    waiter = Process.detach(pid)
    deadline = Time.now + TIMEOUT_SECONDS
    timed_out = false
    until waiter.join(0.1)
      if Time.now >= deadline
        timed_out = true
        kill_process_tree(pid)
        waiter.join(2)
        break
      end
    end

    out_r.close
    reader.join
    [TextNormalizer.normalize(output), timed_out ? :timeout : waiter.value]
  end

  # The child ruby is looked up on PATH (argv array, no sh, no quoting) - the
  # same ruby a model's `ruby script.rb` reaches through run.command's unbundled
  # shell. `ruby -e <script>` feeds the probe as one argument; a stdin pipe is
  # deliberately avoided (it does not survive the unbundled spawn on Windows).
  def spawn_probe(out_w)
    spawn_unbundled(out_w, pgroup: true)
  rescue ArgumentError
    # Older Ruby rejected the process-group spawn flag; a timeout kill then
    # reaches only the direct child (still no hang), same fallback as CommandRunner.
    spawn_unbundled(out_w, pgroup: false)
  end

  def spawn_unbundled(out_w, pgroup:)
    Bundler.with_unbundled_env do
      opts = { out: out_w, err: out_w, chdir: @workdir }
      opts[CommandRunner::PGROUP_SPAWN_KEY] = true if pgroup
      Process.spawn("ruby", "-e", PROBE_SCRIPT, **opts)
    end
  end

  def kill_process_tree(pid)
    if Gem.win_platform?
      system("taskkill", "/T", "/F", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
    else
      Process.kill(:TERM, -pid) rescue nil
      sleep 1
      Process.kill(:KILL, -pid) rescue nil
    end
  end

  def parse(output)
    report = {
      error: nil,
      ruby: nil,
      exe: nil,
      bundler: nil,
      rubylib: nil,
      default_dir: nil,
      user_dir: nil,
      count: nil,
      gems: []
    }
    output.each_line do |line|
      fields = line.chomp.split("\t")
      case fields.first
      when "RUBY"    then report[:ruby], report[:exe] = fields[1], fields[2]
      when "BUNDLER" then report[:bundler] = fields[1]
      when "RUBYLIB" then report[:rubylib] = fields[1]
      when "DEFAULT_DIR" then report[:default_dir] = fields[1]
      when "USER_DIR" then report[:user_dir] = fields[1]
      when "SPECS" then report[:count] = fields[1].to_i
      when "ERROR" then report[:error] = fields[1]
      when "GEM"
        report[:gems] << { name: fields[1], version: fields[2], kind: fields[3] }
      end
    end
    report
  end

  def error_for(output)
    output.strip.empty? ? "the probe produced no output" : output.strip
  end

  def header_lines(report)
    counts = KINDS.to_h { |kind| [kind, report[:gems].count { |g| g[:kind] == kind }] }
    [
      "Child ruby a run.command script runs under (NOT this harness' bundle):",
      "  ruby #{report[:ruby]}  (#{report[:exe]})",
      "  bundler active in that child: #{report[:bundler]}",
      "  gem home:      #{report[:default_dir]}",
      "  user gem dir:  #{report[:user_dir]}",
      "  installed specs: #{report[:count]} (stdlib #{counts['stdlib']}, " \
        "ruby #{counts['ruby']}, user #{counts['user']}, other #{counts['other']})"
    ]
  end

  # A full scan: distinct names, versions dropped so the whole set fits, one line
  # per kind with that kind's meaning spelled out on the same line (the kind is
  # what tells the reader whether the gem is guaranteed or only installed here).
  def full_scan_lines(report)
    grouped = KINDS.map do |kind|
      names = report[:gems].select { |g| g[:kind] == kind }.map { |g| g[:name] }.uniq
      next if names.empty?

      label = "#{kind} - #{KIND_NOTES[kind]}"
      "  #{label}: #{names.sort.join(', ')}"
    end
    lines = ["", "Available gems by kind (call again with gems: for versions):"]
    lines << grouped.compact.join("\n")
    lines
  end

  def query_lines(report, tokens)
    tokens.map do |token|
      matches = report[:gems].select { |g| g[:name].to_s.downcase.include?(token) }
      if matches.empty?
        "  #{token}: no installed gem matches"
      else
        listed = matches.map { |g| "#{g[:name]} #{g[:version]} (#{g[:kind]})" }
        "  #{token}: #{listed.join(', ')}"
      end
    end
  end
end
