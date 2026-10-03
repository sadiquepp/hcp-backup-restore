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

**Status:** fixed and confirmed on the live SNO (`svid client` shows
`spiffe://sno.mylab.com/ns/spiffe-demo/sa/client`, issued by the SPIRE Server
CA, valid 1h).

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
3. **First fix, half right: the name in libvirt's DNS.** Cluster DNS
   forwards what it cannot answer to the node's resolvers. The lab's
   libvirt network did not know a bare `sno` - the SNO is addressed
   statically, so its DHCP reservation is never used. A libvirt `dns-host`
   entry made it answer:

   ```text
   # dig +short @192.168.122.1 sno
   192.168.122.20
   ```

   and the pod still could not resolve it, even as the absolute name `sno.`:

   ```text
   # inpod client python3 -c "import socket; print(socket.gethostbyname('sno.'))"
   socket.gaierror: [Errno -2] Name or service not known
   ```
4. **The resolver in front of libvirt.** Cluster DNS's upstreams on the SNO
   are not just libvirt:

   ```text
   # oc -n openshift-dns exec ds/dns-default -c dns -- cat /etc/resolv.conf
   nameserver 192.168.122.20
   nameserver 192.168.122.1
   ```

   192.168.122.20 is the SNO itself, and on it:

   ```text
   # oc debug node/sno -q -- chroot /host sh -c 'ss -lunp | grep ":53 "; cat /etc/dnsmasq.d/*'
   UNCONN 0 0 0.0.0.0:53 0.0.0.0:* users:(("dnsmasq",pid=2926,fd=4))
   address=/apps.sno.mylab.com/192.168.122.20
   address=/api-int.sno.mylab.com/192.168.122.20
   address=/api.sno.mylab.com/192.168.122.20
   ```

   The single-node install's own dnsmasq (`single-node.conf`): it answers
   the cluster's `api`, `api-int` and `*.apps` names itself and passes
   everything else on. It had asked about `sno` before the libvirt entry
   existed and cached the "no such host" - and as the first upstream, its
   answer was final.
5. **Confirmed by clearing that cache.** SIGHUP makes dnsmasq drop its
   cache and reread its config, without a restart:

   ```text
   # oc debug node/sno -q -- chroot /host pkill -HUP dnsmasq && sleep 5 && \
       inpod client python3 -c "import socket; print(socket.gethostbyname('sno'))"
   192.168.122.20
   # svid client
   "URI", "spiffe://sno.mylab.com/ns/spiffe-demo/sa/client"   (notBefore 14:39:55, notAfter 15:40:05)
   ```

   A first attempt failed with `pods "sno-debug-..." is forbidden: ...
   serviceaccount "default" not found` - `oc debug`'s throwaway namespace
   racing its own service account, nothing to do with DNS. Re-running
   worked; `--to-namespace=default` avoids it.

**Why the hub never had this.** Its nodes are named by DHCP, with fully
qualified names (`dhcp_fqdn` in setup-bm-host's `default-network.xml.j2`:
`<node>.hub.mylab.com`), which libvirt forwards to the helper's zone. And it
is a multi-node install, so there is no `single-node.conf` dnsmasq in front
of anything. The SNO is the only cluster here whose node name is a bare,
static `sno` - agent-config.yaml's `hostname`.

### Root cause

A node name that resolves nowhere. Nothing in the base needed it before:
the API, the ingress and the console are all reached by `api.` / `*.apps.`
names. The SPIRE agent's attestor is the first client that dials a node by
its own name. Then, once the name did resolve, a cached failure in the
single-node install's own dnsmasq - the first resolver cluster DNS asks on
an SNO - kept the old answer alive.

### Fix, and what the lab does now

- setup-sno publishes the node name as a libvirt DNS host entry
  (`virsh net-update default add dns-host ... --live --config`). On a fresh
  build it runs before the VM exists, so nothing has looked the name up yet
  and there is no stale answer to clear.
