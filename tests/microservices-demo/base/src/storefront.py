"""Storefront — the edge service. Holds no state; fans out to catalog + orders.

Standard library only (see catalog.py for why).

Downstream addresses come from the environment so the same image works when the
services are renamed, moved to another namespace, or pointed at a stub during a
test. A downstream failure degrades /api/summary but never /healthz, so a
transient backend outage cannot evict this pod from its Service endpoints.
"""

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
CATALOG = os.environ.get("CATALOG_URL", "http://catalog:8080")
ORDERS = os.environ.get("ORDERS_URL", "http://orders:8080")
TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "5"))

PAGE = b"""<!doctype html>
<html><head><meta charset="utf-8"><title>microservices-demo</title>
<style>body{font-family:sans-serif;margin:2rem;max-width:44rem}
code{background:#eee;padding:.1rem .3rem}
button{padding:.4rem .8rem;margin:.5rem 0}</style></head>
<body><h1>microservices-demo</h1>
<p><code>storefront</code> &rarr; <code>catalog</code> + <code>orders</code></p>
<pre id="out">loading...</pre>
<button onclick="place()">Place an order</button>
<script>
async function refresh(){
  const r = await fetch('api/summary');
  document.getElementById('out').textContent =
    JSON.stringify(await r.json(), null, 2);
}
async function place(){
  await fetch('api/orders', {method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({item:'RHEL9'})});
  refresh();
}
refresh();
</script></body></html>
"""


def get_json(url):
    with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
        return json.load(resp)


def post_json(url, payload):
    raw = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=raw, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.load(resp)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"status": "ok"})
        if self.path in ("/", "/index.html"):
            return self.reply(200, PAGE, "text/html; charset=utf-8")
        if self.path == "/api/summary":
            summary = {"status": "ok", "catalog": None, "orders": None}
            for key, url in (("catalog", CATALOG + "/items"),
                             ("orders", ORDERS + "/orders")):
                try:
                    summary[key] = get_json(url)
                except (urllib.error.URLError, OSError, ValueError) as exc:
                    summary["status"] = "degraded"
                    summary[key] = {"error": str(exc)}
            code = 200 if summary["status"] == "ok" else 503
            return self.reply(code, summary)
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/orders":
            return self.reply(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.reply(400, {"error": "invalid json"})
        try:
            return self.reply(201, post_json(ORDERS + "/orders", payload))
        except (urllib.error.URLError, OSError, ValueError) as exc:
            return self.reply(502, {"error": str(exc)})

    def log_message(self, fmt, *args):
        print("storefront %s" % (fmt % args), flush=True)


def main():
    print("storefront listening on %d -> %s, %s" % (PORT, CATALOG, ORDERS), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
