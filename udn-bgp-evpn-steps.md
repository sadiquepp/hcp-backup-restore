# UDN over BGP, VRF-Lite and EVPN - Steps

Commands only, with the expected output beside each one. Pick a destination in
section 0 and follow the sections it names.

Why each phase is shaped the way it is, and every "following one packet"
walkthrough: **[bgp-evpn.md](bgp-evpn.md)**. What the fabric in section 2
actually builds, and how to build it by hand:
**[clab-fabric.md](clab-fabric.md)**. Design notes, constraints and the
troubleshooting table: **[README.md](README.md#udn-over-bgp-vrf-lite-and-evpn-containerlab-fabric)**.

> **`ClusterUserDefinedNetwork`, never `cudn`.** The short name does not work
> reliably against this API. Every `oc` line below spells it out.

---

## 0. Pick your destination

Three transports, each a complete stopping point. **You do not have to walk
through the earlier ones.** Every phase tag runs the same common prefix -
enable the feature, resolve node names, install NMState, address the fabric
NICs, bring up the base BGP session - and then its own part. `--tags evpn` on a
freshly built cluster does all of it.

| You want | Transport | Sections | Tenant subnets |
| --- | --- | --- | --- |
| **A** - UDNs reachable off-cluster, no isolation | targetVRF unset, one shared VRF | 1, 2, 3, 4, **5** | `udn_subnet_shared` - unique per tenant |
| **B** - tenant isolation on VLANs, no overlay | VRF-Lite, `targetVRF: auto` | 1, 2, 3, 4, **6** | `udn_subnet` - blue and red identical on purpose |
| **C** - tenant isolation over VXLAN | EVPN, nodes as VTEPs | 1, 2, 3, 4, **7** (+ 8 for a second cluster) | `udn_subnet`, same as B |

Then optionally **9** (web pages and the tenant ingress) on any path, and **10**
to tear down.

**The one thing that must be decided before section 2**: the fabric is built in
a different shape for C.

```bash
# paths A and B - single border leaf
--tags fabric

# path C - leaf1 / spine / leaf2 with VXLAN between the VTEPs
--tags fabric -e clab_topology=evpn
```

`clab_topology` defaults to `bgp` and **must be repeated on every fabric
command** once the EVPN fabric is up. Omit it and the run succeeds while
rendering the phase-3 shape; the role now records what it deployed and refuses
a mismatched run, but the flag is still yours to pass.

### Moving between paths later

Going A -> B -> C in sequence is supported and is what the phases were built
for. Two things happen that are worth knowing before you start:

- **A -> B changes every tenant's subnet** (`udn_subnet_shared` to
  `udn_subnet`), so the CUDNs and namespaces are deleted and recreated. Phase
  A's state is not recoverable afterwards. Snapshot it first - section 5.4.
- **B -> C removes the VRF-Lite VLAN plumbing.** Under EVPN the tenant routes
  travel as type-5 routes over VXLAN; leaving the VLAN handoff in place would
  give every tenant two paths to the same destinations with nothing choosing
  between them. `--tags evpn` removes it for you.

---

## 1. Prerequisites

All paths. Run on the **lab host**.

```bash
# a hub cluster that is already up, and its kubeconfig
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
oc get nodes                              # all Ready

# the RHEL9 image the clab VM and the client VMs are copied from
ls /var/lib/libvirt/images/rhel-9.8-x86_64-kvm.qcow2
```

OpenShift **4.22+** for path C (nodes as VTEPs). Paths A and B work on 4.21.
Section 3 reports the version and refuses nothing - read it before committing
to C.

Nothing in `vars.yaml` needs editing for the defaults. The knobs that matter:

| Variable | Default | What it decides |
| --- | --- | --- |
| `clab_deploy_mode` | `vm` | `host` runs containerlab on the lab host instead of in a VM |
| `clab_fabric_clusters` | `[hub, sno]` | which clusters get fabric NICs and a leaf1 peering |
| `clab_clusters.<name>.asn` | hub 64512, sno 64515 | **must differ per cluster** - see section 8 |
| `udn_bgp_tenants` | blue red orange green purple | the tenants, their subnets, VLANs and VNIs |