- On an SNO that is already running, the same step then sends the node's
  dnsmasq SIGHUP (`oc debug ... --to-namespace=default`, retried), so the
  cached "no such host" goes at once: `setup_sno.yaml --tags snodns`.
- build-lab.sh's `lvm` step runs `--tags snodns,snostorage`, so an older
  lab gets both with `./build-lab.sh --only lvm`.
- Nothing to restart afterwards: spiffe-helper retries every 30s and the
  agent re-attests on each try.

By hand, on the lab host (the SNO is ip_list.sno, .20 here):

```bash
virsh net-update default add dns-host \
  "<host ip='192.168.122.20'><hostname>sno</hostname></host>" --live --config
dig +short @192.168.122.1 sno                                   # 192.168.122.20
oc debug node/sno -q --to-namespace=default -- chroot /host pkill -HUP dnsmasq
inpod client python3 -c "import socket; print(socket.gethostbyname('sno'))"
svid client
```

An alternative for a future rebuild: name the node `sno.sno.mylab.com` in
agent-config.yaml, which the helper's zone already resolves. Not done: it
changes the node name of every SNO, and the entry above is enough.

---

## Case 3 - federation on, and the SpireServer is never `Ready` again

**Date:** 2026-10-03 · **Cluster:** hub · **Phase:** workshop Lab 7a

**Status:** cause read from the operator's source; the lab no longer waits
on `Ready` for the server.

### Symptom

Lab 7a's patch and Route applied, the server rolled, and the bundle endpoint
answered through the lab's Route - but `Ready` never came:

```text
spireserver.operator.openshift.io/cluster patched
route.route.openshift.io/spire-federation created
partitioned roll out complete: 1 new pods have been updated...
error: timed out waiting for the condition on spireservers/cluster
{
    "keys": [
        {
            "use": "x509-svid",
            ...
```

### The trail

Nothing on the cluster was wrong; the question was what `Ready` means. In
the operator (release-1.1 source):

- `pkg/controller/spire-server/routes.go` - with `federation` set and
  `managedRoute: "false"`, `reconcileRoute` records
  `RouteAvailable=False`, reason `FederationRouteDisabled`.
- `pkg/controller/status/status.go`, `SetReadyCondition` - `Ready` is
  False if any other condition is False, except Ready/Degraded/CreateOnlyMode
  themselves and three rollout reasons (`StatefulSetNotReady`,
  `DaemonSetNotReady`, `DeploymentNotReady`). `FederationRouteDisabled` is
  not one of them, so it counts as a failure.

So a server federating through a Route the operator did not make - this
lab's deliberate choice, because the operator's would be
`federation.<trust domain>`, outside the helper's DNS - reports `Ready=False`
for as long as it runs.

### Fix, and what the lab does now

- `tasks/server-ready.yml`: the SpireServer is healthy when every condition
  is True except the roll-ups (Ready, Degraded, CreateOnlyMode) and that one
  `RouteAvailable=False/FederationRouteDisabled`. Used by `spire`, `verify`,
  `demo`, `boutique`, `mesh` and the federation plays in place of
  `oc wait spireserver/cluster --for=condition=Ready` - every one of which
  would have timed out on a federated server.
- The SPIRE agent and CSI driver are still waited on by `Ready`; their
  roll-ups have no such condition.
- The fake `oc` used for simulation now reports these conditions and times
  out `oc wait ... Ready` on a federated server, as the real one does.
- Workshop Lab 7a lists the conditions instead of waiting on `Ready`, and
  says which two False lines are expected.

To check by hand:

```bash
oc get spireserver cluster -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
# everything True, except:
#   RouteAvailable=False FederationRouteDisabled
#   Ready=False Failed
```

Worth raising with the operator's maintainers: a deliberately disabled
managed Route should not fail the roll-up (or `FederationRouteDisabled`
should be reported True / as a non-failure reason).
