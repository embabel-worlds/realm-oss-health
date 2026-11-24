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
import base64, json, os, sys, urllib.parse, urllib.request

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
    return v

def cypher(q):
    return post("/api/v1/admin/kg/execute", {"cypher": q}).get("rows") or []

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
    code_mode("await gateway.repository.createEntries(%s); return 'seeded';"
              % json.dumps([{"type": "CriticalProject", "data": s} for s in SEED]))
    tracked = cypher("MATCH (p:CriticalProject) RETURN p.projectKey AS key, p.name AS name")
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
check("the check detail reuses the headline's cached call", calls3 == 0, "%s calls" % calls3)

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
