import json, urllib.parse, urllib.request

BASE="http://127.0.0.1:18080"
def run(sql, prepared=None, tag=""):
    r=urllib.request.Request(BASE+"/v1/statement", data=sql.encode(), method="POST")
    r.add_header("X-Trino-User","tester")
    if prepared:
        n,p=prepared; r.add_header("X-Trino-Prepared-Statement", f"{n}={urllib.parse.quote(p)}")
    res=json.loads(urllib.request.urlopen(r).read())
    qid=res["id"]
    while "nextUri" in res:
        res=json.loads(urllib.request.urlopen(res["nextUri"]).read())
    e=res.get("error") or {}
    print(f"{tag}\t{qid}\t{res.get('stats',{}).get('state')}\t{e.get('errorName','-')}")

run("EXECUTE nosuch USING 'SHIP'", tag="no-such-prepared")
run("EXECUTE ps9 USING 'A','B'", prepared=("ps9","SELECT * FROM tpch.sf1.lineitem WHERE shipmode = ?"), tag="param-count-mismatch")
run("EXECUTE IMMEDIATE 'SELECT nosuchcol FROM tpch.sf1.lineitem'", tag="analysis-failure")
run("EXECUTE IMMEDIATE 'SELEKT 1'", tag="parse-failure")
