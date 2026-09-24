<!--
  Case files, not a manual. The other docs say how the lab is meant to work;
  this one records what happened when it did not, in enough detail that the
  next person recognises the shape before spending a day on it.

  Convention: one section per non-obvious debug. Symptom first, then what was
  ruled out and by what evidence, then the trail in the order it was walked -
  including the wrong turns, which are the useful part - then the root cause,
  the fix, and what the lab now does so it cannot happen silently again.

  Keep the real command output. A paraphrased symptom is not searchable and
  cannot be compared against what someone is looking at.
-->

# Troubleshooting case files

Long-form records of faults that were hard to find. Deliberately separate from
[README.md](README.md), [udn-bgp-evpn-steps.md](udn-bgp-evpn-steps.md),
[bgp-evpn.md](bgp-evpn.md), [clab-fabric.md](clab-fabric.md) and
[real-fabric.md](real-fabric.md), so those stay about how the lab works.

---

## Read this first — the failure shapes this lab produces

Every case below is an instance of one of these. Knowing them shortens the
next hunt more than any individual command does.

| Shape | What it looks like | Why it wastes time |
| --- | --- | --- |
| **A check that reads instead of asserting** | A phase prints `show bgp summary` and moves on. The build completes with two sessions in Connect. | Nothing fails, so nothing is investigated. The first sign is a user finding an unreachable tenant hours later. |
| **A check scoped to the wrong objects** | A VRF-Lite assert read *every* frr-k8s pod, masters included. Masters have no fabric NIC and sit at `never/Active` by design. | The assert fails on nodes that were never in scope, and the real state is hidden in the noise. |
| **A status field that is a receipt, not a statement** | `Profile.status.conditions[Applied]=True` from the Node Tuning Operator. NTO runs tuned in `no_daemon` mode - it applies once and exits. | `Applied=True` means "this was written at some point", not "this is the value now". Last writer wins permanently. |
| **`ping` succeeding while the thing you care about is broken** | See both cases below. It happened twice in one day for two unrelated reasons. | ICMP takes a different path through NAT, ACLs and MTU than the TCP flow you are actually testing. |
| **A check that reads the global knob when the per-interface one decides** | `conf.all.rp_filter=0` looks fine; `conf.enp8s0.rp_filter=1` is what drops the packet, because the effective value is `max(all, iface)`. | The reassuring value is the one that is easy to read, and it is not the one in force. |
| **A component that is internally consistent but stale** | leaf1's config was self-consistent and correct - built from a `vars.yaml` two commits old, so a whole VLAN was simply absent. | Everything you inspect agrees with everything else you inspect. |
| **A test that asserts a conclusion instead of measuring it** | The `--shared` cross-cluster verdict was reasoned out from one VRF-Lite observation and never run against a shared lab. It contradicted a row in this repo's own README. | The test fails loudly and correctly, and ten cells of real output get read as a lab fault. Hours go into repairing something that was behaving as designed and documented. |
| **One play depending on another play's side effect, while both run in parallel** | `setup-sno` needed `oc`; nothing in it installed `oc`; `setup-hub-cluster` unpacks one into `/usr/bin`. `build-lab.sh` starts both with `play_bg`. | The dependency is invisible - it is not an import, a `when:` or a variable, just a file that usually happens to be there. It passes on every host that has built the lab before, and fails on the first clean one. |
| **State that is wrong with no event left to correct it** | Both cases below. A reconcile ran while a dependency was down, produced the wrong answer, and nothing re-triggered it when the dependency came back. | Retrying the *symptom* never helps. Only forcing the reconcile does. |

### Two rules that came out of this iteration

**`ping` is not a test of anything in this lab.** It passed while TCP was
being black-holed (Case 2), and in a separate incident a `ping` inside the
web pod exited 1 because the `httpd` image has no `ping` binary — which was
briefly read as "no reply". Use `curl`, and read the *distinction* between
`Connection refused` (packets arrive, nothing listening) and
`Connection timed out` (packets do not arrive).

**Capture per-interface before theorising.** `tcpdump -nei any` with the
interface column is what ended a multi-day hunt in about five minutes, by
showing a packet present on one interface and absent on the next one. Every
hypothesis before that capture was wrong.

---

## Case 1 — a BGP session in `Connect` for hours, byte-identical config at both ends

**Date:** 2026-09-22 · **Cluster:** sno · **Phase:** `--tags vrflite`
**Previously seen:** worker3 and sno, cleared by a rebuild, cause never found.
**Fix:** commit `8c49b65`, `roles/setup-udn-bgp/tasks/stale-nexthop.yml`

### Symptom

```
TASK [setup-udn-bgp : Fail with the node whose session to the border leaf never came up]
failed: [localhost] (item=sno)
  "msg": "sno (192.168.140.20) is 'BGP state = Connect' after 180s."
```

leaf1's view:

```
BGP neighbor is 192.168.140.20, remote AS 64515, local AS 64513, external link
  BGP state = Connect
  Last read 00:33:54, Last write never
  Configured tcp-mss is 0, synced tcp-mss is 504
  Message statistics:
                         Sent       Rcvd
    Opens:                  0          0
  Connections established 0; dropped 0
  Last reset 00:33:54,  Waiting for peer OPEN (n/a)
Local host: 192.168.140.1, Local port: 45030
Foreign host: 192.168.140.20, Foreign port: 179
Peer Authentication Enabled
```

Read that carefully before doing anything:

* `Opens: 0` both ways and a local port in the 45000s means **leaf1's TCP
  connection never completed**. This is not a BGP negotiation failure.
* `synced tcp-mss 504` is `536 - 20 (MD5) - 12 (timestamps)`. It confirms the
  MD5 option is armed on leaf1's socket, and that the socket is unconnected
  (an established socket would report the path MSS).
* leaf1 shows only its own outbound attempt. There is **no inbound attempt
  from sno**, which a healthy peer would be making every few seconds. That
  second observation is what eventually cracked it, and it was visible from
  the first output.

### Ruled out, and by what

