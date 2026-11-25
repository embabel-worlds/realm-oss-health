#!/bin/sh
# The battery for realm-oss-health: every view, re-checked against deps.dev itself.
#
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
#
# deps.dev is open and keyless, so this needs no source key. CriticalProject is the one thing a
# person seeds; when the world has none, the battery seeds four well-known projects (and says so),
# because a battery that passes on an empty estate has checked nothing.
#
#   L1  every view answers by name on its defaults
#   L2  each project's overall score and check scores equal what deps.dev reports for it,
#       and the realm's three traps hold (-1 is not a failure, scores ride the edge, an
#       unscored project is never ranked worst)
#   L3  cost: a cold read is at most one deps.dev call per project, and a repeat is free
#
# The last line is exactly `ALL CHECKS PASS` when everything holds; any failure exits 1.
exec python3 - "$@" <<'PY'
import base64, json, os, sys, time, urllib.parse, urllib.request

APPLIANCE = os.environ.get("APPLIANCE", "http://127.0.0.1:11043").rstrip("/")
AUTH = os.environ.get("AUTH") or os.environ.get("EMBABEL_AUTH") or sys.exit("set AUTH=user:pass")
HDR = {"Authorization": "Basic " + base64.b64encode(AUTH.encode()).decode(), "Content-Type": "application/json"}
DEPS = "https://api.deps.dev/v3/projects/"
SEED = [  # only used when the world tracks no project at all
    {"projectKey": "github.com/apache/logging-log4j2", "name": "log4j", "criticality": "critical",
     "whatWeUseItFor": "logging in every service", "alternative": "logback"},
    {"projectKey": "github.com/expressjs/express", "name": "express", "criticality": "important",
     "whatWeUseItFor": "the public HTTP API", "alternative": "fastify"},
    {"projectKey": "github.com/madler/zlib", "name": "zlib", "criticality": "critical",
     "whatWeUseItFor": "compression under everything", "alternative": ""},
    {"projectKey": "github.com/tukaani-project/xz", "name": "xz", "criticality": "incidental",
     "whatWeUseItFor": "build-time archive tooling", "alternative": "zstd"},
]
fail = 0

# Whether an engine answer is the whole truth. A source that failed under load, a capped page or a
# refused hop leaves the rows looking like an answer while the figure is short; reading the figure
# and ignoring the rest reports drift that is not the realm's. short(d) is None when the answer is
# whole, else what to print in place of the figure: "REFUSED: <why>" or "PARTIAL <n>: <reason>".
# Query answers carry `error`, `reason`, `run` and string `warnings` opening with the engine's code;
# a view envelope carries `status`, `outcome` and `warnings` as {code, message}.
# Raw warning codes that mean rows or values may be missing (the engine's incompleteness kinds).
# Cost notes (FILTERED_IN_GRAPH, AGGREGATE_NOT_PUSHED, EMPTY_NOT_KEPT, PUSHDOWN_VALUE_UNMATCHED),
# FILTER_STARVED (an honest empty), STALE_COPY, FIELDS_WITHHELD and UNKNOWN_VIA leave every row in place.
SHORT_CODES = (
    "PARTIAL_RESULT", "PRODUCER_ERROR", "NEEDS_FILTER", "NEEDS_PRODUCER", "FILTER_REJECTED",
    "UNPUSHED_FILTER", "AMBIGUOUS_LABEL", "INCOMPLETE_TRAVERSAL", "INCOMPLETE_RANKING",
    "INCOMPLETE_AGGREGATE", "INCOMPLETE_INPUT", "MATERIALIZATION_FAILED", "REDUCTION_FAILED",
    "UNPARSEABLE_ANSWER", "TERMS_UNAVAILABLE", "COMPUTE_FAILED", "PROPERTY_NOT_STORED",
    "FOLLOW_CAPPED", "UNLINKED_CHILDREN", "RESOLUTION_DROPPED", "AGENTIC_DEGRADED",
    "SOURCE_UNANSWERED",
)
# The typed `reason` a query result carries when it is not a clean answer and not an honest empty.
SHORT_REASONS = ("UNBOUNDED", "PARTIAL_NOT_MATCHED", "UNPUSHED_FILTER", "DISCONNECTED",
                 "INTERNAL_ERROR", "WRITE_IN_PROGRESS", "KILLED", "TOO_EXPENSIVE")
