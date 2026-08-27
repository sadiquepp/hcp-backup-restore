"""Catalog service — owns the product list, persists it as JSON.

Standard library only, on purpose: the whole app must run with no `pip install`
at runtime so it works unchanged on an air-gapped cluster.
"""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
DATA = os.path.join(os.environ.get("DATA_DIR", "/data"), "catalog.json")
LOCK = threading.Lock()

SEED = [
    {"sku": "RHEL9", "name": "Red Hat Enterprise Linux 9"},
    {"sku": "OCP4", "name": "OpenShift Container Platform"},
    {"sku": "ODF4", "name": "OpenShift Data Foundation"},
]


def load():
    try:
        with open(DATA) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def save(items):
    tmp = DATA + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(items, handle)
    os.replace(tmp, DATA)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"status": "ok"})
        if self.path == "/items":
            with LOCK:
                return self.reply(200, load() or [])
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/items":
            return self.reply(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            item = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.reply(400, {"error": "invalid json"})
        with LOCK:
            items = load() or []
            items.append(item)
            save(items)
        return self.reply(201, item)

    def log_message(self, fmt, *args):
        print("catalog %s" % (fmt % args), flush=True)


def main():
    with LOCK:
        if load() is None:
            save(SEED)
    print("catalog listening on %d, data at %s" % (PORT, DATA), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
