# Agent rules for orchestrated builds

How an orchestrating session hands a plan step to a builder agent and a reviewer agent. Read
AGENTS.md first; these rules add to it.

## Builders

1. Start with `git reset --hard m1-base`, or rebase onto it, and confirm the sha you're on.
2. Write the test first and see it fail, then make it pass. New behavior needs a test that fails
   without the change.
3. Iterate with `./scripts/test --changed`. At the end, rebase onto `m1-base`, run
   `./scripts/format`, `swift format lint --strict --recursive --parallel Package.swift Sources
   Tests` (the gate's lint step: `format` fixes layout but not lint rules such as
   `OnlyOneTrailingClosureArgument`, which failed AU.9's merge) and `./scripts/arch`, then
   `./scripts/test --changed m1-base` on the tree
   you commit. Don't run `./scripts/check`: the orchestrator runs it at merge, and several full
   test runs at once load the machine until timing tests fail. Never call `swift build` or
   `swift test` directly (0092-native-build-system.md).
4. No new dependencies. No file-system I/O on the main thread. No TODOs. Don't edit
   `Sources/Bench/Budget.swift`.
5. Use only the decision-record number the orchestrator gave you.
6. Tests don't wait on real time. Use an injected clock, a stub, or a condition to wait for, not
   a sleep. When only a real-time animation or timer will do, wait for its end state with a
   bounded poll and say so in your report.
7. Never take focus or show windows on the main display; test windows go on the second display
   (0091-test-windows-on-second-display.md). Never run `./scripts/dev`. Don't run benches.
8. Never write to `tmp/` or `/Volumes`. Scratch files go in your session's scratchpad directory,
   named with your step as a prefix. Read the user's screenshots from `tmp/shots/` when the brief
   names them.
9. No `&` and no `pkill` in shell commands. Run anything concurrent as a background command.
10. Commit on your worktree branch, following docs/writing.md, with no Claude or Anthropic
    attribution. Never push.
11. Match Finder for behavior questions. Undo and persistence must have no edge cases.
12. A step that adds a path the user can reach (a place, a row, a menu item, a view) has at least
    one window-level test that drives it through the real collaborators. Fakes stand in only for
    the disk, the network and the clock, never for the icon cache, the listing service or the
    views: SB.7c's stubbed icon cache hid a crash that every server listing would have hit.
13. Report the commit sha(s), what changed, the tests added and how each failed before the change,
    the gate result, judgement calls, the benches to run, and steps to check by hand.

## Reviewers

1. Check out the builder's sha in a throwaway `git worktree add` under `$TMPDIR` and confirm it;
   remove it at the end. Never run `git checkout` or `git switch` in the main repo directory: the
   merge gate runs there. Write no product code and commit nothing.
2. Run `./scripts/test --changed <base>`, where `<base>` is the commit the step sits on. The
   orchestrator runs the full gate at merge. Don't run it.
3. A test that waits on real time is a finding. Say whether it can fail under load and what would
   make it deterministic; the fix goes in before merge, not after it flakes.
4. A user-reachable path with no window-level test through the real collaborators (builders,
   rule 12) is a blocking finding.
5. Report PASS or FAIL. For each finding give file:line, the problem, a concrete failure scenario,
   its severity, and whether it blocks. Keep nits apart from blockers.

## Orchestrator

1. At most three builders at once, each in its own worktree. Give each one its record number.
2. Before a brief that touches threads, blocking calls, volumes, persistence or undo, search
   `docs/decisions` for the record that governs it and quote it in the brief. Don't describe an
   approach from memory: 0038-slow-volumes.md, not "a DispatchQueue like the others", is what
   keeps a step from failing review on a rule that was already decided.
3. Every build gets a fresh reviewer. Fixes for a FAIL go back to the builder, and a fresh
   reviewer checks them. Nits after a PASS can merge without another review.
4. After a second FAIL with the same cause, don't send a third patch round. Narrow the scope,
   change the design, or ask the user. A third FAIL shelves the step on a `shelved/` branch.
5. Merge by cherry-picking onto `m1-base`, then run `SEARCHER_GENTLE=1 ./scripts/check`. A flaky
   test that fails a merge gate gets its own hunt for the cause, not a rerun and a shrug.
6. When two briefs touch the same idea, name in each what the other adds, and tell the later one
   to reuse it: "PL.1 adds `ColumnTrail.selectedFolderColumn`; build on it". Two builders
   working blind each define it, and one fails review for it.
7. Never run a load reproduction (a CPU hog for a flake hunt) while a merge gate runs. Flake hunts
   and merges take turns.
8. Save the user's screenshots into `tmp/shots/` as soon as they arrive, named for what they
   show, and give builders the paths. Describe what to match only beside the image, never instead
   of it: a misread "no white box" in RN.1's brief cost a build, a FAIL and a full redo. The
   scratchpad is wiped when a session crashes; `tmp/` is not.
