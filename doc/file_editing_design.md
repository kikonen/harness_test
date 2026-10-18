# File editing: how the harness decides a file's line-ending style

Why `file.write` and `file.patch` go through `lib/file_text.rb` (the byte
boundary) instead of reading and writing files as text. Issue #318.

---

## The root cause: a text-mode read has already destroyed the evidence

`File.read` on Windows translates every CRLF it reads into LF. So a check like

    content = File.read(path)
    crlf = content.include?("\r\n")     # always false for a real CRLF file

does not detect the file's style - it detects the translation. That is what
`file.patch` did: `crlf` was false for a genuine CRLF file, so a patch touching
one line rewrote the WHOLE file with LF, and the reverse case (an LF file
written back with the platform's CRLF) happened on every write. The tool
reported "applied 1 hunk" while quietly changing every line in the file.

The style can only be decided from the BYTES on disk. `FileText.from_disk`
uses `File.binread` for exactly that reason, and writes with `File.binwrite`
so no translation happens on the way out either.

## Measurements that drove the rules

All measured in the repo working directory (Windows checkout,
`core.autocrlf = false`, `.gitattributes` `* text=auto eol=lf`), 158 tracked
files.

- `file.patch` on a 3-line CRLF file: every line rewritten to LF, the tool
  answered `ok: applied 1 hunk(s)`.
- A file carrying `a\r\r\n` (one damaged line): after one patch the CR count
  went 3 -> 4, because the old code appended `"\n"` to a line that already
  ended in a stray `CR`, i.e. the damage multiplied on every patch.
- `file.write` doubled model-supplied CRLF: content `"X\r\nY\r\n"` reached the
  disk as `"X\r\r\nY\r\r\n"`.
- `file.patch` RAISED `ArgumentError: invalid byte sequence in UTF-8` on a
  cp1252 file, and the raise left the file untouched but the tool call dead.
- `file.patch` DROPPED a trailing blank line: `"a\nb\n\n"` patched into
  `"a\r\nB\r\n"`. A trailing blank line is content, not noise.
- The existing spec that was supposed to cover CRLF passed while the file it
  wrote was `CR CR LF`, because its assertion read the file back with
  `File.read` - i.e. with the same translation that hides the damage. Any
  line-ending assertion must use `binread`/`binwrite`.
- `Layout/EndOfLine` with the unconfigured `native` style fires **83 times**
  over `lib/**/*.rb` + `harness.rb` (83 files, all LF on disk): `native` means
  "the platform's own style", which on Windows is CRLF. A cop whose idea of
  correct depends on the OS of whoever runs it cannot be a house rule here.
- At the start of the fix 0 tracked files were CRLF on disk. While the fix
  was being written, the three files it edits (`lib/tools/file_patch_tool.rb`,
  `lib/tools/file_write_tool.rb`, `spec/lib/tools/file_patch_tool_spec.rb`)
  became CRLF on disk - converted by the still-running, unfixed tool that was
  performing the edits. The bug was live in its own fix commit.
- `FileText`'s `binread` + `TextNormalizer` produces byte-identical results to
  the old `File.read` path for UTF-8 files, so moving to the byte boundary
  does not regress `doc/encoding_design.md`.

## The rules FileText implements

1. **Style comes from the bytes, never from a text-mode read.** CRLF count vs
   bare-LF count decide the separator.
2. **Majority wins.** A mostly-CRLF file with a couple of stray LFs is repaired
   to CRLF instead of flipped wholesale by a patch that touched one line; a
   file with no CRLF at all is LF - which is the case the old code got wrong.
3. **A bare CR is damage, and it is deleted, not converted.** Treating a stray
   CR as a newline would invent a blank line and change the file's line count;
   deleting it preserves the count. A CR-only file (a classic old Mac file) is
   its own style, not damage: it gets `sep = "\r"` and zero bare CRs.
4. **A trailing separator is reproduced exactly** (`split("\n", -1)` plus one
   exact `pop`), so a missing final newline stays missing and a trailing blank
   line stays.
5. **A lossy source is refused, not rewritten.** If the bytes are not valid
   UTF-8, the model only ever sees the `?`-scrubbed view (`TextNormalizer`),
   and writing that view back would destroy bytes the harness never read
   correctly. `file.patch` refuses and leaves the file alone; `file.write` is a
   complete rewrite the model asked for, so it proceeds and says so.
6. **A repair is never silent.** When the source (or the model's content)
   carried bare CRs or mixed endings, the tool's result names what was wrong
   and what it became: `1 bare CR normalized to CRLF`.
7. **Model-supplied content is analysed by the same rules** (`from_text`). An
   existing file keeps its own style; plain LF content into a CRLF file is the
   NORMAL path (the model always sees LF text) and therefore carries no note -
   only content that genuinely carries both endings does.

## What a spec must do to test any of this

Write with `File.binwrite`, assert with `File.binread`. `File.read` and
`File.write` translate on Windows, so a spec using them passes for the wrong
reason or fails for the wrong reason.
