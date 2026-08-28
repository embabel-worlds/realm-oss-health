#!/usr/bin/env python3
"""Run every view this realm ships against a LIVE host, and check its guarantees.

Row counts are the least of it. This realm's characteristic failures all produce a
full, plausible table that is quietly upside down:

  * a check scored -1 (not evaluated) averaged in as a zero, sinking a good project;
  * one project's score reported for all of them, because a global check NAME was used
    as the node identity and the per-project score does not live on the node;
  * a project deps.dev never indexed ranked as the worst thing you depend on, because
    a null sorts first in a descending order.

Each is asserted below. A harness that only counted rows would pass on all three.

    export EMBABEL_TOKEN=...
    python3 scripts/test-views.py [http://127.0.0.1:11043]
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:11043").rstrip("/")
TOKEN = os.environ.get("EMBABEL_TOKEN")

VIEWS = {
    "WeakestLinks":          {"limit": 30},
    "ExposureRanked":        {"limit": 30},
    "FailingChecks":         {"limit": 50},
    "SinglePointsOfFailure": {"limit": 25},
    "CheckMatrix":           {"limit": 400},
    "SystemicWeakness":      {"limit": 20},
    "NotEvaluated":          {"limit": 50},
    "HealthBriefing":        {"limit": 25},
}

# Empty is a legitimate — indeed desirable — answer only here.
MAY_BE_EMPTY = {
    "SinglePointsOfFailure": "no critical dependency failing a weight-3 check is the outcome you want",
    "FailingChecks": "an estate where nothing scores below the threshold",
    "NotEvaluated": "every check applied and ran",
    "HealthBriefing": "written from failing checks; nothing failing, nothing to brief",
}

failures, notes = [], []


def run_view(name, params):
    req = urllib.request.Request(
        f"{BASE}/api/v1/admin/kg/views/{name}/run",
        data=json.dumps(params).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)


def check_views():
    results = {}
    for name, params in VIEWS.items():
        try:
            res = run_view(name, params)
        except urllib.error.HTTPError as e:
            failures.append(f"{name}: HTTP {e.code} {e.read()[:200]!r}")
            continue
        except Exception as e:  # noqa: BLE001 — a harness reports; it does not raise
            failures.append(f"{name}: {e}")
            continue
        results[name] = res
        rows, warns = res.get("rows") or [], res.get("warnings") or []
        if not rows and name not in MAY_BE_EMPTY:
            failures.append(f"{name}: ZERO ROWS — a join that never fires looks exactly like this")
        for w in warns:
            notes.append(f"{name}: {str(w)[:200]}")
        why = f"  ({MAY_BE_EMPTY[name]})" if not rows and name in MAY_BE_EMPTY else ""
        print(f"  {name:<24}{len(rows):>4} rows{why}")
    return results


def check_ground_truth(results):
    # 1. A not-evaluated check must never reach a ranking as though it were a failure.
    for name in ("FailingChecks", "SinglePointsOfFailure", "CheckMatrix"):
        for row in (results.get(name) or {}).get("rows") or []:
            if row.get("score") is not None and row["score"] < 0:
                failures.append(
                    f"ground truth: {name} includes {row.get('project')}/{row.get('check')} "
                    f"scored {row['score']} — -1 means NOT EVALUATED, not failed"
                )
    print("  no not-evaluated check is reported as a failure")

    # 2. THE trap: a global check NAME must still carry per-project scores.
    matrix = (results.get("CheckMatrix") or {}).get("rows") or []
    by_check = {}
    for row in matrix:
        by_check.setdefault(row.get("check"), set()).add(row.get("score"))
    multi = {c: s for c, s in by_check.items() if len(s) > 1}
    projects = {row.get("project") for row in matrix}
    if len(projects) > 1 and matrix and not multi:
        failures.append(
            "ground truth: every check has an IDENTICAL score across all projects — the per-project "
            "score is not reaching the edge, so one project's scorecard is being reported for all"
        )
    print(f"  check scores vary per project ({len(multi)} of {len(by_check)} checks differ across projects)")

    # 3. An unscored project must not be ranked as the worst.
    for name in ("WeakestLinks", "ExposureRanked"):
        for row in (results.get(name) or {}).get("rows") or []:
            if row.get("scorecard") is None:
                failures.append(
                    f"ground truth: {name} ranks {row.get('project')} with a NULL scorecard — "
                    f"unassessed is being presented as badly run"
                )
    print("  no unscored project is ranked as though it were badly run")

    # 4. Scores must be within Scorecard's own scale.
    for row in matrix:
        if row.get("score") is not None and not (0 <= row["score"] <= 10):
            failures.append(f"ground truth: score {row['score']} outside 0-10 for {row.get('project')}")
    print("  scores are within Scorecard's own scale")


def main():
    if not TOKEN:
        sys.exit("EMBABEL_TOKEN is not set — this harness needs an admin bearer token. It refuses "
                 "to run rather than report a green that only means it never asked.")
    print(f"realm-oss-health against {BASE}\n\nviews:")
    results = check_views()
    print("\nground truth:")
    check_ground_truth(results)

    if notes:
        print("\nwarnings from the host — read these; an empty table here reads as 'all healthy':")
        for n in notes:
            print(f"  {n}")
    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)
    print("\nOK — every view answered and every guarantee holds.")


if __name__ == "__main__":
    main()