# Public warning codes on a view envelope that mean the same.
SHORT_PUBLIC = ("PARTIAL", "REDUCTION_FAILED", "COMPUTE_FAILED", "PROPERTY_NOT_STORED",
                "AGENTIC_DEGRADED", "RATE_LIMITED", "SOURCE_UNAVAILABLE", "SOURCE_REJECTED",
                "INVALID_FILTER", "UNPUSHED_FILTER", "TOO_BROAD", "FETCH_CAPPED",
                "INDEX_UNAVAILABLE", "ARGUMENT_REFUSED")


def short(d, figure=None):
    tag = "PARTIAL" if figure is None else "PARTIAL %s" % (figure,)
    if not isinstance(d, dict):
        return "REFUSED: not an engine answer: " + str(d)[:160]
    if "outcome" in d or "status" in d:  # a view envelope
        err = d.get("error") or {}
        if d.get("status") != "SUCCEEDED":
            return "REFUSED: %s %s" % (d.get("status"), (err.get("code", "") + " " + err.get("message", "")).strip()[:160] if isinstance(err, dict) else str(err)[:160])
        ws = [w for w in d.get("warnings") or [] if isinstance(w, dict) and w.get("code") in SHORT_PUBLIC]
        if d.get("outcome") not in ("OK", "EMPTY") or ws:
            why = ws[0]["code"] + ": " + ws[0].get("message", "") if ws else "outcome " + str(d.get("outcome"))
            return "%s: %s" % (tag, why[:200])
        return None
    if d.get("error"):
        return "REFUSED: " + str(d["error"])[:160]
    if d.get("run"):
        return "%s: the run had not finished (%s)" % (tag, d["run"])
    ws = [w for w in d.get("warnings") or [] if isinstance(w, str) and w.split(":", 1)[0].strip() in SHORT_CODES]
    if ws:
        return "%s: %s" % (tag, ws[0][:200])
    if d.get("reason") in SHORT_REASONS:
        return "%s: reason %s" % (tag, d["reason"])
    return None

def check(name, ok, detail=""):
    global fail
    print(("  ok   " if ok else "  FAIL ") + name + (("  (" + detail + ")") if detail else ""))
    if not ok: fail = 1

def post(path, body, timeout=300):
    req = urllib.request.Request(APPLIANCE + path, json.dumps(body).encode(), HDR, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def invoke(name, args=None):
    v = post("/api/v1/views/%s/invoke" % name, {"args": args or {}})
    if v.get("status") != "SUCCEEDED":
        raise SystemExit("view %s: %s %s" % (name, v.get("status"), json.dumps(v.get("error"))))
    # A short view is flagged here and handed on with no rows, so nothing below counts part of an
    # answer as the whole of it; the battery has already failed with the engine's reason.
    s = short(v, len(v.get("data") or []))
    if s:
        check("view %s answered whole" % name, False, s)
        return dict(v, data=[])
    return v

def cypher(q):
    # A refused or short read of the tracked projects must never read as "the world tracks none":
    # that is what decides whether to seed, and a seed written over a failed read duplicates work.
    r = post("/api/v1/admin/kg/execute", {"cypher": q})
    rows = r.get("rows") or []
    s = short(r, len(rows))
    if s:
        print("  FAIL %s\n         %s" % (q, s)); print("FAILED"); sys.exit(1)
    return rows

def code_mode(script):
    """Writes go through the code door: the studio's Cypher is read-only."""
    h = dict(HDR, Accept="application/json, text/event-stream")
    def rpc(body, sid=None):
        hh = dict(h, **({"Mcp-Session-Id": sid} if sid else {}))
        with urllib.request.urlopen(urllib.request.Request(APPLIANCE + "/mcp/code", json.dumps(body).encode(), hh), timeout=300) as r:
            sid = r.headers.get("Mcp-Session-Id") or sid
            text = r.read().decode()
        for line in text.splitlines():
            if line.startswith("data:"): text = line[5:]
        return (json.loads(text) if text.strip() else {}), sid
    _, sid = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "oss-health-verify", "version": "1"}}})
    rpc({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    res, _ = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                  "params": {"name": "code_mode", "arguments": {"script": script}}}, sid)
    return res

