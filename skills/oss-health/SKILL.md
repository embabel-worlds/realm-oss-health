---
name: oss-health
description: Answer questions about the health and governance of the open-source projects this organisation depends on — how well-maintained they are, which checks they fail, where a supply-chain problem would most plausibly come from, and which weaknesses are systemic across the estate. Use for "are our dependencies well maintained", "what's our supply chain risk", "which projects should worry us", "who reviews the code we ship", or any question about OpenSSF Scorecard, project governance or maintainer risk.
---

# The health of what you depend on

Every organisation ships code it did not write and cannot fix. This realm scores the projects
underneath your product with the OpenSSF Scorecard — fourteen automated checks — and ranks them
by how much a problem there would actually cost you.

## Run a view

| The question | The view |
|---|---|
| Which are worst run? | `WeakestLinks` |
| What should we work on? | `ExposureRanked` — score weighted by dependence |
| Why is this one bad? | `FailingChecks` |
| Where would an incident come from? | `SinglePointsOfFailure` |
| What's wrong across the board? | `SystemicWeakness` |
| The whole grid | `CheckMatrix` |
| What couldn't be assessed? | `NotEvaluated` |
| Write it up | `HealthBriefing` — costs a model call |

Two scheduled agents run without being asked: `healthSweep` and `healthCoverage`, both Monday
mornings.

## Three things to get right

**A check score of -1 is NOT zero.** It means the check could not be evaluated or does not apply —
`Packaging` on a project that publishes no package, `Signed-Releases` where there are no releases.
Averaging it in drags a well-run project below a mediocre one and inverts the ranking. Every view
excludes it; `NotEvaluated` lists what was excluded.

**The score lives on the EDGE.** Scorecard check names are global, so `ScorecardCheck` is one node
per name and the per-project score rides on `HAS_CHECK`. Read `r.score`, never `c.score` — the
latter is null for everything, and a hand-written query that reaches for it gets a table of nulls
rather than an error.

**An unscored project is not a bad one.** deps.dev has not indexed every repository. A null score
sorts to the top of a descending ranking, so "we could not assess this" arrives looking like "this
is the worst thing you depend on". The ranking views exclude nulls; `healthCoverage` reports them.

## Saying it properly

- **Weigh dependence, not just score.** A badly-run project nobody uses is a curiosity. Lead with
  `ExposureRanked`, not `WeakestLinks`, when someone asks what to do.
- **Popularity is not maintenance.** Stars say a project is used, not that anyone is looking after
  it — the xz-utils backdoor landed in something everybody used.
- **Quote the check's reason.** "Code-Review 0/10 — found 0/30 approved changesets" lands; "scores
  badly on governance" does not.
- **`Maintained`, `Code-Review` and `Dangerous-Workflow` are the three that matter most** for a
  project you ship. The weighting is this realm's judgement and lives in `reference/`, so it can be
  argued with rather than assumed.
- **An empty `SinglePointsOfFailure` is a real and good answer.** Say so plainly.
- **Scorecard runs periodically.** A stale `scoredOn` describes a repository that may have changed;
  `healthCoverage` flags scorecards older than 90 days.
