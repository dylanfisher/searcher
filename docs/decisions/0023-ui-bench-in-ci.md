# 0023. UI bench in CI: a history file in the artifact, enforcement that stays once earned

- **Date:** 2026-10-21
- **Status:** accepted

## Context

Decision [0002](0002-performance-measurement.md) says the UI bench reports only until its p95s
stay within 10% across three consecutive CI runs, then fails on a p95 over budget like the
harness. Judging that needs the last runs' p95s, and a CI run only has what it downloads from an
earlier run's artifact (decision [0008](0008-bench-runner-shape.md), M0.16a amendment). The UI
bench draws a real window and fails when the window is covered (decision
[0022](0022-ui-bench-mode.md)); a GitHub macOS runner has one display, and whether its window
server reports a window as visible hasn't been tried.

## Decision

- **History.** `Bench compare-ui <previous history> <bench-ui.json> <branch>` writes
  `.build/bench-ui-history.json`: the branch, and for each UI case the p95s of the last three
  runs, newest last, and whether the case is enforced. CI uploads it with `bench-ui.json` as the
  `bench-ui-report` artifact, and the next run downloads the newest one from its branch, else
  `main`, the same search as the harness report's.
- **Stable.** A case is enforced from the run in which its three kept p95s are within 10% of the
  smallest (largest ≤ smallest × 1.1). This run's p95 counts, so a case whose third steady run is
  over budget fails that run. A case with fewer than three runs kept is report-only.
- **Once enforced, always enforced.** Enforcement is never cleared. Judging only the last three
  runs would turn a case back to report-only on the run after a regression, since that run's p95
  breaks the window, and the regression would pass from then on.
- **One branch.** A history from another branch, such as `main` for a new branch's first run,
  keeps its enforced flags and drops its p95s, so runs are counted on this branch only. A case
  enforced on `main` is already known to be steady on the runner.
- **One shape.** A previous history that is missing or doesn't decode is stated and discarded;
  counting starts again. A case missing from this run is stated and dropped.
- **A run that doesn't finish fails.** `bench-ui.json` that is missing, or holds fewer than 20
  launches, fails `compare-ui` and the job, and the summary says the UI bench didn't finish. One
  holding more than 20 isn't one run's record and fails the same way. No history is written and
  nothing is uploaded, so the next run still finds the previous history, and the finished runs
  either side of the failed one count as consecutive. A previous history that can't be read is
  stated in the summary with the reason.
  This covers the runner's display: if its window isn't visible, the occlusion check exits with
  its reason in the log, and the job fails. The check stays as it is: a window that isn't
  composited times nothing that's on screen.
- **Its own job.** The UI bench runs in a `bench-ui` job beside `bench`, so a UI run that can't
  finish doesn't hide the harness results, and the two run at the same time.

## Alternatives considered

- **Keep the history in `bench-ui.json`** — rejected: that file is the app's and runner's record
  of one run's samples (`UIBenchRecord` in Base), and history is CI's concern.
- **Download the last three artifacts** — rejected: three downloads and gaps when a run failed,
  for data one small file carries.
- **Stable judged on the runs before this one only** — rejected: the history then lags a run, and
  a case that is steady on its third run would wait for a fourth to be enforced.
- **Report-only when the UI bench can't run on the runner** — rejected for now: it would let CI
  pass with no UI timings at all and nothing failing. If the runner can't show the window, the
  choice between a self-hosted runner, a job allowed to fail, or no UI bench in CI is Dylan's.

## Consequences

The first three runs on a branch with no history report only. A case enforced on `main` is
enforced on every branch made from it after that. Artifacts can't be edited, so lowering a case
back to report-only means deleting the branch's `bench-ui-report` artifacts, and `main`'s too
when the flag came from there. M0.17's first CI run is the first test of the
runner's display; if the job fails there with a visibility error, see the last alternative.