| Hypothesis | Evidence that killed it |
| --- | --- |
| Fabric NIC has no address / not on the bridge | `docker exec clab-udnbgp-leaf1 ping -c2 192.168.140.20` → 0% loss; `ip neigh` shows `dev eth1 lladdr 52:54:00:e2:55:20` |
| Neighbour not configured on the node | `oc get frrnodestate sno -o jsonpath='{.status.runningConfig}'` shows `neighbor 192.168.140.1 remote-as 64513`, a `password` line, timers, and the address-family activation |
| TCP-MD5 key mismatch | `tcpdump -M '<key>'` on the node prints **`md5 valid`** on the `.140` SYNs. Both ends template from the same `udn_bgp_password` / `udn_bgp_password_secret` |
| Fabric NIC enslaved to a VRF (so the default-VRF socket never sees it) | `ip -d link show enp7s0` has no `master`; `ip route get 192.168.140.1` → `dev enp7s0 src 192.168.140.20` in `main` |
| Stale fabric / wrong topology | violet's session on `192.168.146` was Established on the *same NIC* throughout |

### The trail

**1. Capture on the node.** This is where it turned.

```bash
oc debug node/sno --quiet -- chroot /host timeout 20 tcpdump -ni enp7s0 'tcp port 179'
```

```
IP 192.168.140.1.51596 > 192.168.140.20.bgp: Flags [S], ... options [nop,nop,md5 valid,mss 8960,...]
IP 192.168.146.1.bgp  > 192.168.146.20.51882: Flags [P.], ... options [nop,nop,md5 valid], length 19: BGP
IP 192.168.146.1.bgp  > 192.168.146.20.51882: Flags [.], ack 20, ...
IP 192.168.140.1.47462 > 192.168.140.20.bgp: Flags [S], ... (retransmitting)
```

Two sessions on one NIC. The violet VRF-Lite session on `enp7s0.160` is
**Established and exchanging 19-byte keepalives every 3s, MD5-signed**. The
default-VRF session's SYN arrives repeatedly and is answered by **nothing —
not even an RST**. So the NIC, the bridge, forwarding, and MD5 as a mechanism
are all provably fine.

Note the direction difference: for violet, **sno** is the initiator
(`.20:51882` → leaf1:179). For `.140`, sno emits nothing at all.

**2. Is anything listening?**

```bash
oc debug node/sno --quiet -- chroot /host ss -lntp 'sport = :179'
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
```

Empty. Nothing listens on 179 — while violet's session is Established,
because that one is an *outbound* socket, not a listener.

> **Why no RST.** When Linux has no socket for an incoming segment it
> normally sends an RST. But the SYN carries a TCP-MD5 option, and
> `tcp_v4_send_reset()` refuses to emit an unsigned RST for a signed segment
> with no key available, so it drops silently. Unsigned, this would have
> presented as an RST and been found on day one.

**3. Ask FRR on the node.**

```bash
oc -n openshift-frr-k8s rsh -c frr <pod> vtysh -c 'show bgp summary' -c 'show bgp neighbor 192.168.140.1'
```

```
Neighbor        V    AS  MsgRcvd MsgSent ... Up/Down State/PfxRcd
192.168.140.1   4 64513        0       0 ...   never       Active

  BGP state = Active
  Last reset 00:17:50,  No path to specified Neighbor (n/a)
  BGP Connect Retry Timer in Seconds: 120
  Read thread: off  Write thread: off  FD used: -1
```

`FD used: -1` — there is no socket. `No path to specified Neighbor` — bgpd
asked zebra to resolve the nexthop and zebra said it had none. That explains
both halves at once: no outbound SYN, and no listener to answer the inbound
one.

**4. The contradiction.** The *kernel* has the route. Does zebra?

```bash
oc rsh -c frr <pod> vtysh -c 'show interface enp7s0' \
                        -c 'show ip route 192.168.140.0/24' \
                        -c 'show bgp nexthop'
```

```
Interface enp7s0 is up, line protocol is up
  Link ups:       6    last: 2026/09/22 04:13:22.42
  inet 192.168.140.20/24 noprefixroute

Routing entry for 192.168.140.0/24
  Known via "kernel", distance 0, metric 101, best
  * directly connected, enp7s0, weight 1

Current BGP nexthop cache:
 192.168.140.1 invalid, #paths 0, peer 192.168.140.1
  Must be Connected
```

There it is, in three lines:

* The address carries **`noprefixroute`**, so the kernel never generated a
  connected prefix route; NetworkManager installed `192.168.140.0/24` itself.
* zebra therefore classifies it **`Known via "kernel"`**, not `connected`.
* A single-hop eBGP peer requires its nexthop to resolve over a **connected**
  route — the literal `Must be Connected` line. A kernel route does not
  satisfy it, so the nexthop is `invalid` and the peer never leaves `Active`.

`Link ups: 6` is the trigger. The fabric NIC is hot-plugged
(`sno_fabric_nic: false`) and then addressed by NNCP, so it flaps *after*
frr-k8s has started. zebra loses its connected entry for the interface and
never rebuilds one.

### Root cause

> The fabric NIC flaps after frr-k8s is running. zebra drops its connected
> route for it and does not recreate it, leaving only NetworkManager's
> proto-kernel route. bgpd's nexthop tracking rejects that route for a
> single-hop eBGP peer, holds the peer `Active`, and never opens a socket.
> Nothing re-triggers a netlink resync, so it stays broken indefinitely.

Per-node, non-deterministic, byte-identical config at both ends, cleared by a
rebuild — because a rebuild restarts frr-k8s as a side effect and the real
fault was never observed.

### Fix

```bash
oc -n openshift-frr-k8s delete pod <frr-k8s pod on that node>
# ~9 seconds later, from leaf1:
sno(192.168.140.20)  4  64515  7  8  0  0  0  00:00:09  0  0  sno [sno]
```

### What the lab does now

`roles/setup-udn-bgp/tasks/stale-nexthop.yml`, included by `verify.yml`
between the session wait and the session assert. For each node whose session
is down it reads that node's `show bgp nexthop`; **only** if the leaf's
address comes back `invalid` does it restart frr-k8s, wait for the rollout,
re-run the leaf-side wait and hand the new result to the assert.

Gated on the signature on purpose. A blanket restart-on-failure would
"fix" the symptom of an unrelated fault and hide it — the same mistake this
document is largely a record of.

---

## Case 2 — an advertised UDN whose pods answered nobody

**Date:** 2026-09-22 · **Cluster:** sno · **Tenant:** violet (VRF-Lite)
**Fix:** commit `8f352d7`, `roles/setup-udn-bgp/tasks/snat-exclusion.yml`
**Caused by:** Case 1. Read that first.

### Symptom

