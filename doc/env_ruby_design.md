# The child Ruby a model script runs under (issue #340)

Issue #340 asks: since the harness names Ruby as the scripting language a model
may use, could a pre-installed "sandbox Gemfile" (pdf, html, csv, xml, ...) give
a model-run script gems to use instead of hand-writing parsers? Its sibling
#330 is the symptom: a model wanted `kramdown`, went looking in the harness'
`Gemfile.lock`, and wrote the HTML by hand instead.

The answer shipped here is a **report, not a bundle**: `env.ruby` (tool) and
`/env` (command) over one `EnvRuby` object, which *measures* what a model script
can require. Rationale for not shipping a bundle is below; the mechanism first.

## The constraint that decides the design

`CommandRunner#run_in_shell` wraps every command in `Bundler.with_unbundled_env`
(issue #185). That was a fix: the harness may have been started from a shell
carrying ANOTHER project's bundler setup, and a `bundle exec` typed by the model
must resolve against the workdir's own Gemfile, not the harness'.

The consequence for #340 is decisive: **a `ruby script.rb` the model runs through
`run.command` does not see the harness' bundle.** So the harness' own `Gemfile`
is the wrong answer to "which gems can my script use?", and a static list of the
harness' gems would be a promise about an environment the model's child process
does not have.

## What the probe measures

`EnvRuby#probe` spawns a child ruby the same way `run.command` does - unbundled
env, the PATH ruby, its own process group, and killed on a timeout so a wedged
child can never block the caller (the issue #202 lesson; a probe failure is a
stated error, never an empty "0 gems" success). It runs:

    ruby -e <PROBE_SCRIPT>

An **argv array** with no shell: the probe is then one exact argument, so there is
no quoting hazard. A stdin pipe (`ruby -`) was tried first and deliberately
dropped: an inherited stdin pipe does not survive the unbundled spawn on Windows
(measured: the child produced no output), while `-e` and a temp-file argument
both work.

The child ruby reports its OWN view (`Gem::Specification` is exactly what a bare
`require` could find in that process), and each spec is classified by where it
came from:

| kind | meaning | guarantee |
|---|---|---|
| `stdlib` | `default_gem?` - ships with Ruby itself | always importable |
| `ruby` | inside this Ruby's own gem home (`Gem.default_dir`) | as long as this Ruby install stands |
| `user` | `Gem.user_dir` (user-installed) | this machine/user only |
| `other` | anywhere else on `GEM_PATH` | this machine only |

That column is the point of the whole feature. Measured on this box (ruby 4.0.7,
2026-11-01): **172 installed specs - 47 stdlib, 38 ruby-home, 87 user**, with
`bundler active in that child: no`. `csv`/`rexml`/`json` are stdlib or ruby-home;
`nokogiri` and `kramdown` are **user** installs - present here because installing
the harness' own bundle populated the user gem dir, **not** because the harness
guarantees them. On a fresh box they would not be there. `pdf-reader` and `prawn`
are absent.

So the honest sentence #340 needs is not "these gems are available" but "here is
what your child ruby actually has, and here is which of them are Ruby's own".

## Why a sandbox bundle is not shipped

1. **A promise the harness cannot keep.** Availability is per-machine and
   per-install. Announcing "kramdown is available" from a config list would be
   wrong on a clean box, and a wrong capability claim is worse than no claim -
   it is what #330's model burned turns on.
2. **It would still need an incantation.** With the child unbundled, gems in a
   dedicated sandbox Gemfile are not importable by a plain `ruby script.rb`; the
   model would have to remember `BUNDLE_GEMFILE=<path> bundle exec ruby ...` on
   every call. The failure mode of an unremembered incantation is a LoadError the
   model then works around by hand - the #330 outcome again.
3. **Native gems on this platform.** nokogiri/pdf stacks want a toolchain on
   Windows; a "standard installation" claim would carry that burden.
4. **Announcement beats availability.** #340 itself notes "if the model does not
   know the gem, then it does not help much." A measured list the model is TOLD
   once is worth more than a bundle it cannot discover, and it costs no gems.

## Boundaries

- **Report only.** `env.ruby` / `/env` read; they install nothing and change
  nothing. `/env` is the human mirror of the tool over the SAME `EnvRuby` object,
  so the two cannot disagree about what exists (the /mcp + Mcp::Manager pattern,
  issue #405).
- **No model-initiated install.** `gem install` is network plus arbitrary code
  execution. It is not a capability this feature opens, and it must not become
  one through `env.ruby`; the shell consent system (postures + allowlist + the
  disaster denylist) stays the only path to running an installer, exactly as for
  any other command. The `web.fetch` host-grant axis and the MCP url axis stay
  separate too (issues #33 / #402) - a report about gems authorizes nothing.
- **The report goes into the context window like any tool result**, so a full
  scan lists distinct NAMES grouped by kind (versions dropped) to fit one call;
  a query (`gems: [..]`) answers per name WITH versions, and keeps every version
  of a gem installed twice (e.g. three `kramdown-ansi` versions here) rather than
  silently collapsing them.
- **Lazy.** The probe spawns a child ruby only when asked. A run that never calls
  `env.ruby` or `/env` pays nothing, so unlike an MCP banner the probe is not a
  per-run startup cost.
- **`bin/installed_bins` is not this.** That helper lists the harness' own bundle
  (what `bundle exec` in the harness' directory would run). `env.ruby` describes
  the CHILD env the model's scripts live in. The two are different questions and
  can legitimately give different answers.

## Where the code is

- `lib/env_ruby.rb` - `EnvRuby`: `#probe` (spawn + parse), `#format` (report ->
  one String), the probe script, the kind table, timeout/kill.
- `lib/tools/env_ruby_tool.rb` - `env.ruby` (registered in every run, like
  `tools.list`).
- `lib/commands/env_command.rb` - `/env [gems...]`, `HELP` in the `general`
  group, registered in `CommandHandler::COMMANDS`.
- `Harness#env_ruby` - the one object both sides read.
