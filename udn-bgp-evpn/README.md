<!--
  Moved out of the repository README so the whole UDN/BGP/EVPN lab lives in
  one directory. Everything in here is run from udn-bgp-evpn/, which is why
  the shared inventory and the other playbooks are reached as ../.
-->

# UDN over BGP, VRF-Lite and EVPN (containerlab fabric)

Built by `setup_udn_bgp_lab.yaml` (roles `setup-clab-fabric` and
`setup-udn-bgp`). Entirely additive: nothing in the hub, hosted-cluster, OADP
or Ceph flows reads any of it, and none of those flows change whether or not
you ever run it.

**[quick-build.md](quick-build.md)** is the short version: the three
`build-lab.sh` phases side by side - what each one builds, what it proves,
what it cannot do, and the prerequisites for each. It also covers the
optional prebuilt lab image (`build-lab-image.yaml`), which pre-installs
every package the lab's guests need so a build does not register four VMs
with subscription-manager and run four rounds of dnf.

**[clab-fabric.md](clab-fabric.md)** is the fabric side: what `virbr1`, the
containerlab VM and the FRR containers actually are, what each phase uses, and
how to build the whole fabric by hand.

**[udn-bgp-evpn-steps.md](udn-bgp-evpn-steps.md)** is the one to follow if you
just want to build it: pick shared VRF, VRF-Lite or EVPN up front, and it names
the sections for that path with the test and expected output after each one.

**[real-fabric.md](real-fabric.md)** is for the other case: no containerlab at
all, a real fabric the network team has already configured for the tenants.
The cluster-side objects on their own, with the lab scaffolding removed and
the places a real fabric legitimately differs - how the underlay reaches
each node's VTEP above all - called out.

**[troubleshooting.md](troubleshooting.md)** is the case files: long-form
records of faults that were hard to find, with the real command output, what
was ruled out and by what evidence, and the wrong turns. Kept apart from the
other docs deliberately so they stay about how the lab works. Read its
opening table before starting any hunt - every case in it is an instance of
one of six recurring shapes.

**[bgp-evpn.md](bgp-evpn.md)** takes `setup-udn-bgp` apart into the `oc`
commands it runs, phase by phase, with every manifest shown filled in rather
than as a template. Read that to understand the mechanism, to debug a phase
that failed, or to reproduce this on a cluster the repo does not manage - each
section names the `--tags` that automate it.

### Can this be simulated on this lab? Yes - here is the honest shape of it

Yes, on the bare-metal host, using containerlab as the provider network. The
OpenShift nodes are already KVM guests on a libvirt bridge, and containerlab
attaches container interfaces to an existing Linux bridge as a first-class
feature (its `bridge` kind). Put both on the same bridge and an FRR container
is layer-2 adjacent to an OpenShift node. From there it is ordinary BGP -
there is nothing to fake.

What is and is not testable on this lab, stated up front:

| Phase | Testable here | Needs |
| --- | --- | --- |
| BGP, default pod network | Yes | 4.19+ |
| BGP + primary UDN, shared VRF | Yes | 4.19+ |
| BGP + UDN with **VRF-Lite** | Yes | 4.19+, **local gateway mode** |
| **EVPN**, cluster nodes as VTEPs | Yes | **4.22**, local gateway mode |
| **EVPN** fabric with VRF-Lite handoff at the border leaf | Yes | works on 4.21 too |

