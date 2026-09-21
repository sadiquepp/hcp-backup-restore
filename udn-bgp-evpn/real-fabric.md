# UDN over EVPN on a real fabric - the OpenShift side

Everything else in this directory builds a fabric out of three FRR containers
so there is something to peer with. This document assumes the opposite: the
fabric is real, the network team has already configured it for **blue, red,
orange, green and purple**, and the only question left is what to do on the
cluster.

It is written from the same role this repo automates
(`roles/setup-udn-bgp`), with the lab-specific scaffolding removed and the
places where a real fabric legitimately differs called out. Where a choice
only makes sense on a simulated fabric, it says so and gives the real answer
instead.

> **Scope, stated honestly.** This repo has only ever been run against the
> containerlab fabric. The cluster-side objects below are exactly what it
> applies and are exercised on every run; the *differences* flagged for real
> hardware are reasoned from the APIs and from the lab's own constraints, not
> from a production deployment. Items that need validating on real kit are
> marked **[verify on site]**.

> **`ClusterUserDefinedNetwork`, never `cudn`.** The short name does not work
> reliably against this API. Every `oc` line below spells it out.

---

## Contents

- [1. Who does what](#1-who-does-what)
- [2. The contract with the network team](#2-the-contract-with-the-network-team)
  - [2.1 Per tenant](#21-per-tenant)
  - [2.2 Per fabric](#22-per-fabric)
  - [2.3 Two things people forget](#23-two-things-people-forget)
- [3. Cluster prerequisites](#3-cluster-prerequisites)
- [4. Cluster network configuration](#4-cluster-network-configuration)
- [5. The node's fabric interface](#5-the-nodes-fabric-interface)
  - [5.1 If the uplink already exists](#51-if-the-uplink-already-exists)
  - [5.2 If you are adding one](#52-if-you-are-adding-one)
  - [5.3 IP forwarding](#53-ip-forwarding)
- [6. The VTEP](#6-the-vtep)
- [7. BGP peering](#7-bgp-peering)
- [8. The five networks](#8-the-five-networks)
  - [8.1 Layer3 tenants: blue, red, orange](#81-layer3-tenants-blue-red-orange)
  - [8.2 Layer2 tenants: green and purple](#82-layer2-tenants-green-and-purple)
  - [8.3 Namespaces](#83-namespaces)
- [9. Advertise them](#9-advertise-them)
- [10. Verify, in this order](#10-verify-in-this-order)
- [11. The failures that look like success](#11-the-failures-that-look-like-success)
- [12. What from this repo still applies](#12-what-from-this-repo-still-applies)

---

## 1. Who does what

| | Fabric (network team) | Cluster (you) |
|---|---|---|
| **Underlay** | Reachability between every node and its leaf, and a route to the VTEP block from every leaf | An address on each node's fabric interface, and that interface forwarding |
| **BGP** | A session per node, right ASN, both address families activated | `FRRConfiguration` naming the leaf, both AFs, `allowAsIn: origin` |
| **VTEP** | A route to the whole VTEP block; VXLAN decap | The `VTEP` CR, and an address per node inside its CIDRs |
| **Tenants** | VNI per tenant, route targets, VRF or bridge domain per tenant, external gateway for Layer3 | `ClusterUserDefinedNetwork` per tenant carrying the same VNI and RT |
| **Advertising** | Import what the cluster sends, export what the cluster needs | `RouteAdvertisements` selecting the networks and the FRR config |

The dividing line is the BGP session. Everything above it the fabric decides
and the cluster must match; everything below it the cluster decides and the
fabric must accept. **A VNI or a route target that disagrees across that line
produces a tunnel that forms and carries nothing**, with both ends reporting
health.

---

## 2. The contract with the network team

Agree these before applying anything. The table is the deliverable - fill in
the right-hand columns with the network team and keep it, because every value
in it appears in a manifest below and a mismatch is silent.

### 2.1 Per tenant

The repo's own values for the five tenants, as a starting point:

| Tenant | Topology | EVPN type | VNI | Route target | Subnet | Per-node subnet |
|---|---|---|---|---|---|---|
| blue | Layer3 | `ipVRF` | 101 | `65000:101` | `10.200.0.0/16` | `/24` |
| red | Layer3 | `ipVRF` | 201 | `65000:201` | `10.200.0.0/16` | `/24` |
| orange | Layer3 | `ipVRF` | 301 | `65000:301` | `10.202.0.0/16` | `/24` |
| green | Layer2 | `macVRF` | 400 | `65000:400` | `10.204.0.0/16` | n/a |
| purple | Layer2 | `macVRF` | 500 | `65000:500` | `10.204.0.0/16` | n/a |

Three things in that table are load-bearing and worth saying out loud to the
network team:

**blue and red deliberately share `10.200.0.0/16`.** That is the point of
per-tenant VRFs - two tenants carrying the same addresses in isolation. The
fabric must therefore hold them in **separate VRFs with separate route
targets**; a fabric that leaks both into one table gets two paths for one
prefix and non-deterministic forwarding. orange overlaps with nothing and is
the control: a route to `10.202.0.0/16` means exactly one thing.

**green and purple share `10.204.0.0/16` as well**, but they are Layer2, so
the fabric holds them as two **bridge domains**, not VRFs. Same addresses,
different VNIs, no routing between them.

**Layer2 means the tenant's default gateway is not in the cluster.** A
`macVRF` tenant is a stretched broadcast domain; anything that routes out of
it sits on the fabric, inside the tenant's subnet. The network team owns that
address and you must exclude it from cluster IPAM - see
[2.3](#23-two-things-people-forget).

### 2.2 Per fabric

| Item | Repo's value | Yours | Notes |
|---|---|---|---|
| Cluster ASN | 64512 | | One per cluster. Two clusters sharing an ASN is a silent failure. |
| Leaf ASN | 64513 | | Whatever the leaf the nodes peer with uses. |
| RT administrator field | 65000 | | The `<x>:<vni>` left-hand side. Must be identical on both sides. |
| Node fabric subnet | `192.168.140.0/24` | | The nodes' addresses on the leaf. |
| VTEP block | `100.64.0.0/24` | | Must not collide with anything else. See [6](#6-the-vtep). |
| Underlay MTU | 9000 | | VXLAN adds 50 bytes to every frame. Must exceed pod MTU + 50 end to end. |
| BGP timers | hold 9s / keepalive 3s | | Aggressive; a real fabric usually wants its own. |
| TCP-MD5 | optional, off by default | | If on, **both ends or neither** - see [11](#11-the-failures-that-look-like-success). |

### 2.3 Two things people forget

**The Layer2 external endpoint must be excluded from cluster IPAM.** green's
and purple's gateways live inside `10.204.0.0/16` on the fabric side of the
tunnel. OVN-Kubernetes knows nothing about them and will happily hand the
same address to a pod - two machines on one address in one broadcast domain.
That is a duplicate-address bug, not the deliberate overlap this design is
about. Get the addresses from the network team and put them in the CUDN's
reserved-subnets field.

**Two clusters on one stretched Layer2 network need the prefix split.** Each
cluster's IPAM allocates from the subnet knowing nothing about the other, so
both hand out the low addresses and two pods end up on one address. There is
no cross-cluster IPAM to lean on. Carve the prefix per cluster and express it
as reserved subnets on each - cluster A reserves B's half and vice versa.
Skip this entirely if only one cluster is on the VNI.

> **The reserved-subnets field is named differently across releases.** It is
> `excludeSubnets` on some topologies and something else on `layer2`, and
> getting it wrong is silent: Kubernetes prunes a field the CRD does not
> declare with no error, no warning and no event, so your manifest and the
> live object disagree and nothing says so. Ask the API which name it wants
> before writing it:
>
> ```bash
> oc explain clusteruserdefinednetwork.spec.network.layer2 | grep -iE 'exclude|reserved'
> ```
>
> Then read the applied object back and confirm the field survived.

---

## 3. Cluster prerequisites

```bash
# 4.19+ for RouteAdvertisements; EVPN transport needs 4.21+ (VTEP CRD) and is
# most usable on 4.22.
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'

# The NMState operator, if you will be configuring node interfaces from the
# cluster. Not needed if the uplink is already in place - see 5.1.
oc get csv -n openshift-nmstate | grep nmstate
oc get nmstate cluster
```

OVN-Kubernetes must be the network plugin. This does not work on
OpenShiftSDN, and it does not work with a third-party CNI.

---

## 4. Cluster network configuration

Four settings, and they are best applied as **one patch** so the cluster pays
for one ovnkube-node rollout rather than four:

```bash
oc patch network.operator.openshift.io cluster --type=merge -p '{
  "spec": {
    "additionalRoutingCapabilities": { "providers": ["FRR"] },
    "defaultNetwork": {
      "ovnKubernetesConfig": {
        "routeAdvertisements": "Enabled",
        "gatewayConfig": {
          "routingViaHost": true,
          "ipForwarding": "Global"
        }
      }
    }
  }
}'
```

What each one is for:

| Setting | Why |
|---|---|
| `additionalRoutingCapabilities: [FRR]` | Deploys frr-k8s, which is what actually holds the BGP sessions. `routeAdvertisements` cannot be enabled without it, so this has to be in the same patch. |
| `routeAdvertisements: Enabled` | Installs the `RouteAdvertisements` CRD and the controller that turns a CR into generated FRR config. |
| `routingViaHost: true` | **Local gateway mode. VRF-Lite and EVPN are only implemented in it.** In shared gateway mode the CRs are accepted and quietly do nothing. |
| `ipForwarding: Global` | Under the default `Restricted`, ovnkube-node holds `net.ipv4.ip_forward` at 0 and forwards only across `br-ex` and `ovn-k8s-mpN`. Your fabric interface is neither, so replies from the fabric are dropped in the routing decision with every control-plane signal green. |

Then wait for it properly - `Progressing` has to go **True before False**, or
you are not waiting at all:

```bash
oc wait clusteroperator/network --for=condition=Progressing=True  --timeout=60s || true
oc wait clusteroperator/network --for=condition=Progressing=False --timeout=900s
oc wait clusteroperator/network --for=condition=Available=True    --timeout=900s
```

Confirm the CRDs arrived:

```bash
oc get crd routeadvertisements.k8s.ovn.org vteps.k8s.ovn.org
```

And confirm frr-k8s is actually **ready on every node**, not merely that the
DaemonSet exists:

```bash
oc get daemonset frr-k8s -n openshift-frr-k8s \
  -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}{"\n"}'
```

A node without an frr-k8s pod has nothing listening on TCP/179. The leaf sits
in `Connect` forever, nothing logs, and that node's pods are unreachable over
the fabric while the cluster stays green.

---

## 5. The node's fabric interface

### 5.1 If the uplink already exists

On most real deployments the nodes are already cabled to the fabric and
addressed - a bond, a VLAN sub-interface, or just `br-ex` itself. Then there
is **nothing to create**. Check what you have:

```bash
oc get nodes -o name | while read -r n; do
  echo "== $n"; oc debug "$n" --quiet -- chroot /host ip -br addr show 2>/dev/null
done
```

You need, per node: an address the leaf can reach, and forwarding on that
interface ([5.3](#53-ip-forwarding)). Skip to [6](#6-the-vtep).

### 5.2 If you are adding one

A second NIC dedicated to the fabric is the conservative choice on a live
cluster, because nothing routes out of it until BGP puts something there. One
`NodeNetworkConfigurationPolicy` per node:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: fabric-worker1
spec:
  nodeSelector:
    kubernetes.io/hostname: worker1
  capture:
    # Match on MAC, not on name: interface names depend on PCI enumeration.
    fabric-nic: interfaces.mac-address=="52:54:00:E2:55:22"
  desiredState:
    interfaces:
      - name: "{{ capture.fabric-nic.interfaces.0.name }}"
        type: ethernet
        state: up
        mtu: 9000
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 192.168.140.34
              prefix-length: 24
        ipv6:
          enabled: false
```

Note what it does **not** do: no gateway, no DNS, no default route, no routes
at all. The node keeps reaching everything it currently reaches by its
existing path. That is the property that makes this safe to apply to a
working cluster, and it is worth preserving.

```bash
oc get nncp
oc wait nncp/fabric-worker1 --for=condition=Available --timeout=300s
```

### 5.3 IP forwarding

Traffic from the fabric to a pod arrives on this interface and has to be
forwarded to `ovn-k8s-mpN`. With forwarding off the kernel drops it in the
routing decision, leaving **nothing on the wire** - the reply is visible on
the NIC with `tcpdump` and never appears on `mp0` - while every control-plane
signal stays green. The one direct piece of evidence:

```bash
ip route get <pod ip> from <fabric subnet gateway> iif <nic>
RTNETLINK answers: No route to host
```

`EHOSTUNREACH`, which the kernel substitutes only when forwarding is off on
the incoming interface. A missing route gives `ENETUNREACH`, "Network is
unreachable" - different message, different problem.

`ipForwarding: Global` in [section 4](#4-cluster-network-configuration) is
what fixes this properly, because OVN-Kubernetes then sets
`net.ipv4.ip_forward=1` itself and stops reverting it. Check it landed:

```bash
for n in $(oc get nodes -o name); do
  echo -n "$n: "
  oc debug "$n" --quiet -- chroot /host sysctl -n net.ipv4.ip_forward
done
```

> **Do not solve this with a Tuned profile alone.** The Node Tuning Operator
> runs tuned in `no_daemon` mode - it applies the profile once and exits, so
> nothing re-asserts the value afterwards. Its `Profile` CR still reports
> `Applied=True`, which is a receipt for one past write, not a statement
> about the node now. Anything that writes `ip_forward` later wins
> permanently. This repo learned that the hard way, with three identically
> configured workers reading 1, 0 and 0.

---

## 6. The VTEP

The VTEP CR tells OVN-Kubernetes which addresses are tunnel endpoints. The
fabric uses them as the next hop for every EVPN route, so **the underlay must
route to the whole block from every leaf**.

**On a real fabric use `Managed`.** The lab uses `Unmanaged` because its
fabric is three FRR containers with no IGP, so something has to hand the leaf
a static route per VTEP, and `Unmanaged` lets the cluster put a known address
on a known node. A real underlay has a route to the block already, and then
`Managed` is simpler - OVN-Kubernetes allocates one address per node and you
create no per-node policies at all.

```yaml
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  cidrs:
    - 100.64.0.0/24
  mode: Managed
```

Four constraints worth knowing before you pick the block:

1. **It must exist nowhere else.** Not the node subnet, not any tenant
   prefix, not the cluster network. A VTEP address that collides with a real
   one produces tunnels that form and then deliver to the wrong place.
2. **Exactly one address per node may fall inside the CIDRs.** If a node has
   two, the CR goes to a failed status rather than picking one. Before
   widening the block, check nothing already on the nodes is inside it.
3. **`cidrs` is append-only in `Managed` mode** - entries cannot be removed,
   reordered or narrowed afterwards, only widened or appended to. Size it
   with room to grow. **[verify on site]**
4. **Every node needs an address, including masters**, even though no tenant
   pod runs on one. A single unannotated node fails the whole CR with
   `reason: AllocationFailed`.

Check it took:

```bash
oc get vtep evpn-vtep -o yaml | tail -20
oc get nodes -o custom-columns='NODE:.metadata.name,VTEP:.metadata.annotations.k8s\.ovn\.org/vteps'
```

The annotation key is `k8s.ovn.org/vteps`. (Not `node-vtep-ips`, which reads
as empty on every node and looks exactly like a failure.)

---

## 7. BGP peering

One `FRRConfiguration` for the session, carrying **both** address families:

```yaml
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: fabric-peering-evpn
  namespace: openshift-frr-k8s
  labels:
    routeAdvertisements: fabric-evpn
spec:
  bgp:
    routers:
      - asn: 64512                      # this cluster
        neighbors:
          - address: 192.168.140.1      # the leaf
            asn: 64513
            addressFamilies:
              - unicast
              - evpn
            allowAsIn: origin
            holdTime: 9s
            keepaliveTime: 3s
            port: 179
            toReceive:
              allowed:
                mode: all
            toAdvertise:
              allowed:
                prefixes:
                  - 100.64.0.0/24
        prefixes:
          - 100.64.0.0/24
  nodeSelector: {}
```

Why each part:

- **`unicast` as well as `evpn`.** The unicast family is the underlay: it is
  how a node learns a route to the *other* VTEPs. Without it the EVPN session
  comes up, routes appear on both sides, and no tunnel ever forms because
  neither end can reach the other's endpoint. That failure looks exactly like
  a data-plane problem and is not one. If your underlay already provides
  those routes by IGP, you may not need the cluster to advertise its VTEP
  prefix - but the node still needs a route to the remote VTEPs from
  somewhere. **[verify on site]**
- **`allowAsIn: origin`** - required, not optional, whenever a route comes
  back having already traversed the cluster's ASN. Without it each end drops
  the other's routes as a loop.
- **`nodeSelector: {}`** applies it to every node. Every node that peers needs
  it; a node the CR does not select simply never peers, and nothing says so.
- **Do not hand-write VNIs, route distinguishers or route targets here.**
  OVN-Kubernetes generates a second, additive `FRRConfiguration` from each
  CUDN's `evpn` block and the `RouteAdvertisements` CR. Two sources for one
  VNI is how you get a tunnel that forms and carries nothing.

If the fabric requires TCP-MD5, create the secret first - a neighbor whose
`passwordSecret` names a Secret that does not exist does not come up:

```bash
oc create secret generic fabric-key -n openshift-frr-k8s \
  --type=kubernetes.io/basic-auth --from-literal=password='<key>'
```

```yaml
            passwordSecret:
              name: fabric-key
              namespace: openshift-frr-k8s
```

`password` and `passwordSecret` are mutually exclusive; the Secret must be
`kubernetes.io/basic-auth` with the key `password`, in the frr-k8s namespace.

---

## 8. The five networks

### 8.1 Layer3 tenants: blue, red, orange

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: blue
  labels:
    bgp: "enabled"          # what RouteAdvertisements selects on
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: blue
  network:
    topology: Layer3
    layer3:
      role: Primary
      subnets:
        - cidr: 10.200.0.0/16
          hostSubnet: 24
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      ipVRF:
        vni: 101
        routeTarget: "65000:101"
```

Repeat for **red** (`10.200.0.0/16`, VNI 201) and **orange**
(`10.202.0.0/16`, VNI 301). blue and red intentionally carry the same subnet;
their isolation comes from the VRF, which is the property worth testing.

`ipVRF` is required for Layer3 and rejected for Layer2. A Layer3 network is a
set of routed prefixes, so what EVPN carries for it is **type-5** routes.

### 8.2 Layer2 tenants: green and purple

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: green
  labels:
    bgp: "enabled"
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: green
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets:
        - 10.204.0.0/16
      # The field name comes from the cluster - check it first, see 2.3.
      # Everything the cluster must NOT allocate: the fabric-side gateway,
      # and any other cluster's half of the prefix.
      reservedSubnets:
        - 10.204.255.10/32      # green's gateway, on the fabric
        - 10.204.128.0/17       # the other cluster's half, if there is one
      ipam:
        lifecycle: Persistent
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF:
        vni: 400
        routeTarget: "65000:400"
```

Repeat for **purple** (VNI 500, its own gateway address).

`macVRF` is required for Layer2 and rejected for Layer3. A Layer2 network is
a broadcast domain, so what EVPN carries is MAC reachability - **type-2**
routes on an L2VNI, preceded by **type-3** (IMET) routes that build the
ingress-replication flood list. Type-3 comes first: it is what lets ARP cross
the fabric, which is what produces the first type-2.

This is also the combination that makes a live migration invisible to
anything outside the cluster - the MAC moves, a type-2 follows it, and the
fabric reprograms.

> `ipam.lifecycle: Persistent` keeps a pod's address across restarts. On a
> stretched Layer2 network that matters more than usual, because the address
> is what the rest of the broadcast domain has in its ARP tables.

### 8.3 Namespaces

The `namespaceSelector` is what attaches a namespace to a network, and it is
matched **at namespace creation**. Label first, then create workloads:

```bash
for t in blue red orange green purple; do
  oc create namespace "$t" --dry-run=client -o yaml | oc apply -f -
  oc label namespace "$t" "udn-tenant=$t" --overwrite
done
```

Then confirm each network was realised into a NetworkAttachmentDefinition -
the CUDN being accepted is not the same as it existing:

```bash
oc get ClusterUserDefinedNetwork -o custom-columns=\
'NAME:.metadata.name,TRANSPORT:.spec.network.transport,TOPOLOGY:.spec.network.topology'
oc get net-attach-def -A
```

---

## 9. Advertise them

One CR covers all five, by selecting the label they share:

```yaml
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: udn-evpn
spec:
  targetVRF: auto
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            bgp: "enabled"
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      routeAdvertisements: fabric-evpn
  advertisements:
    - PodNetwork
```

- **`targetVRF: auto`** keeps each tenant in its own VRF. Setting it to the
  string `default` leaks every tenant into one table and destroys the
  isolation; leaving it unset does the same.
- **`frrConfigurationSelector` must match exactly one** `FRRConfiguration`.
  Matching more than one is a common cause of `Accepted=False`.

```bash
oc get routeadvertisements -o wide
```

`Accepted` is what to look for, and one that is not accepted says why in
`.status.conditions`. The usual causes: `targetVRF` set to `default`,
overlapping subnets leaked into the default VRF, two CRs selecting the same
network, and a selector matching several FRRConfigurations.

---

## 10. Verify, in this order

The order matters. Each step is meaningless if the one above it failed, and
checking them out of order is how a control-plane problem gets diagnosed as a
data-plane one.

**1. The session exists.** On the leaf, every node should be `Established`.
From the cluster side:

```bash
oc get frrnodestate -o wide
oc get frrnodestate <node> -o jsonpath='{.status.runningConfig}' | grep neighbor
```

`frrnodestate` shows the config actually loaded on each node and whether the
last reload succeeded - which is how you catch a cluster-wide CR that applied
unevenly.

**2. The underlay works.** Each node must have a route to the other VTEPs. If
it does not, everything below will form and carry nothing.

**3. Forwarding is on.** Per [5.3](#53-ip-forwarding). Everything above this
is control plane and stays green while it is broken.

**4. The routes are there.** On the fabric, per tenant VNI: type-5 for blue,
red and orange; type-2 and type-3 for green and purple.

**5. The tunnel carries traffic.** Pod to pod inside one tenant, across
nodes. Then pod to something on the fabric side of the same tenant.

**6. Isolation holds.** blue must not reach red, despite sharing a subnet.
This is the test that says the VRFs are real, and it is the one that fails
when `targetVRF` is wrong.

For 5 and 6 the scripts in `scripts/` work against any fabric - they only
talk to the clusters:

```bash
scripts/udn-reachability.sh          # the matrix, by ping
scripts/udn-vrf-isolation.sh         # isolation, with AMBIG where ping cannot tell
scripts/udn-xcluster-curl.sh <kubeconfig> <kubeconfig>   # pod to pod across clusters
```

`udn-xcluster-curl.sh` is worth singling out: it curls rather than pings
precisely because green and purple can hold the *same address*, and a page
can name its own tenant where ICMP cannot.

---

## 11. The failures that look like success

Every one of these was hit for real building the lab this document comes
from. They share a shape: a green control plane over a broken data path.

| Symptom | Cause | How to tell |
|---|---|---|
| BGP `Established`, routes both sides, no traffic | No route to the remote VTEP - the unicast AF is missing or the underlay does not carry the block | `ip route get <remote vtep>` on the node |
| Replies visible on the fabric NIC with `tcpdump`, never on `mp0` | Forwarding off on that interface | `ip route get <pod> from <gw> iif <nic>` → `No route to host` |
| CRs accepted, nothing happens at all | Shared gateway mode. VRF-Lite and EVPN are only implemented with `routingViaHost: true` | `oc get network.operator cluster -o jsonpath='{...gatewayConfig.routingViaHost}'` |
| Tenants can reach each other despite separate VRFs | `targetVRF` set to `default` or unset | `oc get routeadvertisements -o yaml` |
| Tunnel forms, carries nothing | VNI or route target disagrees across the BGP session | Compare the CUDN's `evpn` block against the fabric's VRF config, by hand |
| One node's pods unreachable, everything green | No frr-k8s pod there, or its session never came up | `oc get daemonset frr-k8s -n openshift-frr-k8s -o wide`, then the leaf's neighbor state |
| Session stuck in `Connect`, 0 messages either way, ping fine | TCP-MD5 on one end only. The signature is in the TCP header, so ICMP is unaffected and the kernel discards before BGP sees anything - silently, at both ends | Compare the leaf's `password` line against `frrnodestate`; both ends or neither |
| A field you applied is simply absent from the live object | The CRD does not declare it. Kubernetes prunes unknown fields with no error, no warning and no event | Read the object back and diff it against what you applied |
| Two pods in different clusters share an address | No prefix split on a stretched Layer2 network | See [2.3](#23-two-things-people-forget) |
| A sysctl you set reverts later | Something wrote the global knob. `ip_forward` and `conf.all.forwarding` are the same value, and a write to it propagates to **every** interface | Report `all=` alongside the per-interface value |

The general lesson, if there is one: **check that a thing is true, not that
you asked for it to be true.** A CR is accepted long before it works, a
DaemonSet existing is not a pod running, and `Applied=True` can be a receipt
for a write that something else has since undone.

---

## 12. What from this repo still applies

| Still useful | Skip |
|---|---|
| `roles/setup-udn-bgp` - everything in [4](#4-cluster-network-configuration) to [9](#9-advertise-them) is what it applies | `roles/setup-clab-fabric` - it builds the simulated fabric |
| `scripts/udn-reachability.sh`, `udn-vrf-isolation.sh`, `udn-xcluster-curl.sh`, `udn-snapshot.sh` - they only talk to clusters | `scripts/udn-web-demo.sh --proxy` - the tenant ingress lives on the lab's client VM |
| The tenant table in `vars.yaml` - subnets, VNIs and route targets in one place | `clab_*` variables, the VLAN numbers (VRF-Lite only), `build-lab.sh` steps 1-3 |
| [bgp-evpn.md](bgp-evpn.md) - the packet walkthroughs are fabric-independent | [clab-fabric.md](clab-fabric.md) - how the simulated fabric is built |
| [README.md](README.md) - the design notes and troubleshooting table | |

To drive a real fabric with this repo's automation, the cluster half runs on
its own:

```bash
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml \
  --tags evpn -e udn_bgp_cluster=<cluster>
```

You would need to replace the `clab_*` values with your fabric's, and the
per-node VTEP policies disappear entirely if you use `Managed` mode per
[6](#6-the-vtep).