```
  hostname                   backend        netns    via Host:          via /path/
  blue.hub.mylab.com         10.200.2.5     blue     I am blue on hub   I am blue on hub
  ...
  violet-sno.hub.mylab.com   10.206.0.5     violet   (no answer)        (no answer)

  BROKEN  violet-sno.hub.mylab.com returned: (no answer)
```

Every other tenant clean. Everything cluster-side green.

### Everything that was green while it was broken

This is the important part of the case. Each of these was checked and was
correct:

* `ClusterUserDefinedNetwork violet` realised, labelled `bgp=enabled`,
  `udn-lab-phase=vrflite`
* `RouteAdvertisements udn-vrflite` → `STATUS: Accepted`, with
  `ovn-kubernetes cluster-manager validated the resource and requested the
  necessary configuration changes`
* `FRRConfiguration` objects present with the right labels, plus the
  OVN-generated `ovnk-generated-jpm4n`
* Every BGP session Established, tenant VRFs bound with real vrf-ids
* leaf1's violet VRF holding the leaks, violet's `10.206.0.0/24 via
  192.168.146.20`, `violet-ext` and `10.227.10.0/24`
* The full VRF-Lite leak matrix **correct in all 24 cells**
* The pod `Running`, `10.206.0.5/24` on `ovn-udn1`
* `ip route get 10.206.0.5 from 10.227.10.21 iif enp7s0.160` → `dev
  ovn-k8s-mp2 table 1128`
* **`ping` from the client netns to the pod: 0% loss**

### Ruled out, and by what

| Hypothesis | Evidence that killed it |
| --- | --- |
| Pod default route on `eth0` instead of the UDN | `ip route` in the pod: `default via 10.206.0.1 dev ovn-udn1`; `network-status` annotation has `"default": true` on `ovn-udn1`. Same shape as blue on the hub |
| MTU / path-MTU black hole | `curl -I` (a ~200-byte response) fails identically to `curl`. Setting the client to MTU 1400 to match the pod changes nothing |
| Size-dependent drop | The *smallest* dropped packet is a zero-length pure ACK — smaller than the SYN-ACK that gets through |
| NetworkPolicy / ACL | A policy drop kills the SYN. The handshake completes |
| The pod or its httpd | The pod ACKs the request, D-SACKs each retransmission, and retransmits its `200 OK` six times. Its TCP stack is flawless |
| Shared br-int with the EVPN tenants | `ovn-nbctl list Logical_Router` shows only 4 routers; violet is the **only** UDN on this node |

### The trail

**1. Capture at the client.** Establishes that this is not a connectivity
problem at all.

```bash
ip netns exec violet timeout 8 tcpdump -ni eth1.260 'host 10.206.0.5' &
sleep 1
ip netns exec violet curl -sS --max-time 5 -I http://10.206.0.5:8080/
```

```
10.227.10.21.42318 > 10.206.0.5.webcache: Flags [S],  ... mss 8960
10.206.0.5.webcache > 10.227.10.21.42318: Flags [S.], ... mss 1360
10.227.10.21.42318 > 10.206.0.5.webcache: Flags [.], ack 1
10.227.10.21.42318 > 10.206.0.5.webcache: Flags [P.], seq 1:81, ... HEAD / HTTP/1.1
10.227.10.21.42318 > 10.206.0.5.webcache: Flags [P.], seq 1:81, ... HEAD / HTTP/1.1   (retransmit)
...
```

Handshake completes. The pod does **not** retransmit its SYN-ACK, which
proves it received the ACK and the connection is Established on both sides.
The request is then retransmitted forever, unacknowledged.

> The 2-second `S` → `S.` → `R.` flows interleaved in this capture are
> **haproxy health checks succeeding**. haproxy closes a check with RST to
> avoid TIME_WAIT. This was misread as the bug for two rounds.

**2. Capture per-interface on the node.** The five minutes that solved it.

```bash
oc debug node/sno --quiet -- chroot /host timeout 20 tcpdump -nei any \
  'host 10.227.10.21 and tcp port 8080'
```

Connection 59174, with the interface column, in order:

```
.320916 enp7s0.160  In   10.227.10.21.59174 > 10.206.0.5.webcache: [S]
.320954 ovn-k8s-mp2 Out  10.227.10.21.59174 > 10.206.0.5.webcache: [S]
.320980 6a700f..._3 Out  10.227.10.21.59174 > 10.206.0.5.webcache: [S]        → pod
.321012 6a700f..._3 P    10.206.0.5.webcache > 10.227.10.21.59174: [S.]
.321056 ovn-k8s-mp2 In   10.206.0.5.webcache > 10.227.10.21.59174: [S.]       ← escapes
.321068 enp7s0.160  Out  10.206.0.5.webcache > 10.227.10.21.59174: [S.]       ← reaches client
.321311 6a700f..._3 Out  10.227.10.21.59174 > 10.206.0.5.webcache: HEAD /     → pod has it
.321342 6a700f..._3 P    10.206.0.5.webcache > 10.227.10.21.59174: . ack 81   ← veth only
.321729 6a700f..._3 P    10.206.0.5.webcache > 10.227.10.21.59174: 200 OK     ← veth only
```

**The SYN-ACK traverses. Every pod→client packet after it dies inside br-int,
before `ovn-k8s-mp2`.**

> The `63.6.x.x > 10.227.10.21: ip-proto-158` lines in the same capture are
> tcpdump mis-parsing the 802.1Q frames on the parent `enp7s0`. Each has the
> identical timestamp to the properly decoded `enp7s0.160` line. Ignore them.

**3. Why the first reply and not the rest.** Dump the datapath flows:

```bash
oc debug node/sno --quiet -- chroot /host \
  ovs-appctl dpctl/dump-flows -m | grep -E '10\.206\.0\.5|10\.227\.10\.21'
```

The pod-egress flow:

```
recirc_id(0x17b61), in_port(6a700fedc3701_3), ct_state(0x2a/0x2f),
ipv4(src=10.206.0.5,dst=10.224.0.0/255.224.0.0,ttl=64), packets:986
actions: ct_clear,
  check_pkt_len(size=1414,
    gt( sample(... controller(reason=1 ...)) ),
    le( ct(zone=96), recirc(0x17b63) ))
```

`ct_state` decodes (OVS bits: `0x01` new, `0x02` est, `0x04` related,
`0x08` reply, `0x10` invalid, `0x20` tracked):

