import json, sys, time, urllib.parse, urllib.request

BASE = "http://127.0.0.1:18080"

def req(method, url, body=None, headers=None):
    r = urllib.request.Request(url, data=body, method=method)
    r.add_header("X-Trino-User", "tester")
    r.add_header("X-Trino-Catalog", "tpch")
    r.add_header("X-Trino-Schema", "tiny")
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read() or b"{}")

def submit(sql, prepared=None):
    h = {}
    if prepared:
        name, psql = prepared
        h["X-Trino-Prepared-Statement"] = f"{name}={urllib.parse.quote(psql)}"
    return req("POST", BASE + "/v1/statement", sql.encode(), h)

def drain(res, max_polls=None, cancel_at_end=False, label=""):
    """Follow nextUri. If max_polls is set, stop early (abandon)."""
    polls = 0
    last = res
    while "nextUri" in last:
        if max_polls is not None and polls >= max_polls:
            print(f"[{label}] ABANDON after {polls} polls, state={last.get('stats',{}).get('state')}, nextUri kept")
            if cancel_at_end:
                try:
                    req("DELETE", last["nextUri"])
                    print(f"[{label}] sent DELETE (cancel)")
                except Exception as e:
                    print(f"[{label}] DELETE failed: {e}")
            return last
        last = req("GET", last["nextUri"])
        polls += 1
        time.sleep(0.05)
    print(f"[{label}] DONE polls={polls} state={last.get('stats',{}).get('state')} error={bool(last.get('error'))}")
    return last

SEL = "SELECT orderkey, quantity, comment FROM tpch.sf1.lineitem WHERE shipmode = ?"

mode = sys.argv[1]

if mode == "plain":
    r = submit("SELECT orderkey, quantity, comment FROM tpch.sf1.lineitem WHERE shipmode = 'SHIP'")
    print("qid", r["id"]); drain(r, label="plain")

elif mode == "exec_immediate":
    sql = "EXECUTE IMMEDIATE '" + SEL.replace("'", "''") + "' USING 'SHIP'"
    r = submit(sql)
    print("qid", r["id"]); drain(r, label="exec_immediate")

elif mode == "prepare_execute":
    # legacy explicitPrepare path: PREPARE as its own query, then EXECUTE with header
    r = submit(f"PREPARE ps1 FROM {SEL}")
    print("qid(PREPARE)", r["id"]); drain(r, label="PREPARE")
    r = submit("EXECUTE ps1 USING 'SHIP'", prepared=("ps1", SEL))
    print("qid(EXECUTE)", r["id"]); drain(r, label="EXECUTE")

elif mode == "abandon":
    sql = "EXECUTE IMMEDIATE '" + SEL.replace("'", "''") + "' USING 'SHIP'"
    r = submit(sql)
    print("qid", r["id"]); drain(r, max_polls=3, label="abandon")

elif mode == "abandon_cancel":
    sql = "EXECUTE IMMEDIATE '" + SEL.replace("'", "''") + "' USING 'SHIP'"
    r = submit(sql)
    print("qid", r["id"]); drain(r, max_polls=3, cancel_at_end=True, label="abandon_cancel")

elif mode == "post_only":
    sql = "EXECUTE IMMEDIATE '" + SEL.replace("'", "''") + "' USING 'SHIP'"
    r = submit(sql)
    print("qid", r["id"], "-> POST only, never follow nextUri")
