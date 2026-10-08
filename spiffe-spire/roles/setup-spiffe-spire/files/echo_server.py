#!/usr/bin/env python3
"""mTLS echo server that authorises callers by SPIFFE ID.

Reads its X.509-SVID, key and trust bundle from files that spiffe-helper keeps
current in SVID_DIR, and re-reads them for every connection - so a rotated
SVID (every half hour with the lab's 1h TTL) is picked up with no restart.

A caller must present a certificate that chains to the trust bundle - the
local trust domain's CA, plus any federated trust domain's CA spiffe-helper
was given - AND whose SPIFFE ID is listed in ALLOW_FILE. The first is
authentication, the second authorisation; the demo shows each one refusing
a different caller.

  no client certificate          TLS handshake refused (certificate required)
  certificate from an unknown CA TLS handshake refused (unknown ca)
  valid SVID, ID not allowed     HTTP 403
  valid SVID, ID allowed         HTTP 200, "hello <caller>, this is <me>"

Standard library only; the SPIFFE ID is the URI SAN of the peer certificate.
"""

import http.server
import os
import ssl
import sys
import time

SVID_DIR = os.environ.get("SVID_DIR", "/svid")
ALLOW_FILE = os.environ.get("ALLOW_FILE", "/config/allowed-ids")
PORT = int(os.environ.get("PORT", "8443"))

SVID = os.path.join(SVID_DIR, "svid.pem")
KEY = os.path.join(SVID_DIR, "svid_key.pem")
BUNDLE = os.path.join(SVID_DIR, "svid_bundle.pem")


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def spiffe_ids(cert):
    """The spiffe:// URI SANs of a decoded certificate (getpeercert() form)."""
    return [v for k, v in cert.get("subjectAltName", ())
            if k == "URI" and v.startswith("spiffe://")]


def own_id():
    # ssl has no public call to decode a certificate FILE; this private one
    # has been stable since Python 3.4 and is what the test suite uses.
    try:
        return ",".join(spiffe_ids(ssl._ssl._test_decode_cert(SVID))) or "?"
    except Exception:  # noqa: BLE001 - only used for a greeting
        return "?"


def allowed_ids():
    try:
        with open(ALLOW_FILE) as f:
            return {line.strip() for line in f
                    if line.strip() and not line.startswith("#")}
    except FileNotFoundError:
        return set()


def server_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.verify_mode = ssl.CERT_REQUIRED
    # Python 3.13 turns on X509_STRICT by default, which holds SPIFFE CAs to
    # RFC 5280 details they are not required to meet. The chain and the
    # signatures are still verified in full.
    ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)
    ctx.load_cert_chain(SVID, KEY)
    ctx.load_verify_locations(BUNDLE)
    return ctx


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "spiffe-echo/1"

    def handle(self):
        # The handshake happens here, per connection, so a refused client is
        # logged with its reason instead of vanishing inside socketserver.
        try:
            self.request.do_handshake()
        except (ssl.SSLError, OSError) as e:
            log(f"REFUSED {self.client_address[0]}: TLS handshake failed: {e}")
            return
        super().handle()

    def do_GET(self):  # noqa: N802 - http.server's naming
        peer = spiffe_ids(self.request.getpeercert() or {})
        caller = peer[0] if peer else "(no SPIFFE ID)"
        me = own_id()
        if caller in allowed_ids():
            code, body = 200, f"hello {caller}, this is {me}\n"
            log(f"ALLOWED {caller}")
        else:
            code, body = 403, f"forbidden: {caller} is not allowed by {me}\n"
            log(f"FORBIDDEN {caller}: authenticated, but not in {ALLOW_FILE}")
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass  # one line per decision is logged above; skip the access log


class Server(http.server.ThreadingHTTPServer):
    def get_request(self):
        sock, addr = self.socket.accept()
        try:
            ctx = server_context()
        except (OSError, ssl.SSLError) as e:
            # No SVID yet - spiffe-helper has not written one. Refuse rather
            # than serve with something else.
            log(f"no SVID to serve with yet ({e}); dropping {addr[0]}")
            sock.close()
            raise OSError("no SVID") from e
        return ctx.wrap_socket(sock, server_side=True,
                               do_handshake_on_connect=False), addr

    def handle_error(self, request, client_address):
        log(f"error serving {client_address[0]}: {sys.exc_info()[1]}")


def main():
    while not all(os.path.exists(p) for p in (SVID, KEY, BUNDLE)):
        log(f"waiting for an SVID in {SVID_DIR} - is this workload registered?")
        time.sleep(5)
    log(f"serving as {own_id()} on :{PORT}; allowed callers from {ALLOW_FILE}")
    Server(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
