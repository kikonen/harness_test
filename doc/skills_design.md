# Skills: written-down procedures in .harness/skills

What a skill is, why its body is not in the system prompt, and why `.harness/skills`
is the one part of `.harness/` a grant can cover. Issue #12.

---

## The problem a skill solves

Every session re-explains the same repeatable jobs: how to regenerate the changelog,
how to triage an issue list, how to run a release check. `harness.md` cannot hold
them - it is injected into EVERY system prompt, and a procedure costs context on
turns that never use it. A skill is the same knowledge stored once as a named
markdown file the model loads only when the job appears.

## The invariant

**A skill body is never in the system prompt.** What reaches the model by default is
the index - name plus one line - through `skills.list` or `/skills`. The body arrives
as an ordinary tool result (or command output) when a task asks for it. That single
rule is what makes the feature free: a project can define ten skills and pay for
none of them until one is used.

`lib/skills.rb` is the only reader of a skill file. `skills.list`, `skills.read` and
`/skills` all render from that one loader, so what the owner inspects and what the
model reads cannot drift apart.

## Two file shapes

```
.harness/skills/<name>/SKILL.md      # when the skill ships companion files
.harness/skills/<name>.md            # a single-file skill
```

The directory shape is the canonical one (it matches the SKILL.md convention the
feature is named after); the flat `.<name>.md` shape is accepted because a one-screen
procedure does not deserve a directory. A directory without `SKILL.md` is NOT a
skill - it may hold anything else - and a non-`.md` file is not a skill either.

Optional front matter:

```markdown
---
name: changelog-rollup
description: Regenerate CHANGELOG.md from the merged PR bodies
---
```

- Without `description:` the description is the file's first prose line (a `#`
  heading is skipped - a heading is not a description), truncated at `DESC_MAX`.
- `name:` changes the NAME A SKILL IS LISTED UNDER; the name used to load it stays
  the file/directory name. `skills.read` therefore takes the file name and the index
  may display a different label, which is what a `name:` override is for.
- Malformed front matter is not an error: `safe_load` with the plain Psych 5
  defaults (no classes, no aliases - `permitted_types` does not exist in Psych 5.3,
  measured), a non-Hash result becomes `{}`, a `Psych::SyntaxError` becomes `{}`, and
  the body is still the skill. A file that starts with `---` but never closes it is
  treated as content, not as front matter.
- A body is read through `TextNormalizer` and CRLF is folded to LF, so a
  Windows-authored skill reads the same as a Unix one (the same read-boundary rule as
  every other tool, `doc/encoding_design.md`).

## Name safety (this is the boundary)

A skill name must be ONE path segment: no `/`, no `\`, no `:`, not `.`/`..`, not
starting with `.`. `Skills#normalize_name` refuses anything else BEFORE any path is
built, and `#inside?` re-checks the resolved path against the skills directory.

Without the segment rule, `skills.read(name: "../../.git/config")` would make this
tool a general file reader that bypasses the whole access-grant model - including the
`.git`/`.harness` guard, because `Skills` never goes through `FileList` at all. Both
halves are specced: eleven refused names in `skills_spec.rb`, six more in
`skills_read_tool_spec.rb` (which also asserts the refused read did not return the
contents of a file planted outside the zone).

## Why `skills.read` needs no grant, while writing a skill does

A skill body is harness-owned INSTRUCTION content, the same category as `harness.md`
and the base prompt file: both are read by the harness with no FileList grant, and
`Skills` resolves its directory from the workdir, never from a model-supplied path.
Reading it is not a filesystem access by the model - it is the harness handing the
model a procedure it owns.

Writing a skill is a different act and stays inside the normal model: it goes through
`file.write` / `file.patch` / `dir.create`, each with its grant dialog. That split is
deliberate - the read side has no path the model controls, the write side does.

## Why .harness/skills is exempt from the sensitive guard

`SensitiveFiles` blocks `.git` and `.harness` as ANY component, and that is correct
for the harness's own footing (sessions, logs, allowlists). But a skill is not
harness state: it is repo content the owner chose to keep, reviewed like any other
file. Keeping it ungrantable would mean the model could never edit or fix the
procedures it is told to follow.

`FileList#sensitive?` therefore has a second exemption next to the scratch zone:

