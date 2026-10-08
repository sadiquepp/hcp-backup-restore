"""What the SPIFFE labs need from the network, asked from inside a pod.

Run by the probe step (tasks/probe.yml) in a short-lived pod. Prints one
JSON object; the playbook reads it and says what is missing. Standard
library only.

  NODES  JSON list of node names. The SPIRE agent's workload attestor dials
         its kubelet at https://<node name>:10250, resolved through cluster
         DNS - a name that does not resolve means no SVID on that node
         (troubleshooting.md case 2).
  APPS   JSON object {label: apps domain}. A made-up name under each *.apps
         wildcard must resolve and the router behind it must complete a TLS
         handshake: the labs' Routes - and the federation bundle endpoint -
         are reached that way, from pods, across the two clusters.
"""
import json
import os
import socket
import ssl

result = {"nodes": {}, "apps": {}}

for node in json.loads(os.environ["NODES"]):
    try:
        result["nodes"][node] = "ok " + socket.getaddrinfo(node, 10250, proto=socket.IPPROTO_TCP)[0][4][0]
    except OSError as e:
        result["nodes"][node] = "ERROR does not resolve: %s" % e

ctx = ssl.create_default_context()
ctx.check_hostname = False          # any certificate will do: is a router there at all?
ctx.verify_mode = ssl.CERT_NONE
for label, domain in json.loads(os.environ["APPS"]).items():
    host = "spiffe-probe." + domain
    try:
        addr = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)[0][4][0]
    except OSError as e:
        result["apps"][label] = "ERROR %s does not resolve: %s" % (host, e)
        continue
    try:
        with socket.create_connection((addr, 443), 5) as s, ctx.wrap_socket(s, server_hostname=host):
            pass
        result["apps"][label] = "ok %s -> %s:443" % (host, addr)
    except (OSError, ssl.SSLError) as e:
        result["apps"][label] = "ERROR %s -> %s:443 resolves, but no TLS from a router: %s" % (host, addr, e)

print(json.dumps(result))