---

## 2. The fabric

**Lab host.** No cluster changes at all - this builds `virbr1`, the containerlab
VM, the routers, and adds one NIC to each node.

```bash
# paths A and B
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags fabric

# path C
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags fabric -e clab_topology=evpn
```

### Test

Run on the **clab VM** (`192.168.122.40`), or on the lab host with
`-e clab_deploy_mode=host`.

```bash
ssh root@192.168.122.40 'docker ps --format "{{.Names}}"'
```

```
# paths A and B - one leaf plus one endpoint per tenant
clab-udnbgp-leaf1
clab-udnbgp-blue-ext
clab-udnbgp-red-ext
clab-udnbgp-orange-ext
clab-udnbgp-green-ext
clab-udnbgp-purple-ext

# path C adds two
clab-udnbgp-spine
clab-udnbgp-leaf2
```

The node NICs, from the cluster:

```bash
oc get nncp
# NAME                     STATUS
# fabric-untagged-worker1  Available
# fabric-untagged-worker2  Available
# fabric-untagged-worker3  Available
```

**`Available` is the only acceptable value.** `Degraded` means the NNCE failed,
and a failed enactment **never retries on its own** - nmstate re-enacts on
`metadata.generation`, so re-applying an identical policy changes nothing.
Delete the policy and re-run; the role does this for you now.

```bash
oc get nnce           # <node>.fabric-untagged-<node>  Available
```

---

## 3. Pre-flight

Changes nothing. Run it anywhere with a kubeconfig.

```bash
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags preflight
```

Reports the cluster version, whether FRR-K8s and NMState are present, the
gateway mode, and whether a previous phase is already in place. Read the
version line before choosing path C.

---

## 4. Phase 1: advertise the default pod network

**Optional, and worth the four minutes.** No UDN is involved, so if this does
not work, UDN is not the reason - which removes an entire class of explanation
from whichever path you take next.

```bash
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags default
```

Skip it on a cluster where `clab_clusters.<name>.advertise_default` is `false`
(the SNO), whose default pod network deliberately stays off the fabric.

### Test

```bash
oc get routeadvertisements -o wide
# NAME                 STATUS
# default-podnetwork   Accepted
```

**`Accepted` is not working.** A RouteAdvertisements is accepted long before it
takes effect. The object OVN-Kubernetes *generated* from it carries the actual
prefixes:

```bash
oc get frrconfiguration -n openshift-frr-k8s
# expect a route-advertisements-* object alongside the one the role applied
```

The leaf's view - one prefix per node, each with that node's fabric address as
next hop:

```bash
ssh root@192.168.122.40 \
  'docker exec clab-udnbgp-leaf1 vtysh -c "show bgp ipv4 unicast"'
# 10.128.0.0/23  via 192.168.140.34
# 10.129.0.0/23  via 192.168.140.35
# 10.130.0.0/23  via 192.168.140.36
```

And the thing this lab is careful **not** to have changed:

```bash
oc debug node/worker1 -- chroot /host ip route show default
# default via 192.168.122.1 dev br-ex
```

---

## 5. Path A: shared VRF

Primary UDNs advertised into the default VRF. Adds UDN; still no VLANs, no
VRFs, no NMState policies beyond the fabric NIC.

```bash
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags shared
```

Tenant subnets here are `udn_subnet_shared` - `10.220.0.0/16` blue,
`10.221.0.0/16` red, `10.222.0.0/16` orange, `10.223.0.0/16` green. Unique per
tenant, because one shared VRF holds one route to each.

### 5.1 Test: the objects took effect

```bash
oc get clusteruserdefinednetwork
# blue red orange green purple

oc get pods -n udn-blue -l app=udn-test -o wide     # one per node, Running
oc get routeadvertisements -o wide                  # udn-shared Accepted
```

