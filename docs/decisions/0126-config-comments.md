# 0126. The config file has comments, and a change in the app keeps the user's text

- **Date:** 2026-10-28
- **Status:** accepted
- **Amends:** [0123](0123-config-is-the-settings.md) (the file's format, how a patch is
  written, what a new file looks like)

## Context

Dylan, 2026-10-28: "json should have comments describing each setting, like sublime text does."
0123 wrote the file with `JSONSerialization`, pretty-printed with sorted keys, and read it the
same way, so the file could hold no comment and each write from the app rewrote the user's
spacing and key order. A comment the user added would have been an error, and one the app wrote
would have been lost at the next patch.

## Decision

- **The file is JSON with comments, as Sublime Text's settings are.** `//` line comments,
  `/* */` block comments and a comma after an object's last item are allowed. `ConfigText`
  blanks each comment's bytes, and each trailing comma, to spaces, keeping line breaks, and
  Foundation parses what is left. Every byte keeps its offset, so an error's line and the
  duplicate-key scan's lines are the file's own. A `/*` with no `*/` is an error on the line it
  opens on; a file of comments alone is empty. A comma is blanked only when an item comes before
  it, so `{,}` is an error on its line. A UTF-8 byte order mark, which some editors write, is
  allowed and kept. Nothing else from JSON5 (unquoted keys, single quotes) is accepted.
- **`parse` takes only text the patch's scan can read.** After Foundation parses it, `parse`
  runs `ConfigText.scan`, the scan every patch uses, and reports what it can't read as an
  error on its line. A file the app patches therefore never reaches the scan's
  `preconditionFailure`. A seeded property test patches random files (LF and CRLF, comments with
  quotes and markers in them, trailing commas, escaped strings, a byte order mark, an empty
  item) and checks that each result reads back as the settings with the patches on top.
- **A new file has a comment above each key.** Every preference, in the order
  `Settings.preferences` gives them, then `"shortcuts"`, a blank line between entries:

  ```jsonc
  {
    // Show hidden items: names that start with a dot, and items flagged hidden.
    // Takes true or false.
    "show-hidden": false,
    …
    // The shortcuts you changed, by command ID. "primary" and "alternate" each take a
    // shortcut such as "cmd+shift+k", or "" for none. A slot left out keeps its default.
    "shortcuts": {
      "window.showPalette": {"alternate": ""}
    }
  }
  ```

  A new file is the one made at launch with none there, at a newly chosen place, or after a
  deletion; that is the only time the app writes the whole file.
- **One source for the text.** Each preference's `summary` is declared in
  `Settings.preferences`, beside its key, kind and default. What it takes (`true or false`,
  `"auto", "light" or "dark"`, `a whole number from 100 to 1000`) is `Preference.takes`, made
  from its kind, and is both the comment's second line and the words of its error, so the
  choice error now reads `appearance must be "auto", "light" or "dark", not "purple"`. The
  shortcuts' comment is `ConfigFile.shortcutsComment`, beside `shortcutsKey`. The Settings
  window has no help text for these preferences to share.
- **A patch edits the file's text, not a parsed object.** `ConfigText` finds each key's value
  span with a small scan of text that already parsed. A patch to a key the file has replaces only
  that value's text. A key the file doesn't have goes in before the object's closing brace, after
  the line of its last key, at that key's indent, with its comment above it (a shortcut command
  or slot has none); in an object written on one line it goes on that line with no comment, and
  an empty object is opened onto lines of its own. A trailing comma after the last key is
  matched. A slot set back to its default is taken out with its comma, and its line when nothing
  else is on it; a command left with no slot goes the same way. Comments outside the text taken
  out stay, even when the key they described is gone. Every other byte of the file is kept, its
  final newline or lack of one included. Text put in ends its lines as the file's first line
  ends, `\r\n` or `\n`, so a CRLF file stays CRLF.
- **Patches apply in the order they were made**, so the text a set of patches makes doesn't
  depend on a dictionary's order. Every other rule of 0123 holds unchanged: the byte check before
  the rename, the coalescing by key, the no-op rule (a patch the file already holds writes
  nothing), the queue while the file is broken, the retries and the quit flush.
- **No migration.** A file written by 0123's build keeps its text and gains a comment only for a
  key put in. Deleting `config.json` gives a fully commented one.
- **The Change… panel's message** is "Choose a config file, or a folder for one."

## Alternatives considered

- **`JSONSerialization`'s `.json5Allowed`** — rejected: it also takes unquoted keys, single
  quotes and hex numbers, which Sublime doesn't, and it can't write, so the comments would still
  be lost at the first patch.
- **Write the whole file each time from the settings, comments regenerated** — rejected: it
  drops the user's own comments, spacing and key order, which is what "edits keep the user's
  text" rules out.
- **A general JSONC library** — rejected: it would be a dependency, and the file is one object
  of scalars and one two-level object; a scan of a few dozen lines covers it.

## Consequences

The config file reads like Sublime Text's settings, and the user can annotate it freely: the
app never removes a comment except inside a key it takes out. Comment lines are kept under 100
columns by keeping each summary to one short sentence.