| Packet | ct_state | |
| --- | --- | --- |
| SYN-ACK | `0x29` = tracked + **new** + reply | matches a different flow, escapes |
| everything after | `0x2a` = tracked + **est** + reply | matches the flow above |

That is the whole asymmetry, and it is a conntrack-state split, not a
routing or size one. `packets:986` proves they reach this flow and are passed
on, so the drop is in the recirculation.

`check_pkt_len(size=1414)` is the gateway MTU generating ICMP-too-big. Note
it for the separate MTU defect below; it cannot drop an 84-byte ACK.

**4. Compare the NAT rules against a tenant that works.**

`ovn-nbctl` lives in the `ovnkube-controller` container of an `ovnkube-node`
pod. The NB database is cluster-wide, so on the SNO any pod will do; on the
hub, pick the pod on the node whose gateway router you are naming, because
the router name ends in that node's name.

First find the gateway routers:

```bash
OVN=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node -o name | head -1)
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN \
  ovn-nbctl --bare --columns=name list Logical_Router | grep '^GR_cluster_udn_'
```

```
GR_cluster_udn_violet_sno
```

Then the broken tenant, on the SNO:

```bash
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN \
  ovn-nbctl lr-nat-list GR_cluster_udn_violet_sno
```

```
TYPE   GATEWAY_PORT   MATCH   EXTERNAL_IP     EXTERNAL_PORT   LOGICAL_IP
snat                          169.254.0.13    32768-60999     100.65.0.2
snat                          169.254.0.13    32768-60999     10.206.0.0/16
```

And a working tenant, on the hub:

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
NODE=worker1
OVN_HUB=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node \
            --field-selector spec.nodeName=$NODE -o name | head -1)
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN_HUB \
  ovn-nbctl lr-nat-list GR_cluster_udn_blue_$NODE
```

```
TYPE   GATEWAY_PORT   MATCH               EXTERNAL_IP     EXTERNAL_PORT   LOGICAL_IP
snat                  ip4.dst == $a10426  169.254.0.11    32768-60999     100.65.0.6
snat                  ip4.dst == $a10426  169.254.0.11    32768-60999     10.200.0.0/16
```

To sweep every router and its routes in one go - which is how the four
routers on the SNO were found, and how it became clear violet was the only
UDN on that node - see the loop in the appendix under *What is OVN's logical
topology?*.

**The `MATCH` column.** Blue's SNAT is *conditional* — it applies only when
the destination is in that address set. Dumping the set later (during the
shared-VRF work, Case 4) showed what is actually in it, and it is worth
stating precisely because "excludes advertised destinations" is the wrong
mental model:

```
# ovn-nbctl --format=csv --data=bare --no-headings --columns=name,addresses \
#     list Address_Set
a1042611113178530741,192.168.122.31 192.168.122.32 ... 192.168.140.34 ...
```

Those are **node addresses**, not subnets. So the rule reads *masquerade pod
traffic only when it is headed to a node IP* — which is what an advertised
network wants, because everything else must keep its real pod source for the
fabric to route the reply back. Violet's is **unconditional**:
everything leaving `10.206.0.0/16` through the gateway router is rewritten to
`169.254.0.13`, a link-local masquerade address the fabric has no route back
to.

`ofproto/trace` agrees from the other side:

```
Datapath actions: ct(commit,zone=110,mark=0/0x41,label=...,nat(src)),70
```

`nat(src)` applied to pod→client traffic. (The trace itself did not reproduce
the drop — `--ct-next` put it on the `+new` path, `ct_state=+new-est+trk` in
table 53. It is evidence about SNAT, not about the drop.)

### Root cause

> Case 1 left the default-VRF session dead. OVN-Kubernetes reconciled the
> RouteAdvertisements while the fabric was unreachable and programmed
> violet's SNAT **without** the advertised-destination exclusion. The
> sessions later came back; the SNAT did not. Nothing re-triggers that
> reconcile.
>
> Pod egress was therefore masqueraded to `169.254.0.13`. The reply to the
> SYN is the `ct.new` packet and escapes before the SNAT applies, so the
> handshake completes and the tenant looks alive. Every established packet
> after it is rewritten and lost.

### Why `ping` succeeded the whole time

The SNAT rule carries an **external port range** (`32768-60999`). Port ranges
are a TCP/UDP construct; ICMP has no ports to allocate from that range, so
echo traffic was not matched by the rule and left with its real source
address, `10.206.0.5`.

This is inference from the rule's shape, not something measured — confirming
it would mean deliberately re-breaking the cluster. What is not inference is
the consequence: **ping passed cleanly while every TCP flow was black-holed**,
and it sent this investigation down several wrong paths.

### Fix

```bash
oc -n openshift-ovn-kubernetes rollout restart daemonset/ovnkube-node
oc -n openshift-ovn-kubernetes rollout status daemonset/ovnkube-node --timeout=300s

# re-resolve the pod: the restart gave it a new name
OVN=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node -o name | head -1)
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN \
  ovn-nbctl lr-nat-list GR_cluster_udn_violet_sno
```

```
TYPE   GATEWAY_PORT   MATCH               EXTERNAL_IP     EXTERNAL_PORT   LOGICAL_IP
snat                                      169.254.0.13    32768-60999     100.65.0.2
snat                  ip4.dst == $a10426  169.254.0.13    32768-60999     10.206.0.0/16
```

The `MATCH` appears. `scripts/udn-web-demo.sh --proxy` → `I am violet on sno`,
all six tenants clean.

### What the lab does now

`roles/setup-udn-bgp/tasks/snat-exclusion.yml`, included by `verify.yml`
after the session assert (the exclusion is programmed *from* the
advertisement, so the sessions have to be up first). It reads every SNAT rule
from the NB database in one call:

```bash
ovn-nbctl --format=csv --no-headings --columns=logical_ip,match find NAT type=snat
```

flags any row whose `logical_ip` is an advertised tenant subnet and whose
`match` is empty, restarts `ovnkube-node` when it finds one, re-reads with a
retry until the exclusion appears, and asserts. Signature-gated like Case 1 —
a clean cluster restarts nothing.

The assert's failure message says outright that ping will succeed and every
object will be green, because that is what cost the most time.

> **Confirmed against EVPN**, 2026-09-22. The check asserts the same invariant
> for the `shared`, `vrflite` and `evpn` phases, on the reasoning that
> `advertisements: PodNetwork` means the same thing in each. That was an
> assumption when it was written; a full `./build-lab.sh` under EVPN has since
> run it clean, so OVN-Kubernetes programs the advertised-destination
> exclusion the same way there and the scope does not need narrowing. One
> passing build is evidence for this lab's EVPN configuration, not a proof
> about every one.

---

## Case 3 — the shared phase, unreachable with every layer verified correct

**Date:** 2026-09-23 · **Phase:** `--tags shared` · **Cluster:** hub (and sno)
**Fix:** commit `4140664`, `roles/setup-udn-bgp/tasks/fabric-forwarding.yml`

### Symptom

`udn-web-demo.sh --host` — one client, every pod — six tenants, six timeouts.

```
=== from host/udnnsclient (192.168.122.88), serves blue green orange purple red violet ===
  curl http://10.220.2.4:8080/       -> (no answer)
  ... all six ...