Pod addresses come from the UDN, not the cluster network:

```bash
oc -n udn-blue exec <pod> -- ip -br addr show eth0
# eth0  UP  10.220.0.3/24
```

### 5.2 Test: reachability, both directions

This needs the external client VM (`--tags clabclient`, section 9.1).

```bash
scripts/udn-reachability.sh --both
```

Expect every cell `ok`, in both matrices (this capture predates `purple`;
a current run has five rows):

```
pod -> 192.168.122.47
tenant   worker3   worker1   worker2
blue     ok        ok        ok
green    ok        ok        ok
orange   ok        ok        ok
red      ok        ok        ok
```

The matrix shape is the diagnosis. A failed **row** is one tenant on every node
- that network's config. A failed **column** is every tenant on one node - that
node's NIC, forwarding or `rp_filter`. A single cell is the pod.

`--both` matters specifically here, because inbound is decided by leaf1 from
BGP and outbound by the node from its own table. They can disagree, and the
script says so rather than leaving two matrices to diff by eye:

```
ASYMMETRIC  red/worker1: pod->client ok, client->pod FAIL
```

### 5.3 Test: egress is not SNATed

This is the proof, not the ping. The leaf must see the **pod's** address:

```bash
# on the lab host
ssh root@192.168.122.40 'docker exec clab-udnbgp-leaf1 tcpdump -ni any icmp' &
oc -n udn-blue exec <pod> -- ping -c3 10.210.10.10
# IP 10.220.0.3 > 10.210.10.10: ICMP echo request
#    ^^^^^^^^^^ the pod, not the node
```

### 5.4 Snapshot before moving on

`--tags vrflite` deletes the namespaces and CUDNs and changes every tenant's
subnet. Phase A's state is not recoverable afterwards, and the A-to-B
difference is most of what this lab exists to show.

```bash
scripts/udn-snapshot.sh phaseA
```

**Stop here for path A.** Section 9 adds web pages; section 10 tears down.

---

## 6. Path B: VRF-Lite

Per-tenant VRFs and VLANs, `targetVRF: auto`.

```bash
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags vrflite
```

Tenant subnets switch to `udn_subnet`, and **two pairs now overlap on
purpose**: blue and red both carry `10.200.0.0/16`, green and purple both carry
`10.204.0.0/16`. orange (`10.202.0.0/16`) overlaps with nothing and is the
control - blue-cannot-reach-red could in principle be about the shared subnet
rather than the VRF, blue-cannot-reach-orange cannot be about anything else.

The role reads each node's live VRF layout before templating the NMState policy,
because a VRF's port list is declarative: a policy naming only the VLAN would
**remove `ovn-k8s-mpN` and take the tenant's pods off the network**. Never
hand-write one of these from an example - render it.

### 6.1 Test: the isolation matrix

```bash
scripts/udn-vrf-isolation.sh
```

Expect `ok` on the diagonal and `FAIL` everywhere else, in **both**
directions (capture predates `purple`; a current run has five rows):

```
pod tenant   blue       red        orange     green
blue         ok         FAIL       FAIL       FAIL
red          FAIL       ok         FAIL       FAIL
orange       FAIL       FAIL       ok         FAIL
green        FAIL       FAIL       FAIL       ok
```

Reading it:

| What you see | What it means |
| --- | --- |
| Diagonal `ok`, rest `FAIL` | Correct. This is the result. |
| Everything `ok` | **Not success.** `targetVRF` never took effect - you are still looking at path A. |
| A whole row `FAIL` including the diagonal | That tenant's handoff is broken, not its isolation. |
| Everything `FAIL` | A broken phase, not isolation. |

Add `--pods` for the pod-to-pod matrix as well.

### 6.2 Test: by hand, one cell at a time

