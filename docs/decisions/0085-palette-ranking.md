# 0085. Palette ranking: match score plus small kind and frecency bonuses, top-k per bucket

- **Date:** 2026-10-24
- **Status:** accepted

## Context

The palette (M5a.6) lists commands, saved workspaces, visited folders, the folders open panes
show, and the folders of a typed path, and ranks them on every key against a 50 ms budget with up
to 50k candidates (B11). The fuzzy matcher ([0079](0079-fuzzy-match.md)) scores one query against
prepared candidates and keeps the best `limit` with `best`, ranking equal scores by the shorter
text, then the earlier index. It leaves two things to the palette: "ss" ties "Sessions" with
"Screenshots", so a folder the user opens often has to win through frecency, and kinds have to
be ordered. The plan asks that "proj" rank saved workspace "Project 1" above folder "projects",
that at an equal score a folder visited ten times outrank one visited once, and that an empty
query list workspaces, then folders, then commands. The palette only searches these sources:
no recursive file search or Spotlight (that is M5b.3).

## Decision

- **Score.** An item's score is its match score plus a kind bonus and a frecency bonus:
  - **Kind bonus:** 5 for a saved workspace, 0 for folders and commands. Workspaces are few and
    named by the user, so at an equal match one beats any folder.
  - **Frecency bonus**, folders only: the whole part of log2 of the folder's frecency, from 0
    below 2 up to 4 at 16 and over. One visit within the hour (frecency 4) adds 2, ten (40) add
    4. The cap stays under the workspace bonus, and both are smaller than one letter's run
    bonus in the matcher (6), so they reorder near-ties rather than override the match.
- **Frecency** (`FolderHistory`) is the visit count times a weight for how long ago the last
  visit was, as zoxide weights it: 4 within the hour, 2 within the day, 1/2 within the week,
  1/4 before. It keeps 1,000 folders; a visit past that drops the least frecent. It is
  stored as a list of folders sorted by path, each with its count and last visit; a file with
  more than 1,000 folders, a path that isn't absolute, listed twice or out of order, or a count
  under 1 fails to decode, and the store discards and reports it like any other mismatch.
- **Ties.** Equal scores rank workspaces, then folders, then commands; then the larger frecency
  bonus; then as `best` ranks them, the shorter text first; then the more frecent folder.
- **Top-k, not a full sort.** Items are split into buckets of the same kind, frecency bonus and
  match offset (below). In one bucket every item gets the same bonus, so `best` ranks it
  exactly; the bucket is first sorted most frecent first, when its frecencies differ, so `best`'s
  last tie-break, the earlier index, follows frecency. Each bucket keeps its best 50, and the few
  hundred kept are merged by score. There are at most a dozen buckets, and every candidate is
  still scored once.
- **Empty query.** No matching: workspaces, then folders, then commands, each in its source's
  order. Workspaces come most recently used first (open ones by window activity, then closed
  ones, the last closed first), folders most frecent first, then open panes' folders that were
  never visited, and commands in registration order.
- **A typed path.** A query starting with `/` or `~` that holds a `/` lists the parent it names
  (expanded by `PathInput`) through `ListingService`, off the main actor. Its folders are titled
  the typed parent plus the name, and matched from the end of the typed parent by the name typed
  after the last `/`, so "~/Do" scores the "Do" against "Documents". Only folders are listed.
  A folder whose name starts with a dot is listed once the typed name does too; one hidden by
  its flag, such as `~/Library`, always is, as Finder's Go to Folder completes it. A full listing
  after cached rows or a first batch keeps the items already made and prepares only the new
  folders.
- **Duplicates.** An item another source already gave, such as a typed path's folder that is in
  the history, is dropped; the earlier source's item is kept.
- **Off the main actor.** Each key gathers every source's items on the main actor, from memory,
  and ranks them in a detached task. A source's items for an earlier query are dropped by
  generation. A new ranking cancels the one it replaces, which stops before its next bucket, and
  only the latest ranking's results are kept.

## Alternatives considered

- **Frecency as a tie-break only** — rejected: a folder opened every day would never pass a
  rarely used one whose name matches a point better, and the ties in the matcher are rare.
- **A frecency bonus proportional to frecency** — rejected: ten visits would add 40, more than a
  whole matched word; the log keeps a bonus within a few points.
- **Kind as a fixed order before score** — rejected: a command whose name is typed in full would
  rank under a folder that barely matches.
- **Score everything, then sort** — rejected: B11 asks for top-k; with 50k candidates the sort
  alone would cost what `best` saves.
- **One `best` call over all items with the bonus added after** — rejected: `best` keeps its 50
  by match score alone, so a folder whose bonus would lift it into the 50 could already be cut.
- **Match the typed path's folders on their whole path** — rejected: every query letter in the
  typed parent is matched again for each of up to 50k folders, and a long parent would make each
  key cost several times more.

## Consequences

For a query of one or two letters, an unvisited folder named exactly that ranks below a saved
workspace whose name only starts with it: "p" scores 13 in "~/p" (10 at the component start and
3 for the whole component) and 10 in "Project 1", which the workspace bonus lifts to 15. This is
accepted: one or two letters say little about which item is meant, the user named the
workspace, and a folder the user visits passes it soon, since two visits within the hour add 3.
From three letters a whole component earns 3 a letter on top of the prefix bonus ("pro" scores
37 in "~/pro" and 28 in "~/Projects"), so the exact name wins.

`FolderHistory` is stored in `<application support root>/folder-history.json`, beside the
session, by `WorkspaceStore`, with the same delayed atomic write and the same discard of a file
not in the one stored shape. Nothing counts a visit yet: whoever owns the windows has to call
`FolderHistory.visit` when a pane shows a folder and save the history. The command source lists
every registered command, including ones that are off in the key window; the palette window may
want to grey those out. A folder's frecency is read when its item is made, so it doesn't change
while the palette is open. B11 end to end through `Palette` is not benched here; M5a.7's palette
keystroke case in the UI bench times it.
