<!--
  Case files, not a manual. README.md and workshop.md say how the lab is meant
  to work; this records what happened when it did not, in enough detail that
  the next person recognises the shape before spending time on it.

  Convention (as in ../udn-bgp-evpn/troubleshooting.md): one section per
  non-obvious debug. Symptom first with the real output, then the trail in the
  order it was walked - wrong turns included - then the root cause, the fix,
  and what the lab now does so it cannot happen silently again.
-->

# Troubleshooting case files

Long-form records of faults that were hard to find, kept apart from
[README.md](README.md) and [workshop.md](workshop.md) so those stay about how
the lab works.

---

## Case 1 - `spire-server` is not where anything says it is

**Date:** 2026-10-03 · **Cluster:** hub · **Phase:** workshop Lab 2, `spire healthcheck`

### Symptom

The SPIRE server was up - StatefulSet 1/1, pod 2/2 Running, its PVC bound on
`lvms-vg1` - and the workshop's `spire` helper could not run the CLI:

```text
# spire healthcheck
executable file `spire-server` not found in $PATH: No such file or directory
command terminated with exit code 1
```

`spire` was `oc -n $ZT_NS exec spire-server-0 -c spire-server -- spire-server "$@"`.
The playbook's own checks (agent list, bundle show, entry show, federation
refresh) used the same bare name, so they would have failed the same way on
their first live run - the simulation's fake `oc` accepted any `spire-server`
argument, which is why nothing caught it.

### The trail

1. **The operator source** (`pkg/controller/spire-server/statefulset.go`)
   sets only `Args` (`-expandEnv -config /run/spire/config/server.conf`) on
   the container - so the binary is the image's entrypoint, and its path is
   whatever the image says. Nothing in the operator names it.
2. **Wrong turn: the documented path.** Red Hat's own procedure runs
   `oc exec ... -- /opt/spire/bin/spire-server healthcheck`, which is also
   upstream's layout. The lab switched to it. On the live hub:

   ```text
   executable file `/opt/spire/bin/spire-server` not found: No such file or directory
   ```

   The Red Hat image keeps it somewhere else. (An `ls /opt/` on the lab host
   proves nothing either way - that is the host, not the container.) The
   image is distroless, so there is no shell in it to go and look.
3. **The process, not the path.** The server container's PID 1 is the
   entrypoint - spire-server itself - and the pod does not set
   `shareProcessNamespace`, so `oc exec` lands in that container's own PID
   namespace. `/proc/1/exe` is therefore the running server's binary,
   wherever the image put it, and `exec` of it needs no shell:

   ```text
   # oc -n zero-trust-workload-identity-manager exec spire-server-0 -c spire-server -- /proc/1/exe healthcheck
   Server is healthy.
   # spire healthcheck
   Server is healthy.
   ```

### Root cause

The lab assumed the upstream image layout. Red Hat's SPIRE server image puts
`spire-server` neither on `$PATH` nor at `/opt/spire/bin`, and the
documentation shows the upstream path.

### Fix, and what the lab does now

- `spire_server_cli: /proc/1/exe` in `vars.yaml`, used by every `oc exec`
  of the CLI in the playbook and by the workshop's `spire` helper. No image
  path to keep in sync with a product image that may move it again.
- The fake `oc` used for simulation now rejects both `spire-server` and
  `/opt/spire/bin/spire-server` with the live error messages, so a
  regression to either fails the simulated run.
- A README troubleshooting row for the error text.

Caveat for anyone reusing it: `/proc/1/exe` is right only while the server is
the container's PID 1. If the operator ever adds `shareProcessNamespace` or
an init wrapper to the pod, PID 1 changes and this needs revisiting; the
image's entrypoint (`oc image info <image> -o json | jq .config.config.Entrypoint`)
is then the place to read the real path from.

---

## Case 2 - registered, but `no identity issued`, on the SNO only

**Date:** 2026-10-03 · **Cluster:** sno · **Phase:** workshop Lab 5, after the ClusterSPIFFEID

