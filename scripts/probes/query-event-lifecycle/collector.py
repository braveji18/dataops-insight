import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = open(os.environ.get("EVENTS_LOG", "events.log"), "a", buffering=1)

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        try:
            e = json.loads(raw)
        except Exception:
            e = {}
        meta = e.get("metadata", {})
        qid = meta.get("queryId", "?")
        # QueryCompletedEvent has statistics/endTime; QueryCreatedEvent has createTime only
        kind = "query_completed" if "statistics" in e else "query_created"
        state = meta.get("queryState", "?")
        q = (meta.get("query", "") or "").replace("\n", " ")[:90]
        prep = (meta.get("preparedQuery") or "")
        prep = prep.replace("\n", " ")[:60] if isinstance(prep, str) else ""
        LOG.write(f"{kind}\t{qid}\t{state}\tQ={q}\tPREP={prep}\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass

HTTPServer(("0.0.0.0", int(sys.argv[1])), H).serve_forever()
