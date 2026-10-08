#!/usr/bin/env python3
"""Call an mTLS server with this workload's X.509-SVID, and check who answered.

  spiffe_client.py URL EXPECTED_SERVER_ID [--no-cert]

Both ends are checked, which is what makes it mutual:

  - the server must present a certificate that chains to this workload's trust
    bundle AND carries EXPECTED_SERVER_ID as its URI SAN. A hostname is never
    checked - SPIFFE identifies workloads, not DNS names - which is also why
    the call can go through a Route by any name;
  - this workload presents its own SVID, and the server decides.

The SVID, key and bundle are the files spiffe-helper writes into SVID_DIR.

--no-cert calls without presenting a certificate, as a workload with no SVID
would have to. If there is no trust bundle either (the intruder has neither),
the server's identity cannot be checked, and is not: the point of that call
is to show the SERVER refusing, not the client.

Exit status: 0 allowed; 2 refused by the server (handshake or HTTP 403);
3 the server is not trusted or not who it should be; 4 this workload has no SVID;
5 the server could not be reached at all (DNS, timeout) - no verdict.
"""

import argparse
import http.client
import os
import ssl
import sys
import urllib.parse

SVID_DIR = os.environ.get("SVID_DIR", "/svid")
SVID = os.path.join(SVID_DIR, "svid.pem")
KEY = os.path.join(SVID_DIR, "svid_key.pem")
BUNDLE = os.path.join(SVID_DIR, "svid_bundle.pem")


def spiffe_ids(cert):
    return [v for k, v in cert.get("subjectAltName", ())
            if k == "URI" and v.startswith("spiffe://")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("expected_server_id")
    ap.add_argument("--no-cert", action="store_true",
                    help="present no client certificate")
    a = ap.parse_args()

    have_svid = os.path.exists(SVID) and os.path.exists(KEY)
    have_bundle = os.path.exists(BUNDLE)
    if not a.no_cert and not have_svid:
        print(f"NO SVID: nothing in {SVID_DIR}. This workload has no registration "
              "entry, so the SPIRE agent issued it no identity.")
        return 4

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.check_hostname = False          # SPIFFE ID below, not a DNS name
    ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)
    if have_bundle:
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(BUNDLE)
    else:
        print("no trust bundle either - NOT checking the server, so that what "
              "follows is the server's decision alone")
        ctx.verify_mode = ssl.CERT_NONE
    if not a.no_cert:
        ctx.load_cert_chain(SVID, KEY)

    u = urllib.parse.urlsplit(a.url)
    conn = http.client.HTTPSConnection(u.hostname, u.port or 443,
                                       context=ctx, timeout=15)
    try:
        conn.connect()                  # TLS handshake; SNI = the URL's host
        if have_bundle:
            server = spiffe_ids(conn.sock.getpeercert() or {})
            if a.expected_server_id not in server:
                print(f"WRONG SERVER: expected {a.expected_server_id}, "
                      f"it presented {server or 'no SPIFFE ID'}. Not sending anything.")
                return 3
            print(f"server is {server[0]} - verified against the trust bundle")
        conn.request("GET", u.path or "/")
        resp = conn.getresponse()
        body = resp.read().decode(errors="replace").strip()
    except ssl.SSLCertVerificationError as e:
        # This side's decision, not the server's: its certificate does not
        # chain to anything in our bundle - a foreign trust domain we are not
        # federated with, typically.
        print(f"SERVER NOT TRUSTED: {e.verify_message}. Its CA is not in "
              f"{BUNDLE} - a trust domain this workload is not federated with?")
        return 3
    except ssl.SSLError as e:
        # TLS 1.3: the client finishes its half of the handshake before the
        # server has judged its certificate, so a refusal usually arrives as
        # an alert on the first read - 'certificate required' or 'unknown ca'.
        print(f"REFUSED: {e.reason or e}")
        return 2
    except ConnectionError as e:
        print(f"REFUSED: connection closed by the server ({e})")
        return 2
    except OSError as e:
        # Name resolution, a timeout, no route: nothing was decided about
        # identity at all, so this must not read as a refusal.
        print(f"UNREACHABLE: {u.hostname}:{u.port or 443}: {e}")
        return 5
    print(f"HTTP {resp.status}: {body}")
    return 0 if resp.status == 200 else 2


if __name__ == "__main__":
    sys.exit(main())
