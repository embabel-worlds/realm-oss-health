# realm-oss-health

**How maintained are the open-source projects you bet the company on?**

```
CriticalProject ──HAS_HEALTH──▶ ProjectHealth    the headline Scorecard
                ──HAS_CHECK───▶ ScorecardCheck   fourteen checks; the SCORE is on the edge
ScorecardCheck.name ─────────── CheckMeaning     what the check tells you, and what it is worth
```

Every organisation ships code it did not write and cannot fix. After Log4Shell and the xz-utils
backdoor the question stopped being academic: which of the projects underneath our product have
one maintainer, no security policy, unsigned releases, and nobody reviewing the commits?

The [OpenSSF Scorecard](https://scorecard.dev) answers exactly that — fourteen automated checks per
project — and almost nobody runs it across the projects they actually depend on.

Live, from three dependencies seeded as a test:

> **`jackson-databind` scores 0/10 on Code-Review** — "found 0/30 approved changesets". It is a
> critical dependency sitting on every API boundary. Log4j 2, next to it, scores 10: "all changesets
> reviewed".

That is the realm's whole argument in two rows. Both are Apache projects, both are everywhere, and
they are not run the same way.

## The catalog is data, not a CASE statement

`reference/scorecard-checks.yml` says what each check tells you and how much this realm weights it
for a project you *ship* rather than merely star. `Maintained`, `Code-Review`, `Vulnerabilities` and
`Dangerous-Workflow` carry weight 3 — the ways supply chains actually get compromised. The weighting
is a judgement in a file, so a lender, a procurement team and a platform team can each disagree with
it without touching a query.

## Three traps, all of which produce a confident wrong answer

**A check score of -1 is not zero.** It means the check could not be evaluated or does not apply.
Averaged in, it drags a well-run project below a mediocre one and inverts the ranking. Every view
excludes it; `NotEvaluated` reports what was excluded.

**The score belongs on the edge.** Scorecard check names are global — the same fourteen for every
project — so `ScorecardCheck` is one node per name and the per-project score rides on `HAS_CHECK`
via `edgeProject`. Projecting it onto the node would collapse forty projects' `Maintained` scores
into one and report whichever arrived last for all of them.

**An unscored project is not a bad one.** deps.dev has not indexed every repository, and a null
score sorts to the top of a descending ranking — so "not assessed" arrives looking like "worst".
The ranking views exclude nulls and `healthCoverage` reports them.

## A key that is itself a path

The project key is `github.com/apache/logging-log4j2` — a path, in a single path parameter. Two
things bite:

- `keySplit` defaults to `/`, so path-parameter mode split the key into three and sent deps.dev
  just `github.com`. This realm sets `keySplit: "|"`, a separator that cannot occur in a project key.
- The value then has to reach the source as `%2F`. That needed a host fix
  ([embabel-agent-experimental#32](https://github.com/embabel/embabel-agent-experimental/issues/32)):
  path-variable values are now encoded as path *segments*, so a slash inside a value stays data
  rather than becoming a separator.

## Getting an answer

```javascript
gateway.repository.createEntry({ type: "CriticalProject", data: {
  // projectKeyEncoded is REQUIRED: deps.dev takes the key as ONE encoded path segment.
  projectKey: "github.com/FasterXML/jackson-databind",
  name: "Jackson databind",
  whatWeUseItFor: "JSON on every API boundary",
  criticality: "critical",
  alternative: "Gson, at great cost",
}})
```

Then run `ExposureRanked`, or open **Bill of Health** (`apps/bill-of-health.html`).

## Testing

```bash
export EMBABEL_TOKEN=...
python3 scripts/test-views.py http://127.0.0.1:11043
```

Runs every view, fails on zero rows, surfaces every warning, and checks the guarantees: that no
score of -1 reaches a ranking, that the same check name carries different scores for different
projects (proving the edge projection holds), and that no unscored project is ranked as though it
were badly run.

## Licence

Apache 2.0. Scorecard and project data from [deps.dev](https://deps.dev), used under its terms.