```ruby
rel = relative_path(path)
return false if SensitiveFiles.scratch_zone?(rel)
return SensitiveFiles.env_named?(path) if SensitiveFiles.skills_zone?(rel)
SensitiveFiles.sensitive?(path)
```

- The skills test is on the RESOLVED workdir-relative path (same rule as the scratch
  zone), so `.harness/skills/../sessions/id/session.json` resolves out of the zone and
  stays blocked, and `skills_zone?` matches `.harness/skills` exactly - not
  `.harness/skillsx`, not `.harness/skills-backup`, not `.harness` itself, not a
  `lib/.harness/skills` deeper in a path.
- The exemption lifts the `.harness` COMPONENT rule only. A `.env*` NAME inside the
  skills directory is still a secret file and still blocked - which is why
  `SensitiveFiles.sensitive?` is split into `env_named?` / `state_dir?`: the skills
  branch can reuse the name half while dropping the directory half.
- Grant granularity is unchanged: an exemption makes a path GRANTABLE, it does not
  grant anything. `file_list_spec.rb` asserts `add_dir('.harness', :rw)` is still
  `:blocked`, and `dir_delete_tool.rb`'s tree refusal still applies to every other
  `.harness` subtree.

## Measured: the .gitignore shape (git 2.56.0, Windows)

Persisting `.harness/skills` in git cannot be done with the repo's old
`.harness/**` line, because git never re-includes a file inside a directory it has
already excluded - the negation is never reached. Measured in a scratch repo
(`tmp/scratch/12/repo`):

| rules | skills file | `.harness/harness.log` | `.harness/skills/.env` |
|---|---|---|---|
| `.harness/**` + `!.harness/skills/**` | ignored (cannot re-include) | ignored | ignored |
| `.harness/*` + `!.harness/skills/` | **trackable** | ignored | not ignored (harness guard blocks it) |

So `.gitignore` is now `.harness/*` + `!.harness/skills/`: one level deep, with the
skills subtree re-included. `git check-ignore -v` confirms `harness.log`,
`sessions/x/session.json` stay ignored while `skills/` and everything under it is
not, and a repo-level `.env` line still covers `.harness/skills/.env` - the harness
guard blocks it regardless.

## Checked by spec

- `spec/lib/skills_spec.rb` (28) - both file shapes, the directory-without-SKILL.md
  refusal, front matter (name/description, stripping, fallback line, truncation,
  malformed YAML, an unclosed `---`), sorted listing, CRLF normalization, and the
  eleven refused names.
- `spec/lib/tools/skills_list_tool_spec.rb` (5) and `skills_read_tool_spec.rb` (12) -
  the listing/count/status lines, the empty-project answer, the unknown-name answer
  that names what DOES exist, the refused names, no stdout writes, the advertised
  parameters.
- `spec/lib/commands/skills_command_spec.rb` (8) - listing, the "add one at" answer,
  body printing (incl. a body with no trailing newline), the error paths, and the
  contract that /skills and skills.list show the same set.
- `spec/lib/sensitive_files_spec.rb` - `skills_zone?`: the directory itself, nested
  paths, the lookalikes, `nil`.
- `spec/lib/file_list_spec.rb` - a grant covers the skills subtree for read/write/
  delete; `.harness/config.yml`, `sessions/...` and `skills/../sessions` stay blocked;
  `.harness/skillsx`, `.harness/skills-backup` and `.harness` itself stay blocked; a
  `.env*` name inside the zone stays blocked even under a recursive grant.
- `spec/lib/harness_spec.rb` - `#skills` points at the workdir's `.harness/skills`,
  and both tools were registered over THAT loader instance.
- `spec/lib/commands/help_command_spec.rb` (already on the books) - the new `/skills`
  command and its README row, both directions.

## Deliberately not built (issue #12 leaves these open)

- No user-home tier (`~/.config/harness/skills/`) yet - only the per-project
  directory exists. The owner's note names it as a later step.
- No skill is INJECTED on demand by configuration (no "always load this skill"), and
  a skill has no front matter for tools, models or permissions. A skill is a
  document, not a manifest.
- No companion-file reading: `Skills#body` returns SKILL.md alone. A skill that needs
  more than that names the file, and the model reaches it with `file.read` - which
  goes through the grant model, as it should.
- No mtime watcher: skills are read at call time, so an edit takes effect on the next
  `skills.read`. Nothing needs reloading, which is why `/reload` still only covers the
  system prompt.