**Status:** cause confirmed from the agent's log; the fix below is written
and simulated, and awaits its first run on the live SNO.

### Symptom

The same Lab 5 that worked on the hub, on the SNO: registration complete,
delivery not.

```text
# oc get clusterspiffeid $DEMO_NS -o jsonpath='{.status.stats}{"\n"}'
{"entriesMasked":0,"entriesToSet":2,"entryFailures":0,"namespacesIgnored":0,"namespacesSelected":1,"podEntryRenderFailures":0,"podsSelected":2}
# spire entry show -spiffeID spiffe://$TD/ns/$DEMO_NS/sa/client
Found 1 entry
SPIFFE ID        : spiffe://sno.mylab.com/ns/spiffe-demo/sa/client
Parent ID        : spiffe://sno.mylab.com/spire/agent/k8s_psat/sno/6a7ddf0a-...
Selector         : k8s:pod-uid:cc88a923-...
# oc -n $DEMO_NS get pods
client-6b89df5f8b-9rtsn       2/2     Running   0          13m
echo-server-d5548ccc4-wlpj9   1/2     Running   0          13m
# svid client
ssl.SSLError: ("Can't open file",)
```

The entry exists and is parented to the SNO's agent; the pod never gets the
SVID.

### The trail

1. **The workload's side** - spiffe-helper, every 30s:

   ```text
   level=error msg="Error while watching x509 context: rpc error: code = PermissionDenied desc = no identity issued"
   ```

   The socket works (the agent answers). The agent is saying it does not
   know who is asking - workload attestation, not registration and not the
   CSI driver.
2. **The agent's side** names it outright:

   ```text
   level=error msg="Failed to collect all selectors for PID" error="workload attestor \"k8s\" failed: ... unable to perform request: Get \"https://sno:10250/pods\": dial tcp: lookup sno on 172.30.0.10:53: no such host"
   ```

   The k8s workload attestor asks the kubelet which pod a PID belongs to,
   and it dials the kubelet **by node name** (the operator configures it
   with `node_name_env: MY_NODE_NAME`). The SNO's node is named `sno`, a
   single label, and cluster DNS (172.30.0.10) could not resolve it.
3. **Why the hub is fine** (inferred, not yet checked on the hub itself -
   `oc get nodes` there and `dig @192.168.122.1 <node>` would confirm).
   Cluster DNS forwards what it cannot answer to
   the node's resolver, libvirt's dnsmasq on 192.168.122.1. dnsmasq answers
   bare names for the hosts it knows - and it learns a host's name from its
   DHCP lease. The hub's nodes take leases. The SNO is addressed statically
   from agent-config.yaml and never asks for one, so the `ip-dhcp-host`
   reservation setup-sno makes is never used and `sno` stays unknown. The
   helper's zone does have `sno.sno.mylab.com`, but nothing appends that
   domain to a bare `sno`.

### Root cause

A node name that resolves nowhere. Nothing in the base needed it before:
the API, the ingress and the console are all reached by `api.` / `*.apps.`
names. The SPIRE agent's attestor is the first client that dials a node by
its own name.

### Fix, and what the lab does now

- setup-sno publishes the node name as a libvirt DNS host entry
  (`virsh net-update default add dns-host ... --live --config`): dnsmasq
  answers at once and after reboots, with no change to the node. It runs
  before the VM is defined on a fresh build, and on its own against a live
  SNO with `setup_sno.yaml --tags snodns`.
- build-lab.sh's `lvm` step runs `--tags snodns,snostorage`, so an older
  lab gets it with `./build-lab.sh --only lvm`.
- Nothing to restart afterwards: spiffe-helper retries every 30s and the
  agent re-attests on each try.

The by-hand equivalent, on the lab host (the SNO is ip_list.sno, .20 here):

```bash
virsh net-update default add dns-host \
  "<host ip='192.168.122.20'><hostname>sno</hostname></host>" --live --config
dig +short @192.168.122.1 sno                     # 192.168.122.20
oc -n $ZT_NS logs ds/spire-agent --since=2m | grep -c 'no such host'   # stops growing
svid client
```
