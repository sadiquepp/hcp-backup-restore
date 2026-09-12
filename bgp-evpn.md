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
- [Phase 2: UDNs in the default VRF](#phase-2-udns-in-the-default-vrf)
- [Phase 3: VRF-Lite](#phase-3-vrf-lite)
- [Phase 4: EVPN](#phase-4-evpn)
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

### The two tenants

| | blue | red |
| --- | --- | --- |
| VLAN (phase 3) | 110 | 120 |
| VRF handoff subnet (phase 3) | `192.168.141.0/24` | `192.168.142.0/24` |
| UDN subnet, phase 2 | `10.220.0.0/16` | `10.221.0.0/16` |
| UDN subnet, phases 3–4 | `10.200.0.0/16` | `10.200.0.0/16` |
| External network behind leaf1 | `10.210.10.0/24` | `10.211.10.0/24` |
| External test host | `10.210.10.10` | `10.211.10.10` |
| IP-VRF VNI (phase 4) | 101 | 201 |

The phase 3–4 subnets are **identical on purpose**. Two UDNs carrying the same
addresses in isolation is most of the point of VRF-Lite, and it is the one
result a phase-2 setup cannot fake. Phase 2 has to use distinct subnets
because leaking two overlapping UDNs into one VRF is rejected.

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
          forwarding: true
          address:
            - ip: 192.168.140.34
              prefix-length: 24
        ipv6:
          enabled: false
EOF
```

Repeat for worker2 (`...:35`, `192.168.140.35`) and worker3 (`...:36`,
`192.168.140.36`). The MAC must be uppercase — that is how nmstate reports it.

`forwarding: true` is the return path, and it is not optional.
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
"Network is unreachable". Needs nmstate 2.2.51 (September 2025) or later; set
it per interface rather than reaching for `conf.all.forwarding`, which would
turn forwarding on for every interface on the node.

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

### Prove the data plane

The observable change is not just reachability — it is that pod egress
**stops being SNATed**. Once the pod network is advertised, packets leave with
the real pod IP, because the fabric now has a route back to it.

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
Distinct subnets are required in this phase: OVN-Kubernetes refuses to leak
two UDNs with overlapping subnets into one VRF.

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

Requires local gateway mode. Recreate the tenants on the overlapping
`10.200.0.0/16` subnet first — same delete-and-recreate as phase 2, with
`cidr: 10.200.0.0/16` for **both** tenants and `udn-lab-phase: vrflite`.

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
          forwarding: true
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

Six of these in total: 3 nodes × 2 tenants. Red uses VLAN 120 and
`192.168.142.<octet>`.

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
oc -n udn-blue exec <pod> -- ping -c3 10.210.10.10      # must SUCCEED
oc -n udn-blue exec <pod> -- ping -c3 -W2 10.211.10.10  # must TIME OUT
oc -n udn-red  exec <pod> -- ping -c3 10.211.10.10      # must SUCCEED
```

The middle one is the result worth having. Both tenants carry the same pod
subnet and their external networks are one hop away on the same physical link;
if it succeeds, the VRFs are leaking and VRF-Lite is not doing its job — check
`targetVRF` is `auto` and that the cluster is in local gateway mode.

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
| Part 5 | `templates/nncp-fabric-untagged.yaml.j2` |
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