```

ICMP failed too, so not TCP-specific.

### Everything that was verified correct first

This list is the case. Each was checked, each was right:

| Layer | Evidence |
| --- | --- |
| RouteAdvertisements | `udn-shared-vrf` → `Accepted` |
| OVN programmed it | six `ovnk-generated-*`, label `k8s.ovn.org/route-advertisements=udn-shared-vrf` |
| BGP sessions | all four Established, `PfxRcd 5` per hub worker, 1 for the SNO |
| leaf1's FIB | `B>* 10.220.1.0/24 via 192.168.140.34`, `.2.0/24 via .35`, `.3.0/24 via .36` |
| leaf1 filtering | `FROM-CLUSTER` denies only the management prefix |
| clab VM | router active, `10.220.0.0/16 via 192.168.140.1 dev br-fabric`, `ip_forward=1` |
| client route | `10.220.2.4 via 192.168.122.40 dev eth0` |
| node forwarding | `ip_forward=1`, `conf.all.forwarding=1`, `conf.enp8s0.forwarding=1` |
| policy routing | `2000: from all to 10.220.0.0/16 lookup 1023` |
| the route itself | `10.220.2.0/24 dev ovn-k8s-mp1 ... src 10.220.2.2` in table 1023 |
| SNAT exclusion | `snat  ip4.dst == $a10426  169.254.0.11  10.220.0.0/16` — MATCH present |

### The wrong turns

Worth recording, because four of the six rounds were spent here.

1. **A stale checkout.** Two consecutive runs produced byte-identical output,
   including a sentence that had been deleted in the committed file. The lab
   host had not pulled. Comparing the observed output against the committed
   source is what caught it — not re-reading the code.
2. **An exact-prefix query read as an absence.**
   `show ip route 10.220.0.0/16` answered `% Network not in table`, which was
   taken as "nothing was advertised". It is an **exact** lookup, and OVN
   advertises per-node `/24`s. `show ip route 10.220.0.0/16 longer-prefixes`
   showed all three. The diagnostic command asked a different question from
   the one being asked.
3. **The SNAT hypothesis**, from Case 2. Killed by two facts: ping failed too
   (Case 2's signature is ping *working*, because the rule carries a TCP/UDP
   port range), and the `MATCH` column was populated.
4. **Stale VRF-Lite NNCPs.** `ovn-k8s-mp1` really is `master blue`,
   `vrf_slave table 1023` — but `oc get nncp` showed only `fabric-untagged-*`.
   Those VRFs are OVN-Kubernetes' own, created per UDN in every phase. Normal,
   not leftover.

### What actually found it

A capture on the node while pinging:

```bash
oc debug node/worker2 --quiet -- chroot /host timeout 25 tcpdump -nei any \
  'host 192.168.122.88 or host 10.220.2.4'
```

```
enp8s0 In  192.168.122.88 > 10.220.2.4: ICMP echo request, seq 1
enp8s0 In  ... seq 2, 3, 4, 5
```

Arrives on the fabric NIC. Appears on **no other interface**. No `ovn-k8s-mp*`,
no veth, no reply. The packet is rejected before the kernel assigns it an
output device, which rules out everything downstream in one observation.

Then the simulated forwarded packet:

```bash
ip route get 10.220.2.4 from 192.168.122.88 iif enp8s0
RTNETLINK answers: Invalid argument
```

while the plain query succeeded:

```bash
ip route get 10.220.2.4
10.220.2.4 dev ovn-k8s-mp1 table 1023 src 10.220.2.2
```

**Those two are different lookups.** Without `from`/`iif` the kernel does an
output lookup from a locally-chosen source; the forwarded packet does an input
lookup. Only the second one fails, and only the second one is what the packet
does.

### Root cause

```
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.enp8s0.rp_filter  = 1
net.ipv4.conf.default.rp_filter = 1
```

> The fabric NIC is hot-plugged, so it is created after boot and inherits
> `conf.default.rp_filter`, which is 1 on RHCOS. The effective value is
> **`max(all, iface)`**, so `all=0` does not save it — the interface's own 1 is
> in force, and strict reverse-path filtering rejects the packet at input
> because `192.168.122.88` is reachable from this node via `br-ex`, not via the
> interface the packet arrived on.

The asymmetry is deliberate. Phase 2's client is off-segment: the request goes
over the fabric, the reply leaves by the node's default gateway.

### The part I got wrong, which is the real lesson

The first write-up of this case said "nothing set it on the node". That was
false, and it is worth recording because the mistake cost more than the bug.
The lab had all of this already:

| | |
| --- | --- |
| `roles/setup-udn-bgp/defaults/main.yml:79` | `udn_bgp_loose_rp_filter: false` |
| `templates/tuned-forwarding.yaml.j2` | `net.ipv4.conf.all.rp_filter=2` when true |
| `README.md` (two rows of the symptom table) | this exact symptom and this exact fix |
| `roles/setup-clab-fabric/tasks/client-vm.yml` | a warning when the flag is false |

A supported switch, applied durably through Tuned to every worker, surviving a
reboot — and documented twice. It defaulted to false, and this lab never set
it.

Two things hid it. The flag defaults off, so nothing in a normal run mentions
it. And the warning that *would* have said "the nodes are running strict
reverse-path filtering" lives in `client-vm.yml`, which runs only under
`--tags clabclient` — the step the shared build was deliberately routed
*around* when it was changed to reuse the namespace client. Removing the VM
removed the warning about the VM's own precondition.

So the sequence was: a documented precondition, defaulted off, with its only
runtime reminder attached to a component that had just been designed out.

`vars.yaml` now sets `udn_bgp_loose_rp_filter: true`, and the assert names it
as the durable fix rather than pointing only at `sysctl -w`.

### Fix

```bash
sysctl -w net.ipv4.conf.enp8s0.rp_filter=2
```

Ping answered on the next packet.

### What the lab does now

`vars.yaml` sets `udn_bgp_loose_rp_filter: true` — the durable fix, through
Tuned, on every worker.

`fabric-forwarding.yml` additionally writes `conf.all.rp_filter=2` (plus the
interface and default) beside the forwarding pair, so a run does not depend on
when NTO next applies the profile, and reports `rp=` and `rp_all=`.
`verify.yml` asserts the **effective** value, `max(all, iface)`, is not 1 —
and prints the repair's own output line, `write_rc` included, because a failed
write and a reverted one look identical from the value alone. The first
version of that message omitted `write_rc`, which is exactly the instrument
the forwarding check had already learned to carry.

2 rather than 0 on purpose: loose still rejects a source with no route at all,
so a genuine fabric misconfiguration stays visible, and it matches what the
client scripts already use.

### Also found, not the cause

`snat-exclusion.yml` read `udn_subnet` (10.200–10.206) while this phase
advertises `udn_subnet_shared` (10.220–10.225). A shared run compared the
gateway routers against prefixes the phase never advertises, matched nothing,
and reported "Every advertised pod network is exempt from SNAT." Green, having
looked at nothing. Fixed in `b0b4179`; it only surfaced because an unrelated
failure sent someone reading the check.

---

## Case 4 — "cross-cluster curl is broken" when it was the test that was wrong

**Phase:** shared VRF (phase 2), `./build-lab.sh --shared`, step 9/9.
**Verdict:** the lab was correct. The check was not. Fixed in the check.

### The symptom

`scripts/udn-xcluster-curl.sh --shared` came back a perfect diagonal — every
tenant reached its own pod and nothing else:

```
  from \ to       10.220.4.5   10.223.0.10  ...  10.225.0.5
  (holders)       hub/blue     hub/green         sno/violet
  hub/blue        I am blue on hub  (no answer)  (no answer)
  ...
  sno/violet      (no answer)       (no answer)  I am violet on sno

  BROKEN  hub/blue -> 10.225.0.5  expected violet (one default VRF, ACL does
                                  not span clusters), got: (no answer)
  ... 10 cells ...
  FAIL - 10 cell(s) wrong.