def deps_dev(key):
    try:
        with urllib.request.urlopen(DEPS + urllib.parse.quote(key, safe=""), timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404: return None
        raise

print("== seed: the tracked projects ==")
tracked = cypher("MATCH (p:CriticalProject) RETURN p.projectKey AS key, p.name AS name")
if not tracked:
    # One createEntry({type, data}) per project: the documented write.
    res = code_mode("const out = []; for (const data of %s) { out.push(await gateway.repository.createEntry({ type: 'CriticalProject', data })); } return out;"
                    % json.dumps(SEED))
    text = " ".join(c.get("text", "") for c in ((res.get("result") or {}).get("content") or []))
    print("  code door answered: " + text.split("--- END ORIENTATION ---")[-1].strip()[-800:])
    for _ in range(10):  # a write is visible to a read within moments, not necessarily at once
        tracked = cypher("MATCH (p:CriticalProject) RETURN p.projectKey AS key, p.name AS name")
        if tracked: break
        time.sleep(3)
    print("  seeded %d projects" % len(tracked))
check("the world tracks at least one CriticalProject", len(tracked) > 0, "%d" % len(tracked))
names = {t["key"]: t["name"] for t in tracked}

print("== L3: cost (measured first, while the cache may still be cold) ==")
first = invoke("WeakestLinks", {"limit": 100})
calls1 = (first.get("metrics") or {}).get("externalCalls")
check("WeakestLinks reads at most one deps.dev call per project", calls1 is not None and calls1 <= len(tracked),
      "%s calls for %d projects" % (calls1, len(tracked)))
again = invoke("WeakestLinks", {"limit": 100})
calls2 = (again.get("metrics") or {}).get("externalCalls")
check("a repeat is answered from the cache", calls2 == 0, "%s calls" % calls2)
checks = invoke("CheckMatrix", {"limit": 1000})
calls3 = (checks.get("metrics") or {}).get("externalCalls")
check("the check detail reads at most one deps.dev call per project", calls3 is not None and calls3 <= len(tracked),
      "%s calls" % calls3)
calls4 = (invoke("CheckMatrix", {"limit": 1000}).get("metrics") or {}).get("externalCalls")
check("a repeat of the check detail is answered from the cache", calls4 == 0, "%s calls" % calls4)

print("== L1: every view answers by name on its defaults ==")
MAY_BE_EMPTY = {"SinglePointsOfFailure", "FailingChecks", "NotEvaluated", "HealthBriefing"}
V = {}
for name in ["WeakestLinks", "ExposureRanked", "FailingChecks", "SinglePointsOfFailure",
             "CheckMatrix", "SystemicWeakness", "NotEvaluated", "HealthBriefing"]:
    rows = invoke(name).get("data") or []
    V[name] = rows
    check("%s answers" % name, bool(rows) or name in MAY_BE_EMPTY, "%d rows" % len(rows))

print("== L2: deps.dev itself agrees ==")
truth = {k: deps_dev(k) for k in names}
scored = {k: t for k, t in truth.items() if t and (t.get("scorecard") or {}).get("overallScore") is not None}
ranked = {r["repo"]: r["scorecard"] for r in first.get("data") or []}
check("WeakestLinks ranks exactly the projects deps.dev has scored", sorted(ranked) == sorted(scored),
      "realm %s, deps.dev %s" % (sorted(ranked), sorted(scored)))
for k, t in scored.items():
    want = round(float(t["scorecard"]["overallScore"]), 1)
    got = ranked.get(k)
    check("overall score of %s = deps.dev's" % k, got is not None and round(float(got), 1) == want, "%s vs %s" % (got, want))
grid = {(r["project"], r["check"]): r["score"] for r in checks.get("data") or []}
for k, t in scored.items():
    want = {(names[k], c["name"]): int(c["score"]) for c in t["scorecard"].get("checks") or [] if int(c["score"]) >= 0}
    got = {pc: s for pc, s in grid.items() if pc[0] == names[k]}
    check("evaluated check scores of %s = deps.dev's" % k, got == want, "%d checks" % len(want))
check("no check scored -1 is reported as failing",
      all(r["score"] >= 0 for n in ("FailingChecks", "SinglePointsOfFailure", "CheckMatrix") for r in V[n]))
by_check = {}
for (p, c), s in grid.items(): by_check.setdefault(c, set()).add(s)
check("scores ride the edge: some check differs across projects",
      len(scored) < 2 or any(len(s) > 1 for s in by_check.values()))
check("no unscored project is ranked", all(r.get("scorecard") is not None for n in ("WeakestLinks", "ExposureRanked") for r in V[n]))
check("every score is on Scorecard's 0-10 scale", all(0 <= s <= 10 for s in grid.values()))

if fail:
    print("FAILED"); sys.exit(1)
print("ALL CHECKS PASS")
PY
