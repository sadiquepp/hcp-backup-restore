"""Orders service — append-only order log persisted as JSON.

Standard library only (see catalog.py for why). Starts empty by design: this is
the service whose record count you assert on when testing anything that has to
preserve state — a restore, a migration, a node drain.
"""

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
DATA = os.path.join(os.environ.get("DATA_DIR", "/data"), "orders.json")
LOCK = threading.Lock()


def load():
    try:
        with open(DATA) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return []


def save(orders):
    tmp = DATA + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(orders, handle)
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
        if self.path == "/orders":
            with LOCK:
                orders = load()
            return self.reply(200, {"count": len(orders), "orders": orders})
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/orders":
            return self.reply(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.reply(400, {"error": "invalid json"})
        with LOCK:
            orders = load()
            payload["id"] = len(orders) + 1
            payload["created"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            orders.append(payload)
            save(orders)
        return self.reply(201, payload)

    def log_message(self, fmt, *args):
        print("orders %s" % (fmt % args), flush=True)


def main():
    print("orders listening on %d, data at %s" % (PORT, DATA), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
