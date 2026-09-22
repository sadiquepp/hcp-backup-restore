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
| **A component that is internally consistent but stale** | leaf1's config was self-consistent and correct - built from a `vars.yaml` two commits old, so a whole VLAN was simply absent. | Everything you inspect agrees with everything else you inspect. |
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
the destination is in that address set, which is how OVN-Kubernetes excludes
BGP-advertised destinations from masquerading. Violet's is **unconditional**:
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