```

The same-cluster cross-tenant cells were expected to be silent and were. All
ten **cross-cluster** cells were expected to answer and did not.

### Two wrong hypotheses, and the two commands that killed them

Both came from Case 2, which had just been solved twice by the same
mechanism. That is the trap: the most recent explanation is the one that
comes to mind, not the one the evidence supports.

**Hypothesis 1 — the `advertised-network-subnets` ACL is dropping it.**
Dump what the ACL actually matches on, then what is in the set. Note the
column order: `ovn-nbctl list` prints fields alphabetically, so `addresses`
appears *above* `name`, and a `grep -A` anchored on the name shows the *next*
record's addresses. Use `--columns` and the ambiguity disappears:

```bash
OVN=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node -o name | head -1)

oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN \
  bash -c 'ovn-nbctl list ACL | grep -B4 -A6 advertised-network-subnets'
# match : "(ip4.src == $a10109792604843350142 && ip4.dst == $a10109792604843350142)"
# action: drop

oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN \
  ovn-nbctl --format=csv --data=bare --no-headings --columns=name,addresses \
    list Address_Set | grep '^a10109792604843350142'
# a10109792604843350142,10.220.0.0/16 10.221.0.0/16 10.222.0.0/16 \
#                       10.223.0.0/16 10.224.0.0/16
```

The hub's set holds the **hub's own five prefixes only**. Violet's
`10.225.0.0/16`, which the hub learns over BGP, is not in it — so `ip4.dst ==
$set` is false and the rule cannot fire on a cross-cluster pair. The ACL
reasoning in `scripts/udn-xcluster-curl.sh` was *correct*. It was also moot.

**Hypothesis 2 — the Case 2 SNAT masquerade again.** One command:

```bash
NS=$(oc get ns -l udn-tenant=blue -o jsonpath='{.items[0].metadata.name}')
P=$(oc -n $NS get pods -l app=udn-test -o jsonpath='{.items[0].metadata.name}')
oc -n $NS exec $P -- ping -c2 -W2 10.225.0.5
# 2 packets transmitted, 0 received, 100% packet loss
```

Ping failed too. The SNAT exclusion carries a TCP/UDP **port range**, so it
cannot touch ICMP — the Case 2 signature is *ping works, TCP does not*. Both
failing means a layer-3 blackhole, not NAT. (This is the one time in this
document that `ping` earned its keep, and only as a **negative** control.)

### The measurement that settled it

```bash
NODE=$(oc -n udn-blue get pod $P -o jsonpath='{.spec.nodeName}')
OVN=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node \
        --field-selector spec.nodeName=$NODE -o name | head -1)
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN bash -c '
  for lr in $(ovn-nbctl --format=csv --data=bare --no-headings --columns=name \
                list Logical_Router | grep -i blue); do
    echo "== $lr"; ovn-nbctl lr-route-list $lr; done'
```

```
== GR_cluster_udn_blue_worker1
IPv4 Routes
Route Table <main>:
       169.254.0.0/17     169.254.0.4     dst-ip rtoe-GR_cluster_udn_blue_worker1
        10.220.0.0/16     100.65.0.1      dst-ip
            0.0.0.0/0     192.168.122.1   dst-ip rtoe-GR_cluster_udn_blue_worker1
```

That is the whole table. A pod sending to `10.225.0.5` matches **only the
default**, whose nexthop is `192.168.122.1` — the *management* gateway. The
packet leaves by the management NIC and dies there. Nothing steers pod egress
at the fabric.

And the node-side routes, which look reassuring and are irrelevant:

```bash
oc debug -q node/$NODE -- chroot /host bash -c \
  'echo "== table 1023"; ip route show table 1023 | grep -E "10\.22[0-9]" ;
   echo "== main";      ip route show           | grep -E "10\.22[0-9]"'
