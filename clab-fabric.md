# The containerlab fabric, under the hood

`roles/setup-clab-fabric` builds the "provider network" the cluster peers with.
This document says what it actually creates, why each piece is shaped that way,
and how to build the whole thing by hand.

Its companion on the cluster side is **[bgp-evpn.md](bgp-evpn.md)**. Together
they cover both ends of every session: this file stops at the wire, that one
starts there. To *build* the lab rather than understand it, follow
**[udn-bgp-evpn-steps.md](udn-bgp-evpn-steps.md)**.

## Contents

- [The one idea](#the-one-idea)
- [What exists after a fabric run](#what-exists-after-a-fabric-run)
- [Layer by layer, bottom up](#layer-by-layer-bottom-up)
  - [1. virbr1, the L2 domain](#1-virbr1-the-l2-domain)
  - [2. The node NICs](#2-the-node-nics)
  - [3. The containerlab VM and br-fabric](#3-the-containerlab-vm-and-br-fabric)
  - [4. containerlab itself](#4-containerlab-itself)
- [What each phase uses](#what-each-phase-uses)
  - [Phases 1-2: the default VRF](#phases-1-2-the-default-vrf)
  - [Phase 3: VRF-Lite](#phase-3-vrf-lite)
  - [Phase 4: EVPN](#phase-4-evpn)
- [The node side of the tunnel](#the-node-side-of-the-tunnel)
- [Building it by hand](#building-it-by-hand)
- [Verifying by hand](#verifying-by-hand)
- [Things that bite](#things-that-bite)

---

## The one idea

Everything else follows from this: **leaf1 and the OpenShift nodes share a
broadcast domain.**

The nodes get a second NIC on a new libvirt network (`virbr1`). leaf1 gets a
veth into the same bridge. They are layer-2 adjacent - no routing, no
tunnelling, no NAT between them. So the "provider edge router" is simply a
neighbour on a wire, and every BGP session in this lab is an ordinary session
between two directly-connected speakers.

That is why the lab is believable despite being three containers. Nothing about
the cluster's side is special-cased for a simulated fabric, because the fabric
is not simulated - it is FRR, doing real BGP, over a real bridge.

```
                    virbr0 (management, 192.168.122.0/24)
                    unchanged by any of this
   ┌──────────┬──────────┬──────────┬──────────┬──────────┐
   │ worker1  │ worker2  │ worker3  │   sno    │ clab VM  │
   └────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬─────┘
        │          │          │          │          │
        └──────────┴──────────┴──────────┴──────────┘
                     virbr1 (fabric, no IP, MTU 9000)
                     192.168.140.0/24 - static, everywhere
                                │
                     ┌──────────┴──────────┐
                     │  clab VM: br-fabric │   the guest bridge virbr1
                     │                     │   is extended into
                     │   leaf1 ─ spine ─ leaf2
                     │   (FRR containers)  │
                     └─────────────────────┘
```

`virbr1` carries **no IP address on the host**. The lab host is not on the
fabric, which is what keeps the provider network genuinely external.

---

## What exists after a fabric run

| Thing | Where | Created by |
| --- | --- | --- |
| `virbr1` / libvirt network `fabric` | lab host | `fabric-network.yml` |
| A second NIC per node, MAC `52:54:00:e2:55:<octet>` | each node VM | `node-nics.yml` |
| The `clab` VM (2 NICs: virbr0 + virbr1) | lab host | `clab-vm.yml` |
| Docker + containerlab `0.68.0` | clab VM | `clab-install.yml` |
| `br-fabric`, with the fabric NIC enslaved | clab VM | `clab-fabric-bridge.sh` |
| `/root/udn-bgp-fabric/` - topology + per-router `frr.conf` | clab VM | `clab-deploy.yml` |
| 5 or 7 containers | clab VM | `containerlab deploy` |
| `udn-bgp/.fabric-topology` marker | **controller** | `clab-deploy.yml` |

Containers, `bgp` topology:

```
clab-udnbgp-leaf1              the border leaf
clab-udnbgp-{blue,red,orange,green,purple}-ext    one endpoint per tenant
```

`evpn` adds `clab-udnbgp-spine` and `clab-udnbgp-leaf2`.

### Addressing, all of it

| Network | Prefix | leaf1 | nodes |
| --- | --- | --- | --- |
| Fabric, untagged | `192.168.140.0/24` | `.1` | their `ip_list` octet |
| Per-tenant VLAN 110-150 | `192.168.14N.0/24` | `.1` | same octet |
| Tenant external | `10.210-214.10.0/24` | `.1` | - (endpoint at `.10`) |
| Client segments, VLAN 210-250 | `10.215-219.10.0/24` | `.1` | client VM `.20`, netns `.21` |
| VTEP loopbacks (EVPN) | `100.64.0.0/24` | static /32s | `.<octet>` per node |
| Underlay p2p (EVPN) | `10.1.0.0/30`, `10.1.0.4/30` | - | - |
| Router loopbacks (EVPN) | leaf1 `10.0.0.1`, leaf2 `10.0.0.2`, spine `10.0.0.254` | | |

Every node's octet is the **same number** on every one of those networks - it is
`ip_list[<name>]`, the last octet of its management address. `worker1` is
`192.168.122.34`, `192.168.140.34`, `192.168.141.34` (blue), `100.64.0.34`
(VTEP). That is a deliberate convenience: one number identifies a node
everywhere, and a routing table can be read by eye.

ASNs: cluster `64512` (hub) / `64515` (sno), leaf1 `64513`, leaf2 `64514`,
spine `65000`. eBGP throughout.

---

## Layer by layer, bottom up

### 1. virbr1, the L2 domain

```xml
<network>
  <name>fabric</name>
  <bridge name='virbr1' stp='on' delay='0'/>
  <mtu size='9000'/>
</network>
```

Three deliberate absences, each load-bearing.

**No `<ip>`.** Not "no DHCP" - no address at all. libvirt starts a dnsmasq for
any network that has an IP, whether or not DHCP is configured, and a second
DHCP/DNS server on a bridge that three OpenShift nodes are plugged into is a
genuinely miserable afternoon. Every address on this fabric is static, set by
NMState on the cluster side and by the topology file on the fabric side.

**No `<forward>`.** `<forward mode='open'/>` is the better-looking choice - open
mode adds no firewall rules, where an isolated network can get
`-A FORWARD -i virbr1 -j REJECT`. But libvirt *requires* an IP for open mode:

```
XML error: open forwarding requested, but no IP address provided
```

So "open with no address" does not exist. Isolated wins, because the dnsmasq
problem is worse than the REJECT problem, and the REJECT problem mostly is not
one: libvirt builds those rules from the network's IP range, and there is no
range. The role prints whatever rules do reference the bridge, rather than
trusting the reasoning.

**MTU 9000.** The fabric carries Geneve (phases 1-3) or VXLAN (phase 4) wrapped
around pod traffic already at the cluster MTU. At 1500 the BGP sessions come up
perfectly and large flows silently black-hole.

> An existing network is **never redefined** - only started and set to
> autostart. Redefining tears down every tap already on it, which is every
> node's fabric NIC. A fabric built before `clab_fabric_mtu` was raised keeps
> the old MTU, and the role warns rather than fixing it.

### 2. The node NICs

```
virsh attach-interface worker1 --type network --source fabric \
  --model virtio --mac 52:54:00:e2:55:34 --live --config
```

The node keeps its virbr0 NIC, its address, its DHCP reservation and its default
route. This adds one unaddressed link into the fabric broadcast domain; NMState
configures it later, cluster-side.

The MAC scheme is `52:54:00:e2:55:<octet>` - the lab's usual `...:e2:54:<octet>`
with the fifth octet bumped. So a fabric NIC is recognisable at a glance, can
never collide with a virbr0 DHCP reservation, and - the reason it must be
deterministic - **the NMState policies match on it**.

`--live --config` hot-plugs *and* persists, but only works on a running domain;
a shut-off one takes `--config` alone. That split is the only reason this is two
Ansible tasks.

> A hot-plugged NIC appears instantly but is not named `enp2s0` until udev has
> processed it. Nothing depends on that having happened - the NMState policies
> match on MAC precisely so the ordering never matters.

### 3. The containerlab VM and br-fabric

containerlab's `bridge` kind attaches veths to an **existing Linux bridge**. The
guest has a NIC, not a bridge. So `clab-fabric-bridge.sh` creates `br-fabric`
and enslaves the fabric NIC to it, putting the FRR containers and the OCP nodes
in one L2 domain.

```bash
ip link add name br-fabric type bridge
ip link set br-fabric type bridge vlan_filtering 0
ip link set br-fabric mtu 9000 up
nmcli device set "$NIC" managed no
ip link set "$NIC" mtu 9000 up master br-fabric
```

Four details that are not arbitrary:

- **The NIC is found by MAC, never by name.** Names come from PCI enumeration
  and are not stable across a reboot or a re-attach. The MAC is assigned by this
  lab.
- **`vlan_filtering 0`.** The bridge must forward 802.1Q frames untouched for
  VRF-Lite's VLAN handoff. Turning it on needs a PVID/vid table per port and
  silently drops tagged traffic until one exists.
- **`nmcli device set managed no`.** Otherwise NetworkManager keeps trying DHCP
  on a NIC with no DHCP server, bouncing the carrier under the bridge.
- **The script fails rather than half-configuring.** A bridge with no uplink is
  the worst available outcome: leaf1 comes up, FRR is healthy, the topology
  deploys, and every node silently fails to ARP the leaf.

It runs from Ansible *and* from a systemd unit ordered `Before=docker.service`,
so a reboot cannot start containerlab before the bridge exists.

In `clab_deploy_mode: host` none of this applies - containerlab attaches to
`virbr1` directly and there is no guest bridge.

### 4. containerlab itself

`containerlab deploy --reconfigure` - `--reconfigure` because containerlab
refuses a lab of the same name that is already running, and without it a second
run fails on existing containers rather than picking up an edited topology.
That is the usual reason a config change "did not take".

The FRR image is `quay.io/frrouting/frr:10.2.1`, endpoints are `alpine:3.20`.
Each router gets three bind-mounted files: `frr.conf`, `daemons`, `vtysh.conf`.

The topology's `exec:` blocks build **kernel netdevs** - VRFs, VLAN
subinterfaces, VXLAN devices, bridges. FRR does not create those; it configures
routing *over* them. So the split is: `exec:` builds the plumbing, `frr.conf`
runs the protocols.

> **`vtysh -b`, never `frrinit.sh restart`.** FRR is PID 1 in these containers.
> Stopping it stops the container; Docker restarts it, and the restart destroys
> the network namespace along with every veth containerlab put in it. The node
> comes back running and healthy-looking, with `lo` and `eth0` and nothing else,
> permanently disconnected from the fabric - and `exec:` does not re-run on a
> restart, so it never repairs itself. `fabric-verify.yml` checks the restart
> count for exactly this reason.

---

## What each phase uses

The fabric is built **once** per topology and holds everything all phases need
simultaneously. A phase does not reconfigure the fabric; it decides which of
leaf1's several BGP contexts the cluster talks to.

### Phases 1-2: the default VRF

leaf1's plain `router bgp 64513` instance peers with every node over the
**untagged** fabric link, `192.168.140.0/24`.

```
router bgp 64513
 neighbor 192.168.140.34 remote-as 64512
 neighbor 192.168.140.35 remote-as 64512
 neighbor 192.168.140.36 remote-as 64512
```

Phase 1 carries the cluster's default pod network here. Phase 2 carries UDNs
leaked into the default VRF (`targetVRF: default`). Same session, different
prefixes.

The VLANs, VRFs and tenant endpoints all exist already and are simply unused.

> **Phase 2 cannot reach a tenant's external endpoint.** `blue-ext` lives in
> leaf1's `blue` VRF, and phase 2 is in the default VRF. Phase 2 is verified
> against leaf1's own fabric address and against other nodes' advertised pod
> subnets - not against `10.210.10.10`. This is stated in the rendered config as
> a comment, because it reads as a failure otherwise.

Two route-maps guard the session in both directions:

```
ip prefix-list LAB-MGMT seq 5 permit 192.168.122.0/24 le 32
route-map FROM-CLUSTER deny 5
 match ip address prefix-list LAB-MGMT
```

`192.168.122.0/24` must never cross the fabric. That is virbr0 - a node
preferring a BGP path to its own management network loses the API, the registry
and DNS at once.

> There is deliberately **no BFD**. It is two-ended, and FRR-K8s does not
> configure it for these neighbours. Configured on one side only, bgpd holds the
> peer administratively down and the cluster shows `Active` with `MsgSent`
> climbing and `MsgRcvd` at 0 - which reads exactly like a connectivity problem
> and is not one.

### Phase 3: VRF-Lite

Now the per-tenant contexts matter. For each tenant, the topology's `exec:`
block built:

```bash
ip link add blue type vrf table 1110        # 1000 + VLAN
ip link set blue up
ip link add link eth1 name eth1.110 type vlan id 110
ip link set eth1.110 master blue
ip addr add 192.168.141.1/24 dev eth1.110
ip link set blue-ext master blue            # the endpoint, in the VRF
ip addr add 10.210.10.1/24 dev blue-ext
```

The table id is `1000 + VLAN`, so it reads back as the VLAN and cannot collide
with the main tables.

And `frr.conf` runs a **separate BGP instance per VRF**:

```
router bgp 64513 vrf blue
 neighbor 192.168.141.34 remote-as 64512
 address-family ipv4 unicast
  network 10.210.10.0/24        # originate the tenant's external network
  network 10.215.10.0/24        # and its client segment
```

**There is no route leaking between them.** That is what makes the isolation
test meaningful: a blue pod reaching red's endpoint means something is wrong,
not permissive.

The client segments (VLAN 210-250) are extra subinterfaces in the same VRFs.
They are *off-segment* from the nodes deliberately - a client on the tenant's
own handoff VLAN would share a broadcast domain with the workers, leaf1 would
answer with an ICMP redirect, and "blue cannot reach red" would be proven by
802.1Q rather than by the VRF.

The client segment is **originated**, not left connected, so the cluster learns
the *return* path over BGP. Without that, pods can be reached from the client
but cannot answer - which looks like a one-way fabric fault.

> `udn_vrf_leaks` can deliberately import one VRF into another, both directions.
> Legal only where the two tenants' subnets are disjoint: a table holds one
> entry per destination, so leaking blue into red - both `10.200.0.0/16` - would
> be ambiguous rather than permissive.

### Phase 4: EVPN

The topology changes shape. `leaf1 ─ spine ─ leaf2`, and **leaf1's role gets
narrower, not wider.**

With the OCP nodes acting as VTEPs, leaf1 is not a tunnel endpoint for tenant
traffic at all. VXLAN flows **node ↔ leaf2 directly**. leaf1 holds no tenant
VRFs and provides exactly two things:

1. **Underlay reachability.** Static `/32`s to each node's VTEP, written from
   the same `ip_list` octets as everything else:
   ```bash
   ip route replace 100.64.0.34/32 via 192.168.140.34 dev eth1
   ip route replace blackhole 100.64.0.0/24     # so 'network' has something to originate
   ```
   Without this the EVPN sessions come up, both ends hold the right routes, and
   **no tunnel ever forms** - a control-plane-looks-fine, data-plane-dead
   failure.
2. **EVPN transit.** It peers `l2vpn evpn` with each node and with the spine.

The node sessions carry **both** address families on one adjacency - `ipv4
unicast` so the node learns its way to the other VTEPs, `l2vpn evpn` for tenant
routes. No new session; a second address family on the existing one.

**`bgp retain route-target all` on leaf1 and the spine.** Neither holds a tenant
VRF, and a speaker with no matching VRF discards every EVPN route whose route
target it does not import locally - which here is all of them. This is the
single most common way an EVPN lab ends up with healthy sessions and an empty
table on the far side.

The spine is deliberately dumb: route reflector for `l2vpn evpn`, no VTEP, no
VRFs, no VXLAN devices. `set ip next-hop unchanged` keeps the leaves tunnelling
to each other directly rather than through it.

leaf2 holds the tenants, in **two different shapes**:

**Layer3 → ipVRF / L3VNI, symmetric IRB.** The bridge is enslaved to the VRF and
carries no access port:

```bash
ip link add blue type vrf table 1110
ip link add vni101 type vxlan id 101 local 10.0.0.2 dstport 4789 nolearning
ip link add br101 type bridge
ip link set br101 master blue
ip link set vni101 master br101
ip link set vni101 type bridge_slave neigh_suppress on learning off
ip link set blue-ext master blue
ip addr add 10.210.10.1/24 dev blue-ext
```
```
vrf blue
 vni 101
router bgp 64514 vrf blue
 address-family l2vpn evpn
  advertise ipv4 unicast
  route-target import 65000:101
```

**Layer2 → macVRF / L2VNI.** No VRF, no SVI, nothing to originate:

```bash
ip link add vni400 type vxlan id 400 local 10.0.0.2 dstport 4789 nolearning
ip link add br400 type bridge
ip link set vni400 master br400
ip link set green-ext master br400       # a bridge port, not a VRF slave
```

A macVRF carries **MAC reachability, not prefixes**, so there is nothing to
route. `green-ext` is a host *inside* `10.204.0.0/16`, in the same broadcast
domain as the pods, reaching them by ARP resolved from type-2 routes.
`external_gw` and `external_prefix` go unused for this tenant.

> **Two VNI fields, and picking the wrong one is silent.** The cluster declares
> `macVRF: {vni: 400}` for a Layer2 tenant and `ipVRF: {vni: 101}` for a Layer3
> one. Building every tenant from `evpn_ip_vni` was the original bug here: the
> two ends instantiated different numbers, no tunnel ever formed, and the EVPN
> sessions were up with nothing to show for it.

> **An L2VNI's route target is auto-derived from the LOCAL AS.** Leave it
> implicit and leaf2 uses `64514:400` while the cluster exports `65000:400`. The
> type-2 routes are advertised and silently never imported. leaf2's config
> states both explicitly for that reason.

The tenant endpoints move **behind leaf2**, and that is the whole reason for a
three-node fabric. With them on leaf1, EVPN would be configured and never carry
anything, and every test would pass whether or not the overlay worked.

---

## The node side of the tunnel

Everything above is the fabric. This section is the other end, because the
first thing anyone does is look for the tunnel on a node and not find it.

### It is not in OVS, and it is not Geneve

Two different overlays run on these nodes, doing unrelated jobs:

| | Geneve | VXLAN |
| --- | --- | --- |
| Carries | pod traffic **between nodes of one cluster** | EVPN tenant traffic **off-cluster** |
| Endpoint | the node's InternalIP, `192.168.122.x` | the VTEP, `100.64.0.x` |
| Where | OVS tunnel ports, in `ovs-vsctl show` | a **kernel** netdev, not in OVS at all |

So `ovs-vsctl show` will never show a VTEP or a VXLAN port, and a Geneve
endpoint at `100.64.0.x` would never exist. On a single-node cluster it is
emptier still: Geneve ports are created per *remote* node, so a SNO has none at
all, and their absence says nothing about EVPN either way.

### What is actually there

The VTEP address is a kernel **dummy** interface placed by NMState:

```bash
$ oc debug node/sno --quiet -- chroot /host ip addr show vtep0
inet 100.64.0.20/32 scope global vtep0
```

OVN-Kubernetes discovers it and annotates the node:

```
k8s.ovn.org/vteps: '{"evpn-vtep":{"ips":["100.64.0.20"]}}'
```

And the tunnel itself is a kernel VXLAN device that OVN-Kubernetes creates:

```bash
$ oc debug node/sno --quiet -- chroot /host ip -d link show type vxlan
130: evx4-evpn-vtep: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
        master evbr-evpn-vtep
    vxlan id 0 local 100.64.0.20 srcport 0 0 dstport 4789 ttl auto
        external vnifilter nolearning
    bridge_slave ... learning off ... neigh_suppress on ... vlan_tunnel on
    alias ovn-k8s-ndm:vxlan:evx4-evpn-vtep
```

Read that line by line, because four things in it matter:

- **`alias ovn-k8s-ndm:...`** - the ovn-kubernetes *network device manager* built
  this. It is not an OVS port and never was.
- **`vxlan id 0 ... external vnifilter`** - one device for **every** VNI, not one
  per VNI. `external` means the VNI comes from per-packet metadata rather than
  being baked into the device, and `vnifilter` restricts which VNIs are accepted.
  This is the interesting asymmetry with the fabric: leaf2 builds a *separate*
  device per tenant (`vni400`, `vni101`, each with its own bridge), the node
  builds **one**. Both are ordinary Linux VXLAN, configured two different ways,
  and they interoperate without either end knowing.
- **`neigh_suppress on`, `learning off`** - ARP is answered from EVPN type-2
  routes rather than flooded, and MACs come from BGP rather than from data-plane
  learning. That is what makes it EVPN rather than plain multicast VXLAN.
- **`mtu 1400`** - conservative, and set by OVN-Kubernetes, not by this lab. The
  fabric is at 9000; the inner packets are capped well under it. Safe, but it
  does mean the jumbo fabric is not being used for what it could be.

### What the wire looks like

```bash
oc debug node/sno --quiet -- chroot /host \
  timeout 15 tcpdump -ni enp7s0 udp port 4789
```

Two distinct conversations show up on a working two-cluster fabric, and telling
them apart is the quickest way to read the state of the whole thing.

**Node to the far leaf** - a tenant reaching something behind `leaf2`:

```
IP 10.0.0.2.38207 > 100.64.0.20.vxlan: VXLAN, vni 400
  IP 10.204.255.30.37008 > 10.204.128.2.webcache: Flags [S]
IP 100.64.0.20.33045 > 10.0.0.2.vxlan: VXLAN, vni 400
  IP 10.204.128.2.webcache > 10.204.255.30.37008: Flags [S.]
```

Outer `leaf2 loopback ↔ node VTEP`. Inner `10.204.255.30` is green's client
namespace, an access port on the L2VNI - **in the pods' own subnet**, because a
macVRF carries MACs and there is nothing to route.

**Node to node, across clusters** - the stretched L2VNI doing its job:

```
IP 100.64.0.20.45144 > 100.64.0.36.vxlan: VXLAN, vni 400
  IP 10.204.128.0 > 10.204.0.9: ICMP echo request
IP 100.64.0.36.39715 > 100.64.0.20.vxlan: VXLAN, vni 400
  IP 10.204.0.9 > 10.204.128.0: ICMP echo reply
```

Outer `SNO VTEP ↔ hub worker VTEP` - **the far leaf is not in this path at
all**. Same VNI, different tunnel. And the ARP that set it up crosses the same
way:

```
IP 100.64.0.36.33289 > 100.64.0.20.vxlan: VXLAN, vni 400
  ARP, Request who-has 10.204.128.0 tell 10.204.0.9
IP 100.64.0.20.34899 > 100.64.0.36.vxlan: VXLAN, vni 400
  ARP, Reply 10.204.128.0 is-at 0a:58:0a:cc:80:00
```

`0a:58:0a:cc:80:00` is `0a:58` + `0a.cc.80.00` = `10.204.128.0`. That is the
MAC-derived-from-IP scheme, visible on the wire - and the reason two clusters
cannot both hold `10.204.0.1` without advertising the identical MAC from two
VTEPs.

> **One VNI per tenant, and the numbers are not decoration.** green is VNI 400
> and purple is VNI 500 in the same capture, from `evpn_mac_vni`. Both tenants'
> SNO pods sit on `10.204.128.2` - the same address in two different broadcast
> domains, kept apart by the VNI alone.

> **Regular SYN / SYN-ACK / RST every two seconds is not a fault.** That is the
> tenant ingress health-checking its backends: `server ... check` in
> `haproxy-tenants.cfg.j2`, default interval 2s. A plain TCP check does not
> complete the handshake - it resets instead of closing politely. Seeing it
> flow over the fabric, one conversation per tenant VNI, is a working ingress.

---

## Building it by hand

Equivalent to `--tags fabric`. Values are this lab's; substitute your own.

### On the lab host

```bash
# 1. the fabric network
cat > /tmp/fabric.xml <<'EOF'
<network>
  <name>fabric</name>
  <bridge name='virbr1' stp='on' delay='0'/>
  <mtu size='9000'/>
</network>
EOF
virsh net-define /tmp/fabric.xml
virsh net-start fabric
virsh net-autostart fabric
ip -o link show virbr1                      # mtu 9000

# 2. one fabric NIC per node - octet matches the node's management address
for n in worker1:34 worker2:35 worker3:36; do
  dom=hub_${n%:*}; oct=${n#*:}
  virsh attach-interface "$dom" --type network --source fabric \
    --model virtio --mac 52:54:00:e2:55:$oct --live --config
done
virsh domiflist hub_worker1                 # two NICs now

# 3. the containerlab VM: 2 NICs, virbr0 + virbr1
qemu-img create -f qcow2 /var/lib/libvirt/images/clab_disk.qcow2 60G
# ...virt-install with --network network:default,mac=52:54:00:e2:54:40
#                  and --network network:fabric,mac=52:54:00:e2:55:40
```

### Inside the clab VM

```bash
# 4. Docker and containerlab
dnf install -y iproute tcpdump iptables-nft git tar
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
curl -sL https://get.containerlab.dev | bash -s -- -v 0.68.0

# 5. extend virbr1 into the guest - find the NIC by MAC, not by name
NIC=$(ip -o link show | awk '/52:54:00:e2:55:40/ {gsub(":","",$2); print $2; exit}')
ip link add name br-fabric type bridge
ip link set br-fabric type bridge vlan_filtering 0
ip link set br-fabric mtu 9000 up
nmcli device set "$NIC" managed no
ip link set "$NIC" mtu 9000 up master br-fabric
ip -o link show "$NIC" | grep -o 'master [^ ]*'     # must say br-fabric

# 6. the topology and the FRR configs
mkdir -p /root/udn-bgp-fabric/{leaf1,spine,leaf2}
# write leaf1/frr.conf, leaf1/daemons, leaf1/vtysh.conf
#   (+ spine/ and leaf2/ for the EVPN topology)
# write udnbgp.clab.yml   - or udnbgp-evpn.clab.yml

# 7. deploy
cd /root/udn-bgp-fabric
containerlab deploy --reconfigure --topo udnbgp.clab.yml
```

The rendered files from your last run are on disk - read them rather than
retyping from this document:

```bash
ssh root@192.168.122.40 'cat /root/udn-bgp-fabric/udnbgp.clab.yml'
ssh root@192.168.122.40 'cat /root/udn-bgp-fabric/leaf1/frr.conf'
```

### The `daemons` file

FRR ships with everything off. This lab turns on exactly two: `zebra` and
`bgpd`, plus `vtysh_enable`. Nothing else - no `ospfd`, no `staticd`, and
notably **no `bfdd`** (see the BFD note above).

That is enough because the two things it might look short of are not daemons.
The static routes leaf1 needs to the VTEPs are installed with `ip route` in the
topology's `exec:` block, which is the kernel's table and not FRR's static
config. And VXLAN/EVPN needs no extra daemon at all - zebra handles the VNI and
FDB programming natively, learning the bridge/vxlan pairing from netlink.

---

## Verifying by hand

All of these run **on the clab VM** (`192.168.122.40`), or on the lab host in
`host` mode.

```bash
# every container, and how long it has been up
docker ps --format '{{.Names}}\t{{.Status}}'
```

> **Check the restart count, not just "Up".** A leaf that restarted has lost
> every veth containerlab gave it and is permanently off the fabric while
> looking perfectly healthy. `Up 3 minutes` on a fabric you deployed an hour ago
> is the tell.

```bash
# the bridge has a port per node, plus one per router
ip link show master br-fabric

# leaf1 got its fabric address
docker exec clab-udnbgp-leaf1 ip -br addr show eth1
# eth1  UP  192.168.140.1/24

# one VRF per tenant, table id = 1000 + VLAN
docker exec clab-udnbgp-leaf1 ip -d link show type vrf

# the VLAN subinterfaces, their VRF, and the handoff addresses
docker exec clab-udnbgp-leaf1 ip -br addr show | grep eth1\\.

# sessions. DOWN is correct before the cluster side exists.
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp summary'
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp vrf blue summary'

# the endpoint is addressed and has a way back
docker exec clab-udnbgp-blue-ext ip -br addr show eth1
docker exec clab-udnbgp-blue-ext ip route show
# default via 10.210.10.1 dev eth1
```

EVPN topology only:

```bash
# underlay FIRST. Sessions can be up with no tunnel.
docker exec clab-udnbgp-leaf1 vtysh -c 'show ip route 100.64.0.0/24 longer-prefixes'
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp l2vpn evpn summary'

# the VNIs leaf2 instantiated, and their route targets
docker exec clab-udnbgp-leaf2 vtysh -c 'show evpn vni'
docker exec clab-udnbgp-leaf2 vtysh -c 'show bgp l2vpn evpn vni'

# type-2 MACs on an L2VNI, and which VTEP each sits behind
docker exec clab-udnbgp-leaf2 vtysh -c 'show evpn mac vni 400'

# the tunnels that actually exist
docker exec clab-udnbgp-leaf2 bridge fdb show | grep dst
```

`fabric-verify.yml` automates all of the above and fails with a specific
message; re-run it alone against a live fabric with `--tags clabverify`.

---

## Things that bite

| Symptom | Cause |
| --- | --- |
| Leaf healthy, every node fails to ARP it | `br-fabric` exists with no uplink. The script now fails instead |
| Leaf `Up 2 minutes` on an old fabric, fabric dead | FRR is PID 1; a restart destroyed the veths and `exec:` does not re-run. Never `frrinit.sh restart` |
| Sessions up, correct routes, nothing forwards | Missing `bgp retain route-target all` on leaf1/spine, **or** no underlay route to the VTEPs |
| EVPN sessions up, no tunnel, empty table far side | The two ends instantiated different VNIs - `evpn_mac_vni` vs `evpn_ip_vni` |
| Type-2 routes advertised, never imported | L2VNI route target auto-derived from the local AS; state it explicitly |
| Tagged traffic silently dropped | `vlan_filtering` turned on with no vid table |
| Sessions come up, large flows black-hole | MTU 1500 somewhere. The bridge, the taps, the guests and the containers all need 9000 |
| Cluster shows `Active`, `MsgRcvd` 0, `Last write never` | BFD configured on one side only |
| Node loses the API the moment BGP comes up | `192.168.122.0/24` crossed the fabric. That is what `LAB-MGMT` prevents |
| A second run "did not take" | `containerlab deploy` without `--reconfigure` |
| `--tags fabric` built client VMs and ran the tenant ingress | A tag on a PLAY is added to every task in it, so `tags: [fabric]` on the play matched the whole thing. Removed; the role's own tags decide now |
| `--tags fabric` failed in `nsproxy.yml` with `no udn-web pod` | Same cause. Correct failure - `--tags web` had not been run - from a task that should never have been running |
| `Destination directory .../udn-bgp does not exist` | The role writes its output there but never created it - masked for as long as `setup-udn-bgp` created it and nothing removed it. `cleanup.yaml --tags udnlab` removes it, so a clean tree found it |
| `--tags network` / `nodenics` / `clabvm` ran nothing | `include_tasks` needs `apply:` to pass tags. Fixed, but the pattern recurs |
| Client namespaces got phase-3 shapes on an EVPN fabric | `clab_topology` defaults to `bgp`. The `.fabric-topology` marker now catches it |
| Phase 2 cannot reach `10.210.10.10` | Correct. That endpoint is in leaf1's `blue` VRF; phase 2 is in the default VRF |
| No VTEP or tunnel in `ovs-vsctl show` | Correct. The VTEP is a kernel dummy and the VXLAN is a kernel netdev; neither is an OVS port |
| No Geneve endpoint at `100.64.0.x` | Geneve is the intra-cluster overlay on `192.168.122.x`. EVPN is VXLAN. On a SNO there are no Geneve ports at all |
| SYN / SYN-ACK / RST every 2s on the fabric | The tenant ingress health check (`server ... check`). A TCP check resets rather than closing |

---

## Which file does what

| Layer | File |
| --- | --- |
| `virbr1` | `tasks/fabric-network.yml`, `templates/fabric-network.xml.j2` |
| Node NICs | `tasks/node-nics.yml` |
| clab VM | `tasks/clab-vm.yml` |
| Docker, containerlab, `br-fabric` | `tasks/clab-install.yml`, `templates/clab-fabric-bridge.sh.j2` |
| Topology + deploy | `tasks/clab-deploy.yml` |
| Topology, phases 1-3 | `templates/udnbgp.clab.yml.j2` |
| Topology, phase 4 | `templates/udnbgp-evpn.clab.yml.j2` |
| leaf1 routing | `templates/leaf1-frr.conf.j2`, `templates/leaf1-frr-evpn.conf.j2` |
| spine / leaf2 routing | `templates/spine-frr.conf.j2`, `templates/leaf2-frr.conf.j2` |
| Post-deploy checks | `tasks/fabric-verify.yml` |
| Client VMs, namespaces, ingress | `tasks/client-*.yml`, `tasks/nsclient-*.yml`, `tasks/nsproxy.yml` |

Every template carries a `{# ... #}` header explaining its own decisions - they
are the primary source, and this document is the map.
