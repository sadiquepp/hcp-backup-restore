# UDN over BGP, VRF-Lite and EVPN — the manual walkthrough

This is `roles/setup-udn-bgp` taken apart into the commands it runs, in the
order it runs them, with the manifests it renders shown filled in rather than
as templates. Run it by hand to understand the mechanism, to debug a phase
that failed, or to reproduce the lab on a cluster this repo does not manage.

Everything here is `oc` against one cluster. The fabric side — containerlab,
libvirt, the bridges — is summarised in [Part 0](#part-0-the-fabric-side) and
not broken down; it is a lab-specific convenience, and the cluster does not
know or care how the router on the other end of the wire was built.

The playbook equivalent of this document is:

```bash
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags <phase>
```

where `<phase>` is `preflight`, `default`, `shared`, `vrflite` or `evpn`.

---

## Contents

- [How this maps to the playbook](#how-this-maps-to-the-playbook)
- [The values used throughout](#the-values-used-throughout)
- [Part 0: the fabric side](#part-0-the-fabric-side)
  - [Verifying the fabric by hand](#verifying-the-fabric-by-hand)
- [Part 1: preflight](#part-1-preflight)
- [Part 2: enable the feature](#part-2-enable-the-feature)
- [Part 3: resolve the node names](#part-3-resolve-the-node-names)
- [Part 4: install NMState](#part-4-install-nmstate)
- [Part 5: address the fabric NICs](#part-5-address-the-fabric-nics)
- [Part 6: the base BGP peering](#part-6-the-base-bgp-peering)
- [Phase 1: advertise the default pod network](#phase-1-advertise-the-default-pod-network)
  - [Following one packet](#following-one-packet)
  - [Seeing it yourself](#seeing-it-yourself)
- [Phase 2: UDNs in the default VRF](#phase-2-udns-in-the-default-vrf)
  - [What phase 2 can and cannot reach](#what-phase-2-can-and-cannot-reach)
  - [Reaching a UDN pod from outside the cluster](#reaching-a-udn-pod-from-outside-the-cluster)
  - [The Layer2 tenant gets ECMP](#the-layer2-tenant-gets-ecmp-and-the-layer3-tenants-cannot)
  - [Snapshot phase 2 before moving on](#snapshot-phase-2-before-moving-on)
  - [Following one packet in phase 2](#following-one-packet-in-phase-2)
  - [Why the two directions differ](#why-the-two-directions-differ)
  - [Is this how it works in production?](#is-this-how-it-works-in-production)
- [Phase 3: VRF-Lite](#phase-3-vrf-lite)
- [Phase 4: EVPN](#phase-4-evpn)
- [Live migration on the Layer2 tenant](#live-migration-on-the-layer2-tenant)
- [Teardown](#teardown)
- [Which file does what](#which-file-does-what)

---

## How this maps to the playbook

The phases are **cumulative**, and each one removes an entire class of
explanation for a failure in the next. `--tags shared` does not just apply the
CUDNs - it runs everything `--tags default` does first, so by the time a UDN is
involved, plain BGP is already proven.

Every phase is tagged `never` as well as its own name, so running the playbook
without `--tags` builds nothing. A phase has to be asked for.

| `--tags` | Sections of this document it performs | Changes the cluster? |
| --- | --- | --- |
| `fabric` | [Part 0](#part-0-the-fabric-side) | No - libvirt and the clab VM only |
| `preflight` | [Part 1](#part-1-preflight) | No |
| `default` | Parts [1](#part-1-preflight)-[6](#part-6-the-base-bgp-peering) + [Phase 1](#phase-1-advertise-the-default-pod-network) | Yes |
| `shared` | the above + [Phase 2](#phase-2-udns-in-the-default-vrf) | Yes |
| `vrflite` | the above + [Phase 3](#phase-3-vrf-lite) | Yes |
| `evpn` | the above + [Phase 4](#phase-4-evpn) | Yes |

Parts 2-6 are idempotent: a later phase re-runs them rather than assuming an
earlier one was run. So `--tags vrflite` on a fresh cluster is a complete
build, and on a cluster already at phase 2 it is just the delta.

Two phases also **undo** the one before them, because the objects contend:
phase 3 deletes phase 2's `RouteAdvertisements`, and phase 4 deletes phase 3's
advertisement, VLAN policies and per-VRF peering. Two `RouteAdvertisements`
selecting the same network leaves neither accepted, so this is not tidiness.

Each section below opens with the command that automates it.

---

## The values used throughout

Every manifest below is shown with this lab's numbers substituted. They come
from `vars.yaml`; change them there, not here.

| What | Value | Variable |
| --- | --- | --- |
| Management network (virbr0) | `192.168.122.0/24` | `lab_network_prefix` |
| Fabric network (virbr1) | `192.168.140.0/24`, MTU 9000 | `clab_fabric_prefix`, `clab_fabric_mtu` |
| Border leaf (leaf1) | `192.168.140.1` | `clab_fabric_router_octet` |
| Cluster ASN | `64512` | `clab_cluster_asn` |
| leaf1 ASN | `64513` | `clab_leaf1_asn` |
| Fabric nodes | worker1 `.34`, worker2 `.35`, worker3 `.36` | `clab_fabric_nodes`, `ip_list` |
| Fabric NIC MACs | `52:54:00:e2:55:<octet>` | `clab_fabric_mac_prefix` |
| FRR-K8s namespace | `openshift-frr-k8s` | `udn_bgp_frrk8s_namespace` |

The last one is worth committing to memory. Upstream OVN-Kubernetes examples
put `FRRConfiguration` in `metallb-system` because upstream installs FRR-K8s
through MetalLB. On OpenShift the Cluster Network Operator owns it and it
lives in `openshift-frr-k8s`. An `FRRConfiguration` in the wrong namespace is
accepted and silently never read.

### The four tenants

| | blue | red | orange | green |
| --- | --- | --- | --- | --- |
| Topology | Layer3 | Layer3 | Layer3 | **Layer2** |
| VLAN (phase 3) | 110 | 120 | 130 | 140 |
| VRF handoff subnet (phase 3) | `192.168.141.0/24` | `192.168.142.0/24` | `192.168.143.0/24` | `192.168.144.0/24` |
| UDN subnet, phase 2 | `10.220.0.0/16` | `10.221.0.0/16` | `10.222.0.0/16` | `10.223.0.0/16` |
| UDN subnet, phases 3–4 | `10.200.0.0/16` | `10.200.0.0/16` | `10.202.0.0/16` | `10.204.0.0/16` |
| External network behind leaf1 | `10.210.10.0/24` | `10.211.10.0/24` | `10.212.10.0/24` | `10.213.10.0/24` |
| External test host | `10.210.10.10` | `10.211.10.10` | `10.212.10.10` | `10.213.10.10` |
| EVPN VNI (phase 4) | ipVRF 101 | ipVRF 201 | ipVRF 301 | **macVRF 400** |

**blue and red are identical on purpose** from phase 3 on. Two UDNs carrying
the same addresses in isolation is most of the point of VRF-Lite, and it is
the one result a phase-2 setup cannot fake.

**orange is the control.** It overlaps with nothing, in any phase. That
matters because "blue cannot reach red's network" has two possible
explanations — the VRF, or the fact that they share a subnet and the routing
is simply ambiguous. "blue cannot reach *orange's* network" has only one.
Take that as the isolation result, and blue-vs-red as the overlap result.

**green is Layer2**, and the only tenant a VM belongs on. Layer3 slices its
subnet per node, so a workload that moves node necessarily changes address.
Layer2 is one flat broadcast domain across every node, so an address stays
valid wherever the workload runs — which is the whole requirement for live
migration. See
[Live migration on the Layer2 tenant](#live-migration-on-the-layer2-tenant).

green differs on the wire too: every node advertises its whole prefix, so the
leaf sees one prefix with several paths rather than a distinct per-node prefix
from each — and it installs all of them, giving green three-way ECMP into the
cluster that the Layer3 tenants cannot have. See
[The Layer2 tenant gets ECMP](#the-layer2-tenant-gets-ecmp-and-the-layer3-tenants-cannot).
And under EVPN it takes a **macVRF** — an L2VNI carrying MAC reachability —
where the Layer3 tenants take an ipVRF carrying prefixes.

Phase 2 uses a distinct subnet for all four: that phase leaks every UDN into
the one default VRF, where a prefix cannot belong to two networks.

---

## Part 0: the fabric side

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags fabric
> ```
> Role: `roles/setup-clab-fabric` (all of it)
>
> Not broken down in this document - see the summary below. Add `-e clab_topology=evpn` to build the leaf/spine/leaf fabric phase 4 wants.

`roles/setup-clab-fabric` builds the thing the cluster peers with. In one
pass it:

1. Defines a libvirt network `fabric` — an isolated bridge `virbr1`, MTU 9000,
   deliberately with **no IP and no forwarding**, so no dnsmasq is started on
   a bridge three OpenShift nodes sit on.
2. Hot-plugs a second NIC onto each worker VM (`virsh attach-interface`),
   with a deterministic MAC `52:54:00:e2:55:<ip_list octet>`. The MAC is the
   contract: everything downstream finds the interface by MAC, never by name.
3. Builds a small RHEL VM (`clab`, `192.168.122.40`) with two NICs — one on
   virbr0 for management, one on virbr1 — registers it with
   subscription-manager, and installs Docker and containerlab on it.
4. Extends virbr1 into that VM: the fabric NIC is enslaved to an in-guest
   bridge `br-fabric` with `vlan_filtering 0`, so 802.1Q frames pass through
   untouched. A systemd unit rebuilds this after a reboot.
5. Renders and deploys a containerlab topology onto `br-fabric`: **leaf1**
   (FRR) holding `192.168.140.1`, a VRF + VLAN subinterface per tenant, and
   one Alpine container per tenant as its "customer" endpoint behind leaf1.
   The EVPN topology adds a spine and a second leaf.
6. Verifies the result — leaf1 holds its address, has not restarted, the
   bridge has both the uplink and the veth, and leaf1 is peering with every
   node.

From the cluster's point of view the whole of that is: *there is a BGP router
at `192.168.140.1` in AS 64513, reachable at layer 2 from every worker's
second NIC, and behind it live `10.210.10.0/24` and `10.211.10.0/24`.*

Nothing below depends on containerlab specifically. Point the same manifests
at any BGP router on the same L2 segment and they work unchanged.

### Verifying the fabric by hand

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags clabverify
> ```
> Role: `roles/setup-clab-fabric/tasks/fabric-verify.yml`
>
> Runs every check below and fails with what was missing. Safe to re-run at
> any time — it changes nothing.

**The fabric is topology-agnostic.** Layer2 vs Layer3 is a property of the
CUDN, decided inside the cluster; leaf1 hands every tenant a VLAN into a VRF
the same way regardless. So on the fabric side **green must look identical to
orange**. If it doesn't, the topology did not deploy fully — that is the point
of looking.

Run these on the **clab VM** (`192.168.122.40`), not on the lab host.

```bash
# One leaf plus one endpoint per tenant: 5 containers for the default
# topology, 7 for evpn (which adds spine and leaf2).
docker ps --format '{{.Names}}\t{{.Status}}'
```

Expect `clab-udnbgp-leaf1` and `clab-udnbgp-{blue,red,orange,green}-ext`, all
`Up`, and — this is the one worth reading — **none of them with a restart in
the status**. A restarted container has lost every veth containerlab gave it
and will never repair itself.

```bash
# One VRF per tenant. Table id is 1000+VLAN, so it reads back as the VLAN.
docker exec clab-udnbgp-leaf1 ip -d link show type vrf | grep -E '^[0-9]+:|table'
```

```bash
# The VLAN subinterfaces, their VRF, and the handoff addresses
docker exec clab-udnbgp-leaf1 ip -br link show | grep 'eth1\.'
docker exec clab-udnbgp-leaf1 ip -br addr show | grep '192\.168\.14'
```

Four rows each, and green is indistinguishable from the rest:

| Tenant | VRF (table) | Subinterface | Handoff address | External side |
| --- | --- | --- | --- | --- |
| blue | `blue` (1110) | `eth1.110` | `192.168.141.1/24` | `10.210.10.1/24` |
| red | `red` (1120) | `eth1.120` | `192.168.142.1/24` | `10.211.10.1/24` |
| orange | `orange` (1130) | `eth1.130` | `192.168.143.1/24` | `10.212.10.1/24` |
| green | `green` (1140) | `eth1.140` | `192.168.144.1/24` | `10.213.10.1/24` |

The external legs are veths down to the tenant containers, and they are in
the tenant VRF too:

```bash
docker exec clab-udnbgp-leaf1 ip -br addr show | grep -- '-ext'
docker exec clab-udnbgp-leaf1 ip -br link show | grep -- '-ext'   # master <tenant>
```

Then each endpoint itself. **These containers are `alpine:3.20`, so `ip` is
BusyBox** — it accepts only `-f` and `-o`, and `-br` gets you the usage
message rather than an error you would recognise as one:

```bash
for t in blue red orange green; do
  printf '%-7s ' "$t"
  docker exec clab-udnbgp-$t-ext ip -o addr show eth1 | grep -o 'inet [0-9.]*'
done
```

```
blue    inet 10.210.10.10
red     inet 10.211.10.10
orange  inet 10.212.10.10
green   inet 10.213.10.10
```

Each also needs its default route back through the leaf, or the pod-side
tests later will look like a fabric failure when they are really a return-path
failure:

```bash
docker exec clab-udnbgp-green-ext ip route show
# default via 10.213.10.1 dev eth1
```

Finally, FRR. One BGP instance per VRF, plus the default one:

```bash
docker exec clab-udnbgp-leaf1 vtysh -c 'show running-config' | grep -E 'router bgp|^ vrf'
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp vrf all summary' | grep -E 'VRF|Neighbor|^192'
```

Nothing is peering yet if the cluster side has not been built — `Active` or
`Idle` against the node addresses is the correct state at the end of
`--tags fabric`. What matters here is that the **instances exist**: a tenant
with no `router bgp ... vrf <tenant>` will silently never advertise anything
in phase 3, and the failure will look like a cluster problem.

#### What this cannot tell you

Nothing above distinguishes green's Layer2-ness, because nothing on the
fabric depends on it — in phases 2 and 3 a Layer2 CUDN hands its prefix over
the same VLAN into the same VRF as a Layer3 one. The only fabric-visible
difference arrives in phase 4, where green takes a **macVRF** (L2VNI 400)
rather than an ipVRF. Until then, "green looks exactly like orange" *is* the
pass condition.

The Layer2 behaviour that actually matters is verified from the cluster side:
one flat subnet with no `hostSubnet` slicing, and an address that survives a
move between nodes. See
[Live migration on the Layer2 tenant](#live-migration-on-the-layer2-tenant).

---

## Part 1: preflight

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags preflight
> ```
> Role: `tasks/preflight.yml`
>
> The only phase that changes nothing. Every other phase runs it first.

Read-only. Establishes what the cluster can do, and deliberately does **not**
check for the feature CRDs — those are installed by Part 2, so their absence
before it says nothing.

```bash
export KUBECONFIG=/path/to/hub/auth/kubeconfig

oc get clusterversion version -o jsonpath='{.status.desired.version}'; echo
oc get network.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.type}'; echo
```

Two hard requirements:

- **4.19 or later** for BGP route advertisements. **4.22 or later** for EVPN
  on primary CUDNs — the `VTEP` API and the CUDN `network.transport` /
  `network.evpn` fields do not exist before it.
- `defaultNetwork.type` must be `OVNKubernetes`.

Then, for information only:

```bash
# Present already? Then someone has run Part 2 before.
oc get crd routeadvertisements.k8s.ovn.org vteps.k8s.ovn.org --ignore-not-found

# NMState — Part 4 installs it if this is missing
oc get crd nodenetworkconfigurationpolicies.nmstate.io

# Is anything else already running FRR-K8s?
oc get daemonset -A | grep -i frr-k8s

# Gateway mode: false/empty means shared gateway, the default
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}'; echo
```

Phases 1 and 2 work in either gateway mode. **Phases 3 and 4 require local
gateway mode** (`routingViaHost: true`) — an OVN-Kubernetes restriction, not a
lab one.

On MetalLB: this lab runs it in L2 mode for the hosted clusters' API VIPs, so
it is not competing for BGP sessions. If you later switch a MetalLB pool to
BGP mode, point it at the CNO's FRR-K8s in `openshift-frr-k8s` rather than
letting the MetalLB operator stand up a second instance.

---

## Part 2: enable the feature

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default
> ```
> Role: `tasks/enable.yml`
>
> Re-run by **every** phase from `default` on, and idempotent - so running a later phase does this again rather than assuming it was done.

One merge patch turns on both the FRR routing-capability provider and route
advertisements. It has to be one patch: route advertisements cannot be
`Enabled` unless FRR is already an available provider, so two patches fail on
the first.

```bash
oc patch network.operator.openshift.io cluster --type=merge -p '{
  "spec": {
    "additionalRoutingCapabilities": { "providers": ["FRR"] },
    "defaultNetwork": {
      "ovnKubernetesConfig": { "routeAdvertisements": "Enabled" }
    }
  }
}'
```

Local gateway mode is a **separate** patch, because it is a second full
`ovnkube-node` rollout and it changes how all pod egress leaves the node —
not something to do silently on the way to a phase that may not need it.
Required for phases 3 and 4:

```bash
oc patch network.operator.openshift.io cluster --type=merge -p '{
  "spec": {
    "defaultNetwork": {
      "ovnKubernetesConfig": { "gatewayConfig": { "routingViaHost": true } }
    }
  }
}'
```

Both restart every `ovnkube-node` pod. Wait for them:

```bash
oc wait clusteroperator/network --for=condition=Progressing=False --timeout=900s
oc wait clusteroperator/network --for=condition=Available=True --timeout=900s
```

Now check the CRDs — **here** their absence is a real failure, because this
patch is what installs them:

```bash
oc get crd routeadvertisements.k8s.ovn.org      # required
oc get crd vteps.k8s.ovn.org                    # 4.22+, needed for phase 4 only
oc get daemonset frr-k8s -n openshift-frr-k8s -o wide
```

If the CRD never appears:

```bash
oc get network.operator.openshift.io cluster -o yaml | grep -A3 additionalRoutingCapabilities
oc get co network
oc -n openshift-network-operator logs deploy/network-operator --tail=50
```

---

## Part 3: resolve the node names

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default
> ```
> Role: `tasks/node-names.yml`
>
> Re-run by **every** phase from `default` on, and idempotent - so running a later phase does this again rather than assuming it was done.

Not optional, and not cosmetic. Every `NodeNetworkConfigurationPolicy` below
selects its node by `kubernetes.io/hostname`, and the only name that works is
the one the cluster actually registered — which is whatever the host sent as
its hostname at install time. `worker1` and `worker1.hub.mylab.com` are both
plausible and only one is right.

Getting it wrong does not produce an error. nmstate accepts a policy whose
`nodeSelector` matches nothing and quietly does nothing with it:

```
NAME                      STATUS    REASON
fabric-untagged-worker1   Ignored   NoMatchingNode
```

`oc wait --for=condition=Available` **passes** on that. So the run reports
success with no interface configured anywhere, and every later phase fails
for reasons that look unrelated.

Resolve it from the address instead. The node's address on virbr0 is a fact
this repo owns — `ip_list` sets it through a DHCP reservation keyed on a MAC
the repo also assigns — and the node name is just whatever the cluster
attached to it:

```bash
oc get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[?\(@.type==\"InternalIP\"\)].address
```

Match `192.168.122.34` → the name for `worker1`, `.35` → worker2, `.36` →
worker3. Use those names everywhere below.

---

## Part 4: install NMState

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default
> ```
> Role: `tasks/nmstate.yml`, `templates/nmstate-*.yaml.j2`
>
> Re-run by **every** phase from `default` on, and idempotent - so running a later phase does this again rather than assuming it was done.

Skip if `oc get crd nodenetworkconfigurationpolicies.nmstate.io` already
succeeds.

```bash
cat <<'EOF' | oc apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nmstate
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nmstate
  namespace: openshift-nmstate
spec:
  targetNamespaces:
    - openshift-nmstate
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubernetes-nmstate-operator
  namespace: openshift-nmstate
spec:
  channel: stable
  name: kubernetes-nmstate-operator
  installPlanApproval: Automatic
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

On a disconnected hub, `source` must be the mirrored catalog.

Wait for the operator's CRDs, then create the **instance**. Installing the
operator without it is worse than not installing it at all: `oc apply` of an
NNCP would succeed and nothing would ever reconcile it.

```bash
oc get crd nmstates.nmstate.io     # retry until present

cat <<'EOF' | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF

oc -n openshift-nmstate rollout status daemonset/nmstate-handler --timeout=600s
oc get crd nodenetworkconfigurationpolicies.nmstate.io
```

If the operator never installs, the usual cause is the subscription failing to
resolve against the catalog:

```bash
oc -n openshift-nmstate get subscription,csv,installplan
oc -n openshift-nmstate get subscription kubernetes-nmstate-operator -o jsonpath='{.status.conditions}'
```

---

## Part 5: address the fabric NICs

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default
> ```
> Role: `tasks/main.yml`, `templates/nncp-fabric-untagged.yaml.j2`
>
> Re-run by **every** phase from `default` on, and idempotent - so running a later phase does this again rather than assuming it was done.

One policy per node. Matched on **MAC**, not interface name: the NIC is
hot-plugged, so its name depends on PCI enumeration order and on whether the
node was running at the time. NMState's `capture` syntax resolves one to the
other at apply time, which is why there is a policy per node rather than one
for all of them.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: fabric-untagged-worker1
spec:
  nodeSelector:
    kubernetes.io/hostname: worker1
  capture:
    fabric-nic: interfaces.mac-address=="52:54:00:E2:55:34"
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
EOF
```

Repeat for worker2 (`...:35`, `192.168.140.35`) and worker3 (`...:36`,
`192.168.140.36`). The MAC must be uppercase — that is how nmstate reports it.

### Forwarding: the step that is not in the NNCP

Before or alongside these policies, the fabric nodes need IP forwarding, and
it is not optional — it is the return path.
OVN-Kubernetes turns IP forwarding on **per interface** — `br-ex` and
`ovn-k8s-mpN` — and leaves `net.ipv4.conf.all.forwarding` at 0, so any
interface it does not know about inherits `conf.default.forwarding`, also 0,
and silently refuses to forward. A reply from the fabric to a pod arrives on
this NIC and has to reach `ovn-k8s-mpN`; without this the kernel drops it in
the routing decision, leaving no trace — the reply is visible here with
`tcpdump` and never appears on `mp0`. The only direct evidence is:

```
# ip route get 10.129.2.55 from 192.168.140.1 iif enp8s0
RTNETLINK answers: No route to host
```

`EHOSTUNREACH`, which the kernel substitutes **only** when forwarding is off
on the incoming interface. A genuinely missing route gives `ENETUNREACH`,
"Network is unreachable".

nmstate grew a per-device `ipv4.forwarding` in 2.2.51, but the build shipped
with the 4.22 NMState operator (2.2.60) rejects it — `unknown field
'forwarding'` — and rolls the **whole policy** back when it does, taking the
NIC's address with it. So it goes in a Tuned profile instead:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: udn-bgp-fabric-forwarding
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
    - name: udn-bgp-fabric-forwarding
      data: |
        [main]
        summary=Forward between the UDN/BGP fabric NIC and the OVN management port
        include=openshift-node

        [sysctl]
        net.ipv4.ip_forward=1
  recommend:
    - priority: 20
      profile: udn-bgp-fabric-forwarding
      match:
        - label: node-role.kubernetes.io/worker
EOF
```

Three things in there are deliberate:

- **`include=openshift-node`.** The Node Tuning Operator applies *one* profile
  per node. A profile that does not inherit the base one replaces it, silently
  dropping OpenShift's own tuning.
- **`priority: 20`.** Lower wins; the built-in `openshift-node` profile is 30.
- **The global knob rather than `conf.<nic>.forwarding`** — the opposite of
  the usual advice, for one reason: a per-interface sysctl has to name the
  interface, and this NIC is hot-plugged, so its name comes from PCI
  enumeration and is not guaranteed stable. A Tuned profile naming an
  interface that no longer exists applies cleanly and does nothing, which is
  exactly the silent failure being fixed here. `net.ipv4.ip_forward` cannot
  miss: it is the same knob as `conf.all.forwarding`, and writing it
  propagates to every interface present and sets the default every later one
  inherits. The cost is forwarding on for every interface on those nodes.

Note what this policy does **not** do: no gateway, no DNS, no default route,
no auto-dns, no routes at all. The node keeps reaching everything it currently
reaches through virbr0 and `192.168.122.1`. The only thing that will ever send
traffic out this interface is a route learned over BGP. That is the property
that makes it safe to apply to a working cluster.

The MTU must match the bridge and the FRR containers. A mismatch is the
classic "BGP is up but nothing works": small packets pass, full-size ones
vanish.

```bash
oc get nncp
# Available / SuccessfullyConfigured. "Ignored / NoMatchingNode" means Part 3
# was wrong - fix the name, do not proceed.

oc debug node/worker1 -- chroot /host ip -br addr show | grep 192.168.140
oc debug node/worker1 -- chroot /host ping -c3 192.168.140.1

# forwarding actually took - 1, not 0
oc debug node/worker1 -- chroot /host sysctl net.ipv4.conf.enp8s0.forwarding
```

That ping is the underlay. If it fails, nothing below can work and the cause
is on the fabric side, not in OVN-Kubernetes.

---

## Part 6: the base BGP peering

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default
> ```
> Role: `tasks/main.yml`, `templates/frrconfiguration-default.yaml.j2`
>
> Re-run by **every** phase from `default` on, and idempotent - so running a later phase does this again rather than assuming it was done.

The `FRRConfiguration` an admin writes. OVN-Kubernetes does not replace it:
when a `RouteAdvertisements` CR selects it, OVN-Kubernetes reads the peering
out of it and **generates a second, additive** `FRRConfiguration` carrying the
prefixes to advertise. Both exist; the generated one is named
`route-advertisements-*` and should not be edited.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: fabric-peering-default
  namespace: openshift-frr-k8s
  labels:
    routeAdvertisements: fabric-default
spec:
  bgp:
    routers:
      - asn: 64512
        neighbors:
          - address: 192.168.140.1
            asn: 64513
            holdTime: 9s
            keepaliveTime: 3s
            port: 179
            toReceive:
              allowed:
                mode: all
            toAdvertise:
              allowed:
                mode: filtered
  nodeSelector: {}
EOF
```

Four things in there are load-bearing:

- **`toReceive: mode: all`** is what makes the fabric's prefixes usable inside
  the cluster. FRR-K8s installs received routes into the node's kernel routing
  table, so a route to a tenant's external network learned here becomes a real
  route on the node. This is the mechanism that replaces the "point the UDN's
  default gateway at the router" idea — the pods' gateway never moves, the
  node simply learns where the fabric's prefixes are.
- **`toAdvertise: mode: filtered`** with no prefixes of our own. Everything
  this session advertises comes from the generated CR. `all` would advertise
  the node's own connected routes, `192.168.122.0/24` included — a node
  preferring a BGP path to its own management network loses the API, the
  registry and DNS at once.
- **`nodeSelector: {}` must stay empty.** Narrowing it to the three workers
  that actually have a fabric NIC looks tidier and breaks phases 3 and 4:
  with `targetVRF: auto`, OVN-Kubernetes checks *per node* that the selected
  FRRConfigurations cover every selected network active on it, and a Layer3
  CUDN is active on the masters too. The price is that the masters hold a BGP
  session they can never establish. That is expected here.
- The **label** is specific rather than something like `app=frr` because
  `RouteAdvertisements` errors out if its `frrConfigurationSelector` matches
  more than one FRRConfiguration.

```bash
oc get frrconfiguration -n openshift-frr-k8s
oc -n openshift-frr-k8s exec ds/frr-k8s -c frr -- vtysh -c 'show bgp summary'
```

Expect `Established`. Sessions on the masters will not establish — see above.

---

## Phase 1: advertise the default pod network

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default
> ```
> Role: `templates/routeadvertisements-default.yaml.j2`, `tasks/wait-ra.yml`
>
> `--tags default` runs Parts 1-6 and then this. It is the whole of phase 1.

No UDN involved. Worth doing first because it is the one phase where a failure
is unambiguously about BGP.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default-podnetwork
spec:
  networkSelectors:
    - networkSelectionType: DefaultNetwork
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      routeAdvertisements: fabric-default
  advertisements:
    - PodNetwork
EOF
```

**`targetVRF` is deliberately absent, and absent is not the same as
`default`.** An empty `targetVRF` means "advertise in the default VRF". A
non-empty one is matched *literally* against the `vrf` field of the routers in
the selected FRRConfiguration — and a router in the default VRF has no `vrf`
field at all; it is unnamed, not named `default`. Writing `targetVRF: default`
makes OVN-Kubernetes hunt for a `router bgp 64512 vrf default` that cannot
exist, and reject the CR:

```
Not Accepted: configuration error: FRRConfiguration "fabric-peering-default"
selected for node "master1" has no VRF matching the RouteAdvertisements
target VRF or any selected network
```

`auto` is the only other meaningful value.

`advertisements: [PodNetwork]` means "the pod subnets of the networks this CR
selects". The enum has exactly two values, `PodNetwork` and `EgressIP`; there
is no "advertise nothing". Here the selected network is the default one, so it
means the cluster pod network. In phases 2–4 the identical line means the
tenant UDN subnets.

`nodeSelector` must be empty whenever `PodNetwork` is advertised — the CRD
enforces it, because a pod can be scheduled anywhere and a partial
advertisement is a black hole.

### Confirm it took

Applying a `RouteAdvertisements` **always succeeds**. Whether OVN-Kubernetes
can act on it is decided afterwards and reported only in status, so a script
that applies and moves on passes while advertising nothing.

```bash
oc get ra
# NAME                 STATUS
# default-podnetwork   Accepted

oc get routeadvertisements default-podnetwork -o jsonpath='{.status.status}'; echo
```

Then check the generated object and the prefixes:

```bash
oc get frrconfiguration -n openshift-frr-k8s
# expect a route-advertisements-* object alongside yours

docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp ipv4 unicast'
# expect ONE PREFIX PER NODE, each with that node's 192.168.140.x as next hop
```

One prefix per node, not one blanket route, is the check most likely to look
fine in summary output and be wrong.

### What this costs, and why phase 1 is not a resting state

Removing the SNAT is the point — and it is **not scoped to the fabric**. It
applies to all egress from the advertised network. For the cluster default
network that is every pod in the cluster, OpenShift's own included, which now
reaches `192.168.122.0/24` with its pod IP. Nothing there has a route back.

The first casualty is DNS. CoreDNS forwards `*.apps` and external names to the
lab's resolver, gets no answer, and returns SERVFAIL:

```
authentication  False  False  True   OAuthServerRouteEndpointAccessibleControllerAvailable:
  ... lookup oauth-openshift.apps.hub.mylab.com on 172.30.0.10:53: server misbehaving
console         False  False  True   RouteHealthAvailable: failed to GET route ...
ingress         True   False  True   CanaryChecksRepetitiveFailures ...
```

That is phase 1 working exactly as designed. The cluster is not broken; it
just cannot be answered. Two ways to have both:

- **Add return routes on the lab host**, one per node, and keep the
  advertisement:

  ```bash
  oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/node-subnets}{"\n"}{end}'
  # then, per node:
  sudo ip route add 10.129.2.0/23 via 192.168.122.34
  ```

- **Treat phase 1 as a proof and move on.** `--tags shared` deletes
  `default-podnetwork` for you; from there only the tenant UDNs are
  advertised, and those hold nothing but test pods. Or set
  `udn_bgp_advertise_default: false` to skip it entirely and start at phase 2.

To undo it by hand at any point:

```bash
oc delete ra default-podnetwork
```

The operators recover within a few minutes.

### Prove the data plane

The observable change is that pod egress **stops being SNATed**. Once the pod
network is advertised, packets leave with the real pod IP, because the fabric
now has a route back to it.

```bash
oc -n default run bgp-probe --restart=Never \
  --image=registry.redhat.io/rhel9/support-tools:latest \
  --overrides='{"spec":{"nodeName":"worker1"}}' --command -- sleep 3600

# on the lab host, not inside a container - the FRR image has no tcpdump
sudo tcpdump -ni virbr1 icmp

oc -n default exec bgp-probe -- ping -c3 192.168.140.1
```

The source address on the wire is the whole test:

| Source seen | Meaning |
| --- | --- |
| `10.129.2.x` (a pod IP) | Un-SNATed. The advertisement is in effect |
| `192.168.122.34` (node's virbr0 IP) | Still SNATed — the advertisement is not in effect |

And confirm what the lab is careful **not** to have changed:

```bash
oc debug node/worker1 -- chroot /host ip route show proto bgp
oc debug node/worker1 -- chroot /host ip route show default
# expect: default via 192.168.122.1 - the node's default route never moves
```

```bash
oc -n default delete pod bgp-probe
```

---

## Following one packet

Worth doing once, because the path crosses four routing decisions and only
two of them are Linux routing tables. The numbers below are from a real run:
a pod `10.129.2.58` on worker1 pinging leaf1 at `192.168.140.1`.

```
                        pod: 10.129.2.58/23   gateway: 10.129.2.1
                        node subnet: 10.129.2.0/23
worker1                 ovn-k8s-mp0: 10.129.2.2
                        enp8s0: 192.168.140.34/24
leaf1                   eth1: 192.168.140.1/24
```

### Out

| # | Where | What decides the next hop |
| --- | --- | --- |
| 1 | Pod network namespace | The pod's own table: `default via 10.129.2.1 dev eth0`. That gateway is a **logical** router port, not a device on any host |
| 2 | veth → `br-int` | The pod's logical switch port. From here until step 4 the packet is inside OVN and no kernel routing table is consulted |
| 3 | `ovn_cluster_router` | In **local gateway** mode a logical router policy sends egress at the node's management port, `10.129.2.2`, instead of out the gateway router. This is the fork in the road: in shared gateway mode the packet would leave through `br-ex` and never touch the fabric NIC |
| 4 | `ovn-k8s-mp0` | The packet leaves OVN and enters the host kernel. Its source is still `10.129.2.58` — see [SNAT](#the-snat-that-does-not-happen) below |
| 5 | Host main routing table | `192.168.140.0/24 dev enp8s0 proto kernel scope link` — directly connected. The kernel ARPs for `192.168.140.1` and sends it out `enp8s0`. **Forwarding is checked here**, on the *incoming* interface, which is `ovn-k8s-mp0` and is enabled by OVN-Kubernetes |
| 6 | The wire | `enp8s0` → the node's tap on `virbr1` → the clab VM's NIC → `br-fabric` → the `leaf1-fab` veth → leaf1's `eth1`. All layer 2; no routing decision anywhere in this hop |

Only **one** kernel routing table is consulted on the way out — the host's
`main` table, at step 5. Steps 1–3 are OVN's logical topology, which looks
like routing and is not in any table `ip route` can show you.

### Back

| # | Where | What decides the next hop |
| --- | --- | --- |
| 6' | leaf1 | `10.129.2.0/23 via 192.168.140.34` — **learned over BGP** from worker1 itself. Without this the reply has nowhere to go, and a ping that leaves un-SNATed dies here |
| 5' | worker1, `enp8s0` | Main table again: `10.129.2.0/23 dev ovn-k8s-mp0 proto kernel scope link`. Forwarding is checked here too, on `enp8s0` — **this is the one OVN-Kubernetes does not enable**, and the Tuned profile in Part 5 exists for this single check |
| 4' | `ovn-k8s-mp0` | Back into OVN |
| 3'–1' | `br-int` → logical switch → veth | Delivered to the pod by MAC; no further routing |

The return path is not the mirror image of the outbound one, and that
asymmetry is where both of this lab's hardest bugs lived. Outbound needs
nothing from BGP — the node has a connected route to `192.168.140.0/24` and
would reach the leaf with no advertisement at all. Inbound needs **two**
things that outbound does not: a BGP-learned route on the leaf, and
forwarding enabled on a NIC that OVN-Kubernetes has never heard of.

### The SNAT that does not happen

Normally a pod's egress to anything outside the cluster is SNATed to the
node's IP by a NAT rule on the node's gateway router. With the pod network
advertised, OVN-Kubernetes stops applying it: the fabric has a route back to
the pod, so there is nothing to hide behind.

That is the single most useful observation in phase 1, because it is visible
without reading any OVN state:

```bash
sudo tcpdump -ni virbr1 icmp
```

`10.129.2.58 > 192.168.140.1` means the advertisement is in effect.
`192.168.122.34 > 192.168.140.1` means it is not, and everything else you
are looking at is a distraction until that changes.

The commands to see the rule itself, rather than its effect, are in
[Seeing it yourself](#seeing-it-yourself) below.

### Seeing it yourself

Set these up first. Everything below assumes the pod is `bgp-probe` in
`default`, on `worker1`.

```bash
NODE=worker1
POD_IP=$(oc -n default get pod bgp-probe -o jsonpath='{.status.podIP}')
OVNPOD=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node \
           --field-selector spec.nodeName=$NODE -o name | head -1)
FRRPOD=$(oc -n openshift-frr-k8s get pod -l app=frr-k8s \
           --field-selector spec.nodeName=$NODE -o name | head -1)
echo "$POD_IP / $OVNPOD / $FRRPOD"
```

That `FRRPOD` matters more than it looks. **`oc exec ds/frr-k8s` picks an
arbitrary pod**, so `show bgp summary` run that way may be answering for a
different node than the one you are debugging — check the router-id in the
output against the node you meant. It is an easy hour to lose.

#### Hop 1 — inside the pod

```bash
oc -n default exec bgp-probe -- ip -br addr show eth0
oc -n default exec bgp-probe -- ip route
oc -n default exec bgp-probe -- ip neigh          # who answered for the gateway

# what OVN told the pod it is
oc -n default get pod bgp-probe \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -m json.tool
```

The annotation is the authoritative answer for the pod's IP, MAC and gateway
— it is what OVN-Kubernetes handed the CNI, before anything could drift.

#### Hops 2–4 — inside OVN

The northbound database is the declarative layer: logical switches, routers,
policies and NAT rules. One database per node under OVN interconnect.

```bash
NB="oc -n openshift-ovn-kubernetes exec $OVNPOD -c nbdb -- ovn-nbctl"

$NB show | head -40                       # the whole logical topology
$NB lr-list                               # router names - they vary by release
$NB ls-list                               # switch names

# Hop 3: the local-gateway redirect. In local gateway mode a policy sends
# egress at the management port instead of the gateway router.
$NB lr-policy-list ovn_cluster_router
$NB lr-route-list  ovn_cluster_router

# The SNAT that should NOT list the pod subnet once the network is advertised
$NB lr-nat-list GR_$NODE

# The pod's logical switch port
$NB lsp-list $NODE | grep bgp-probe
```

If `-c nbdb` is not a container on your build, try `-c northd`, and use
`ovn-nbctl show` to find the real router and switch names before assuming
`ovn_cluster_router` and `GR_<node>`.

To ask OVN what it *would* do with a specific packet rather than reading the
tables and inferring — this is the tool worth knowing:

```bash
oc -n openshift-ovn-kubernetes exec $OVNPOD -c northd -- \
  ovn-trace --minimal "$NODE" \
  "inport==\"$(oc -n default get pod bgp-probe -o jsonpath='{.metadata.namespace}_{.metadata.name}')\"
   && eth.src==<pod mac> && eth.dst==<gateway mac>
   && ip4.src==$POD_IP && ip4.dst==192.168.140.1 && ip.ttl==64"
```

Fill the MACs from the pod annotation above and the router port. `--minimal`
prints just the decisions; drop it for the full table-by-table walk.

Underneath the logical layer, the actual OpenFlow rules on `br-int`. OVS runs
on the host, so go through `oc debug` rather than the pod:

```bash
oc debug node/$NODE -- chroot /host ovs-vsctl show
oc debug node/$NODE -- chroot /host ovs-ofctl dump-flows br-int | grep $POD_IP

# what the kernel datapath is really doing, per packet, right now
oc debug node/$NODE -- chroot /host ovs-appctl dpctl/dump-flows --names | grep $POD_IP
```

And the question phase 1 is really asking — was it translated?

```bash
oc debug node/$NODE -- chroot /host conntrack -L -p icmp 2>/dev/null | grep $POD_IP
```

A tuple whose reply direction is `src=192.168.140.1 dst=<pod ip>` means no
NAT happened. If the reply direction says `dst=192.168.122.34`, the packet
was SNATed to the node and the advertisement is not in effect.

#### Hop 5 — the host routing table

```bash
oc debug node/$NODE -- chroot /host ip route
oc debug node/$NODE -- chroot /host ip -br addr show

# the outbound decision
oc debug node/$NODE -- chroot /host ip route get 192.168.140.1 from $POD_IP iif ovn-k8s-mp0

# the return decision - the one that was broken
oc debug node/$NODE -- chroot /host ip route get $POD_IP from 192.168.140.1 iif enp8s0

# and why it was broken
oc debug node/$NODE -- chroot /host sysctl net.ipv4.conf.enp8s0.forwarding \
                                           net.ipv4.conf.ovn-k8s-mp0.forwarding \
                                           net.ipv4.conf.all.forwarding

oc debug node/$NODE -- chroot /host ip neigh show dev enp8s0
oc debug node/$NODE -- chroot /host ip route show proto bgp
oc debug node/$NODE -- chroot /host ip rule show
```

`ip route get ... iif ...` is the highest-value command in this list: it asks
the kernel the exact question the forwarding path asks, and distinguishes
*no route* (`ENETUNREACH`, "Network is unreachable") from *route fine,
forwarding off* (`EHOSTUNREACH`, "No route to host").

#### Hop 6 — the wire, and the leaf

```bash
# on the lab host - every node-to-fabric packet crosses this bridge
sudo tcpdump -eni virbr1 icmp          # -e for MACs, to check who it is addressed to
ip -br link show master virbr1

# in the clab VM
sudo tcpdump -ni br-fabric icmp
ip -br link show master br-fabric

# leaf1's own view
docker exec clab-udnbgp-leaf1 ip -br addr show
docker exec clab-udnbgp-leaf1 ip route show
docker exec clab-udnbgp-leaf1 vtysh -c 'show ip route 10.129.2.0/23'
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp ipv4 unicast 10.129.2.0/23'
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp summary'
```

The FRR image ships no tcpdump — capture on the bridge, not inside the node.

#### The BGP layer, on the cluster side

```bash
# the two CRs and what they produced
oc get frrconfiguration -n openshift-frr-k8s
oc get frrconfiguration -n openshift-frr-k8s -o yaml | grep -A20 'name: route-advertisements'
oc get ra
oc get routeadvertisements default-podnetwork -o yaml

# the config FRR-K8s actually rendered on THIS node, both CRs merged
oc -n openshift-frr-k8s exec $FRRPOD -c frr -- vtysh -c 'show running-config'
oc -n openshift-frr-k8s exec $FRRPOD -c frr -- vtysh -c 'show bgp summary'
oc -n openshift-frr-k8s exec $FRRPOD -c frr -- vtysh -c 'show bgp ipv4 unicast'
oc -n openshift-frr-k8s exec $FRRPOD -c frr -- vtysh -c 'show bgp neighbors 192.168.140.1 advertised-routes'
oc -n openshift-frr-k8s exec $FRRPOD -c frr -- vtysh -c 'show bgp neighbors 192.168.140.1 received-routes'
```

`advertised-routes` is the one that closes the loop on
`RouteAdvertisements`: it should list this node's own pod subnet and nothing
else. If the session is up and that list is empty, the generated
`FRRConfiguration` never arrived — look at the CR's status, not at FRR.

### What the two CRDs actually did

They divide cleanly, and confusing them is the source of most
"why is nothing being advertised" time:

| | `FRRConfiguration` | `RouteAdvertisements` |
| --- | --- | --- |
| Scope | Namespaced, in `openshift-frr-k8s` | Cluster-scoped |
| Answers | *Who do I peer with, and on what terms?* | *Whose prefixes go out over that session, and into which VRF?* |
| Read by | FRR-K8s | OVN-Kubernetes |
| Produces | The BGP session itself | A **generated** `FRRConfiguration` per node, plus data-plane changes in OVN |
| Knows about pods? | No | Yes |

The sequence, in order:

1. You apply **`fabric-peering-default`**. FRR-K8s renders it into the FRR
   config inside the `frr-k8s` pod on every node the `nodeSelector` matches,
   and the session to `192.168.140.1` comes up. At this point **zero prefixes
   are being advertised** — `toAdvertise: mode: filtered` with no prefix list
   is an empty set, deliberately. A session that is `Established` and
   advertising nothing is the expected state after this step.

2. You apply **`default-podnetwork`**. OVN-Kubernetes resolves
   `networkSelectors` to a set of networks, works out **per node** which
   prefixes that node owns for them, and writes a second, additive
   `FRRConfiguration` carrying exactly those:

   ```bash
   oc get frrconfiguration -n openshift-frr-k8s
   # fabric-peering-default          ← yours
   # route-advertisements-...        ← generated, one per node. Do not edit
   ```

   FRR-K8s merges both into one FRR config. This is why the CR names a
   `frrConfigurationSelector` rather than a session: it is saying "take that
   peering, and add these prefixes to it".

3. At the same time, OVN-Kubernetes changes the **data plane** — the SNAT
   above. `RouteAdvertisements` is not only a BGP object; accepting it
   changes how packets leave the node.

4. Separately and continuously, `toReceive: mode: all` on your
   `FRRConfiguration` makes FRR-K8s install everything learned from the leaf
   into the node's kernel table:

   ```bash
   oc debug node/worker1 -- chroot /host ip route show proto bgp
   # 10.128.2.0/23 via 192.168.140.35 dev enp8s0   ← worker2's pods
   # 10.131.0.0/23 via 192.168.140.36 dev enp8s0   ← worker3's pods
   ```

   Note what is *absent*: worker1's own `10.129.2.0/23`. leaf1 advertises all
   three node subnets to every node, but each node rejects its own — the
   AS-path already contains AS 64512. That loop check is doing real work
   here: a node that installed a BGP route to its own pod subnet would send
   its pods' return traffic out to the fabric.

   This is also the mechanism that replaces the idea of pointing a UDN's
   default gateway at the router. The pods' gateway never moves. The node
   simply learns where the fabric's prefixes are.

So: `FRRConfiguration` without `RouteAdvertisements` gives you a BGP session
that carries nothing. `RouteAdvertisements` without a matching
`FRRConfiguration` is rejected outright — there is no session to add prefixes
to. Neither is useful alone, and the split is the reason a lab can bring the
session up first and confirm it before any pod route is involved.

---

## Phase 2: UDNs in the default VRF

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags shared
> ```
> Role: `templates/cudn.yaml.j2`, `templates/workload.yaml.j2`, `templates/routeadvertisements-udn-shared.yaml.j2`
>
> Runs Parts 1-6 and phase 1 first, then this.

Adds UDN. Still no VLANs, no per-tenant VRFs, no NMState. Leaking a UDN into
the default VRF gives up its isolation at the node boundary — anything else in
that VRF can now reach those pods — which is exactly why it is worth doing
before VRF-Lite: it separates "does UDN-over-BGP work" from "does my VLAN and
VRF plumbing work".

### Namespaces first, and why they get deleted

A namespace's primary network is bound **when the namespace is created**. A
namespace that already exists from an earlier phase is on the old network and
cannot be moved by relabelling. Recreating it is the only way to switch a
tenant between the phase-2 and phase-3 subnets:

```bash
oc delete namespace udn-blue udn-red --ignore-not-found --wait=true --timeout=300s
oc delete clusteruserdefinednetwork blue red --ignore-not-found --wait=true --timeout=300s
```

### The CUDNs

> **There is no `cudn` short name.** `oc get cudn` fails with *"the server
> doesn't have a resource type"*, which reads like the CRD is missing rather
> than like an abbreviation that was never registered. Spell it
> `clusteruserdefinednetwork` (case-insensitive) or `ClusterUserDefinedNetwork`
> throughout. `RouteAdvertisements` does have one — `ra` — which is part of why
> the missing one is surprising.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: blue
  labels:
    bgp: "enabled"
    udn-lab-phase: shared
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: blue
  network:
    topology: Layer3
    layer3:
      role: Primary
      subnets:
        - cidr: 10.220.0.0/16
          hostSubnet: 24
EOF
```

Red is identical with `name: red`, `udn-tenant: red` and `10.221.0.0/16`.
Distinct subnets are required in this phase, and **nothing enforces that**.
Both tenants' routes land in the default VRF, where one prefix cannot mean
two things - but the `RouteAdvertisements` is still Accepted, because
OVN-Kubernetes does not validate it. Its route advertisements controller
carries a literal `// TODO check overlaps?` where the check would go. The
result is one winner and one tenant quietly unreachable.

Overlap becomes legal in phase 3, where `targetVRF: auto` gives each tenant
its own VRF and the same prefix in two VRFs is two different routes. That is
the whole point of VRF-Lite, and it is why these two phases use different
subnets.

The `bgp: "enabled"` label is how the `RouteAdvertisements` selects them as a
set.

### The namespaces and test workload

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: udn-blue
  labels:
    udn-tenant: blue
    k8s.ovn.org/primary-user-defined-network: ""
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: udn-test
  namespace: udn-blue
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: udn-test-privileged
  namespace: udn-blue
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: udn-test
    namespace: udn-blue
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: udn-test
  namespace: udn-blue
spec:
  selector:
    matchLabels:
      app: udn-test
      tenant: blue
  template:
    metadata:
      labels:
        app: udn-test
        tenant: blue
    spec:
      serviceAccountName: udn-test
      containers:
        - name: shell
          image: registry.redhat.io/rhel9/support-tools:latest
          command: ["/bin/bash", "-c", "sleep infinity"]
          securityContext:
            capabilities:
              add: ["NET_RAW", "NET_ADMIN"]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      tolerations:
        - operator: Exists
          effect: NoSchedule
EOF

oc -n udn-blue rollout status daemonset/udn-test --timeout=600s
```

A DaemonSet rather than a Deployment, because phase 3 needs a pod of each
tenant on **every** node: OVN-Kubernetes creates a node's UDN VRF only when
that network first has something on the node. It is also the reason the
verification steps can `oc exec` into whichever node they care about.

#### Why `k8s.ovn.org/primary-user-defined-network`

This label is the namespace's opt-in to having a primary UDN at all, and it
is not optional. Without it OVN-Kubernetes refuses to create the
NetworkAttachmentDefinition, and says so on the **CUDN**, not on the
namespace and not on the pods:

```bash
oc get clusteruserdefinednetwork blue -o jsonpath='{.status.conditions}' | jq
```
```
"type": "NetworkCreated", "status": "False",
"reason": "NetworkAttachmentDefinitionSyncError",
"message": "invalid primary network state for namespace \"udn-blue\": a valid
 primary user defined network or network attachment definition custom
 resource, and required namespace label
 \"k8s.ovn.org/primary-user-defined-network\" must both be present"
```

Everything downstream of that stays green. The namespace is created, the pods
schedule, the DaemonSet rolls out, `oc exec` works — all on the **default
cluster network**. The first visible symptom arrives two steps later, when the
RouteAdvertisements sits at `configuration pending: no networks selected`, a
message that points at the label selector on the RA rather than at the label
missing on the namespace.

The value is deliberately empty; only the key's presence is read.

Two things make this worth checking explicitly rather than trusting. The label
must be present **when the namespace is created** — OVN-Kubernetes binds a
primary network at creation time and adding the label afterwards does nothing,
which is why the workload template ships the namespace and the DaemonSet
together and the play deletes and recreates rather than patching. And the
pod's own annotation is the only place the outcome is written down:

```bash
oc -n udn-blue get pod -o jsonpath='{.items[0].metadata.annotations.k8s\.ovn\.org/pod-networks}' | jq
```

```json
{
  "default":        { "ip_address": "10.131.0.79/23", "role": "infrastructure-locked" },
  "udn-blue/blue":  { "ip_address": "10.220.3.3/24",  "role": "primary" }
}
```

Read two things, not one:

- The tenant's key is **`<namespace>/<CUDN name>`** — `udn-blue/blue`, not
  `blue`. It is the NAD reference, not the network name.
- `default` has been demoted to **`"role": "infrastructure-locked"`**. That is
  how OVN-Kubernetes marks the cluster network of a pod whose primary network
  is a UDN, and it is the independent corroboration: a pod that never got its
  UDN keeps `"role": "primary"` on `default`.

So a pod on the default network only looks like this, and nothing else in the
lab distinguishes it from a healthy one:

```json
{ "default": { "ip_address": "10.131.0.74/23", "role": "primary" } }
```

One more thing you will see in the pod events even on a correct run:

```
Warning  ErrorReconcilingPod  invalid primary network state for namespace "udn-blue": ...
Normal   AddedInterface       Add eth0 [10.131.0.79/23 10.220.3.3/24] from ovn-kubernetes
```

The warning is a real race and it resolves itself. The namespace and the
DaemonSet are applied in one manifest, so the DaemonSet controller can create
pods before OVN-Kubernetes has processed the namespace's primary network.
It retries, and `AddedInterface` with **two** addresses — the cluster one and
the UDN one — is the proof it succeeded. Judge the run by the annotation
above, not by the presence of that warning.

#### Why the ServiceAccount and the RoleBinding

The pods ask for `NET_RAW` and `NET_ADMIN` — `ping`, `tcpdump` and `ip` all
need them, and nearly every check from here on runs inside one of these pods.

**The PSA labels on the namespace do not grant that.** Pod Security Admission
and OpenShift's SecurityContextConstraints are two independent admission
layers, and relaxing one says nothing about the other. Without the binding the
`default` ServiceAccount gets `restricted-v2`, which carries
`requiredDropCapabilities: [ALL]`, and every pod the DaemonSet controller
tries to create is refused.

That failure is quiet in an unhelpful way, because **no pod object is ever
created** — `oc get pods` is empty and there is nothing to describe:

```
oc -n udn-blue get daemonset udn-test -o yaml | grep -A6 '^status:'
# desiredNumberScheduled: 3      <- the node selector matched
# currentNumberScheduled: 0      <- but nothing was ever placed
# numberUnavailable: 3
```

`desired` non-zero with `scheduled: 0` always means *refused at creation*, not
*could not be scheduled*. The evidence is only on the DaemonSet:

```bash
oc -n udn-blue describe daemonset udn-test | tail -20
# FailedCreate  Error creating: pods "udn-test-xxxxx" is forbidden: unable to
# validate against any security context constraint: ... capabilities.add:
# Invalid value: "NET_ADMIN": capability may not be added
```

Contrast with `scheduled: 3, ready: 0`, which means the pods *do* exist and
the problem is further along — normally the CUDN not being ready yet, or the
`registry.redhat.io` pull. Those show up in `oc get pods` and
`oc describe pod` as usual.

### Advertise them

```bash
cat <<'EOF' | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: udn-shared-vrf
spec:
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            bgp: "enabled"
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      routeAdvertisements: fabric-default
  advertisements:
    - PodNetwork
EOF

oc get routeadvertisements udn-shared-vrf -o jsonpath='{.status.status}'; echo
```

Same shape as phase 1, same absent `targetVRF`, same FRRConfiguration — only
the network selector differs. That is the point: nothing about the transport
changed, only which networks are being advertised over it.

```bash
oc -n udn-blue get pods -o wide
oc -n udn-blue exec <pod> -- ip -br addr show eth0     # expect 10.220.x.x
oc -n udn-red  exec <pod> -- ip -br addr show eth0     # expect 10.221.x.x
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp ipv4 unicast'
```

Verify against leaf1's own fabric address and the other nodes' pod subnets —
**not** against `10.210.10.10`. That host lives in leaf1's blue VRF and is not
reachable from the default VRF. Reaching it is a phase-3 result.

### What phase 2 can and cannot reach

**A pod on a UDN cannot ping the fabric in this phase, and that is a property
of the topology rather than a fault to fix.** Worth understanding, because
everything about it looks like it should work.

The control plane is genuinely complete. leaf1 has every node's slice of every
tenant:

```
*>  10.220.0.0/24    192.168.140.35(worker2)      <- blue, per node
*>  10.220.1.0/24    192.168.140.36(worker3)
*>  10.220.5.0/24    192.168.140.34(worker1)
*>  10.221.0.0/24    192.168.140.34(worker1)      <- red
...
*>  10.223.0.0/16    192.168.140.34(worker1)      <- green: ONE prefix, Layer2
```

and every node has installed the others' slices, learned from the fabric:

```bash
oc debug node/worker2 --quiet -- chroot /host ip route show table main | grep bgp
# 10.220.1.0/24 via 192.168.140.36 dev enp8s0 proto bgp
# 10.221.0.0/24 via 192.168.140.34 dev enp8s0 proto bgp
```

The data plane is where it stops, and the reason is one missing route. In
local gateway mode (`routingViaHost: true`) pod egress is punted to the host
at the tenant's management port — you can watch it arrive, un-SNATed, which
proves the advertisement reached the data plane:

```bash
oc debug node/worker2 --quiet -- chroot /host timeout 10 tcpdump -nni ovn-k8s-mp5 icmp
# IP 10.220.0.3 > 192.168.140.1: ICMP echo request     <- pod's own address
```

But the management port is enslaved to the **tenant's** VRF, and that VRF's
routing table is not `main`:

```bash
oc debug node/worker2 --quiet -- chroot /host ip route show table 1117
# default via 192.168.122.1 dev br-ex          <- the node's ORDINARY gateway
# 10.220.0.0/24 dev ovn-k8s-mp5 proto kernel scope link src 10.220.0.2
# 10.220.0.0/16 via 10.220.0.1 dev ovn-k8s-mp5
```

There is no `192.168.140.0/24` in it. That prefix is a **connected** route on
`enp8s0`, and `enp8s0` is in the default VRF — so `main` has it and table 1117
does not. The default route wins, and the packet leaves by the management NIC:

```bash
oc debug node/worker2 --quiet -- chroot /host ip route get 192.168.140.1 from 10.220.0.3 iif ovn-k8s-mp5
# 192.168.140.1 from 10.220.0.3 via 192.168.122.1 dev br-ex table 1117

sudo tcpdump -ni virbr0 icmp          # the MANAGEMENT bridge
# IP 10.220.0.3 > 192.168.140.1       <- right source, wrong NIC
```

Right source, wrong NIC, and nothing on virbr1 at all.

This is not OVN-Kubernetes doing something wrong. From its point of view the
external path out of a tenant VRF *is* the node's default gateway, and in a
deployment where the BGP fabric is what `br-ex` faces, phase 2 works exactly
as advertised. **This lab deliberately puts the fabric on a second NIC that is
not the node's default path** — see Part 5, which adds no gateway and no
default route precisely so the change is safe to apply to a working cluster.
That choice is what confines phase 2 to the control plane.

Giving the tenant VRF its own way out is exactly what phase 3 adds: a VLAN
subinterface enslaved into that same VRF, with its own connected route and its
own BGP session. So read phase 2 as: *the advertisement works, the prefixes
are real, the un-SNAT is real* — and treat pod-to-fabric as a phase 3 result.

### Reaching a UDN pod from outside the cluster

The *inbound* direction does work in phase 2, and it is worth doing once
because it proves the advertised prefixes are real routes and not just entries
in a table. An external client can reach a UDN pod, routed by leaf1 using what
BGP told it.

It also takes four separate pieces of hand-holding, which is the argument for
phase 3 better than any prose.

**Inbound depends on one `ip rule` per tenant**, installed by
OVN-Kubernetes on every node:

```bash
oc debug node/worker3 --quiet -- chroot /host ip rule show | grep 10.22
# 2000:  from all to 10.221.0.0/16 lookup 1117
```

That is what catches a packet arriving in the default VRF on `enp8s0` and
redirects it into the tenant's VRF, where the pod's subnet is connected.
Without it the packet falls through to `main`, finds nothing, and leaves again
by the default route — and the fabric side looks perfect while it happens.

#### What a healthy rule table looks like

Every tenant gets **three** rules at priority 2000 on every node. Read them as
two greps, because they answer different questions:

```bash
oc debug node/worker1 --quiet -- chroot /host ip rule show | grep fwmark
```
```
30:    from all fwmark 0x1745ec lookup 7        <- not ours, OVN's own
2000:  from all fwmark 0x1006 lookup 1093
2000:  from all fwmark 0x1008 lookup 1098
2000:  from all fwmark 0x1007 lookup 1101
2000:  from all fwmark 0x1009 lookup 1110
5999:  from all fwmark 0x3f0 lookup main        <- not ours
```

```bash
oc debug node/worker1 --quiet -- chroot /host ip rule show | grep 'to 10\.'
```
```
2000:  from all to 10.221.0.0/16 lookup 1093     <- red
2000:  from all to 10.223.0.0/16 lookup 1098     <- green
2000:  from all to 10.222.0.0/16 lookup 1101     <- orange
2000:  from all to 10.220.0.0/16 lookup 1110     <- blue
```

There is a third per tenant, `to 169.254.0.x lookup <table>`, for the
masquerade address. So **four tenants means twelve rules at priority 2000** —
counting them is the fastest health check there is.

| Rule | Carries |
| --- | --- |
| `fwmark 0x10NN → table` | Traffic OVN has already marked as belonging to that network |
| `to 169.254.0.x → table` | The network's masquerade address |
| `to <subnet> → table` | **Fabric-inbound traffic.** This is the one that matters for an external client, and the one that goes missing |

Three things to know when reading this:

- **Table ids are per node.** worker1 uses 1093/1098/1101/1110 for
  red/green/orange/blue; worker2 uses 1117/1123/1124/1125 for
  blue/green/orange/red. OVN-Kubernetes allocates them per node in creation
  order. Never carry a number between nodes, and never derive one — read it.
- **The low byte of the fwmark is the network id.** `0x1006` is network 6.
  Nothing in the rule says which tenant that is; the subnet rule and the
  management port's address are what tie an id to a name.
- **The id changes if a network is recreated and reallocated**, which is more
  than a curiosity — see below.

**If one tenant's rule is missing on every node while its siblings have
theirs**, that tenant carries stale node-side state. On the cluster this was
built against, blue had been created once with its namespace missing the
`k8s.ovn.org/primary-user-defined-network` label, so its network was never
realised; the rule was never installed, and later recreations by the playbook
did not add it. Deleting the CUDN and its namespace by hand and recreating
them did:

```bash
oc delete namespace udn-blue --wait
oc delete clusteruserdefinednetwork blue --wait
oc apply -f <manifest dir>/cudn-blue.yaml
oc apply -f <manifest dir>/workload-blue.yaml
```

The network id is the evidence that this is what happened. Before the
recreation blue was network 5 (`fwmark 0x1005`); afterwards it was network 9
(`0x1009`, table 1110), while red, orange and green kept 6, 7 and 8 and their
original tables. Blue was allocated a **fresh id**, and the rule appeared with
it — so the stale state was tied to the old id, not to the object. That also
explains why the playbook's own delete-and-recreate never cleared it: recreated
promptly under the same name, the network got its old id back and the old state
with it.

Worth knowing the shape rather than the specific case: a **row** of failures in
the reachability matrix below, with the fabric and the advertisement both
healthy, is this. Check the rule before anything else, then compare fwmarks
before and after any recreation — an id that did not move means the state did
not either.

Set the client up on the clab VM, which is on both networks. Note the address
on `br-fabric`, which the fabric bridge does not otherwise have:

```bash
ip link set br-fabric up
ip addr add 192.168.140.50/24 dev br-fabric
ping -c2 192.168.140.1                          # leaf1 - must work first
ip route add 10.221.0.0/16 via 192.168.140.1
```

Then ping **sourced from the management address**, not the fabric one:

```bash
ping -I 192.168.122.40 10.221.2.3
```

The source matters completely. The pod's reply is routed in the tenant VRF,
whose only external route is `default via 192.168.122.1 dev br-ex` — so the
reply leaves by the **management** network regardless of where the request
came from. Source it from `192.168.140.50` and the reply goes to the lab host,
which has no address on the fabric bridge, and dies there.

So the flow is deliberately asymmetric:

```
request:  clab VM -> br-fabric -> leaf1 -> worker3 enp8s0 -> rule -> red VRF -> pod
reply:    pod -> red VRF -> default route -> br-ex -> virbr0 -> lab host -> clab VM
```

Every host on that path performs a reverse-path check the asymmetry fails.

Check it before changing it, because **the effective value is
`max(all, <iface>)`** and the `all` value on its own is misleading. On the lab
host that was dropping every reply:

```
net.ipv4.conf.all.rp_filter = 0        <- looks permissive
net.ipv4.conf.virbr0.rp_filter = 1     <- and yet strict, because max() wins
```

Setting only `all` changes nothing. Set both, wherever the ping stops:

```bash
# the lab host - this is the one that was demonstrably dropping
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.virbr0.rp_filter=2

# the clab VM - its route to 10.221.0.0/16 points at br-fabric, but the
# reply arrives on eth0
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.eth0.rp_filter=2

# the node, if the request never reaches the management port
oc debug node/worker3 --quiet -- chroot /host sysctl -w net.ipv4.conf.all.rp_filter=2
oc debug node/worker3 --quiet -- chroot /host sysctl -w net.ipv4.conf.enp8s0.rp_filter=2
```

`udn_bgp_loose_rp_filter: true` in `vars.yaml` makes the node's half permanent
through the Tuned profile. The other two are outside the cluster and outside
the playbook.

When it works:

```
64 bytes from 10.221.2.3: icmp_seq=327 ttl=61 time=0.369 ms
```

**Read the TTL.** 64 minus three — and the three are worth naming, because they
are *not* the hops the request took. The reply never touches leaf1. It is
decremented by **OVN's logical router**, then by **worker3's kernel** forwarding
it from the management port out `br-ex`, then by **the lab host** forwarding it
back out virbr0 to the client. Three routers, none of them on the fabric.

That is the whole asymmetry in one number, and it is worth checking anyway,
because the clab VM shares a broadcast domain with all three workers: a plain
unsourced `ping` gets an ICMP redirect from leaf1 (`Redirect Host, new nexthop
192.168.140.36`) and thereafter goes straight to the node, testing nothing
about BGP at all.

#### A dedicated client VM

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags clabclient
> ```
> Files: `client-vm.yml`, `client-router.yml`, `client-config.yml` in `roles/setup-clab-fabric`
>
> Deliberately **not** part of `--tags fabric`: it builds a VM and edits the
> lab host's sysctls, neither of which belongs in a routine fabric run.

**One VM tests all four tenants**, because in phase 2 every tenant is
advertised into leaf1's *default* VRF — one client address reaches all of them,
and adding a tenant is one more static route:

```bash
ip route replace 10.222.0.0/16 via 192.168.140.1     # orange
ip route replace 10.223.0.0/16 via 192.168.140.1     # green
```

That stops being true in phase 3, where each tenant has its own VRF on leaf1
and a single default-VRF client reaches none of them. That is the isolation
working, and it is why the lab ships one `<tenant>-ext` container per VRF
rather than one shared client. **Do not carry this VM forward to phase 3** —
it will report total failure and be right to.

What the role builds:

| Piece | Why |
| --- | --- |
| `udnclient` VM, **one NIC** on the management network | No fabric presence. A client on the fabric segment shares a broadcast domain with leaf1 and every worker, so leaf1 answers `Redirect Host` and the traffic goes direct — testing layer 2, not BGP |
| Disk is a plain `cp --sparse=always` of the base image | It runs ping and tcpdump; there is nothing to grow a filesystem for, and no `virt-resize` pass to wait through |
| DHCP reservation added with `virsh net-update ... --live` | The default network's reservations come from `ip_list`, but re-rendering that template means redefining the network and dropping every guest's lease |
| Routes to each tenant via the **clab VM** | Forces real routing: client → clab VM → leaf1 → node |
| An address on the clab VM's `br-fabric`, plus forwarding | The bridge has no IP normally — it is a pure layer 2 extension of virbr1. Giving it one makes the clab VM a host on the fabric and therefore able to forward |
| `rp_filter=2` on the client, the clab VM **and the lab host** | The reply path differs from the request path at every hop |

Both sides are systemd units, so they survive a reboot — unlike the by-hand
version above, where the clab VM's fabric address disappears with the next
restart and the failure looks like the fabric broke.

Then, from the client:

```bash
ping -c3 10.221.2.3      # a red pod
ping -c3 10.222.x.x      # orange
ping -c3 10.223.x.x      # green
```

No `-I` needed here — the client has only the one address, which is the whole
point of giving it a single NIC. Check `ttl=61` on the replies: three routed
hops, so the packet really went via leaf1 and the node rather than being
answered on-link.

If one tenant fails while the others pass, check its `ip rule` first — see
above.

#### Testing every tenant at once

```bash
scripts/udn-reachability.sh              # pods -> client
scripts/udn-reachability.sh --reverse    # client -> pods
scripts/udn-reachability.sh --both       # both, and it names any disagreement
```

Pings between the pods and the client, and prints a **tenant x node**
matrix. The layout is the point — failures in this lab are almost always
shaped like a whole row or a whole column, and the two mean entirely different
things:

```
tenant   worker1   worker2   worker3
blue     FAIL      FAIL      FAIL        <- a row: this tenant's config
red      FAIL      ok        ok
orange   FAIL      no-udn    ok          <- a cell: this pod
green    FAIL      ok        ok
         ^^^^ a column: this node
```

| Shape | Means | Look at |
| --- | --- | --- |
| A row | One tenant, every node | That network: a missing `ip rule`, an unrealised CUDN, no NAD |
| A column | Every tenant, one node | That node: strict `rp_filter`, forwarding off, fabric NIC unaddressed |
| One cell | That pod | The pod, or its node's slice of that network |
| `no-udn` | The pod has no `ovn-udn1` at all | The primary UDN never attached — see the namespace label, above |

Both failures this lab was debugged through are one glance in this layout, and
neither was obvious one ping at a time: blue missing its rule on all three
nodes, and a single node left with strict reverse-path filtering.

`--both` earns its place in phase 2 specifically, because the two directions
are **not** equivalent here — inbound is decided by leaf1 from BGP, outbound by
the node from the tenant VRF's own table. They can disagree, so the script says
so rather than leaving two matrices for you to diff by eye:

```
  ASYMMETRIC  red/worker1: pod->client ok, client->pod FAIL
```

A cell like that is one direction's mechanism broken while the other's works,
and the two have entirely separate causes. Reverse only is the `ip rule` and
the node's inbound path; forward only is the VRF's route out.

It reaches the client over ssh as `root` with `~/.ssh/lab_rsa`; override with
`UDN_CLIENT_SSH_USER` and `UDN_CLIENT_SSH_KEY`.

#### A healthy phase 2, in full

This is what a finished phase 2 looks like — four tenants, three nodes, both
directions:

```
# scripts/udn-reachability.sh --both
Pinging 192.168.122.47 from every udn-test pod (3 packets each)

  blue     worker3   10.220.2.3       ok   ttl=61 1.877 ms
  blue     worker1   10.220.0.3       ok   ttl=61 1.717 ms
  blue     worker2   10.220.1.3       ok   ttl=61 2.317 ms
  green    worker1   10.223.0.4       ok   ttl=61 2.433 ms
  green    worker3   10.223.0.3       ok   ttl=61 1.836 ms
  green    worker2   10.223.0.5       ok   ttl=61 1.869 ms
  orange   worker3   10.222.1.3       ok   ttl=61 2.224 ms
  orange   worker2   10.222.5.3       ok   ttl=61 2.096 ms
  orange   worker1   10.222.3.3       ok   ttl=61 1.626 ms
  red      worker3   10.221.2.3       ok   ttl=61 1.516 ms
  red      worker1   10.221.0.3       ok   ttl=61 1.496 ms
  red      worker2   10.221.1.3       ok   ttl=61 2.138 ms

Pinging every udn-test pod from 192.168.122.47 (3 packets each)

  blue     worker3   10.220.2.3       ok   ttl=61 1.492 ms
  blue     worker1   10.220.0.3       ok   ttl=61 1.538 ms
  blue     worker2   10.220.1.3       ok   ttl=61 1.497 ms
  green    worker1   10.223.0.4       ok   ttl=61 2.135 ms
  green    worker3   10.223.0.3       ok   ttl=61 1.348 ms
  green    worker2   10.223.0.5       ok   ttl=61 2.767 ms
  orange   worker3   10.222.1.3       ok   ttl=61 3.190 ms
  orange   worker2   10.222.5.3       ok   ttl=61 2.290 ms
  orange   worker1   10.222.3.3       ok   ttl=61 1.949 ms
  red      worker3   10.221.2.3       ok   ttl=61 1.514 ms
  red      worker1   10.221.0.3       ok   ttl=61 1.558 ms
  red      worker2   10.221.1.3       ok   ttl=61 1.745 ms

pod -> 192.168.122.47
tenant   worker3   worker1   worker2
blue     ok        ok        ok
green    ok        ok        ok
orange   ok        ok        ok
red      ok        ok        ok

192.168.122.47 -> pod
tenant   worker3   worker1   worker2
blue     ok        ok        ok
green    ok        ok        ok
orange   ok        ok        ok
red      ok        ok        ok
```

Three things in that output are worth more than the twelve `ok`s.

**`ttl=61` on every line, both directions.** 64 minus three routers. Nothing
was answered on-link, and the two directions take different three-hop paths —
the same number for different reasons, which is exactly the asymmetry
[described above](#why-the-two-directions-differ).

**green is `10.223.0.3`, `.4`, `.5` across three nodes.** One flat /24 for the
whole cluster. Compare orange — `10.222.1.3`, `.3.3`, `.5.3` — a distinct /24
per node. That is Layer2 against Layer3 in four lines, and it is the property
live migration depends on: a workload that changes node keeps its address only
because the subnet was never sliced. Reading the addresses is a faster check
than reading the CUDN.

**No `ASYMMETRIC` lines.** Each tenant is reachable both ways, so both
mechanisms are working: the `ip rule` carrying fabric-inbound traffic into the
tenant VRF, and the VRF's route back out. A tenant can pass one and fail the
other, and the script names it when that happens.

#### The Layer2 tenant gets ECMP, and the Layer3 tenants cannot

Green's flat subnet has a consequence on the fabric that is easy to state and
worth confirming: **every node advertises the whole prefix, so the leaf gets
three paths to one destination** — and it uses all of them.

```bash
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp ipv4 unicast 10.223.0.0/16'
```
```
Paths: (3 available, best #1, table default)
  64512
    192.168.140.34(worker1) ... valid, external, multipath, bestpath-from-AS 64512, best
  64512
    192.168.140.36(worker3) ... valid, external, multipath
  64512
    192.168.140.35(worker2) ... valid, external, multipath
```

All three marked **`multipath`** — but the BGP table selecting them is not the
same as the kernel using them, and the two are worth checking separately:

```bash
docker exec clab-udnbgp-leaf1 vtysh -c 'show ip route 10.223.0.0/16'
```
```
Routing entry for 10.223.0.0/16
  Known via "bgp", distance 20, metric 0, best
  * 192.168.140.34, via eth1, weight 1
  * 192.168.140.35, via eth1, weight 1
  * 192.168.140.36, via eth1, weight 1
```

Three `*` — all installed, all active. This is genuine three-way ECMP into the
cluster, and **it needs no configuration**: FRR enables eBGP multipath by
default. Worth knowing if you swap FRR for another NOS in this topology, since
Cisco IOS and older Quagga default `maximum-paths` to 1 and would install one
path from the same BGP table.

Now the Layer3 comparison, which is the point:

```bash
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp ipv4 unicast 10.222.0.0/16 longer-prefixes'
```
```
 *>  10.222.1.0/24    192.168.140.36(worker3)
 *>  10.222.3.0/24    192.168.140.34(worker1)
 *>  10.222.5.0/24    192.168.140.35(worker2)
```

Three prefixes, one path each, no `=` anywhere. **Layer3 cannot have ECMP into
a tenant** — each node advertises only its own slice, so for any given pod
there is exactly one correct node and the path must be right. A misrouted
packet for orange has nowhere to go.

##### ECMP here is distribution, not reachability

This is the part that inverts the usual intuition. For a Layer2 tenant, **any
node can deliver to any pod**: the subnet is one flat domain, so a packet for
`10.223.0.5` arriving at worker1 is handed into the green network and tunnelled
over geneve to worker2 where the pod actually lives.

So green would work with no ECMP at all — one best path, every inbound packet
entering through one node, everything still reachable, and nothing in any test
distinguishing it. ECMP buys load distribution and failure tolerance, not
correctness. For the Layer3 tenants it is the reverse: there is no ECMP to have,
and correctness depends entirely on the path being right.

##### Seeing the distribution

A single ping will not show it. Linux hashes ECMP on source and destination
address (`net.ipv4.fib_multipath_hash_policy=0` by default), so every packet of
one flow picks the same next hop. Vary the destination instead — the three
green pods hash differently:

```bash
# on each node, while pinging all three green pods from the client
oc debug node/worker1 --quiet -- chroot /host timeout 20 tcpdump -nni enp8s0 icmp
```

Different pods arrive at different nodes, and each is delivered regardless of
which node received it.

##### Why this is the right shape for VMs

Put the two properties together — one prefix from every node, and any node able
to deliver — and **a live migration is invisible to the fabric**. The prefix
does not change, the path set does not change, the leaf's forwarding table is
untouched. Traffic may already be arriving at the target node, or arriving at
the old one and being tunnelled; both work, throughout, with no BGP
reconvergence at all.

A Layer3 workload that moves node changes address, and therefore changes
prefix, and therefore requires a withdraw and a re-announce. That is the real
reason the VM tenant is Layer2 — not the flat subnet for its own sake, but that
the fabric never has to learn anything when the workload moves. See
[Live migration on the Layer2 tenant](#live-migration-on-the-layer2-tenant).

#### Making it symmetric instead

One route on the node removes every rp_filter problem at once, by sending the
reply back the way the request came:

```bash
ip route add 192.168.122.40/32 via 192.168.140.50 dev enp8s0 table 1117
```

Forward and reverse paths then agree and each check passes on its own merits.
Two caveats: `enp8s0` is in the default VRF while the route lives in a tenant
table, so it is a cross-VRF nexthop; and **table 1117 belongs to
OVN-Kubernetes**, so a hand-added route there lasts until the controller next
reconciles that VRF, with no warning when it goes.

Which is the summary of this whole section. It works, it demonstrates
something true, and every part of making it work is something phase 3 does
properly: the tenant VRF gets its own fabric interface, its own connected
route and its own BGP session, both directions use it, and none of the above
is needed.

### Following one packet in phase 2

Phase 1's [walkthrough](#following-one-packet) had one routing table in it. This
one has two, and everything surprising about phase 2 comes from which packets
land in which.

Worked with a **red** pod, `10.221.2.3`, on **worker3**, and the client at
`192.168.122.47`.

> One trap before the tables: worker2's **blue** VRF is table 1117 and
> worker3's **red** VRF is *also* table 1117. Table ids are allocated per node
> by OVN-Kubernetes, in creation order. Never carry a number between nodes —
> read it from `ip -d link show type vrf` on the node you are on.

#### Out — a pod to anything outside the cluster

| # | Where | What decides the next hop |
| --- | --- | --- |
| 1 | Pod netns | `default via 10.221.2.1 dev ovn-udn1`. A logical router port, not a device on any host. Note it is `ovn-udn1`, not `eth0` — `eth0` is still the cluster network |
| 2 | veth → `br-int` | The pod's logical switch port. Inside OVN until step 4 |
| 3 | The UDN's cluster router | **Local gateway mode**: a logical router policy redirects egress at this network's management port. **No SNAT** — the network is advertised, so the pod's own address survives |
| 4 | `ovn-k8s-mp6` | Leaves OVN, enters the host kernel, still sourced `10.221.2.3` |
| 5 | **`ip rule` 1000, l3mdev** | The management port is enslaved to VRF `red`, so the lookup goes to **table 1117 — not `main`**. This is the fork phase 1 does not have, and everything below follows from it |
| 6 | Table 1117 | `default via 192.168.122.1 dev br-ex`. There is **no** `192.168.140.0/24` here. That prefix is a *connected* route on `enp8s0`, and `enp8s0` is in the default VRF, so `main` has it and this table does not |
| 7 | `br-ex` → the node's primary NIC | Out the **management** network |
| 8 | virbr0 | Wherever the management network reaches |

Step 6 is the entire story. In phase 1 the equivalent lookup landed in `main`,
where a connected `192.168.140.0/24` beat the default route and the packet went
out the fabric. Here it lands in a table that has never heard of the fabric.

##### Where BGP is involved in this path

**In the forwarding decisions: nowhere.** Not one next hop above comes from
BGP. Steps 1–3 are OVN's logical topology, steps 5–6 are kernel routes
OVN-Kubernetes installed, and step 6's default route is copied from the node's
own default gateway. Read the whole table and there is no BGP in it.

**In the packet: once, and not as a route.** Advertising the network makes
OVN-Kubernetes drop the SNAT at step 3, so the packet leaves carrying
`10.221.2.3` instead of the node's address. That is the only fingerprint the
advertisement leaves on the way out, and it is why watching the management port
is the proof the advertisement reached the data plane:

```
IP 10.221.2.3 > 192.168.122.47: ICMP echo request     <- the pod's own address
```

It is worth being precise about this, because the node **does** hold
BGP-learned routes — just not in the table this packet uses:

```bash
oc debug node/worker2 --quiet -- chroot /host ip route show table main | grep bgp
# 10.220.1.0/24 via 192.168.140.36 dev enp8s0 proto bgp
# 10.221.0.0/24 via 192.168.140.34 dev enp8s0 proto bgp
```

Those are in `main`. Pod egress is routed in table 1117. The two never meet.

Which is the difference between phase 1 and phase 2 in one sentence: **the
default pod network's egress lands in `main`, where BGP-learned routes live, so
BGP can decide its next hop — a UDN's egress lands in the tenant's own table,
where FRR-K8s installs nothing, so BGP decides nothing.** `targetVRF` is unset
in this phase, meaning learned routes go to the default VRF only. Giving the
tenant VRF its own BGP session, and therefore its own learned routes, is
phase 3.

#### In — an external client to a pod

| # | Where | What decides the next hop |
| --- | --- | --- |
| 1 | Client | Static: `10.221.0.0/16 via 192.168.122.40` |
| 2 | clab VM | `10.221.0.0/16 via 192.168.140.1` out `br-fabric`, and forwards |
| 3 | **leaf1** | `10.221.2.0/24 via 192.168.140.36` — **learned over BGP from worker3**. This hop, and only this hop, is what the RouteAdvertisements bought |
| 4 | worker3 `enp8s0` | Arrives in the **default VRF**. `main` has no `10.221.2.0/24` — it is in red's table |
| 5 | **`ip rule` 2000** | `from all to 10.221.0.0/16 lookup 1117`. Installed by OVN-Kubernetes; without it the packet falls through to `main` and leaves again by the default route. **This is exactly blue's situation** |
| 6 | Table 1117 | `10.221.2.0/24 dev ovn-k8s-mp6 proto kernel scope link` → back into OVN |
| 7 | `br-int` → logical switch → veth | Delivered to the pod by MAC |

#### Back — the pod's reply

**Identical to Out.** Steps 1–8 again, unchanged. The reply does not retrace In,
does not know In happened, and never sees leaf1.

```
in:    client -> clab VM -> leaf1 -> worker3 enp8s0 -> rule 2000 -> red VRF -> pod
back:  pod -> red VRF -> default route -> br-ex -> virbr0 -> lab host -> client
```

### Why the two directions differ

Because **they are decided by different routers, using different information.**

- **Inbound is decided by leaf1**, from BGP. The advertisement told the fabric
  where the pods are, so leaf1 sends the packet over the fabric to the node
  holding that slice.
- **Outbound is decided by the node**, from the tenant VRF's table. That table
  contains the tenant's own subnets and the node's default gateway. Nothing
  put the fabric in it.

Which exposes what a route advertisement actually is: **one-way information.**
It tells the fabric how to reach the pods. It does not tell the node how to
reach the fabric, and it was never meant to — in the topology this feature is
designed for, the node already knows, because there is only one way out.

### Is this how it works in production?

**No.** This asymmetry is a property of this lab, not of UDN-over-BGP.

In a production deployment the BGP fabric is **what `br-ex` faces**. One data
NIC or bond, attached to `br-ex`, and the ToR at the other end is both the
node's default gateway *and* its BGP peer. The tenant VRF still gets
`default via <the node's default gateway>` — but now that gateway **is** the
fabric. Both directions use the same link, the flow is symmetric, and none of
the reverse-path filtering in the section above is needed.

This lab deliberately does something else. The fabric is a **second** NIC
(`enp8s0` on virbr1) with no gateway, no DNS and no default route — see
[Part 5](#part-5-address-the-fabric-nics), which is explicit that this is what
makes the change safe to apply to a working cluster. The node keeps reaching
everything it already reached via virbr0, and the only traffic that ever uses
the fabric is traffic something has a specific route for. That safety property
and phase 2's symmetry are the same trade-off seen from two sides.

### Can the return path be forced to match?

**Not in any way worth running.** Three options, and the first two are not real:

1. **Write a route into the tenant VRF's table.** It works —
   `ip route add 192.168.122.47/32 via 192.168.140.50 dev enp8s0 table 1117` —
   and every reverse-path check then passes on its own merits. But table 1117
   is allocated and owned by **OVN-Kubernetes**, which reconciles that VRF on
   its own schedule and will remove anything it did not put there, with no
   event and no warning. It is also a cross-VRF next hop: the table is the
   tenant's, `enp8s0` is the default VRF's. Fine for a demonstration you are
   watching; not a configuration.

2. **Make the fabric the node's default route.** This would work *properly* —
   the tenant VRF inherits the node's default gateway, so pointing that at the
   fabric fixes every tenant at once, with nothing hand-written. It is also
   exactly the production shape. But in this lab virbr1 is an isolated bridge
   with no upstream and no NAT, so the moment it carries the default route the
   nodes lose the API, the registry and DNS. Making it viable means giving
   leaf1 an upstream and NAT — at which point you have rebuilt the lab as a
   production topology and thrown away the property that made Part 5 safe.

3. **Phase 3.** The supported answer, and the reason phase 3 exists. A VLAN
   subinterface enslaved into the *same* VRF gives that VRF a connected route to
   the fabric and its own BGP session. Outbound then matches inbound because
   both are the tenant's own link, and no sysctl anywhere needs relaxing.

OVN-Kubernetes exposes no field for this. There is no `targetVRF` value, no CR
and no annotation that adds a fabric route to a tenant VRF while leaving the
node's default gateway alone. **In phase 2, on this topology, the return path
cannot be made symmetric.** Read phase 2 for what it proves — the advertisement
is real, the prefixes are real, the un-SNAT is real, and the fabric can reach
the pods — and go to phase 3 for a data path you would actually deploy.

### Snapshot phase 2 before moving on

```bash
scripts/udn-snapshot.sh phase2
```

**Do this before `--tags vrflite`, not after.** That phase deletes the
namespaces and the CUDNs and changes every tenant's subnet — blue and red both
become `10.200.0.0/16` — so phase 2's state is not recoverable once it runs,
and the phase 2 against phase 3 difference is most of what this lab exists to
show.

Everything it collects is read-only. Run it again after phase 3 and diff:

```bash
scripts/udn-snapshot.sh phase3
diff -ru snapshots/phase2-* snapshots/phase3-*
```

What to look for in that diff, in rough order of how much it says:

| File | Phase 2 | Phase 3 |
| --- | --- | --- |
| `egress-decisions.txt` — tenant destinations | no route | **via the tenant's own VLAN subinterface** |
| `egress-decisions.txt` — `192.168.140.1`, `192.168.122.47` | `via 192.168.122.1 dev br-ex` — the node's default gateway | no route |
| `node-*-routes-all-tables.txt` | tenant table holds its subnets and a default route | plus a connected route to its handoff subnet and its own BGP-learned routes |
| `leaf1-bgp-default-vrf.txt` | every tenant's prefixes | tenant prefixes gone |
| `leaf1-bgp-all-vrfs.txt` | nothing per-tenant | every tenant's prefixes, **blue and red carrying the same one** in different VRFs |
| `node-*-link.txt` | no VLAN subinterfaces | `enp8s0.110`, `.120`, `.130`, `.140`, each enslaved to its VRF |
| `node-*-ip-rule.txt` | three rules per tenant at priority 2000, including `to <subnet>` | no rule references a tenant subnet; l3mdev at 1000 does the steering |
| `cluster-frrconfig.yaml` | one peering CR | plus one router per tenant VRF |
| `pod-networks.txt` | distinct subnets per tenant | blue and red identical |

`egress-decisions.txt` is the one to read first. It asks the kernel directly
where a given tenant's egress goes, per node, for two sets of destinations —
and **both directions of the change matter**:

- **The tenant's own destinations** — leaf1's addresses inside that tenant's
  VRF: its handoff VLAN subinterface, the `<tenant>-ext` gateway, and the
  phase-3 client segment gateway. These are unreachable in phase 2 and routed
  in phase 3. They are read off leaf1 live (`ip -o -4 addr show master
  <tenant>`) rather than listed in the script, so they cannot drift from the
  topology.
- **`192.168.140.1` and `192.168.122.47`** — leaf1's untagged default-VRF
  address and the phase-2 client. Routed in phase 2 via the node's default
  gateway; **`No route to host` in phase 3**, because the tenant table has no
  default route and the tenant is no longer in the default VRF.

A phase-3 capture showing nothing but `No route to host` is reporting the
second half correctly and missing the first. If you see that, the snapshot
predates this and was only probing the phase-2 destinations — re-run it.

**Expect the reachability matrix to go red, and expect that.** The client sits
in leaf1's *default* VRF, and phase 3 moves every tenant into its own — so the
client should stop reaching the tenants entirely. That is the isolation
working, not a regression. Phase 3's test is each tenant reaching **its own**
`<tenant>-ext` container and no other, which is a different measurement; see
[3e](#3e-the-test-that-must-fail).


---

## Phase 3: VRF-Lite

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags vrflite
> ```
> Role: `tasks/vrflite-discover.yml`, `tasks/vrflite-apply.yml`, `templates/nncp-vrflite.yaml.j2`, `templates/frrconfiguration-vrflite.yaml.j2`, `templates/routeadvertisements-udn-vrflite.yaml.j2`
>
> Runs Parts 1-6 and phase 1 first, recreates the tenants on the overlapping subnet, then this.

Each tenant gets its own VRF on the node, its own VLAN to leaf1, and its own
BGP session inside that VRF. Routes never meet.

Requires local gateway mode. Recreate the tenants on their phase-3 subnets
first — same delete-and-recreate as phase 2, with `udn-lab-phase: vrflite`
and `udn_subnet` rather than `udn_subnet_shared`: `10.200.0.0/16` for **both**
blue and red, `10.202.0.0/16` for orange, `10.204.0.0/16` for green.

### 3a. Discover the VRFs OVN-Kubernetes created

**This is the step that cannot be templated, and skipping it is the most
likely way to break a working cluster.**

When a primary UDN exists, OVN-Kubernetes creates a Linux VRF per network on
every node and enslaves its own management port (`ovn-k8s-mpN`) to it.
VRF-Lite needs a VLAN subinterface added to that *same* VRF.

The trap: NMState treats a VRF's port list as **declarative**. A policy
declaring the VRF with only the VLAN in `ports` removes `ovn-k8s-mpN`, which
severs the UDN from the node and takes the tenant's pods off the network. So
read the port list first and re-state it in full.

**The VRF is named after the CUDN, and there is no status field that tells
you so.** An earlier version of this document said to read
`status.vrfName`; that field does not exist —

```bash
oc explain clusteruserdefinednetwork.status
# FIELDS:
#   conditions <[]Object>      <- and nothing else
```

So the name is a derivation, not a published contract. Linux caps an
interface name at 15 characters, so a CUDN with a longer name necessarily has
a device called something else, and the scheme is OVN-Kubernetes' to change
between releases. Derive it, then **verify it against the node** — never
template a VRF policy from a name you have not seen in the kernel.

Per node, read the link table:

```bash
oc debug node/worker1 --quiet -- chroot /host ip -d link show type vrf
oc debug node/worker1 --quiet -- chroot /host ip -br link show master blue
```

For each (node, tenant) you need three facts:

```
118: blue   vrf table 1117
126: green  vrf table 1123
127: orange vrf table 1124
128: red    vrf table 1125
```

Note the table ids — allocated by OVN-Kubernetes in creation order, with no
relation to anything in this lab's numbering. They are read, never derived.

| Fact | Where it comes from | Why it matters |
| --- | --- | --- |
| VRF device name | The CUDN's name, **confirmed against `ip -d link show type vrf`** | Must match the kernel device exactly |
| Route table id | `linkinfo.info_data.table` | Allocated by OVN-Kubernetes. Naming a different one **recreates** the VRF instead of editing it |
| Existing ports | links whose `master` is the VRF | Must be restated or they are removed |

The role does this in one call per node with `ip -j -d link show` and parses
the JSON; by hand the two commands above are easier to read.

### 3b. The VLAN and the VRF edit

One policy per node per tenant. The `port:` list below contains the
**discovered** `ovn-k8s-mp1` plus the new VLAN — check it against what you
read in 3a before applying:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: vrflite-blue-worker1
spec:
  nodeSelector:
    kubernetes.io/hostname: worker1
  capture:
    fabric-nic: interfaces.mac-address=="52:54:00:E2:55:34"
  desiredState:
    interfaces:
      - name: "{{ capture.fabric-nic.interfaces.0.name }}.110"
        type: vlan
        state: up
        mtu: 9000
        vlan:
          base-iface: "{{ capture.fabric-nic.interfaces.0.name }}"
          id: 110
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 192.168.141.34
              prefix-length: 24
        ipv6:
          enabled: false
      - name: blue
        type: vrf
        state: up
        vrf:
          route-table-id: 1010
          port:
            - ovn-k8s-mp1
            - "{{ capture.fabric-nic.interfaces.0.name }}.110"
EOF

oc wait nncp/vrflite-blue-worker1 --for=condition=Available --timeout=300s
```

Twelve of these in total: 3 nodes × 4 tenants. Red uses VLAN 120 and
`192.168.142.<octet>`, orange VLAN 130 and `192.168.143.<octet>`, green
VLAN 140 and `192.168.144.<octet>`. The VRF edit is the same shape for the
Layer2 tenant — a primary UDN gets a VRF per node whatever its topology.

### 3c. Per-VRF peering

```bash
cat <<'EOF' | oc apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: fabric-peering-vrflite
  namespace: openshift-frr-k8s
  labels:
    routeAdvertisements: fabric-vrflite
spec:
  bgp:
    routers:
      - asn: 64512
        vrf: blue
        neighbors:
          - address: 192.168.141.1
            asn: 64513
            holdTime: 9s
            keepaliveTime: 3s
            port: 179
            toReceive: { allowed: { mode: all } }
            toAdvertise: { allowed: { mode: filtered } }
      - asn: 64512
        vrf: red
        neighbors:
          - address: 192.168.142.1
            asn: 64513
            holdTime: 9s
            keepaliveTime: 3s
            port: 179
            toReceive: { allowed: { mode: all } }
            toAdvertise: { allowed: { mode: filtered } }
  nodeSelector: {}
EOF
```

The `vrf:` values are the VRF device names confirmed on the nodes — FRR renders them
straight into `router bgp 64512 vrf <name>`, so they must match the kernel
device exactly.

### 3d. Advertise, then remove phase 2's CR

```bash
cat <<'EOF' | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: udn-vrflite
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
      routeAdvertisements: fabric-vrflite
  advertisements:
    - PodNetwork
EOF

oc delete routeadvertisements udn-shared-vrf --ignore-not-found
```

`targetVRF: auto` is the whole difference from phase 2. Instead of leaking
into the default VRF, each network is advertised inside its own.

**Order matters, and the wait goes last.** Two `RouteAdvertisements` may not
select the same network — OVN-Kubernetes reports an error and applies
neither — so while both exist neither is accepted. Delete phase 2's first,
*then* check:

```bash
oc get routeadvertisements udn-vrflite -o jsonpath='{.status.status}'; echo
```

Applying before deleting (rather than the reverse) means a half-finished run
leaves at least one advertisement in place.

### 3d-bis. Make bgpd bind to the tenant VRFs

Before testing anything, check this. It is the one failure in phase 3 that
every other layer reports as success.

```bash
POD=$(oc -n openshift-frr-k8s get pods -l component=frr-k8s \
        --field-selector spec.nodeName=worker1 -o name | head -1)
oc -n openshift-frr-k8s exec $POD -c frr -- vtysh -c 'show bgp vrf all summary'
```

**`vrf all` matters.** Plain `show bgp summary` is scoped to the default VRF,
which keeps working throughout phase 3 — it will look perfectly healthy while
every tenant is dead.

Broken looks like this:

```
BGP router identifier 0.0.0.0, local AS number 64512 VRF blue vrf-id -1
Neighbor        V   AS  MsgRcvd MsgSent  Up/Down State/PfxRcd
192.168.141.1   4 64513       0       0    never         Idle
```

`vrf-id -1` is FRR's `VRF_UNKNOWN`. bgpd resolves `router bgp <asn> vrf <name>`
to a kernel VRF device when it parses that stanza; if the device is replaced
afterwards, the instance is left unattached and goes inert. Phase 3 replaces
every one of them — recreating the CUDNs on the new subnets makes
OVN-Kubernetes tear down each tenant VRF and build a new one with a new table
id. The two tells are `0.0.0.0` (bgpd cannot see into the VRF to find an
address) and zero messages in **both** columns: it never attempts the
connection.

Healthy is the same command showing a real router-id and a real table id:

```
BGP router identifier 192.168.141.34, local AS number 64512 VRF blue vrf-id 118
192.168.141.1   4 64513      27      25 00:00:55            2       1
```

Fix it by restarting frr-k8s, which starts bgpd with the VRFs already present:

```bash
oc -n openshift-frr-k8s rollout restart daemonset/frr-k8s
oc -n openshift-frr-k8s rollout status daemonset/frr-k8s --timeout=300s
```

Each node's default-VRF session drops for a few seconds. That is the whole
cost. The role now does this automatically at the end of phase 3, and only
when some instance actually reports `vrf-id -1`.

#### Why this one is worth knowing by name

Every layer above it reports success, and each one is telling the truth about
its own job:

| Check | Says | And is right |
| --- | --- | --- |
| `oc get nncp` | `Available` | the VLAN subinterfaces exist and are in the VRFs |
| `oc get routeadvertisements` | `Accepted` | OVN-K read the config and generated its own |
| `oc get frrconfiguration` | present | including six `ovnk-generated-*` |
| `grep 'router bgp' frr.conf` | four VRF routers | frr-k8s rendered it correctly |
| `vtysh -c 'show vrf'` | `blue id 118 table 1116` | zebra sees every VRF |
| `show bgp summary` | one session, up 1d22h | the *default* VRF is fine |
| leaf1 `ip vrf exec blue ping <node>` | 0.38ms, ARP `REACHABLE` | the wire is fine |

Only `show bgp vrf all summary` disagrees. The leaf's own view —
`Active`/`never` — reads like a connectivity fault and points at the wrong
layer, which is where the time goes: the tempting moves are to suspect the
VRF port list, 802.1Q across the bridge chain, or an frr-k8s merge conflict,
and all three are answered by checks that pass.

The lab's containerlab topology already works around the same hazard on the
leaf: `udnbgp.clab.yml.j2` reloads FRR *after* the VRFs and subinterfaces are
built, with the comment "so bgpd sees every VRF at startup". That is this bug,
on the other end of the wire. The node side never had the equivalent.

### 3e. The test that must fail

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

The failures are the result, and they are not interchangeable. Their external
networks are one hop away on the same physical link, so nothing but the VRF
separates them — but blue→red could in principle fail because the two share a
subnet and the routing is ambiguous rather than isolated. **blue→orange
cannot.** Orange overlaps with nothing, so a failure to reach it is the VRF
and only the VRF. That is the isolation result; blue→red is the overlap
result.

If any of them succeeds, the VRFs are leaking — check `targetVRF` is `auto`
and that the cluster is in local gateway mode. If *everything* times out,
including the positive half, that is not isolation, it is a broken phase.

```bash
oc debug node/worker1 -- chroot /host ip route show vrf blue
docker exec clab-udnbgp-leaf1 vtysh -c 'show ip route vrf blue'
```

### 3f. The whole matrix at once, and the thing ping cannot tell you

The tests in 3e are one cell each. There are sixteen, in two directions, and
the interesting ones are the failures — so running them by hand means reading
a lot of timeouts and deciding by eye which were supposed to time out.

```bash
scripts/udn-vrf-isolation.sh
```

Two matrices, a verdict, and an identity check. Expect `ok` on the diagonal
and `FAIL` everywhere else, in *both* directions:

```
pod tenant   blue       red        orange     green
blue         ok         FAIL       FAIL       FAIL
red          FAIL       ok         FAIL       FAIL
orange       FAIL       FAIL       ok         FAIL
green        FAIL       FAIL       FAIL       ok
```

A whole row of `FAIL` including the diagonal is that tenant's handoff, not
isolation. Everything `ok` is not success — it means `targetVRF` never took
effect and you are still looking at phase 2.

The diagonal is collapsed strictly and the off-diagonal loosely, which is
deliberate: on the diagonal every node must reach its own endpoint, so a cell
reads `2/3` rather than `ok` when one node fails and the per-node faults this
lab keeps producing (strict `rp_filter`, a missing NNCP) stay visible. Off the
diagonal a single node getting through is already a leak, so any success wins
and the cell reads `ok(1/3)`.

#### Where the clients are, and why not anywhere else

Phase 2 needed a client VM: the question was whether a real machine outside the
cluster could reach a pod, and the `*-ext` containers sat behind leaf1 rather
than in front of it.

Phase 3 asks a different question, and the containers already answer it. The
topology enslaves each tenant's external link to that tenant's VRF on leaf1:

```yaml
- ip link add blue type vrf table 1110
- ip link set blue-ext master blue          # ← the client link is IN the VRF
```

So the four `*-ext` containers *are* four clients, each already in its own VRF,
and nothing about the network is proven by replacing them with VMs — the
packets take a byte-identical path. A netns with its own routing table is a
host for an L3 test.

There are still per-tenant client **VMs** (`--tags clabtenantclients`), for two
reasons that are worth being honest about. Neither is correctness:

1. **Demonstration.** Two machines you can `ssh` into, pinging addresses out of
   the same `10.200.0.0/16` and reaching different pods, is a better thing to
   show someone than a counter diff inside a container.
2. **No second path.** Every `*-ext` container has `eth0` on
   `clab-udnbgp-mgmt`, a route between them that exists outside the fabric. It
   cannot produce a false pass — the tests ping tenant addresses and default is
   via `external_gw` — but a VM with one fabric NIC has no such thing to
   explain away.

Where they attach matters far more than whether they are VMs, and the two
obvious spots are both wrong:

| Attachment | Why not |
| --- | --- |
| The tenant handoff VLAN (110–140) | The client shares a broadcast domain with all three workers, so leaf1 answers with an ICMP redirect and traffic goes direct. Worse, the client has no VLAN 120 interface at all — so blue-cannot-reach-red is proven by **802.1Q**, not by the VRF. Nobody doubts two VLANs don't mix. |
| The tenant's existing `external_prefix` | That subnet is already connected on leaf1 through the `<tenant>-ext` veth. A second interface carrying it gives the VRF two ambiguous paths to one network. |

So each client gets **its own segment**, a VLAN on the same fabric bridge with
leaf1 holding the gateway inside the tenant VRF:

| Tenant | Client VLAN | Segment | leaf1 | client |
| --- | --- | --- | --- | --- |
| blue | 210 | `10.215.10.0/24` | `.1` in VRF blue | `.20` |
| red | 220 | `10.216.10.0/24` | `.1` in VRF red | `.20` |
| orange | 230 | `10.217.10.0/24` | `.1` in VRF orange | `.20` |
| green | 240 | `10.218.10.0/24` | `.1` in VRF green | `.20` |

Off-segment from the nodes, so leaf1 genuinely routes. Reachable only from the
VLAN that lands in that VRF. leaf1 originates each segment into its VRF so the
cluster learns the **return** path over BGP — without that the pods can be
reached but cannot answer, which presents as a one-way fabric fault.

#### Why three VMs and not one, or four

```yaml
udnclient-blue: [blue]        # 10.200.0.0/16
udnclient-red:  [red]         # 10.200.0.0/16  - same prefix, must be separate
udnclient-og:   [orange, green]   # 10.202.0.0/16 and 10.204.0.0/16 - distinct
```

The grouping is forced by the addressing, not chosen for tidiness. Blue and red
carry the **same** pod subnet in phase 3, and one host has one routing table: a
single VM serving both would hold one route to `10.200.0.0/16`, reach one
tenant, and silently never reach the other. Orange and green don't collide, so
one VM with two VLAN subinterfaces and two routes serves both — **and needs no
VRFs of its own to do it.**

That last point is why the clients are not one multi-VRF machine. A client-side
VRF fault would be indistinguishable from the leaf-side VRF fault under test,
and leaf1 is the thing being tested. The clients stay dumb. `tenant-client-vms.yml`
asserts the no-overlap rule rather than trusting it, so adding a fifth tenant
later cannot quietly produce a meaningless result.

Drive them with:

```bash
scripts/udn-vrf-isolation.sh --vms
```

```
client VM -> pod   (expect ok only for the tenants each VM serves)
client           blue       green      orange     red
udnclient-blue   ok         FAIL       FAIL       FAIL
udnclient-red    FAIL       FAIL       FAIL       ok
udnclient-og     FAIL       ok         ok         FAIL
```

The two rows to read together are the per-destination lines behind that
matrix, not the matrix itself:

```
udnclient-blue   -> red   10.200.2.3   FAIL
udnclient-red    -> red   10.200.2.3   ok
```

**Two separate machines, the same destination address, opposite results.**
`10.200.2.3` is inside the `/16` that blue and red both carry, and the only
thing deciding whether it resolves is which VRF the packet entered leaf1 on.
Nothing in either VM differs but the VLAN tag.

That is worth stating because it is a *different* proof from the identity check
further down, and it does not depend on OVN having allocated a colliding
address. It is available on every run.

These need the topology **redeployed** (`--tags clabdeploy`) after
`udn_client_segments` was added — leaf1 builds the client VLAN subinterfaces in
its `exec` block at container start, so an already-running leaf1 has none of
them and every client fails at its gateway.

#### A healthy phase 3, in full

Confirmed on a 4.22 hub with three workers, four tenants and three client VMs.
All three matrices, every cell:

```
pod -> external endpoint      external endpoint -> pod      client VM -> pod
pod tenant blue  grn  org  red    ext     blue  grn  org  red    client          blue grn  org  red
blue       ok    FAIL FAIL FAIL   blue    ok    FAIL FAIL FAIL   udnclient-blue  ok   FAIL FAIL FAIL
green      FAIL  ok   FAIL FAIL   green   FAIL  ok   FAIL FAIL   udnclient-red   FAIL FAIL FAIL ok
orange     FAIL  FAIL ok   FAIL   orange  FAIL  FAIL ok   FAIL   udnclient-og    FAIL ok   ok   FAIL
red        FAIL  FAIL FAIL ok     red     FAIL  FAIL FAIL ok
```

```
Verdict
 pod -> ext:       clean: every tenant reached its own external network and nobody else's
 ext -> pod:       clean: every tenant reached its own pods and nobody else's
 client VM -> pod: clean: every client VM reached exactly the tenants it serves

PASS - phase 3 isolation holds in both directions.
```

`udnclient-og` holding **both** `ok` cells on one row is the other half of the
addressing argument: orange and green do not collide, so one host serves both
with two routes and no VRFs of its own. blue and red each need their own
machine for the same reason that row is possible.

#### Curl it instead: a page that names the responder

```bash
ansible-playbook setup_udn_bgp_lab.yaml -i inventory/hosts --tags web --ask-vault-pass
scripts/udn-web-demo.sh
```

One pod per tenant, serving a page built at start-up from what the running pod
knows:

```
I am blue

tenant:   blue
pod:      udn-web-6c9f4d7b8-x2klm
node:     worker1
udn:      10.200.4.5/24
subnet:   10.200.0.0/16
```

`scripts/udn-web-demo.sh` curls every tenant's pod from every client VM.
Confirmed output:

```
Web pods
  blue     http://10.200.4.4:8080/
  red      http://10.200.1.5:8080/

What answered
client           blue           red
udnclient-blue   I am blue      (no answer)
udnclient-red    (no answer)    I am red
udnclient-og     (no answer)    (no answer)
```

Both addresses are inside `10.200.0.0/16` — `10.200.4.0/24` is blue's slice on
its node, `10.200.1.0/24` is red's. The only difference between those machines
is the VLAN tag on their fabric interface, and that is what decided which
document came back.

**The third row is the one that closes the argument.** Two machines each
reaching "their" page is consistent with a weaker story — that both pages are
reachable from anywhere and each VM simply found one. `udnclient-og` sits on
the same fabric bridge with VLANs for orange and green and none for blue or
red, and it gets nothing from either. So the pages are not reachable from
anywhere; they are reachable from exactly one VRF each.

Two details worth knowing:

- **The address comes off `ovn-udn1`, not `status.podIP`.** For a primary UDN,
  `podIP` is the *cluster* network address on `eth0` — printing it would show
  an address with nothing to do with what was curled.
- **This pod needs no privileged SCC**, unlike the ping DaemonSet. It listens
  on 8080 as a non-root user, which `restricted-v2` allows; the DaemonSet needs
  `NET_RAW` and therefore a ServiceAccount bound to `system:openshift:scc:privileged`.
  Listening above 1024 is the whole difference.

Where blue and red pods *do* land on the same address, this replaces the
counter check below outright: same URL, two machines, two answers, each naming
itself.

#### A successful ping does not prove isolation

This is the part 3e cannot cover and no amount of extra clients would fix.

Blue and red both use `10.200.0.0/16`. When `blue-ext` pings `10.200.0.5` and
gets a reply, that reply proves *something* answered. It does not prove
**which pod** answered — and "the wrong tenant's pod replied to the right
address" is precisely the failure VRF-Lite exists to prevent. ICMP carries no
identity, so a reachability test is structurally incapable of detecting the
one leak that matters most.

The script closes that by counting instead of pinging. `InEchos` in
`/proc/net/snmp` is incremented by the kernel of the pod that actually
received the echo request, so reading it on *both* candidate pods either side
of a single ping names the responder:

```
Overlapping-address identity check

  10.200.0.5 is held by: blue red
    blue-ext   pinged 10.200.0.5      answered by blue(+3)   correct
    red-ext    pinged 10.200.0.5      answered by red(+3)    correct

  Every ext container reached its OWN tenant's pod at the shared
  address. Same destination IP, different VRF, different pod -
  which is the whole claim of VRF-Lite, measured rather than assumed.
```

`WRONG TENANT` there is the finding the two matrices would have reported as a
clean pass.

If OVN hands blue and red distinct addresses out of their identical subnets
there is no collision to disambiguate, and the script says so rather than
inventing a result.

**Expect that to be the normal case, and possibly the only one.** On this lab
the six node slices came out pairwise disjoint — blue got `10.200.4/5/0.0/24`
and red got `10.200.1/2/3.0/24`, covering 0–5 with no repeats. Independent
per-network allocation starting at the base of the CIDR would have produced
three *identical* pairs, so something is handing these out from one sequence
across both networks. It is not a correctness requirement — no `ip rule`
references the subnet in phase 3, so identical addresses would be unambiguous —
which makes it a property of OVN-Kubernetes' allocator rather than of the data
path.

So treat this check as a bonus that may never fire, and the web demo
(§3f, *Curl it instead*) as the reliable proof of identity.

---

### 3f-bis. purple: the same address on two networks

blue and red share `10.200.0.0/16` and never produced two pods on one address.
Layer3 slices the prefix per node, and OVN-Kubernetes handed the six slices out
pairwise disjoint — so "same IP, different pod" stayed a claim.

**purple** is a Layer2 tenant carrying green's subnet exactly:

| | green | purple |
| --- | --- | --- |
| topology | Layer2 | Layer2 |
| `udn_subnet` | `10.204.0.0/16` | `10.204.0.0/16` |
| handoff VLAN | 140 | 150 |
| client VLAN | 240 | 250 |
| client VM | `udnclient-og` | `udnclient-purple` |

Layer2 has no per-node slicing — the whole prefix exists on every node and IPAM
allocates from the base of it — so green's first pod and purple's first pod
should land on the *same* address.

**The experiment is worth running whichever way it goes.** A collision
demonstrates the claim outright. No collision is the stronger result: it means
OVN-Kubernetes coordinates allocation across networks sharing a CIDR even with
no slicing to coordinate, and two pods on one address is simply not obtainable
— which settles a question this lab has otherwise only been able to infer.

purple needs **its own client VM**. One host holds one route to
`10.204.0.0/16`, so a machine serving both green and purple would reach one and
silently never reach the other. That is the same rule that forces blue and red
apart, and `tenant-client-vms.yml` asserts it rather than trusting it.

#### What a ping can no longer tell you

Once two tenants share a pod address, a ping to it answers for **both**, and
ICMP carries nothing to say which replied. `udn-vrf-isolation.sh` marks those
cells `AMBIG` and excludes them from the verdict rather than calling them
`ok` — which it would otherwise report as a leak:

```
  green-ext    -> purple   10.204.0.3       AMBIG (address shared with green purple)
  udnclient-og -> purple   10.204.0.3       AMBIG (address shared with green purple)
```

Note which cells stay judged. `blue-ext -> purple` is *not* ambiguous: blue owns
nothing on that address, so an answer there really would be a leak. Only a
source that already owns one of the tenants sharing the address is excluded.

Two things do resolve it:

- **The identity check** — `InEchos` in `/proc/net/snmp` on both candidate pods,
  either side of one ping. This is the case it was written for, and purple is
  what finally makes it fire.
- **The web demo** — the page names its own tenant, so one URL returning two
  documents needs no inference at all.

```
client             10.204.0.3
(served by)        green purple
udnclient-og       I am green
udnclient-purple   I am purple
```

One address. Two machines. Two pages. That is the claim, demonstrated rather
than argued.

### 3g. Following one curl in phase 3

Phase 2's walkthrough followed a ping. This follows a `curl`, because TCP
carries a request *and* an identified response, and identity is the whole
question once blue and red share a subnet.

The sharpest case is the one the lab actually produced. Both web pods landed on
**worker1**: `10.200.4.0/24` is blue's worker1 slice and `10.200.1.0/24` is
red's, so `10.200.4.4` and `10.200.1.5` are served by two pods on one node,
reached over one physical NIC. Confirm with:

```bash
oc get pods -A -l app=udn-web -o wide
```

#### Out — `udnclient-blue` to blue's page

`curl http://10.200.4.4:8080/`

| # | Where | What happens |
| --- | --- | --- |
| 1 | the client VM | One routing table, one matching route: `10.200.0.0/16 via 10.215.10.1 dev <nic>.210`. The frame leaves **tagged VLAN 210**. |
| 2 | virbr1 → clab VM → `br-fabric` | Carried untouched. `vlan_filtering` is 0 on the guest bridge, which is why a tag survives the chain at all. |
| 3 | **leaf1 `eth1.210`** | **The decision point.** That interface is enslaved to VRF `blue`, so the lookup happens in **table 1110** — not in `main`. Nothing about the destination address chose this; the *ingress interface* did. |
| 4 | leaf1 table 1110 | `10.200.4.0/24` was learned over BGP from worker1 at `192.168.141.34`, out `eth1.110` — also in VRF blue. Frame leaves **tagged VLAN 110**. |
| 5 | worker1 `enp8s0.110` | In VRF blue, **table 1116**. `10.200.4.0/24 dev ovn-k8s-mp10`. |
| 6 | OVN | Into the pod. httpd answers on 8080. |

#### Back — the pod to the client

| # | Where | What happens |
| --- | --- | --- |
| 7 | the pod | Replies to `10.215.10.20`. Out `ovn-udn1`, to `ovn-k8s-mp10`. |
| 8 | worker1 | The l3mdev rule sends it to the tenant VRF, **table 1116**. |
| 9 | table 1116 | `10.215.10.0/24 via 192.168.141.1 dev enp8s0.110`, learned over BGP — because leaf1 carries `network 10.215.10.0/24` **inside the blue VRF**. Out **tagged VLAN 110**. |
| 10 | leaf1 `eth1.110` | VRF blue again, table 1110. `10.215.10.0/24` is connected on `eth1.210`. Out **tagged VLAN 210**. |
| 11 | the client VM | Reply arrives on the same interface the request left. |

**Step 9 is the one to keep.** That `network` statement in leaf1's per-VRF
stanza is not decoration — without it the pod is reachable and cannot answer,
and the symptom is a one-way fabric that looks like a drop somewhere in the
middle. It exists so the *return* path is learned, not the forward one.

#### The same curl from `udnclient-red`

`curl http://10.200.1.5:8080/` — every step is identical in shape:

| Step | blue | red |
| --- | --- | --- |
| client's route | `10.200.0.0/16 via 10.215.10.1` | `10.200.0.0/16 via 10.216.10.1` |
| leaves on | VLAN 210 | VLAN 220 |
| leaf1 ingress | `eth1.210`, VRF blue | `eth1.220`, VRF red |
| leaf1 table | 1110 | 1120 |
| next hop | `192.168.141.34` | `192.168.142.34` |
| toward worker1 on | VLAN 110 | VLAN 120 |
| node table | 1116 | 1117 |
| management port | `ovn-k8s-mp10` | `ovn-k8s-mp11` |

**`10.200.0.0/16` exists in both of leaf1's tables, with different next hops.**
Two routes to the same prefix, and no tiebreak is ever needed because they are
never compared — they live in different tables, and which table gets consulted
was settled at step 3 by the VLAN the frame arrived on.

That is the entire mechanism of VRF-Lite, and it is why the demo works: the
destination address does not select the path.

#### Why no `ip rule` mentions the tenant subnet any more

Phase 2 needed three rules per tenant at priority 2000 — fwmark, masquerade,
and **subnet**:

```
2000:  from all to 10.221.0.0/16 lookup 1117
```

That subnet rule was load-bearing. Fabric traffic arrived on `br-ex`, which
lives in the **default** VRF, so something had to redirect it into the tenant's
table *by destination address* — and a tenant missing that one rule was
unreachable on every node while every control-plane signal stayed green. It
cost a debugging session.

Phase 3 has no such rule:

```bash
oc debug node/worker1 -- chroot /host ip rule show | grep -E '10\.200|l3mdev'
# 1000:	from all lookup [l3mdev-table]
```

Nothing references `10.200.0.0/16` at all. It does not need to: the fabric
interface `enp8s0.110` is itself **inside** the blue VRF, so l3mdev at priority
1000 picks the table from the interface the frame arrived on, before any
priority-2000 rule is reached. The destination address never enters the
steering decision.

Two consequences worth having:

- **The phase-2 missing-rule failure cannot happen here.** There is no rule to
  be missing. If a tenant is unreachable in phase 3, look at VRF membership and
  BGP, not at `ip rule`.
- **Identical pod addresses between blue and red would be unambiguous.** The
  concern would have been two `to 10.200.0.0/16` rules pointing at different
  tables with order deciding. There are none, so nothing compares them.

#### Why phase 3 is symmetric and phase 2 was not

Phase 2's request crossed the fabric and its reply came back via the node's
*default gateway* on a different interface — asymmetric by construction, which
is why it needed loose `rp_filter` on the nodes, on the lab host and on the
client, and why one node left strict silently swallowed a whole column of the
matrix.

Here, steps 1–6 and 7–11 traverse the same two VLANs in reverse, in the same
VRF, on the same interfaces. Nothing is asymmetric, so nothing needs
`rp_filter` relaxed. `udn-tenant-client-routes.sh` sets it loose anyway, so
that a real isolation result is never mistaken for an rp_filter drop — set it
to `1` and the tests should still pass. That difference is worth naming in the
phase 2 / phase 3 comparison: VRF-Lite did not only isolate the tenants, it
made the path symmetric.

#### Watching it

Three points, while `scripts/udn-web-demo.sh` runs:

```bash
# on the client VM - the request leaving, tagged
tcpdump -nei <nic>.210 tcp port 8080

# on leaf1 - the same frame arriving in the blue VRF, then leaving on VLAN 110
ssh root@192.168.122.40 \
  "docker exec clab-udnbgp-leaf1 tcpdump -nei eth1 'vlan 210 or vlan 110' and tcp port 8080"

# on worker1 - arriving in the tenant VRF
oc debug node/worker1 -- chroot /host timeout 10 tcpdump -nei enp8s0.110 tcp port 8080
```

The leaf1 capture is the one that shows the mechanism: the same TCP stream
appears twice, once tagged 210 and once tagged 110, with the VRF lookup in
between.

---

## Phase 4: EVPN

> **Automate this step**
> ```
> ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags evpn
> ```
> Role: `tasks/evpn.yml`, `templates/vtep.yaml.j2`, `templates/nncp-vtep.yaml.j2`, `templates/cudn-evpn.yaml.j2`, `templates/frrconfiguration-evpn.yaml.j2`, `templates/routeadvertisements-udn-evpn.yaml.j2`
>
> Runs Parts 1-6 and phase 1 first, recreates the tenants with `transport: EVPN`, then this.

Requires **4.22+**. Each *node* becomes a VXLAN tunnel endpoint; tenant routes
are EVPN type-5 routes carrying a per-tenant VNI, and the data plane is VXLAN
node-to-node.

This phase does **not** build VRF-Lite's plumbing, and removes it if present.
With node VTEPs the VLAN handoff is not the path, and leaving it in place
would give each tenant two routes to the same destinations with nothing
choosing between them.

### 4a. VTEP addresses on the nodes, first

Order matters: the addresses must exist before the `VTEP` CR, because in
`Unmanaged` mode the CR's job is to *discover* what is already there. A CR
created against nodes with no matching address goes straight to failed.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: vtep-worker1
spec:
  nodeSelector:
    kubernetes.io/hostname: worker1
  desiredState:
    interfaces:
      - name: vtep0
        type: dummy
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 100.64.0.34
              prefix-length: 32
        ipv6:
          enabled: false
EOF

oc wait nncp/vtep-worker1 --for=condition=Available --timeout=300s
```

A dummy interface with a /32 — the VTEP address is an identity, not a subnet.
One per node, `.34/.35/.36` matching `ip_list`.

### 4b. The VTEP CR

```bash
cat <<'EOF' | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  cidrs:
    - 100.64.0.0/24
  mode: Unmanaged
EOF

oc wait vtep/evpn-vtep --for=condition=Accepted=True --timeout=300s
oc get vtep evpn-vtep -o wide
```

`Unmanaged` means OVN-Kubernetes finds each node's address inside the CIDR
rather than assigning one. Exactly one match per node is required — **an
ambiguous match is a failure, not a choice**. `Managed` mode makes `cidrs`
append-only.

### 4c. The CUDNs, recreated

`network.transport` is **immutable**. A CUDN created without it can never be
moved to `transport: EVPN` in place, so the tenants are deleted and created
again — along with their namespaces, for the primary-network reason in phase 2.

```bash
oc delete namespace udn-blue udn-red --ignore-not-found --wait=true --timeout=300s
oc delete clusteruserdefinednetwork blue red --ignore-not-found --wait=true --timeout=300s

cat <<'EOF' | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: blue
  labels:
    bgp: "enabled"
    udn-lab-phase: evpn
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
EOF
```

Then recreate the namespaces and DaemonSets from phase 2 unchanged.

`transport` and `evpn` sit under **`spec.network`**, not at the top of `spec`.
`ipVRF` is required for Layer3 and `macVRF` is forbidden there; a Layer2 CUDN
is the other way round. Red uses VNI 201 and `65000:201`.

### 4d. EVPN peering and advertisement

```bash
cat <<'EOF' | oc apply -f -
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
      - asn: 64512
        neighbors:
          - address: 192.168.140.1
            asn: 64513
            addressFamilies:
              - unicast
              - evpn
            allowAsIn: origin
            holdTime: 9s
            keepaliveTime: 3s
            port: 179
            toReceive: { allowed: { mode: all } }
            toAdvertise:
              allowed:
                prefixes:
                  - 100.64.0.0/24
        prefixes:
          - 100.64.0.0/24
  nodeSelector: {}
EOF
```

The session carries **both** address families. `unicast` advertises the VTEP
addresses so the nodes can find each other — without a route to a node's VTEP
there is no tunnel to it, whatever the EVPN table says — and `evpn` carries
the type-5 routes. `allowAsIn: origin` is needed because every node is in AS
64512, so a node would otherwise discard its peers' routes as a loop.

```bash
cat <<'EOF' | oc apply -f -
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
EOF
```

Shape-identical to phase 3 — same `targetVRF: auto`, same network selector —
selecting a different FRRConfiguration. EVPN changes how routes *travel*, not
how they are advertised.

### 4e. Remove phase 3

```bash
oc delete routeadvertisements udn-vrflite udn-shared-vrf --ignore-not-found
oc delete nncp vrflite-blue-worker1 vrflite-blue-worker2 vrflite-blue-worker3 \
               vrflite-red-worker1  vrflite-red-worker2  vrflite-red-worker3 --ignore-not-found
oc delete frrconfiguration fabric-peering-vrflite -n openshift-frr-k8s --ignore-not-found

oc get routeadvertisements udn-evpn -o jsonpath='{.status.status}'; echo
```

Again the wait comes after the delete.

### 4f. Verify, underlay first

```bash
docker exec clab-udnbgp-leaf1 vtysh \
  -c 'show ip route 100.64.0.0/24 longer-prefixes' \
  -c 'show bgp l2vpn evpn summary' \
  -c 'show bgp l2vpn evpn'
```

In that order. EVPN can be healthy at the control plane and dead at the data
plane — sessions up, type-5 routes on both sides, and no tunnel, because
neither VTEP can reach the other.

```bash
oc get nodes -o custom-columns=NODE:.metadata.name,VTEP:.metadata.annotations.k8s\\.ovn\\.org/node-vtep-ips
```

Empty for a node means OVN-Kubernetes found no address inside `100.64.0.0/24`
on it. The annotation key varies by release; if the column is empty for every
node, read `oc get node <node> -o yaml | grep -i vtep` rather than trusting it.

---

## Live migration on the Layer2 tenant

> **No automation.** The role creates the `green` CUDN and the `udn-green`
> namespace; the VM is yours to build. Works from `--tags shared` onwards.

The reason `green` exists. A VM that changes address when it moves node has
not really migrated, and Layer3 guarantees it will: the subnet is sliced per
node, so an address that is valid on worker1 is not valid on worker2.

Layer2 is one flat broadcast domain across every node — the whole prefix
exists everywhere — and `ipam.lifecycle: Persistent` ties the allocation to
the VM rather than to the pod backing it. That second part is what makes live
migration work at all, because a migration **replaces the pod**: a new
`virt-launcher` starts on the target node and takes over. Without persistent
IPAM the VM arrives with a different address.

Needs OpenShift Virtualization installed. Everything else is already in place
after any phase from `shared` on.

### Build a VM on it

```bash
cat <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: green-vm
  namespace: udn-green
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
          interfaces:
            # The interface name and the network name below must match.
            - name: green-net
              binding:
                # Not masquerade. l2bridge puts the VM directly on the UDN's
                # virtual switch, which is what keeps its MAC and IP its own
                # rather than NATed behind the pod's.
                name: l2bridge
        resources:
          requests:
            memory: 1Gi
      networks:
        # pod: {} means "the namespace's primary network" - which for
        # udn-green is the green CUDN, not the cluster pod network.
        - name: green-net
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:41
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: green
              chpasswd: { expire: False }
EOF

oc -n udn-green get vmi green-vm -o wide -w
```

If `l2bridge` is rejected as an unknown binding, it has not been registered —
check `oc get hyperconverged -n openshift-cnv kubevirt-hyperconverged -o yaml`
for `spec.network.binding`.

Record what you are about to test:

```bash
oc -n udn-green get vmi green-vm -o custom-columns=\
NAME:.metadata.name,IP:.status.interfaces[0].ipAddress,MAC:.status.interfaces[0].mac,NODE:.status.nodeName
```

The address should be from `10.204.0.0/16` — the whole tenant prefix, not a
per-node slice of it. That is the visible difference from the other three
tenants, and it is worth comparing side by side:

```bash
oc -n udn-blue  get pods -o wide     # 10.200.<node slice>.x
oc -n udn-green get vmi  -o wide     # 10.204.x.x, from anywhere in the /16
```

### Migrate it

`virtctl migrate green-vm -n udn-green`, or with no virtctl:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: green-vm-migrate-1
  namespace: udn-green
spec:
  vmiName: green-vm
EOF

oc -n udn-green get vmim green-vm-migrate-1 -w
```

If it refuses, the VM is not migratable and the reason is on the VMI:

```bash
oc -n udn-green get vmi green-vm -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

A `containerDisk` VM is migratable — the disk is immutable and present on
every node. A writable RWO PVC is the usual reason one is not.

### What to watch, and where

Run this from the tenant's own external endpoint **before** starting the
migration. It is the whole demonstration in one window:

```bash
# on the clab VM - green-ext is behind leaf1 in the green VRF
docker exec clab-udnbgp-green-ext ping -i 0.2 <vm ip>
```

A successful live migration costs a handful of packets, not a timeout and a
reconnect. Then:

| Check | Expect |
| --- | --- |
| `oc -n udn-green get vmi green-vm -o wide` | `NODE` changed, `IP` **unchanged** |
| Inside the VM: `ip -br addr` | Identical. No DHCP renew, no new lease |
| `oc -n udn-green get pods` | A **different** `virt-launcher` pod, on the new node |
| `docker exec clab-udnbgp-leaf1 vtysh -c 'show ip route vrf green'` | `10.204.0.0/16` still there; the next hop may change, the prefix does not |
| `sudo tcpdump -eni virbr1 arp` during the migration | A gratuitous ARP for the VM's address from the new node's MAC |

That last one is the mechanism made visible: nothing re-addressed anything,
the fabric was simply told where the address lives now.

### What each phase adds to it

The migration itself works in every phase — it is a property of the Layer2
UDN, not of BGP. What changes is how far the illusion extends:

| Phase | The VM's address is reachable from |
| --- | --- |
| `shared` | The fabric, via the default VRF, alongside every other tenant |
| `vrflite` | The fabric, inside green's own VRF and VLAN, isolated from the other tenants |
| `evpn` | The same, over VXLAN — and the broadcast domain itself is stretched, because a Layer2 tenant under EVPN gets a **macVRF** (an L2VNI carrying MAC reachability) rather than the ipVRF a Layer3 tenant gets |

The EVPN case is the interesting one for migration specifically: the L2 domain
no longer stops at the cluster. A VM moving between nodes is a MAC moving
between VTEPs, which is a thing EVPN has a type-2 route for and an answer to.
That is also why `evpn_mac_vni` exists in `vars.yaml` and had nothing using it
until this tenant.

---

## Teardown

> **No automation.** The role builds and moves forward between phases; it
> never unwinds itself. These are by hand.

Cluster objects, roughly in reverse:

```bash
oc delete routeadvertisements --all
oc delete frrconfiguration -n openshift-frr-k8s fabric-peering-default fabric-peering-vrflite fabric-peering-evpn --ignore-not-found
oc delete vtep evpn-vtep --ignore-not-found
oc delete namespace udn-blue udn-red --ignore-not-found
oc delete clusteruserdefinednetwork blue red --ignore-not-found
oc delete nncp --all
```

The generated `route-advertisements-*` FRRConfigurations disappear with their
CRs. Deleting the NNCPs does **not** remove the interfaces they created —
nmstate leaves the last applied state in place; write a policy with
`state: absent` if you want the fabric NICs unconfigured.

To return the cluster's network config to where it started:

```bash
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

That is another full `ovnkube-node` rollout.

---

## Which file does what

| Manual step | Role file |
| --- | --- |
| Part 1 | `tasks/preflight.yml` |
| Part 2 | `tasks/enable.yml` |
| Part 3 | `tasks/node-names.yml` |
| Part 4 | `tasks/nmstate.yml`, `templates/nmstate-operator.yaml.j2`, `templates/nmstate-instance.yaml.j2` |
| Part 5 | `templates/tuned-forwarding.yaml.j2`, `templates/nncp-fabric-untagged.yaml.j2` |
| Part 6 | `templates/frrconfiguration-default.yaml.j2` |
| Phase 1 | `templates/routeadvertisements-default.yaml.j2` |
| Phase 2 | `templates/cudn.yaml.j2`, `templates/workload.yaml.j2`, `templates/routeadvertisements-udn-shared.yaml.j2` |
| Phase 3a | `tasks/vrflite-discover.yml` |
| Phase 3b–d | `tasks/vrflite-apply.yml`, `templates/nncp-vrflite.yaml.j2`, `templates/frrconfiguration-vrflite.yaml.j2`, `templates/routeadvertisements-udn-vrflite.yaml.j2` |
| Phase 4 | `tasks/evpn.yml`, `templates/nncp-vtep.yaml.j2`, `templates/vtep.yaml.j2`, `templates/cudn-evpn.yaml.j2`, `templates/frrconfiguration-evpn.yaml.j2`, `templates/routeadvertisements-udn-evpn.yaml.j2` |
| Every "confirm it took" | `tasks/wait-ra.yml`, `tasks/verify.yml` |
| Rendering, ordering | `tasks/main.yml`, `tasks/apply.yml` |
| Phase 2 reachability, by hand | `scripts/udn-reachability.sh` |
| Phase 3 isolation, by hand | `scripts/udn-vrf-isolation.sh` |
| Capturing a phase to diff against the next | `scripts/udn-snapshot.sh` |

The role renders every manifest to `udn-bgp/` beside the playbook before
applying it, so after any run the exact YAML that was sent is on disk to read,
diff and re-apply by hand.

For troubleshooting, see the table at the end of the
[README](README.md#udn-over-bgp-vrf-lite-and-evpn-containerlab-fabric).