```

```
== table 1023
== main
10.225.0.0/24 nhid 125 via 192.168.140.20 dev enp8s0 proto bgp metric 20
...
```

The route to violet **exists** — in `main`, learned over BGP, on the fabric
NIC. The tenant's own table `1023` is empty of it, and the gateway router has
its own table and never consults the host's at all. A `main`-table route is
for host-originated traffic; pod egress never reads it.

### Why this is by design, and where it was already written down

`README.md`, phase 2 row:

> **Phase 2: a UDN pod cannot ping the fabric, nothing on the fabric bridge
> at all** — *Expected in this lab, not a fault.* […] the packet leaves by
> the management NIC instead […] Giving the tenant VRF its own path to the
> fabric is what phase 3 does.

Phase 2 advertises pod subnets *outward* so fabric clients can reach pods.
It does not give pods a path *out* to the fabric. Phase 3 (VRF-Lite) does,
which is exactly why the violet→green curl worked there — and that single
observation is what the broken expectation had been extrapolated from.

### Why the passing tests did not catch it

`udn-web-demo.sh --host` passes in this phase, and that is not a
contradiction. The client sits at `192.168.122.88`, **on the management
segment**: pod→client is a direct ARP off `br-ex`, and client→pod arrives
inbound over BGP. Neither direction exercises pod egress toward the fabric,
which is the only thing that is missing.

A test can pass, be correct, and still say nothing about the property you
are about to assume it covered.

### The fix

In `scripts/udn-xcluster-curl.sh`, the `shared` verdict now expects silence
across the cluster boundary and names the *mechanism* per cell, because the
two kinds of silence are not the same fact:

| Cell | Expected | Mechanism |
| --- | --- | --- |
| same cluster, same tenant | answers | — |
| same cluster, different tenant | silent | the `advertised-network-subnets` ACL |
| other cluster, any tenant | silent | phase 2 gives the tenant no path to the fabric |

A cross-cluster answer is now reported as `UNEXPECTED` with the two things
worth checking (`gatewayConfig.routingViaHost`, leftover phase-3 VRF/VLAN
plumbing) rather than being celebrated as the expected result. Duplicate
`udn_subnet_shared` addresses are now reported directly from the discovered
holders, since with every cross-cluster cell silent no curl can reveal them.

### The rule

**A test's expectation is a claim about the system and needs the same
evidence as any other claim.** This one was derived by analogy from a
different phase, fixture-tested only, and shipped asserting the opposite of
a row in this repo's own README. It was flagged as unproven before the run
and still read as a lab fault for the first several minutes of the hunt.

When a check fails on a path it has never passed on, rank "the check is
wrong" *first*, not last — and grep the repo's own docs for the behaviour
before touching the lab.

---

## Case 5 — the SNO agent ISO failed on a fresh host and nowhere else

**Phase:** clusters (step 4), `./build-lab.sh`, first build on a new c5.metal.
**Verdict:** a race between two plays that run in parallel, exposed by the
host being clean. Fixed in `setup-sno`.

### The symptom

```
TASK [setup-sno : Build the agent ISO] ***
fatal: [localhost]: FAILED! => {"cmd": [".../openshift-install", "--dir",
  ".../sno_install", "agent", "create", "image"], "delta": "0:00:08", "rc": 1,
 "stderr": "...
   level=info msg=Extracting base ISO from release payload
   level=warning msg=Failed to extract base ISO from release payload - check registry configuration
   level=info msg=Downloading base ISO
   level=error msg=failed to write asset (Agent Installer ISO) to disk: cannot generate ISO image due to configuration errors
   level=fatal msg=... exec: \"oc\": executable file not found in $PATH"}
```

And then, from the same shell, seconds later:

```
# oc version
Client Version: 4.22.15
```

`oc` was right there. That is the whole case: **the binary existed by the time
anyone looked, and did not exist at the moment it was needed.**

### The misleading line

`Failed to extract base ISO from release payload - check registry
configuration` is a `warning`, it names the registry, and it arrives four
lines before the actual cause. It sends you to the pull secret, to quay.io
reachability, to `ImageContentSourcePolicy` — none of which is involved.

Read to the `fatal` line. `exec: "oc": executable file not found in $PATH` is
the whole diagnosis, and it is unambiguous: `openshift-install` shells out to
`oc` to pull the base RHCOS ISO out of the release payload.

### Why it had never happened before

Two facts, neither visible from the failing task:

1. **`setup-sno` never installed `oc`.** It downloads `openshift-install`
   into `sno_install_folder` and assumes a client is already on `PATH`.
2. **`setup-hub-cluster` installs one**, into `/usr/bin`, from
   `clients/ocp/latest/`.

And `build-lab.sh` runs them at the same time:

```bash
play_bg hub ../setup_hub_cluster.yaml --skip-tags acm
play_bg sno ../setup_sno.yaml
wait_all
```

So whether the ISO built came down to which background play reached its own
step first. On any host that had built this lab before, `/usr/bin/oc` was
already there from the previous run and the race could not be lost — which is
exactly why it survived every run on the old baremetal and failed on the
first clean cloud instance.

The version printout is the proof, not a guess. The SNO role pins
`4.22.10`; the `oc` on the host reported **4.22.15**, which is what
`clients/ocp/latest/` serves. The client on that box came from the hub play.
It just arrived late.

There is a worse version of this failure that nobody hit: losing the race by
a smaller margin, and exec'ing an `oc` that the hub's `unarchive` is still
in the middle of writing.

### The fix

Not ordering, and not a `when:`. **Remove the dependency**: `setup-sno`
fetches its own version-matched client beside the installer, and the ISO
build gets that directory prepended to `PATH`.

```yaml
- name: Build the agent ISO
  ansible.builtin.command:
    cmd: "{{ sno_install_folder }}/openshift-install --dir {{ sno_install_folder }} agent create image"
  environment:
    PATH: "{{ sno_install_folder }}:{{ ansible_env.PATH }}"