```bash
# each tenant reaches its own - all must SUCCEED
oc -n udn-blue   exec <pod> -- ping -c3 10.210.10.10
oc -n udn-red    exec <pod> -- ping -c3 10.211.10.10
oc -n udn-orange exec <pod> -- ping -c3 10.212.10.10

# and reaches no one else's - all must TIME OUT
oc -n udn-blue   exec <pod> -- ping -c3 -W2 10.211.10.10
oc -n udn-blue   exec <pod> -- ping -c3 -W2 10.212.10.10
oc -n udn-orange exec <pod> -- ping -c3 -W2 10.210.10.10
```

### 6.3 Test: the routing tables that produce it

```bash
oc debug node/worker1 -- chroot /host ip route show vrf blue
ssh root@192.168.122.40 \
  'docker exec clab-udnbgp-leaf1 vtysh -c "show ip route vrf blue"'

# routes learned over BGP, not statically pointed anywhere
oc debug node/worker1 -- chroot /host ip route show proto bgp
```

```bash
scripts/udn-snapshot.sh phaseB
```

**Stop here for path B.** Section 9 adds web pages and the tenant ingress -
which is where the overlapping `10.200.0.0/16` gets interesting.

---

## 7. Path C: EVPN

Nodes as VTEPs. Needs OpenShift 4.22+ and the EVPN fabric from section 2.

```bash
# the fabric, if section 2 was run without it
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags fabric -e clab_topology=evpn

# the cluster half
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags evpn -e udn_bgp_cluster=hub
```

Each node becomes a tunnel endpoint at `100.64.0.<its usual octet>`, assigned by
NMState because the fabric is three FRR containers with no IGP - something has
to give leaf1 a route to each VTEP. The CUDN carries `transport: EVPN` with an
`ipVRF` VNI for the Layer3 tenants and a `macVRF` VNI for the Layer2 ones, and
the node peers `l2vpn evpn` with leaf1 over the fabric link it already uses - a
second address family on an existing session, not a new adjacency.

### 7.1 Test: underlay first

In this order. EVPN is routinely healthy at the control plane and dead at the
data plane - sessions up, type-5 routes on both sides, and no tunnel, because
neither VTEP can reach the other.

```bash
ssh root@192.168.122.40 'docker exec clab-udnbgp-leaf1 vtysh \
  -c "show ip route 100.64.0.0/24 longer-prefixes" \
  -c "show bgp l2vpn evpn summary" \
  -c "show bgp l2vpn evpn"'
```

```
# one /32 per node, then one session per node, all Established:
Neighbor        V   AS    MsgRcvd  MsgSent  Up/Down  State/PfxRcd
192.168.140.34  4   64512     412      408  00:20:11    6
192.168.140.35  4   64512     410      407  00:20:09    6
192.168.140.36  4   64512     411      408  00:20:10    6
```

VTEP addresses as the cluster sees them:

```bash
oc get nodes -o custom-columns=\
NODE:.metadata.name,VTEP:.metadata.annotations.k8s\\.ovn\\.org/node-vtep-ips
```

Empty for a node means OVN-Kubernetes found no address inside `100.64.0.0/24`
on it. The annotation key varies by release - if the column is empty for
*every* node, read `oc get node <node> -o yaml | grep -i vtep` rather than
trusting it.

### 7.2 Test: isolation still holds

Same matrix as path B, same expected shape - the transport changed, the result
did not:

```bash
scripts/udn-vrf-isolation.sh --pods
```

### 7.3 Test: routed vs bridged, the TTL tells you which

The two tenant kinds take genuinely different paths, and one field distinguishes
them:

```bash
# Layer3 / ipVRF - routed into the L3VNI at the node, out of it at leaf2
oc -n udn-blue exec <pod> -- ping -c3 10.210.10.10
# ttl=62   two routing hops

# Layer2 / macVRF - bridged across the L2VNI, no gateway in the path
oc -n udn-green exec <pod> -- ping -c3 10.204.255.10
# ttl=64   unchanged
```