EVPN for primary cluster user-defined networks is GA in OpenShift 4.22, and
`vars.yaml` sets `ocp_major_version: "4.22"` so the full path - nodes as
VTEPs, VXLAN between them, type-5 routes carrying a per-tenant VNI - is
available. The border-leaf handoff variant is still described
[below](#evpn-two-ways) because it is a legitimate production design and the
only option on 4.21.

### The one idea to drop first: you do not move a UDN's default gateway

The natural mental model - "point each UDN's default gateway at the
containerlab router" - is worth discarding early, because there is no setting
that does it and designing around it leads somewhere unpleasant.

A pod on a primary UDN always has the OVN gateway router **on its own node**
as its default gateway. That is structural: OVN-Kubernetes owns the pod's
first hop, and it is how the UDN's isolation, its per-node subnet allocation
and its east/west path all work. Nothing external can take that over.

What BGP actually changes is one layer further out - the **node's** routing
table and the **absence of SNAT**:

- The cluster advertises pod and UDN subnets to the fabric
  (`RouteAdvertisements`), so the fabric has a route back to real pod
  addresses.
- The fabric advertises its prefixes to the cluster, and FRR-K8s installs
  them in the node's kernel routing table, so the node knows to send that
  traffic out the fabric NIC.
- Because the fabric can now route back to the pod, pod egress to those
  prefixes **stops being SNATed to the node IP**. Packets arrive at the
  router with the real pod IP as the source. That is the single most
  legible proof the whole thing is working.

The pod's gateway never moves. Which is exactly why this is safe to run
against a cluster that is already doing other work: no node's default route
changes, and the only prefixes that go out the fabric are ones a BGP peer
explicitly advertised.

### Topology

```
  virbr0  192.168.122.0/24  NAT       <-- the existing lab, untouched
    helper .21   hub masters .31-.33   hub workers .34-.36
    hosted-cluster workers, MetalLB VIPs, mirror registry, MinIO, Ceph ...
    clab VM .40  (management/ssh only)

  virbr1  no address on the host, MTU 9000, no NAT, no DHCP, no DNS
    |                                    <-- NEW. Pure L2, the "provider network"
    +-- hub_worker1 second NIC   192.168.140.34   (+ VLAN 110 .141.34, VLAN 120 .142.34)
    +-- hub_worker2 second NIC   192.168.140.35   (+ VLANs)
    +-- hub_worker3 second NIC   192.168.140.36   (+ VLANs)
    +-- clab VM second NIC -> in-guest bridge br-fabric
          |
          +-- containerlab: leaf1 (FRR)  192.168.140.1
                            + VRF blue on VLAN 110  192.168.141.1
                            + VRF red  on VLAN 120  192.168.142.1
                            blue-ext 10.210.10.10   red-ext 10.211.10.10
```

Every fabric address ends in the octet the node already owns on virbr0 -
worker1 is `.34` on `192.168.140`, `192.168.141` and `192.168.142` alike - so
there is one number per node to remember and no new collision surface.

The VLANs are how VRF-Lite is done: one L3 link per VRF between the node and
the provider edge. A plain Linux bridge (`vlan_filtering=0`, which is the
default) forwards 802.1Q frames untouched, so virbr1 carries the tagged
traffic without OVS or any special configuration.

### Containerlab in a VM, or on the bare-metal host?

Both work and `setup_udn_bgp_lab.yaml` builds either. `clab_deploy_mode`
defaults to `vm`.

**`vm` (default).** A dedicated RHEL9 guest with two NICs; its fabric NIC is
enslaved to an in-guest bridge that containerlab attaches FRR nodes to. The
reason to prefer this is narrow and real: **containerlab needs Docker, and
Docker rewrites the host's iptables** - it sets the `FORWARD` policy to
`DROP`, adds its own chains, and loads `br_netfilter`, which makes bridged
frames traverse `FORWARD` too. On a hypervisor that is also running your
entire HCP lab behind libvirt NAT, that is a real risk to take on for a side
project. In a VM it is somebody else's problem.

**`host`.** Containerlab runs on the bare-metal host and attaches directly to
virbr1. One less hop, and `tcpdump`/`ip netns`/`containerlab inspect` all
live where you already run Ansible - noticeably easier to debug. Containerlab
inserts `FORWARD ACCEPT` rules for any bridge its topology references, which
handles the specific Docker problem above, and the role inserts an explicit
intra-bridge ACCEPT of its own and then prints whatever rules end up
referencing the bridge, so you can see the situation rather than assume it.

(`<forward mode='open'/>` would have libvirt add no rules at all, but libvirt
refuses to define an open network without an IP address, and giving the
fabric an address starts a dnsmasq on a bridge three OpenShift nodes are
plugged into - the worse trade. Hence an isolated network with no address.)

Pick `host` if you want the easiest debugging and are comfortable with Docker
on the hypervisor. Stay on `vm` otherwise.

### What it costs the existing lab

- Each node VM of every cluster in `clab_fabric_clusters` gains **one extra
  NIC**. Hot-plugged on a running VM, no reboot, no rebuild.
- A new libvirt network (`virbr1`): isolated, with no `<ip>` at all - so no
  NAT, no DHCP, no DNS, no address on the host, and no dnsmasq started for
  it. It cannot route anywhere and cannot perturb virbr0.
- One extra VM (`clab`, `.40`) in `vm` mode: 4 vCPU / 8G. It is registered
  with subscription-manager from the same `org_id` / `activation_key` in
  `vault.yaml` the helper uses - it is a bare RHEL9 image and cannot install
  Docker or containerlab until it is entitled. In `host` mode this does not
  apply, since containerlab runs on the already-registered hypervisor.
- On the cluster: the **Kubernetes NMState Operator** is installed if absent
  (namespace `openshift-nmstate`, plus its `NMState` instance) - every phase
  from `default` on applies `NodeNetworkConfigurationPolicy` objects, which
  come from it. On a disconnected hub, point `udn_bgp_catalog_source` at the
  mirrored catalog; it follows `acm_catalog_source` when vars.yaml sets one.
- On the cluster: `Network.operator.openshift.io/cluster` is patched to
  enable FRR and route advertisements, which **restarts every ovnkube-node
  pod**. That is a few minutes of rolling pod-egress disruption on this lab's
  three workers. The API, the hosted clusters' control planes and MetalLB are
  unaffected. Enabling local gateway mode is a second such rollout.

What does *not* change: every address on virbr0, DNS, the DHCP reservations,
MetalLB's L2 pools, and every node's default route. The leaf's BGP policy
explicitly refuses to advertise or accept `192.168.122.0/24` in either
direction, so no BGP-learned route can shadow the lab's management network.

### Constraints worth knowing before you start

**The lab is now 4.22.** `ocp_major_version` is `"4.22"` (with
`ocp_minor_version: 8` / `coreos_minor_version: 8`) because BGP EVPN for
primary cluster user-defined networks is GA there and does not exist on 4.21.
That variable drives the hub install, the RHCOS images, the mirror registry
payload, the hosted clusters' release image and the operator channels, so it
is not a UDN-only change - a hub built before the bump is still 4.21 and must
be rebuilt or upgraded for the EVPN phase. Everything except `--tags evpn`
works on either version; to go back, set those three values to `"4.21"` / 15
/ 0.

**Do this on hub1, not on a hosted cluster.** Every phase patches
`Network.operator.openshift.io/cluster` and applies `NodeNetworkConfiguration`
policies. hub1 is a plain standalone cluster where that is straightforward.
A HyperShift hosted cluster's OVN-Kubernetes is configured through its
`HostedCluster`/`NodePool` and reconciled from the management cluster, so
patching the guest's Network CR directly is at best fragile. Prove the
mechanism on hub1 first; extending it to a hosted cluster afterwards is a
separate piece of work, not a variable change. `clab_fabric_clusters`
therefore starts with hub1's three workers.

### More than one cluster on the fabric

`vars.yaml` declares two things: `clab_clusters`, which says who is in each
cluster (its nodes, its kubeconfig and its BGP ASN), and
`clab_fabric_clusters`, which says which of those are actually wired into the
fabric. The fabric half builds for all of them in one pass; the cluster half
runs once per cluster and is told which one with `-e udn_bgp_cluster=<key>`.

```
# once, on the lab host: NICs for every cluster's nodes, and a leaf1 that
# knows all of them
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
    --tags nodenics,clabdeploy -e clab_topology=evpn

# then once per cluster, anywhere with the right kubeconfig
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
    --tags evpn -e clab_topology=evpn -e udn_bgp_cluster=hub
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
    --tags evpn -e clab_topology=evpn -e udn_bgp_cluster=sno
```

Three things are per-cluster and all three are load-bearing:

**Its own ASN.** leaf1 re-advertises one cluster's EVPN routes to the other,
and eBGP loop prevention makes the receiver drop anything carrying its own
ASN in the AS\_PATH. Share an ASN between two clusters and you get healthy
sessions, the right routes on leaf1, and an empty table on the far side -
with nothing logged anywhere. An assert in `setup-clab-fabric` refuses the
configuration rather than letting you find out later.

**Its own half of a stretched Layer2 subnet.** A macVRF on one L2VNI is one
broadcast domain across both clusters - that is the point - but each
cluster's OVN-Kubernetes allocates from the subnet knowing nothing about the
other, so both would hand out the low addresses and two pods would land on
one address. There is no cross-cluster IPAM; `evpn_l2_excludes` on the tenant
carves the prefix per cluster. `green` and `purple` give hub `10.204.0.0/17`
and the SNO `10.204.128.0/17`.

**Its own slice of a routed tenant's subnet.** A tenant's identity in the
fabric is its route target, and that belongs to the tenant rather than to the
cluster. Build the Layer3 tenant `blue` in two clusters from one `/16` and both
allocate the same node `/24`s into RT `65000:101`, so leaf2 imports two equally
good paths to one prefix pointing at two different VTEPs - and traffic for a
hub pod starts arriving at the SNO, where nothing answers. A routed tenant can
span clusters, but only with a slice per cluster: `violet` does exactly that
under EVPN, `10.206.0.0/17` on the hub and `10.206.128.0/17` on the SNO, from
`evpn_udn_subnets` on the tenant. `setup-udn-bgp` refuses a Layer3 tenant built
on two clusters without distinct slices. `clab_clusters.<name>.tenants_evpn`
says what each cluster builds in this phase: the SNO builds `green`, `purple`
and `violet`, the hub its five plus `violet`.

### Testing it

`scripts/udn-xcluster-curl.sh` asks the question from inside the clusters — a
pod in one curling a pod in the other, with nothing in the path belonging to
either cluster's host networking. It runs under VRF-Lite too, where it asks a
different question and detects which lab it is looking at; see
[udn-bgp-evpn-steps.md](udn-bgp-evpn-steps.md) section 6.4:

```bash
scripts/udn-xcluster-curl.sh \
    /var/lib/libvirt/images/hub_install/auth/kubeconfig \
    /var/lib/libvirt/images/sno_install/auth/kubeconfig
```

It curls rather than pings for a specific reason. Two tenants on a stretched
Layer2 network can hold the same address — on this lab the SNO's green and
purple pods are both `10.204.128.2` — and `scripts/udn-vrf-isolation.sh` has to
mark those cells `AMBIG`, because ICMP cannot say which of the two answered. A
page names its own tenant and its own cluster, so the cell that is
unresolvable by ping is the most informative one here.

A pass means same tenant reached same tenant in **both** clusters and nothing
else answered at all, and the summary counts how many of those answers crossed
a cluster boundary - and says which were bridged (`green`, `purple`) and which
routed (`violet`). The cell worth looking at first is `sno/violet` against the
hub's `blue`: same fabric, same VTEPs, different route target, and it must be
silent while the hub's `violet` answers.

### What a routed Layer3 UDN across two clusters does

`violet` is the routed counterpart of `green` and `purple`: one tenant, one
L3VNI (`601`) and one route target (`65000:601`), built on both clusters, with
each cluster allocating from its own half of `10.206.0.0/16`. Where a stretched
Layer2 network is one broadcast domain and carries MAC routes (type-2), this is
one routed network carrying prefix routes (type-5) - each node advertises its
own node subnet, the same per-node `/24`s VRF-Lite advertises.

The expected path, a SNO violet pod to a hub violet pod:

```
violet pod 10.206.128.x (SNO)
  → SNO's violet VRF: type-5 route for the hub node's /24
        RT 65000:601, next hop 100.64.0.<hub node>, VNI 601
  → VXLAN  outer src 100.64.0.20 (SNO vtep0)  dst 100.64.0.<hub node>  VNI 601
  → outer packet: 100.64.0.0/24 from leaf1 → leaf1 → static /32 → hub node
  → hub node decapsulates VNI 601 → violet VRF → pod
```

The tunnel runs **node to node** across the cluster boundary; leaf1 carries
the outer packet and relays the EVPN routes, and leaf2 is not in the path.
That relies on EVPN next hops surviving leaf1 unchanged, which this lab
already depends on for every node-to-leaf2 tunnel.

Two things this avoids that the stretched Layer2 pair cannot. Each cluster's
node subnets are its own, so the per-node gateway addresses never collide -
green and purple share one `10.204.0.1` and one cluster's is shadowed at the
VTEP. And isolation from `blue` beside it on the hub comes from the route
target: blue's routes are imported into no violet VRF, anywhere. Since violet
gained an internet default (below), a packet for blue's address does leave
the node - it follows that default to leaf2 - and leaf2 refuses it, because
violet's VRF there holds private space unreachable rather than handing it to
the internet uplink. Still silent; the refusal just moved to the border.

**Expected, not yet measured** - violet was added to the EVPN phase after the
results elsewhere in this document. To confirm it is routed and node to node:

```bash
# the SNO holds the hub's violet /24s, next hop a HUB node's VTEP
oc debug node/<sno node> -- chroot /host ip route show table all | grep '^10\.206\.'

# the type-5 routes themselves, as leaf1 relays them - RT 65000:601, VNI 601
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp l2vpn evpn route type prefix'

# routed, so the TTL drops below 64 - where green's stays at 64, bridged
oc --kubeconfig=<sno> -n udn-violet exec <pod> -- ping -c3 <hub violet pod>
```

The other two views are still per-cluster and still worth running:
`scripts/udn-vrf-isolation.sh --pods` for the isolation matrix, and
`scripts/udn-web-demo.sh --proxy` for the ingress, which fronts every cluster
at once.

### Reaching the internet from a UDN

A UDN reaches a network through the fabric only if **a router in the tenant's
VRF advertises it** into the tenant's route target. VXLAN never goes looking
for a next hop: each packet is encapsulated toward whatever VTEP the route for
its destination names, so an address nobody advertises has no tunnel to take.
It ends in the node's copy of the tenant VRF, and the pod sees
`Destination Host Unreachable` from its node subnet's `.2` - the management
port, the host's end of OVN.

`blue` reaching `10.210.10.10` works because leaf2 originates
`10.210.10.0/24` into `65000:101`. The internet works the same way for
`violet` (`evpn_internet: true`): leaf2 originates `0.0.0.0/0` into violet's
VRF (`default-originate ipv4`), so every node's copy of it learns
`default via 10.0.0.2, VNI 601`:

```
violet pod 10.206.x.y
  → node's violet VRF: default via 10.0.0.2 (leaf2's VTEP), VNI 601
  → VXLAN to leaf2 → decapsulated into leaf2's violet VRF
  → default via eth0, the containerlab management NIC      leaf2-egress.sh
  → the containerlab host: MASQUERADE out its uplink       egress-nat.yml
  → the internet, from the host's address
replies: host un-NATs → 10.206.0.0/16 via leaf2 → leaf2 main → violet VRF
         → type-5 route to the node holding the pod → VXLAN → pod
```

**"No NAT" means inside the cluster.** Pods keep their own addresses on the
fabric, but the internet cannot route to `10.206.x`, so the NAT moves to the
border. leaf2 cannot do it itself - the FRR image ships no `iptables` - so the
host that runs containerlab does, and routes the replies back to leaf2.

**Public destinations only.** leaf2 keeps `10/8`, `172.16/12` and `192.168/16`
unreachable inside violet's VRF, so the default is not a way round tenant
isolation: violet still cannot reach `blue`, or the lab's management network.

**Why violet and not blue.** Nothing overlaps violet. `blue` and `red` share
`10.200.0.0/16` by design, and one NAT cannot tell their return traffic apart
- that needs per-VRF NAT, which is what the border firewall is for in a real
design.

The EVPN phase checks it end to end from a violet pod on each cluster
(`udn_bgp_internet_probe`, `http://1.1.1.1/` by default; `""` to skip), and on
failure names the hops to walk in order. By hand:

```bash
oc -n udn-violet exec <udn-test pod> -- curl -sI http://1.1.1.1/
oc debug node/<node> -- chroot /host ip route show vrf <violet vrf> default
docker exec clab-udnbgp-leaf2 vtysh -c 'show bgp l2vpn evpn route type prefix'
```

### What a stretched Layer2 UDN across two clusters actually does

Measured on this lab, hub + SNO on L2VNI 400:

**Pod to pod works, and is bridged rather than routed.** A SNO pod at
`10.204.128.0` pings a hub pod at `10.204.0.6` with 0% loss and `ttl=64` —
unchanged, so the packet crossed SNO VTEP → VXLAN → leaf2 → hub VTEP without
passing through any gateway router. That is what a macVRF is for.

In particular the `advertised-network-subnets` drop ACL does **not** block it.
That ACL matches source and destination against the set of advertised UDN
subnets, in the source node's ingress pipeline, using addresses only — so a
hub pod sending to `10.204.128.5` is indistinguishable from one sending to
`10.204.0.5`, and the latter obviously has to work. Same-UDN traffic is
allowed whichever cluster it lands in.

Traffic between **different** tenants in different clusters is allowed too,
for a different reason, and it applies under VRF-Lite as much as EVPN: each
cluster's ACL is built from that cluster's own advertised subnets. The SNO's
holds `10.206.0.0/16` and knows nothing of the hub's `10.204.0.0/16`, so
neither end sees a pair where both sides are locally advertised. A violet pod
on the SNO curling `10.204.0.7` on the hub gets green's page; the same curl
between two hub tenants is dropped. Within a cluster the ACL is the backstop
whatever `udn_vrf_leaks` opens; across clusters the leaks decide alone. You
can read the set directly and confirm it holds only local prefixes:

```bash
OVN=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node -o name | head -1)

# which set the drop rule matches on
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN \
  bash -c 'ovn-nbctl list ACL | grep -B4 -A6 advertised-network-subnets'

# then what is in it. Use --columns: plain `list` prints fields
# ALPHABETICALLY, so `addresses` comes out above `name` and a grep -A
# anchored on the name shows the NEXT record's addresses.
oc -n openshift-ovn-kubernetes rsh -c ovnkube-controller $OVN \
  ovn-nbctl --format=csv --data=bare --no-headings --columns=name,addresses \
    list Address_Set | grep '^a<the id from the match above>'
```

**None of this extends to phase 2.** The reasoning above is about what the
ACL permits, and under the shared VRF the question never reaches the ACL:
phase 2 gives a tenant no path to the fabric at all, so cross-cluster
pod-to-pod is silent regardless. See the phase-2 row in the table below, and
Case 4 in `troubleshooting.md`.

**The infrastructure addresses collide, and cannot be split.** Both clusters
put their Layer2 gateway on `10.204.0.1` and their per-node management port on
`10.204.0.2`. ovn-kubernetes derives a MAC from the IP, so those are literally
the same MAC advertised from two VTEPs — `show evpn mac vni 400` lists
`0a:58:0a:cc:00:02` at one VTEP only, so one cluster's is shadowed. Pod ranges
separate cleanly with `reservedSubnets`; these do not, because every cluster on
the subnet needs them. This is the real limit on the design, not the IPAM.

It does not break pod-to-pod traffic, which never touches the gateway — but
anything a pod sends *off* its own subnet goes to whichever `10.204.0.1`
answered its ARP, which may be the other cluster's router.

The tenant ingress fronts every cluster at once. `udn_proxy_clusters` decides
which, the first entry keeps the bare hostname and the rest are suffixed, so
`green.hub.mylab.com` stays the hub's and the SNO's is
`green-sno.hub.mylab.com` — one address, one haproxy, seven names. The network
namespace is chosen by *tenant*, not by cluster, which is why no client
plumbing changes: `green` and `green-sno` are one stretched L2VNI, so the
`green` namespace reaches both clusters' pods on-link and only the backend
address differs.

Those hostnames live in two places generated by two different playbooks — the
haproxy config from `--tags clabnsproxy`, and the hub DNS zone from
`setup_bm_host.yaml --tags dns`. Both render from `udn_proxy_names`, and
`clabnsproxy` asserts the two agree, because a zone built from the tenant list
while haproxy was built from the route list gives a hostname that resolves and
404s — which reads as a proxy fault and is not one. **Adding a cluster means
re-running the DNS tag too**; the demo itself sends an explicit `Host:` header
and needs no DNS at all.

Do not run `--tags default` on a second cluster. Its default pod network is
the same `10.128.0.0/14` the first one has, and one prefix advertised into
the fabric from two origins leaves leaf1 with a winner and a loser.
`clab_clusters.sno.advertise_default: false` makes that phase a no-op with an
explanation rather than a silent breakage.

**VRF-Lite and EVPN require local gateway mode** (`routingViaHost: true`).
This is an OVN-Kubernetes restriction, not a lab one - VRF-Lite is not
implemented in shared gateway mode, and the CRs are accepted and quietly do
nothing. `udn_bgp_set_local_gateway` (default `true`) makes the switch; it is
a separate patch from the enablement one precisely because it is a second
full rollout and changes how all pod egress leaves the node.

**The nodes also need `gatewayConfig.ipForwarding: Global`**
(`udn_bgp_set_ip_forwarding`, default `true`). Under the default
`Restricted`, ovnkube-node holds `net.ipv4.ip_forward` at 0 and forwards only
across the interfaces it manages - `br-ex` and `ovn-k8s-mpN`. The fabric NIC
is not one of them, so replies from the fabric are dropped in the routing
decision while every control-plane signal stays green.

Setting the sysctl instead does not survive. `ip_forward` and
`conf.all.forwarding` are the same value and a write to it propagates to
*every* interface, so each ovnkube-node restart re-zeroes the fabric NIC. The
Tuned profile that also sets it cannot re-assert it either: the Node Tuning
Operator runs tuned in **no_daemon mode** - it applies the profile once and
exits - so `Applied=True` on the Profile CR is a receipt for one past write,
not a claim about the current value. Last writer wins, permanently. Three
identically configured workers were found disagreeing for exactly this
reason. `Global` makes OVN-Kubernetes set the value itself, so there is no
writer to lose to.

**MetalLB is already on this cluster** for the hosted clusters' API VIPs, in
**L2 mode**, so it is not competing for BGP sessions. MetalLB also ships an
FRR-K8s; the Cluster Network Operator deploys its own into
`openshift-frr-k8s`, and that is the one this lab uses. If you later move a
MetalLB pool to BGP mode, point it at the CNO's instance rather than letting
the MetalLB operator stand up a second one. The pre-flight phase lists every
FRR-K8s daemonset it finds so you can see the situation before enabling
anything.

**`FRRConfiguration` goes in `openshift-frr-k8s`, not `metallb-system`.**
Upstream OVN-Kubernetes examples use `metallb-system` because upstream
installs FRR-K8s via MetalLB. On OpenShift the CNO owns it. An
`FRRConfiguration` in the wrong namespace is accepted and silently never
read, which is a tedious hour to lose.

**Overlapping UDN subnets only work with VRF-Lite, and nothing stops you
getting it wrong.** With `targetVRF` unset both tenants' routes land in the
default VRF, where the same prefix cannot mean two things - but the
`RouteAdvertisements` is still Accepted. OVN-Kubernetes does not validate
this; its route advertisements controller carries a literal
`// TODO check overlaps?` where that check would go. What you get is one
winner and one tenant quietly unreachable, not an error.

The tenant definitions carry two subnets for this reason:
`udn_subnet_shared` (unique across all tenants, used by the `shared` phase)
and `udn_subnet` (**deliberately identical between blue and red**, used by
`vrflite` and `evpn`). The role asserts the shared-phase subnets are distinct,
because the cluster will not. Proving two UDNs can carry the same addresses in
isolation is most of the point of VRF-Lite.

**The fourth tenant, `green`, is Layer2**, and is the only one a VM belongs
on. Layer3 slices its subnet per node, so a workload that moves node
necessarily changes address; Layer2 is one flat broadcast domain across every
node, and with `ipam.lifecycle: Persistent` the allocation follows the VM
rather than the pod behind it. That combination is what lets an OpenShift
Virtualization live migration keep its IP - a migration replaces the
`virt-launcher` pod, so without persistent IPAM the VM arrives with a new
address. Under EVPN it takes a `macVRF` (an L2VNI carrying MAC reachability)
where the Layer3 tenants take an `ipVRF`, which is what `evpn_mac_vni` in
`vars.yaml` has been reserved for. [bgp-evpn.md](bgp-evpn.md) has the VM
manifest and the migration walkthrough.

**The third tenant, `orange`, is the control.** It overlaps with nothing in
any phase, and it exists to make the isolation result unambiguous. "blue
cannot reach red's external network" has two possible explanations - the VRF,
or the fact that they share a subnet so the routing is ambiguous rather than
isolated. "blue cannot reach *orange's*" has only one. Read blue-vs-orange as
the isolation result and blue-vs-red as the overlap result. Orange's prefix is
also the only tenant prefix that means exactly one thing wherever it appears,
which makes it the one to look for when reading a routing table on the leaf or
on a node.

**MTU.** The fabric is 9000 end to end - bridge, taps, node NICs, VLAN
subinterfaces and FRR containers. At 1500 the BGP sessions come up fine and
then large flows black-hole, because the fabric is carrying Geneve or VXLAN
wrapped around pod traffic that is already encapsulated.

### Building it

Phases are cumulative and are meant to be run in order. Each one removes an
entire class of explanation for a failure in the next - that ordering is the
main thing this playbook is for.

```bash
# 0. The fabric. No cluster changes at all.
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags fabric

# Report what the cluster can do. Changes nothing.
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags preflight

# 1. Advertise the cluster DEFAULT pod network. No UDN involved -
#    if this does not work, UDN is not the reason.
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default

# 2. Primary UDNs advertised into the default VRF (targetVRF unset).
#    Adds UDN. Still no VLANs, no VRFs, no NMState.
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags shared

# 3. VRF-Lite: per-tenant VRFs and VLANs (targetVRF: auto).
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags vrflite

# 4. EVPN. Rebuild the fabric as leaf/spine/leaf first, then the cluster side.
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags fabric -e clab_topology=evpn
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags evpn
```

`--tags fabric -e clab_topology=evpn` redeploys the containerlab topology in
place (`containerlab deploy --reconfigure`); it does not disturb the node
NICs, `virbr1`, or anything on the cluster.

Run containerlab on the bare-metal host instead: `-e clab_deploy_mode=host`.

Every manifest is rendered to `udn-bgp/` before it is applied, so you can
read and diff exactly what was sent, and re-apply by hand with `oc apply -f`.

The VRF-Lite phase does something worth understanding rather than trusting.
OVN-Kubernetes creates a Linux VRF per UDN on each node and enslaves its own
management port (`ovn-k8s-mpN`) to it. VRF-Lite needs a VLAN subinterface
added to *that same VRF*. But NMState treats a VRF's port list as
declarative - a policy declaring the VRF with only the VLAN in `port:` would
**remove `ovn-k8s-mpN` and take the tenant's pods off the network**. So the
role reads the live VRF layout off each node first (`vrflite-discover.yml`),
and templates the policy with the discovered port list and route-table id
restated in full. Never hand-write one of these from the example; render it.

The VRF's *name* is derived from the CUDN's name, and then confirmed against
the node's link table before anything is templated from it. There is no status
field to read instead - `oc explain clusteruserdefinednetwork.status` lists
`conditions` and nothing else - so the derivation is the only option, and a
derivation that is never checked is how you end up writing a policy for a VRF
that does not exist. A Linux interface name caps at 15 characters, so the role
also refuses tenant names longer than that rather than looking for a device
OVN-Kubernetes had to call something else.

The discovery still needs the VRF to *exist*, and OVN-Kubernetes only creates
it on a node that has something on that network - which is why the test
workload is a DaemonSet, and why the CUDNs and workloads are applied before
the discovery runs.

### Verifying each phase

The playbook prints control-plane state and then the data-plane commands to
run by hand (they need a pod name). The ones that matter:

```bash
# Accepted? A RouteAdvertisements is accepted long before it works.
oc get routeadvertisements -o wide
oc get routeadvertisements <name> -o jsonpath='{.status.conditions}' | jq

# The objects OVN-Kubernetes GENERATED from it carry the actual prefixes.
# If these are absent, nothing took effect regardless of the status above.
oc get frrconfiguration -n openshift-frr-k8s

# The leaf's view.
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp summary' -c 'show bgp ipv4 unicast'
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp vrf blue ipv4 unicast'

# Pod address comes from the UDN, not the cluster network.
oc -n udn-blue exec <pod> -- ip -br addr show eth0

# Egress is NOT SNATed - the leaf sees the real pod IP. This is the proof.
docker exec clab-udnbgp-leaf1 tcpdump -ni any icmp
oc -n udn-blue exec <pod> -- ping -c3 10.210.10.10

# Tenant isolation. This one MUST FAIL (VRF-Lite phase):
oc -n udn-blue exec <pod> -- ping -c3 -W2 10.211.10.10
# blue and red carry the SAME pod subnet and their external networks are one
# hop away on the same physical link. If this succeeds, the VRFs are leaking.

# Routes learned over BGP, not statically pointed anywhere:
oc debug node/worker1 -- chroot /host ip route show proto bgp
oc debug node/worker1 -- chroot /host ip route show vrf blue

# And the thing this lab is careful NOT to have changed:
oc debug node/worker1 -- chroot /host ip route show default
# expect: default via 192.168.122.1
```

### EVPN, two ways

`-e clab_topology=evpn` builds a three-node fabric - `leaf1` (border),
`spine` (EVPN route reflector), `leaf2` (far end) - with VXLAN between the
VTEPs and the tenant external endpoints moved behind `leaf2`, so traffic
genuinely crosses the overlay instead of being configured and never used.

**Nodes as VTEPs (4.22, what this lab does).** Each OCP node is a tunnel
endpoint. The `VTEP` CR discovers the node's address, the CUDN carries
`network.transport: EVPN` with an `ipVRF` VNI and route target, and the node
peers `l2vpn evpn` with `leaf1` over the fabric link it already uses - a
second address family on an existing session, not a new adjacency. VXLAN
then flows node to `leaf2` directly; `leaf1` only provides underlay
reachability and EVPN transit, and holds no tenant VRFs.

Note this phase does **not** use the VRF-Lite VLAN plumbing, and removes it
if phase 3 left it behind. Under EVPN the tenant routes travel as type-5
routes over VXLAN; keeping the VLAN handoff as well would give every tenant
two paths to the same destinations with nothing choosing between them.

**Border-leaf handoff (works on 4.21).** Use `clab_topology=evpn` with
`--tags vrflite` instead of `--tags evpn`. The cluster keeps peering
per-tenant VLANs with `leaf1` exactly as in phase 3, and `leaf1` maps each
VRF into an EVPN VNI itself. Plenty of real clusters hand off to an EVPN
fabric at a border leaf rather than running VTEPs on nodes, and it exercises
the same VNI and route-target mapping. What it does not exercise is
node-level VTEPs.

**VTEP addressing is `Unmanaged`, and has to be.** The `VTEP` CR's other
mode, `Managed` (OVN-Kubernetes allocates a VTEP IP per node), is not
implemented as of OpenShift 4.22 and 4.23 - a `Managed` VTEP is rejected with
`ManagedModeNotSupported` - and `mode` defaults to it, so the CR here sets
`Unmanaged` explicitly. Source references and a re-check command are in
[real-fabric.md 6](real-fabric.md#6-the-vtep). The lab assigns
`100.64.0.<the node's usual octet>` via NMState on a `vtep0` dummy, which
also lets `leaf1` - three FRR containers, no IGP - carry static `/32`s written
at render time. Exactly one address per node may fall inside the CR's
CIDRs - two is a failed status, not a choice.

**Layer 2 / MAC-VRF is not wired up.** Both tenants here are `Layer3` with
an `ipVRF`, which is the direct continuation of the VRF-Lite phase. The API
also supports `Layer2` primary CUDNs with a `macVRF` VNI, which is what you
want for stretching an L2 segment off-cluster and preserving a VM's MAC and
IP across migration. That needs a MAC-VRF on the fabric side too - an L2VNI
bridge and SVI on `leaf2` - which this topology does not build. The tenant
definitions already carry an unused `evpn_mac_vni` for that extension. The
API shape is:

```yaml
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets: ["10.200.0.0/16"]
      # for a VM keeping its off-cluster gateway and address:
      # defaultGatewayIPs / infrastructureSubnets / reservedSubnets
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF: { vni: 100, routeTarget: "65000:100" }
      ipVRF:  { vni: 101, routeTarget: "65000:101" }   # optional on Layer2
```

`macVRF` is required for `Layer2` and forbidden for `Layer3`; `ipVRF` is
required for `Layer3`.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| `oc get nncp` shows `vrflite-*` `Degraded / FailedToConfigure` for existing tenants while a newly added tenant is `Available` | The VRF-Lite policy was not idempotent. `nncp-vrflite.yaml.j2` restates the discovered port list and then appends the tenant's VLAN subinterface; on a re-run that subinterface is *already* in the VRF, so discovery returns it and it gets declared twice - `NmstateError: InvalidArgument: Controller blue (vrf) has multiple ports pointing to the same kernel interface enp8s0.110`. A brand-new tenant has no VLAN yet and applies cleanly in the same run, which makes it look tenant-specific rather than like the re-run it is. Read the real error from the enactment, not the policy: `oc get nnce <node>.<policy> -o jsonpath='{.status.conditions[?(@.type=="Failing")].message}'`. Fixed by filtering any discovered port ending in `.<vlan>` before appending. Note the node's data plane is usually fine meanwhile - the interfaces are still attached from the previous successful apply |
| Want the phase-3 client without four VMs | `--tags clabnsclient` builds one VM with one network namespace per tenant; both test scripts take `--netns` for the namespaces alone, or `--vms --netns` to run them beside the VMs. A namespace is stronger client-side isolation than a VRF - no visibility of another namespace's interfaces or routes, and no shared rule table to mis-order - so the objection to one multi-tenant host does not apply. It also drops the grouping rules: blue and red need separate *hosts* only because one routing table holds one route to `10.200.0.0/16`. Built alongside `clabtenantclients`, not instead of it; they coexist because the namespaces take `.21` on each client segment and the VMs `.20`, which `nsclient-vm.yml` asserts |
| Reach a tenant whose pod address another tenant also holds | `--tags clabnsproxy` builds a tenant ingress on the namespace client: one hostname per tenant (`green.hub.mylab.com`, `purple.hub.mylab.com`, ...), all resolving to the SAME address, with haproxy choosing the tenant from the Host header. The load-bearing part is `namespace <name>` on the server line, which opens the backend connection inside that network namespace - so two backends can name the identical `10.204.0.12:8080` and reach different pods. Nothing in the root namespace can do this: it has one routing table and therefore one route to that address. Records come from `--tags dns`; verify with `scripts/udn-web-demo.sh --proxy`, which checks each hostname returns the page naming the tenant that was asked for - a 200 from the wrong tenant is this design's characteristic failure and a health check cannot see it. Note it deliberately gives one machine reach into every tenant, so the Host-to-namespace mapping becomes the only thing keeping them apart |
| Phase 3: `udn-vrf-isolation.sh` shows `AMBIG` cells | Two tenants hold the same pod address — by design, green and purple are Layer2 tenants sharing `10.204.0.0/16`. A ping there answers for both and ICMP cannot say which replied, so those cells are excluded from the verdict instead of being scored as a leak. Cells whose source owns nothing on that address stay judged. Resolve it with the identity check (`InEchos` on both pods) or `scripts/udn-web-demo.sh`, where the page names its own tenant |
| Want the isolation result readable rather than inferred | `--tags web` puts a one-pod web server on blue and red; `scripts/udn-web-demo.sh` curls each from each client VM. A ping reply proves something answered, not what — and once blue and red share a subnet that is the whole question. The page names its own tenant, pod, node and UDN address, so two machines curling two addresses in one `/16` get two self-identifying documents. Needs no privileged SCC: it listens on 8080 as non-root, unlike the `NET_RAW` ping DaemonSet |
| A hosted cluster's API goes intermittently unreachable after building UDN lab client VMs | The VM is on a MetalLB pool address. `hosted_cluster_metallb_pools` owns `.60-.62` (hub1 API for hcp-cluster1/2/3), `.67-.69` (hubd) and `.90-.95` (hub2); MetalLB L2 mode ARPs for those itself, so a VM holding one does not fail cleanly - both answer, whichever is first wins, and the symptom lands on the hosted cluster rather than on the VM. The UDN clients now sit on `.47`, `.50`, `.57` and `.70`, and `client-ip-check.yml` fails the build rather than letting it happen |
| `--tags clabtenantclients`: a client VM cannot reach its tenant's gateway (`10.215.10.1` etc.) | leaf1 has no `eth1.<client VLAN>` yet. Those subinterfaces are built by leaf1's `exec:` block at container start, so adding `udn_client_segments` needs the topology redeployed (`--tags clabdeploy`) before the VMs can work. The role asserts on this rather than letting it surface later as an all-FAIL row indistinguishable from a real VRF fault |
| Can one client VM serve all four tenants in phase 3? | No, and the role refuses to build it. blue and red both use `10.200.0.0/16`, and one host has one routing table: it would hold a single route to that prefix, reach one tenant, and silently never reach the other. Overlapping tenants need separate machines; non-overlapping ones (orange `10.202.0.0/16`, green `10.204.0.0/16`) can share one VM with two VLAN subinterfaces and no VRFs. Giving the client its own VRFs would make a client-side fault indistinguishable from the leaf-side fault under test |
| Phase 3: every tenant fails both directions, but NNCPs are `Available`, the RouteAdvertisements is `Accepted`, `frr.conf` has all four `router bgp ... vrf` stanzas, `show vrf` lists every VRF, and the leaf can ping the node's VLAN address through the VRF | bgpd never bound to the tenant VRFs. Check `vtysh -c 'show bgp vrf all summary'` — **`vrf all` is required**, plain `show bgp summary` covers only the default VRF and looks healthy throughout. `vrf-id -1` with router-id `0.0.0.0` and zero messages in both directions means the BGP instance is holding `VRF_UNKNOWN`: bgpd resolves `router bgp <asn> vrf <name>` to a kernel device when it parses that stanza, and phase 3 replaces every tenant VRF (recreating the CUDNs makes OVN-K rebuild them with new table ids). The leaf shows `Active`/`never`, which reads like a connectivity fault and is not one. Fix: `oc -n openshift-frr-k8s rollout restart daemonset/frr-k8s`. The role now does this at the end of phase 3, conditionally |
| After `--tags vrflite`, `scripts/udn-reachability.sh` goes all red | Expected. The phase-2 client VM sits in leaf1's **default** VRF and phase 3 moves every tenant out of it, so the client reaches none of them - that is the isolation working. The client's routes are also stale: both `udn-client-routes.sh.j2` and `clab-fabric-router.sh.j2` render `udn_subnet_shared` (`10.220-10.223`), which no longer exists after phase 3. Re-running `--tags clabclient` re-renders the same stale routes without erroring. Use `scripts/udn-vrf-isolation.sh` instead |
| Want a client VM per tenant to test the overlapping phase-3 subnets | Not needed, and worse than what exists. `udnbgp.clab.yml.j2` already enslaves each `<tenant>-ext` link to that tenant's VRF on leaf1 (`ip link set blue-ext master blue`), so the four ext containers are four clients each in its own VRF. A single VM holding all four tenants would need four VRFs of its own, and a client-side VRF bug is indistinguishable from the leaf-side VRF bug under test. Pointing the phase-2 templates at `udn_subnet` instead would not work either: blue and red are both `10.200.0.0/16`, so one routing table has one entry and one of the two tenants is unreachable by construction |
| `scripts/udn-vrf-isolation.sh` shows every cell `ok` | Not a pass. Every tenant reaching every other tenant's endpoint means `targetVRF` never took effect and the tenants are still in leaf1's default VRF - that is phase 2. Check `oc get routeadvertisements udn-vrflite -o jsonpath='{.status.status}'` and that phase 2's advertisement was deleted first |
| A phase-3 ping from one tenant's ext container to an overlapping address succeeds - is that a leak? | Reachability cannot answer it. Blue and red share `10.200.0.0/16`, so a reply proves something answered, not **which pod** answered, and "the wrong tenant's pod replied" is the exact failure VRF-Lite prevents. `scripts/udn-vrf-isolation.sh` reads ICMP `InEchos` from `/proc/net/snmp` on both candidate pods either side of the ping and names the responder. `WRONG TENANT` there is a leak that both reachability matrices report as clean |
| Want to confirm the Layer2 tenant really load-shares into the cluster | `vtysh -c 'show bgp ipv4 unicast <subnet>'` should show one prefix with a path per node, all marked `multipath`, and `show ip route <subnet>` should show all of them installed with `*`. FRR enables eBGP multipath by default, so this needs no `maximum-paths` - but Cisco IOS and older Quagga default to 1, so a different NOS in the same topology would install one path. A single ping will not show distribution: Linux hashes on source and destination address, so vary the destination |
| **Phase 2 only.** One tenant unreachable on every node, the others fine, fabric and advertisement both healthy | That tenant is missing its `2000: from all to <subnet> lookup <table>` rule, which is what redirects fabric-inbound traffic into the tenant's VRF. Compare `oc debug node/<node> -- chroot /host ip rule show \| grep 10.22` across tenants. Seen on a tenant that had once been created with its namespace missing `k8s.ovn.org/primary-user-defined-network`: the network was never realised, the rule was never installed, and later recreations by the playbook did not add it. Deleting the CUDN and namespace by hand and recreating them did - and the network id moved (`fwmark 0x1005` to `0x1009`) while the other tenants kept theirs, so the stale state was tied to the id rather than the object. A prompt recreate under the same name gets the old id back and the old state with it. Healthy is **three rules per tenant** at priority 2000: fwmark, masquerade, subnet. Note this is a phase-2 failure only: in phase 3 the fabric interface is itself inside the tenant VRF, so l3mdev at priority 1000 does the steering and no rule references a tenant subnet at all - there is nothing to be missing |
| Pods on one node answer an external client and pods on another do not | Strict reverse-path filtering on the node that is silent. The client's traffic is asymmetric - request over the fabric, reply out the node's default gateway - so every node it talks to must accept packets whose reverse path points elsewhere. Set `udn_bgp_loose_rp_filter: true` and re-run `--tags shared`: that applies it to every worker through the Tuned profile and survives a reboot, which a hand-run `sysctl -w` on one node does not. `net.ipv4.conf.all.rp_filter=2` alone is enough - the kernel uses `max(all, <iface>)` and there is no value above 2 |
| `sudo: a password is required` from the first task of a `--tags fabric` or `--tags clabclient` run | The playbook is `hosts: localhost` with `become: true`, and those tags drive libvirt - so they must run **on the lab host**, not from a workstation. The cluster-side tags (preflight, default, shared, vrflite, evpn) are only `oc` calls and run anywhere with a kubeconfig. With `--tags` only the selected tasks execute, so this surfaces at whatever runs first rather than at the task that actually needs libvirt |
| An external client's packets reach a UDN pod, the pod replies, and the reply vanishes on the way back | Reverse-path filtering somewhere on the return path. Phase 2's reply leaves by the node's default gateway rather than the fabric, so forward and reverse paths differ at every hop and each host's rp_filter rejects it. Check each in turn - **the effective value is `max(all, <iface>)`**, so `net.ipv4.conf.all.rp_filter = 0` with `conf.virbr0.rp_filter = 1` is strict. Set both to 2. `udn_bgp_loose_rp_filter: true` covers the cluster nodes; the lab host and any client VM are outside the playbook |
| A ping from the clab VM to a pod succeeds but proves nothing | The clab VM shares a broadcast domain with all three workers, so leaf1 answers with `Redirect Host` and the traffic goes direct, testing no routing at all. Source the ping from the management address (`ping -I 192.168.122.40`) and check the reply's TTL - 61 rather than 63 means it was really routed via leaf1 and the node |
| Phase 2: a UDN pod cannot ping the fabric, nothing on the fabric bridge at all | Expected in this lab, not a fault. In local gateway mode pod egress lands in the tenant's VRF table, whose only external route is the node's ordinary default gateway. `192.168.140.0/24` is a connected route on the fabric NIC, which lives in the default VRF, so `main` has it and the tenant table does not - the packet leaves by the management NIC instead (`tcpdump -ni virbr0` shows it, un-SNATed). Giving the tenant VRF its own path to the fabric is what phase 3 does. In **shared** gateway mode the same thing happens one layer up: the tenant's OVN gateway router holds its own `/16` and a default via the management gateway, and never consults the host table where the BGP routes live. Either way the consequence is the same and it is the phase-2 answer to a common question - **cross-cluster pod-to-pod does not work under phase 2**, and `udn-xcluster-curl.sh --shared` expects every such cell to be silent. Clients on the fabric still reach pods: that direction is inbound over BGP and works. See Case 4 in `troubleshooting.md` |
| Phase 2 reply takes a different path from the request | By design, and not how production works. Inbound is decided by **leaf1** from BGP; outbound is decided by the **node** from the tenant VRF's table, which holds only the tenant's subnets and the node's default gateway. A route advertisement is one-way information - it tells the fabric how to reach the pods, not the node how to reach the fabric. In production the fabric is what `br-ex` faces, so the VRF's default gateway *is* the fabric and both directions match. This lab puts the fabric on a second NIC with no default route, deliberately, so the change is safe on a live cluster. There is no supported way to force symmetry in phase 2 - see bgp-evpn.md, "Can the return path be forced to match?" |
| Want to prove phase 2 worked at all | Three things are real: the RA is Accepted, leaf1 holds every node's slice of every tenant, and every node has the others' slices in `main` via `proto bgp`. Plus the un-SNAT: `tcpdump -nni ovn-k8s-mpN` on the tenant's management port shows the pod's own address as the source |
| RouteAdvertisements stuck at `configuration pending: no networks selected` | Rarely the label selector, which is what the message suggests. OVN-Kubernetes resolves the selected CUDNs against networks it has actually instantiated, so a correctly-labelled CUDN with no NetworkAttachmentDefinition selects as nothing. Check `oc get clusteruserdefinednetwork <tenant> -o jsonpath='{.status.conditions}'` - the CUDN carries the real reason (there is no `cudn` short name; `oc get cudn` fails with "the server doesn't have a resource type") |
| CUDN `NetworkCreated=False`, `NetworkAttachmentDefinitionSyncError`, "required namespace label ... must both be present" | The tenant namespace is missing `k8s.ovn.org/primary-user-defined-network`. It is the namespace's opt-in to having a primary UDN; without it no NAD is created. It must be present **when the namespace is created** - OVN-Kubernetes binds a primary network at creation time and will not retrofit it, so the fix is to recreate the namespace, not to label it |
| Everything green but the pods are on the cluster network | The silent form of the two rows above. Pods schedule, the DaemonSet rolls out and `oc exec` works whether or not the primary UDN attached. The only place the truth is recorded is `oc -n udn-<tenant> get pod -o jsonpath='{.items[0].metadata.annotations.k8s\.ovn\.org/pod-networks}'`: two keys (`default` plus the tenant) is right, one key `default` with `role: primary` means the UDN never attached. Note the tenant's key is `<namespace>/<cudn>` (`udn-blue/blue`, not `blue`), and a healthy pod also has `default` demoted to `role: infrastructure-locked`. The play now asserts both |
| `ErrorReconcilingPod: invalid primary network state` in pod events on a run that otherwise worked | A race that resolves itself. The namespace and the DaemonSet are applied in one manifest, so pods can be created before OVN-Kubernetes has processed the namespace's primary network; it retries. `AddedInterface` with two addresses afterwards is the proof it succeeded. Judge by the pod-networks annotation, not by this warning |
| Test DaemonSet stuck at `desiredNumberScheduled: 3`, `currentNumberScheduled: 0`, no pods at all | SCC, not scheduling. `desired` non-zero with `scheduled: 0` means the pods were refused at *creation*, so no pod object exists and there is nothing to `describe`. The pods ask for `NET_RAW`/`NET_ADMIN`; the namespace PSA labels do not cover that, because PSA and SecurityContextConstraints are separate admission layers. The workload now ships a ServiceAccount bound to `system:openshift:scc:privileged`. Evidence is on the DaemonSet: `oc -n udn-<tenant> describe daemonset udn-test` |
| Test DaemonSet at `currentNumberScheduled: 3`, `numberReady: 0` | Different failure - the pods exist, so `oc get pods` and `oc describe pod` have the answer. Usually the CUDN not being ready yet, or the `registry.redhat.io/rhel9/support-tools` pull |
| BGP session never establishes | Fabric NIC not addressed (check `oc get nncp`), or MTU mismatch, or the node has no fabric NIC at all |
| `Configuration file[/etc/frr/frr.conf] processing failure: N` from vtysh | Cosmetic, and misleading. vtysh had no `vtysh.conf`, so it read `frr.conf` as its own config and failed the lines that are daemon config. It says nothing about whether the daemons are healthy - read `show bgp summary` for that. The role ships a `vtysh.conf` to stop it |
| leaf1 peers `Idle` with `Last write never`, and `show bfd peers brief` says `down` | BFD configured on one end only. It is a two-ended protocol - FRR-K8s needs a `bfdProfile` to match - and a permanently-down BFD session holds the BGP peer administratively down. The lab does not use BFD for this reason |
| leaf1 peers all `Idle`, `MsgSent 0`, while nodes sit in `Active` | bgpd is running but was never given its configuration - `frrinit.sh` applies the config as its last step, so a kill part-way through leaves a running bgpd with zero peers, refusing every SYN. `show bgp summary` showing `Peers 0` is the tell. Redeploy |
| `Failed to execute command "/usr/lib/frr/frrinit.sh restart" rc=137` | FRR is the container's PID 1. Stopping it stops the container, Docker restarts it, and the restart wipes every containerlab veth. Use `vtysh -b` to apply the config instead - never restart FRR from an `exec:` block |
| A clab node has only `lo` and `eth0`; its other interfaces vanished | The container was restarted. containerlab builds every link but the management one as a veth into the container's netns, and a restart destroys it - the node comes back running and healthy-looking with no fabric connection, and the `exec:` block that addressed those links does not re-run. Redeploy (`--tags clabdeploy`), never `docker start` |
| BGP `Active`, never `Established`, and the node has its fabric address | The same underlay failure as the row below - the session cannot open a TCP connection to a neighbour it cannot ARP. Run `--tags clabverify` to check leaf1's address and the fabric bridge's ports before looking at any FRR configuration |
| Pod ping returns `Destination Host Unreachable` from the node subnet's `.2` | That address is `ovn-k8s-mpN` - the host, not OVN: the packet got through OVN and the node's kernel refused it. **Two causes give this identical symptom**, and one command tells them apart - on the pod's node, `ip route get <dst> vrf <tenant vrf>` (VRF names from `ip -br link show type vrf`). **`unreachable`**: no route in the tenant's VRF. Nothing on the fabric advertises that destination into the tenant's route target - under EVPN a tunnel is only ever built toward a VTEP some route names, so an address nobody advertises ends here. Expected for anything outside the tenant; for the internet, see *Reaching the internet from a UDN* above. **A route, via a next hop**: the kernel could not ARP it. Underlay problem: check the fabric NIC's address on the node, then `virbr1` on the lab host, then the bridge inside the clab VM - the BGP session will be down too, for the same reason |
| `tcpdump: executable file not found` inside a clab node | The FRR image does not ship tcpdump. Capture on `virbr1` on the lab host (or `br-fabric` in the clab VM) instead - all fabric traffic crosses it |
| Session up, `RouteAdvertisements` Accepted, no `route-advertisements-*` FRRConfiguration | `frrConfigurationSelector` matched zero or more than one FRRConfiguration |
| `RouteAdvertisements` not Accepted: "has no VRF matching the target VRF" | `targetVRF` was set to the string `default`. Unset means the default VRF; a value is matched literally against the routers' `vrf` field, and a default-VRF router has none. Only `auto` or unset are meaningful |
| `RouteAdvertisements` not Accepted, other reasons | Overlapping UDN subnets leaked into the default VRF, or two CRs selecting the same network |
| Session up, prefixes exchanged, pod ping still fails - and `tcpdump` shows the reply arriving on the fabric NIC but never on `ovn-k8s-mp0` | IP forwarding is off on the fabric NIC. OVN-Kubernetes enables it per interface (`br-ex`, `ovn-k8s-mpN`) and leaves `conf.all.forwarding` at 0, so a NIC it does not manage inherits 0. `ip route get <pod ip> from <leaf ip> iif <nic>` answering "No route to host" is the tell - that is EHOSTUNREACH, which the kernel returns only when forwarding is off, never for a missing route. The role sets `net.ipv4.ip_forward=1` on the workers with a Tuned profile - nmstate 2.2.60 rejects the per-device `ipv4.forwarding` field and rolls the whole policy back when it does |
| `authentication`/`console` Degraded with `lookup ... on 172.30.0.10:53: server misbehaving` after phase 1 | Advertising the cluster default pod network removed OVN's SNAT for **all** its egress, not just towards the fabric, so CoreDNS now queries the lab resolver from a pod IP nothing can route back to. Expected, not a fault. `oc delete ra default-podnetwork` restores it, `--tags shared` does it for you, or add return routes on the lab host - see `udn_bgp_advertise_default` |
| Everything green, pods still SNATed | The advertisement did not reach the node - check the generated FRRConfiguration, not the CR |
| VRF-Lite configured, no isolation | Cluster is in shared gateway mode. VRF-Lite needs `routingViaHost: true` |
| Tenant pods lose the network after an NNCP | A VRF policy was applied without the discovered `ovn-k8s-mpN` port restated. Re-render, do not hand-write |
| Small pings work, real traffic does not | MTU. Check the bridge, the taps, the node NIC, the VLAN subinterface and the FRR containers are all 9000 |
| Fabric dies as soon as Docker is installed | `br_netfilter` + Docker's `FORWARD DROP`. `iptables -I FORWARD 1 -i virbr1 -o virbr1 -j ACCEPT` |
| `FRRConfiguration` applied and ignored | Wrong namespace. It belongs in `openshift-frr-k8s` on OpenShift |
| VRF-Lite discovery fails with "missing a tenant VRF" | Either no tenant pod is running on that node yet (the VRF is created on demand), or OVN-Kubernetes names the VRF something other than the CUDN name in your release - the task above the failure lists what is actually there |

---

## The rest of this lab

| Document | What it covers |
| --- | --- |
| **[udn-bgp-evpn-steps.md](udn-bgp-evpn-steps.md)** | Build it step by step, branched by transport. Start here |
| **[bgp-evpn.md](bgp-evpn.md)** | The cluster side: every phase, every CR, packet walks, live migration |
| **[clab-fabric.md](clab-fabric.md)** | The fabric side: what containerlab builds, and the manual equivalent |
| **[troubleshooting.md](troubleshooting.md)** | Case files: hard faults, the traces that found them, and the wrong turns |