```

`openshift-install` resolves `oc` with `exec.LookPath`, so prepending is
sufficient — and nothing writes to `/usr/bin`, so the hub play keeps sole
ownership of the copy the user's own shell picks up.

### What to take from it

**"It works on the host I always use" is not evidence.** A machine that has
run the automation before carries the residue of every previous run, and that
residue silently satisfies dependencies nobody declared. The workshop plan —
20+ clean hosts — turns every one of those into a first-build failure.

**A parallel step needs its dependencies to be self-contained, or it is not
parallel.** `play_bg` makes ordering unavailable as a fix, which is the right
pressure: it forces the dependency to be removed rather than sequenced.

**When a tool prints a warning and a fatal, the fatal is the diagnosis.** The
warning here described a consequence — extraction failed — in the vocabulary
of the wrong subsystem.

---

## Closed — client segments ran at MTU 9000 against a path carrying ~1400

Found during Case 2, not its cause. Fixed in `a8d6325`.

```
ip netns exec violet ping -c2 -M do -s 1372 10.206.0.5   →  0% loss
ip netns exec violet ping -c2 -M do -s 8972 10.206.0.5   →  100% loss
```

Note what the second one did **not** print: `Frag needed and DF set (mtu = …)`.
`ping -M do` prints that line whenever an ICMP too-big comes back. None did, so
path-MTU discovery was not working on that path and this was a black hole
rather than a clamp.

`eth1.260` was 9000, advertising `mss 8960`; the pod's `ovn-udn1` is 1400; the
datapath carries `check_pkt_len(size=1414)` at the OVN gateway. All six client
segments came from `clab_fabric_mtu: 9000` via
`roles/setup-clab-fabric/templates/udn-tenant-client-routes.sh.j2` and
`udn-netns-client.sh.j2`, so every tenant had it.

**Why no test caught it for months of builds.** TCP is protected by MSS
clamping - each end sends no more than the other advertised, so the pod's
`mss 1360` pinned every flow to a safe size and every web page passed. Only
UDP, and DF-set packets, were affected, and nothing in the lab sent either.

The fix is a separate `clab_client_mtu: 1400` for the VLAN **children** only.
The parent NIC keeps `clab_fabric_mtu`: the fabric carries encapsulated pod
traffic and wants 9000, while a client segment is the last hop to a pod and
must not exceed what the pod can answer with. A child may be smaller than its
parent.

Matched to the pod, the failure becomes local and explicit instead of silent:

```
# ip netns exec blue ping -c2 -M do -s 1373 10.200.3.5
ping: local error: message too long, mtu=1400
```

`scripts/udn-web-demo.sh` now probes it - one DF ping per client, sized to
that client's own interface MTU, which must arrive. It sits after the page
matrix on purpose: the pages pass either way, so the check cannot be folded
into them. Raising it again means raising the cluster MTU first, which is the
OpenShift MTU migration and reboots every node twice, on both clusters.

---

## Appendix — the commands that did the work

Kept together because the value was in the *order*, and because several of
them are hard to reconstruct from memory.

### Is the session a BGP problem or a TCP problem?

```bash
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp neighbor <node addr>'
docker exec clab-udnbgp-leaf1 ping -c2 <node addr>
docker exec clab-udnbgp-leaf1 ip neigh show <node addr>
```

`Opens: 0` + a high local port = TCP never completed. Ping working narrows it
to TCP/179 specifically.

### What the node's own FRR thinks

```bash
POD=$(oc -n openshift-frr-k8s get pods -l component=frr-k8s \
        --field-selector spec.nodeName=<node> -o name | head -1)
oc -n openshift-frr-k8s rsh -c frr $POD vtysh \
  -c 'show bgp summary' \
  -c 'show bgp neighbor <leaf addr>' \
  -c 'show bgp nexthop' \
  -c 'show ip route <fabric subnet>' \
  -c 'show interface <fabric nic>'
```

`FD used: -1` = no socket. `No path to specified Neighbor` +
`invalid ... Must be Connected` + `Known via "kernel"` = Case 1.

### Is the kernel dropping it, and is MD5 to blame?

```bash
oc debug node/<node> --quiet -- chroot /host ss -lntp 'sport = :179'
oc debug node/<node> --quiet -- chroot /host timeout 20 tcpdump -ni <nic> 'tcp port 179'
oc debug node/<node> --quiet -- chroot /host timeout 15 \
  tcpdump -ni <nic> -M '<the udn_bgp_password value>' 'tcp port 179'
```

`-M` prints `md5 valid` / `md5 invalid` per packet and settles the key
question outright — far better than comparing configs. A second, working
session in the same capture is a built-in control.

Empty `ss` + SYN with no RST = no listener *and* a signed segment.

### Where does the packet actually die?

```bash
oc debug node/<node> --quiet -- chroot /host timeout 20 tcpdump -nei any \
  'host <client addr> and tcp port <port>'
```

Read the **interface column**. Present on one interface and absent on the next
tells you the hop. This is the single highest-value command in this document.

### What is OVS doing with it?

```bash
oc debug node/<node> --quiet -- chroot /host \
  ovs-appctl dpctl/dump-flows -m | grep -E '<pod ip>|<client ip>'

oc debug node/<node> --quiet -- chroot /host bash -c '
P=$(ovs-vsctl get Interface <veth> ofport)
ovs-appctl ofproto/trace br-int \
 "in_port=$P,dl_src=<pod mac>,dl_dst=<gw mac>,dl_type=0x0800,nw_src=<pod ip>,\
nw_dst=<client ip>,nw_proto=6,nw_ttl=64,tp_src=8080,tp_dst=<port>,tcp_flags=ack" \
 --ct-next "trk,est,rpl" --ct-next "trk,est,rpl"' 2>&1 | tail -70
```

The veth name comes from the pod's `ovn-udn1@ifNNN` — `NNN` is the host
ifindex.

`ct_state` bits: `0x01` new, `0x02` established, `0x04` related, `0x08` reply,
`0x10` invalid, `0x20` tracked.

### What is OVN's logical topology?

```bash
OVN=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node -o name | head -1)
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN bash -c '
  for r in $(ovn-nbctl --bare --columns=name list Logical_Router); do
    echo "== $r"; ovn-nbctl lr-route-list $r; ovn-nbctl lr-nat-list $r
  done'
```

The NB database is cluster-wide, so one pod is enough. Compare a broken
tenant's gateway router against a working one — the **`MATCH` column** is
where Case 2 was hiding.

### From inside the pod

```bash
P=$(oc -n udn-<tenant> get pod -l app=udn-web -o name | head -1)
oc -n udn-<tenant> rsh $P ip route
oc -n udn-<tenant> rsh $P ip rule
oc -n udn-<tenant> get $P -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
```

The `httpd` image has `curl` and `ip`. It does **not** have `ping` — a
`ping` there exits non-zero because the binary is missing, not because the
packet was lost.