`ttl=63` on the Layer2 case would mean something routed it, and the macVRF is
not doing what it is for. Full walkthroughs of both:
[bgp-evpn.md](bgp-evpn.md#following-one-packet-in-phase-4-routed).

**Stop here for path C on one cluster.** Section 8 stretches it across two.

---

## 8. Path C, second cluster

A second cluster on the same fabric, sharing the Layer2 tenants' broadcast
domain over L2VNI 400. This lab uses a single-node cluster (`setup_sno.yaml`).

### 8.1 The rule that is not optional

**Every cluster needs its own ASN.** hub is 64512, sno is 64515. Share one and
leaf1 re-advertises one cluster's EVPN routes to the other, which drops them
all as an AS_PATH loop - and the failure is silent: healthy sessions, correct
routes on leaf1, an empty table on the far side, nothing logged anywhere.

**And its own slice of any stretched Layer2 subnet.** There is no cross-cluster
IPAM. Both clusters allocate from `10.204.0.0/16` knowing nothing about each
other, so both hand out the low addresses and two pods land on one address.
`evpn_l2_excludes` carves it: hub takes `10.204.0.0/17`, sno the high half.

> The SNO's reservation is a list of 15 CIDRs, not one prefix, and the shape is
> load-bearing. **Too small and the node dies**: `.1` is the Layer2 switch
> gateway and `.2` the node's management port, and reserving either gives
> `F failed to run ovnkube` -> ovnkube-node CrashLoopBackOff -> **all** pod
> networking on that node, not just this UDN. **Too big and the split does
> nothing**: IPAM hands out the lowest free address, so a 16-wide hole put the
> pods back at `10.204.0.3`. The hole is exactly what ovn-kubernetes needs and
> not one address more. It is sized for a **single-node** cluster and needs
> widening by one address per extra node.

### 8.2 Build

```bash
# once, on the lab host - NICs for every cluster's nodes, and a leaf1 that
# knows all of them. Both clusters must be in clab_fabric_clusters.
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags nodenics,clabdeploy -e clab_topology=evpn

# then once per cluster, anywhere with the right kubeconfig
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags evpn -e clab_topology=evpn -e udn_bgp_cluster=hub
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags evpn -e clab_topology=evpn -e udn_bgp_cluster=sno
```

`-e udn_bgp_cluster=<name>` picks the kubeconfig from
`clab_clusters.<name>.install_folder`. Without it the run targets `hub` - so a
SNO run would silently reconfigure the hub and look like it worked. The play
fails early if the selected kubeconfig is not there.

### 8.3 Test: both clusters are on the fabric

```bash
ssh root@192.168.122.40 \
  'docker exec clab-udnbgp-leaf1 vtysh -c "show bgp l2vpn evpn summary"'
# four sessions: three hub workers in AS 64512, the SNO in AS 64515
```

```bash
ssh root@192.168.122.40 \
  'docker exec clab-udnbgp-leaf2 vtysh -c "show evpn mac vni 400"'
# both clusters' pod MACs, each behind its OWN VTEP:
#   100.64.0.36   hub
#   100.64.0.20   sno
```

### 8.4 Test: pod to pod, across clusters

The one that asks the question from **inside** the clusters - a pod in one
curling a pod in the other, with nothing in the path belonging to either
cluster's host networking.

```bash
scripts/udn-xcluster-curl.sh \
    /var/lib/libvirt/images/hub_install/auth/kubeconfig \
    /var/lib/libvirt/images/sno_install/auth/kubeconfig
```

Measured on this lab:

```
  from \ to       10.200.1.5          10.204.0.9          10.202.4.5          10.204.0.10         10.200.3.6          10.204.128.2
  (holders)       hub/blue            hub/green           hub/orange          hub/purple          hub/red             sno/green,sno/purple
  hub/blue        I am blue on hub    (no answer)         (no answer)         (no answer)         (no answer)         (no answer)
  hub/green       (no answer)         I am green on hub   (no answer)         (no answer)         (no answer)         I am green on sno
  hub/orange      (no answer)         (no answer)         I am orange on hub  (no answer)         (no answer)         (no answer)
  hub/purple      (no answer)         (no answer)         (no answer)         I am purple on hub  (no answer)         I am purple on sno
  hub/red         (no answer)         (no answer)         (no answer)         (no answer)         I am red on hub     (no answer)
  sno/green       (no answer)         I am green on hub   (no answer)         (no answer)         (no answer)         I am green on sno
  sno/purple      (no answer)         (no answer)         (no answer)         I am purple on hub  (no answer)         I am purple on sno

  clean: every tenant reached its own pods in BOTH clusters,
         and nothing reached a tenant it does not belong to.

  4 of those answers crossed a cluster boundary.
```

It curls rather than pings for a specific reason. Two tenants on a stretched
Layer2 network can hold the **same address** - the SNO's green and purple pods
are both `10.204.128.2` - and `udn-vrf-isolation.sh` has to mark those cells
`AMBIG`, because ICMP cannot say which of the two answered. A page names its own
tenant and its own cluster, so the cell that is unresolvable by ping is the most
informative one here. **The 4 crossings and that shared-address column are the
result**; a clean diagonal on its own would also be produced by two clusters
that never reached each other at all.

Cross-check that it really is bridged:

```bash
oc --kubeconfig=<sno> -n udn-green exec <pod> -- ping -c3 10.204.0.9
# 0% loss, ttl=64 - no gateway, no route, no NAT anywhere in the path
```

### 8.5 What this does *not* give you

Measured, and worth stating because the lab looks like it works:

- **The infrastructure addresses collide and cannot be split.** Both clusters
  put their Layer2 gateway on `10.204.0.1` and a management port on `10.204.0.2`.
  ovn-kubernetes derives the MAC from the IP, so that is the *same MAC*
  advertised from two VTEPs, and leaf2 holds only one of them. Pod-to-pod is
  unaffected - it never touches the gateway - but anything a pod sends **off**
  its own subnet goes to whichever router answered the ARP. This is the real
  limit on the design, not the IPAM.
- **A routed tenant cannot simply be copied into a second cluster.** A tenant's
  identity in the fabric is its route target. Build Layer3 `blue` in both and
  each originates `10.200.0.0/16` into RT `65000:101`, so leaf2 imports two
  equally good paths to one prefix at two different VTEPs. A genuinely
  cross-cluster routed tenant needs its own subnet, VNI and route target - not a
  second copy. `clab_clusters.sno.tenants` limits the SNO to green and purple
  for exactly this reason.
- **The `advertised-network-subnets` ACL does not block cross-cluster traffic**,
  and could not. It matches source and destination against the advertised-subnet
  set on **addresses alone**, so a hub pod sending to `10.204.128.5` is
  indistinguishable from one sending to `10.204.0.5`.

---

## 9. Clients, web pages and the tenant ingress

Optional on any path. All of these are **lab host** commands, and all of them
need `-e clab_topology=evpn` on path C.

### 9.1 The clients

```bash
# one external client VM, for the section 5.2 reachability matrix
... --tags clabclient

# one client VM per isolation domain (paths B and C)
... --tags clabtenantclients

# or one VM holding one namespace per tenant - same test, a fifth of the RAM
... --tags clabnsclient
```

`clabnsclient` is built *alongside* `clabtenantclients`, not instead of it: the
namespaces take `.21` on each client segment and the VMs take `.20`.

### 9.2 Web pages

A web server per tenant, so the answer identifies the responder where a ping
cannot. Additive and independent of transport.

```bash
... --tags web -e udn_bgp_cluster=hub
... --tags web -e udn_bgp_cluster=sno       # second cluster, if section 8
```

```bash
scripts/udn-web-demo.sh --netns
# a clean diagonal: each tenant's client reaches that tenant's pod and no other
```

### 9.3 The tenant ingress

One hostname per tenant, **all resolving to one address**, with haproxy choosing
the namespace from the `Host` header. This answers the question the overlapping
subnets provoke: how does an end user reach a tenant whose pod address another
tenant also holds?

```bash
... --tags clabnsproxy -e clab_topology=evpn

# DNS for the names - a SEPARATE playbook, on the helper
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns --ask-vault-pass
```

> **Re-run `--tags clabnsproxy` after every `--tags web`.** It proxies to pod
> addresses, and those change.
>
> **Do not skip the DNS step.** The demo sends `Host:` headers, so it passes
> without it - which is how the gap went unnoticed once already.

```bash
scripts/udn-web-demo.sh --proxy
```

Seven hostnames on one address, each returning a different page:

```
green.hub.mylab.com        I am green on hub
purple.hub.mylab.com       I am purple on hub
blue.hub.mylab.com         I am blue on hub
red.hub.mylab.com          I am red on hub
orange.hub.mylab.com       I am orange on hub
green-sno.hub.mylab.com    I am green on sno
purple-sno.hub.mylab.com   I am purple on sno
```

A `200` from the **wrong** tenant is this design's characteristic failure, and a
health check cannot see it. That is what the script checks and why the page
names itself.

---

## 10. Teardown

```bash
# the UDN lab only - clab VM, client VMs, fabric network, rendered manifests
ansible-playbook -i inventory/hosts cleanup.yaml --tags udnlab

# the SNO as well
ansible-playbook -i inventory/hosts cleanup.yaml --tags sno

# everything
ansible-playbook -i inventory/hosts cleanup.yaml
```

The cluster-side objects are **not** removed by that - it destroys VMs. To
return a cluster that is staying:

```bash
oc delete routeadvertisements --all
oc delete frrconfiguration -n openshift-frr-k8s \
  fabric-peering-default fabric-peering-vrflite fabric-peering-evpn --ignore-not-found
oc delete vtep evpn-vtep --ignore-not-found
oc delete namespace udn-blue udn-red udn-orange udn-green udn-purple --ignore-not-found
oc delete clusteruserdefinednetwork blue red orange green purple --ignore-not-found
oc delete nncp --all

oc patch network.operator.openshift.io cluster --type=merge -p '{
  "spec": {
    "additionalRoutingCapabilities": null,
    "defaultNetwork": {
      "ovnKubernetesConfig": {
        "routeAdvertisements": "Disabled",
        "gatewayConfig": { "routingViaHost": false }
      }
    }
  }
}'
```

Deleting the NNCPs does **not** unconfigure the interfaces they created -
nmstate leaves the last applied state in place. Write a policy with
`state: absent` if you want them gone. The final patch is another full
`ovnkube-node` rollout.

---

## Things that report success while doing nothing

Every one of these cost real time in this lab. They share a shape: the exit
status is zero and the artifact is wrong, so **check the rendered object, not
the return code**.

| Symptom | Cause |
| --- | --- |
| `--tags nodenics` ran, `changed=0 skipped=0`, nothing happened | `include_tasks` does not pass tags to included tasks without `apply:` |
| NNCP stuck `Failing` for 39 minutes after the cause was fixed | nmstate re-enacts on `metadata.generation` only; `oc apply` of an identical policy changes nothing |
| Manifest has `excludeSubnets`, live object does not | Wrong field name for `layer2` - it is `reservedSubnets` - and CRD pruning drops unknown fields **silently**. `oc apply` says `configured` |
| `NetworkAllocationSucceeded: True` while pods will not start | It covers cluster-level allocation and says nothing about the per-node switch |
| A shell probe always returns empty | `cmd: >-` folds lines with spaces and breaks any multi-line script. Use `cmd: \|` |
| Client namespaces get phase-3 addressing on an EVPN fabric | `clab_topology` defaults to `bgp` and must be passed on every fabric command |
| A hot-plugged fabric NIC has forwarding off | `net.ipv4.ip_forward` reaches interfaces existing at that moment and does not set `conf.default.forwarding` |
| `-e cluster=sno` | No such variable. It is `-e udn_bgp_cluster=sno` |

Full troubleshooting table:
[README.md](README.md#udn-over-bgp-vrf-lite-and-evpn-containerlab-fabric).
