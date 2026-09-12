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
from each. And under EVPN it takes a **macVRF** — an L2VNI carrying MAC
reachability — where the Layer3 tenants take an ipVRF carrying prefixes.

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
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
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
that network first has something on the node.

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

The VRF's name comes from the CUDN's **status**, not its metadata name. Linux
caps an interface name at 15 characters, so a longer CUDN name necessarily has
a VRF called something else, and the naming scheme is OVN-Kubernetes' to
change between releases:

```bash
oc get clusteruserdefinednetwork blue -o jsonpath='{.status.vrfName}'; echo
oc get clusteruserdefinednetwork red  -o jsonpath='{.status.vrfName}'; echo
```

An empty answer means the CUDN has not been reconciled yet — check its
`NetworkCreated` condition rather than proceeding.

Then, per node, read the link table:

```bash
oc debug node/worker1 --quiet -- chroot /host ip -d link show type vrf
oc debug node/worker1 --quiet -- chroot /host ip -br link show master blue
```

For each (node, tenant) you need three facts:

| Fact | Where it comes from | Why it matters |
| --- | --- | --- |
| VRF device name | `status.vrfName` | Must match the kernel device exactly |
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

The `vrf:` values are the ones read from `status.vrfName` — FRR renders them
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

The role renders every manifest to `udn-bgp/` beside the playbook before
applying it, so after any run the exact YAML that was sent is on disk to read,
diff and re-apply by hand.

For troubleshooting, see the table at the end of the
[README](README.md#udn-over-bgp-vrf-lite-and-evpn-containerlab-fabric).
