/*
 * Scheduled agents over the health of what you depend on.
 *
 * Why a clock: a project's score does not change because you looked at it, but it does change —
 * a maintainer walks away, a release-signing workflow is added, a Scorecard run finds a dangerous
 * workflow that was always there. None of that announces itself, and by the time it matters you
 * are reading about it in someone else's incident report. The estate is also the thing people
 * forget to re-examine: a dependency added in a hurry two years ago is exactly the one nobody has
 * looked at since.
 *
 * A handler reads the graph with ctx.gateway.cypher.query. There is no global `gateway` here, and
 * `gateway.kg.query` is the code_mode surface rather than the wasm one; the granted host tools
 * inside wasm are cypher_query, sql_query and sql_update. cypher_query takes no bound parameters,
 * so every threshold below is applied in TypeScript over a bounded read.
 */

type Row = Record<string, any>

async function read(ctx: any, cypher: string): Promise<Row[]> {
  const res = await ctx.gateway.cypher.query({ cypher })
  if (!res) return []
  if (Array.isArray(res)) return res
  if (Array.isArray(res.rows)) return res.rows
  if (res.data && Array.isArray(res.data.rows)) return res.data.rows
  return []
}

const num = (v: any): number => {
  // Number(null) is 0, and Number('') is 0. Both would turn "we have no value for this" into a
  // real, low, plausible number — an unscored project reported as 0/10 and ranked the most
  // exposed thing in the estate, which is what this helper originally did.
  if (v === null || v === undefined || v === '') return NaN
  const n = Number(v)
  return Number.isFinite(n) ? n : NaN
}

const DEPENDENCE: Record<string, number> = { critical: 3, important: 2, incidental: 1 }

/*
 * The weekly sweep. What you depend on, ranked by how much a problem there would cost you —
 * which is NOT the same as ranked by score.
 *
 * The `score >= 0` guard is load-bearing rather than defensive. Scorecard writes -1 for a check
 * it could not evaluate, and -1 is not a bad score: averaged in, it drags a well-run project below
 * a mediocre one and inverts the whole ranking, silently and plausibly.
 */
export async function healthSweep(args: { below?: number }, ctx: any) {
  const projects = await read(ctx, `
    MATCH (p:CriticalProject)-[:HAS_HEALTH]->(h:ProjectHealth)
    RETURN p.projectKey AS projectKey, p.name AS name, p.criticality AS criticality,
           p.whatWeUseItFor AS usedFor, p.alternative AS alternative,
           h.overallScore AS overallScore, h.scorecardDate AS scoredOn
    LIMIT 300
  `)
  const checks = await read(ctx, `
    MATCH (p:CriticalProject)-[r:HAS_CHECK]->(c:ScorecardCheck)
    OPTIONAL MATCH (m:CheckMeaning {name: c.name})
    RETURN p.name AS project, c.name AS check, r.score AS score, r.reason AS reason,
           m.weight AS weight, m.tells AS tells
    LIMIT 2000
  `)

  const below = args && typeof args.below === 'number' ? args.below : 5
  const scored = projects.filter(p => Number.isFinite(num(p.overallScore)))

  const ranked = scored
    .map(p => {
      const dep = DEPENDENCE[String(p.criticality || '').toLowerCase()] ?? 1
      return { ...p, score: num(p.overallScore), exposure: (10 - num(p.overallScore)) * dep }
    })
    .sort((a, b) => b.exposure - a.exposure)

  /* Only checks that were actually evaluated, and only ones this realm weights as consequential. */
  const serious = checks
    .filter(c => Number.isFinite(num(c.score)) && num(c.score) >= 0 && num(c.score) < below)
    .filter(c => num(c.weight) >= 3)
    .sort((a, b) => num(a.score) - num(b.score))

  const worst = ranked[0] || null
  const noAlternative = ranked.filter(p => !p.alternative || String(p.alternative).trim() === '')

  return {
    checkedAt: new Date().toISOString(),
    projectsTracked: projects.length,
    projectsScored: scored.length,
    seriousFailingChecks: serious.length,
    criticalWithNoAlternativeRecorded: noAlternative.map(p => p.name),
    headline: worst
      ? `${worst.name} is the most exposed dependency: ${worst.score}/10 on OpenSSF Scorecard and a ` +
        `${worst.criticality || 'unrated'} dependency` +
        (worst.usedFor ? ` used for ${worst.usedFor}` : '') + '.' +
        (serious.length ? ` ${serious.length} consequential check(s) are failing across the estate.` : '')
      : 'No tracked project has a Scorecard yet.',
    mostExposed: ranked.slice(0, 10).map(p => ({
      project: p.name, score: p.score, dependOn: p.criticality,
      exposure: Math.round(p.exposure * 10) / 10,
    })),
    seriousFindings: serious.slice(0, 15),
  }
}

/*
 * Coverage, as a fact rather than a hope.
 *
 * Every number above is conditional on deps.dev actually having indexed the project, and on
 * Scorecard having run recently. A project nobody indexed and a project that scored well look
 * identical in a table of the projects that DID come back, so this states the denominator — and
 * flags a scorecard old enough that it describes a repository which has since moved on.
 */
export async function healthCoverage(args: { staleAfterDays?: number }, ctx: any) {
  const rows = await read(ctx, `
    MATCH (p:CriticalProject)
    OPTIONAL MATCH (p)-[:HAS_HEALTH]->(h:ProjectHealth)
    OPTIONAL MATCH (p)-[r:HAS_CHECK]->(:ScorecardCheck)
    RETURN p.projectKey AS projectKey, p.name AS name, p.criticality AS criticality,
           h.overallScore AS overallScore, h.scorecardDate AS scoredOn,
           count(r) AS checksReturned
    LIMIT 300
  `)

  const staleDays = args && typeof args.staleAfterDays === 'number' ? args.staleAfterDays : 90
  const unindexed = rows.filter(r => !Number.isFinite(num(r.overallScore)))
  const stale = rows.filter(r => {
    const t = Date.parse(String(r.scoredOn || ''))
    return Number.isFinite(t) && (Date.now() - t) / 86400000 > staleDays
  })
  const thin = rows.filter(r => Number.isFinite(num(r.overallScore)) && num(r.checksReturned) < 10)

  return {
    checkedAt: new Date().toISOString(),
    projectsTracked: rows.length,
    projectsWithNoScorecard: unindexed.map(r => ({ project: r.name, key: r.projectKey })),
    scorecardsOlderThanDays: staleDays,
    staleScorecards: stale.map(r => ({ project: r.name, scoredOn: r.scoredOn })),
    projectsWithFewChecks: thin.map(r => ({ project: r.name, checks: Number(r.checksReturned) })),
    verdict: unindexed.length
      ? `${unindexed.length} tracked project(s) have no Scorecard at all — deps.dev has not indexed them, ` +
        'so nothing in the health views speaks about them. That is a gap, not a clean result.'
      : stale.length
        ? `Every project is scored, but ${stale.length} scorecard(s) are older than ${staleDays} days ` +
          'and may describe a repository that has since changed.'
        : 'Every tracked project has a current Scorecard.',
  }
}

/* Weekly. Scorecard is recomputed on roughly this cadence, and a project's governance does not
   change between Tuesdays. */
defineSchedule('healthSweep', '0 0 7 * * MON')
/* The denominator changes when somebody adds a dependency, so a little after the sweep. */
defineSchedule('healthCoverage', '0 30 7 * * MON')
