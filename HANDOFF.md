# Handoff: UDN over EVPN, two clusters

Written at the end of a long session so the next one — possibly on a different
machine or account — can pick up without re-deriving anything. Everything
described here is committed and pushed on `claude/dazzling-cannon-t9qwph`,
merged to `integration`.

Point a new session at this file first, then `bgp-evpn.md` for depth.

## Where things stand

The lab runs an EVPN fabric (containerlab: leaf1 / spine / leaf2) with **two**
OpenShift clusters attached: `hub` (3 workers) and `sno` (single node). One
Layer2 UDN is stretched across both on L2VNI 400.

Verified working, measured not assumed:

- Four BGP sessions on leaf1, distinct ASNs per cluster (hub 64512, sno 64515)
- `show evpn mac vni 400` on leaf2 shows both clusters' pod MACs behind their
  own VTEPs (`100.64.0.36` hub, `100.64.0.20` sno)
- Pod-to-pod **across clusters** works, bridged: `ttl=64` unchanged
- Pod ranges split by `reservedSubnets` — hub `10.204.0.0/17`, sno the high half
- Tenant isolation holds in every direction (`udn-vrf-isolation.sh --pods`)
- One ingress fronting both clusters: seven hostnames, one address, including
  `green-sno` and `purple-sno` sharing one backend address and returning
  different pages

## Re-verify in five commands

```bash
# fabric
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp l2vpn evpn summary'   # 4 peers
docker exec clab-udnbgp-leaf2 vtysh -c 'show evpn mac vni 400'         # both VTEPs

# clusters
scripts/udn-xcluster-curl.sh <hub-kubeconfig> <sno-kubeconfig>         # pod->pod, both ways
scripts/udn-vrf-isolation.sh --pods                                    # isolation
scripts/udn-web-demo.sh --proxy                                        # ingress, 7 names
```

## Findings worth reporting

In descending order of interest. None of these is a lab misconfiguration.

1. **Infrastructure addresses collide across clusters and cannot be split.**
   Every cluster on a stretched Layer2 subnet puts its gateway on `<subnet>.1`
   and a management port on `.2`. ovn-kubernetes derives the MAC from the IP,
   so the *same MAC* is advertised from two VTEPs and leaf2 holds only one of
   them. `reservedSubnets` separates pod ranges; it cannot separate these,
   because every cluster needs them. Pod-to-pod is unaffected (it never touches
   the gateway), but anything leaving the subnet goes to whichever router
   answered the ARP.

2. **An unsatisfiable `reservedSubnets` is fatal, not rejected.** Reserving an
   address ovn-kubernetes needs gives `F failed to run ovnkube`; ovnkube-node
   CrashLoopBackOffs and **all** pod networking on that node goes with it, not
   just the affected UDN. Rejecting the CR at admission would be reasonable.

3. **`NetworkAllocationSucceeded: True` stays green through both.** It covers
   cluster-level allocation and says nothing about the per-node switch, which
   made it actively misleading during diagnosis.

4. **Not a finding, deliberately:** the `advertised-network-subnets` ACL does
   **not** block cross-cluster same-UDN traffic, and could not — it matches
   source and destination against the advertised-subnet set on addresses
   alone, so cross-cluster is indistinguishable from intra-cluster.

## Open

- `scripts/udn-web-demo.sh --netns` is still single-cluster (discovers from one
  kubeconfig). `--proxy` and `udn-xcluster-curl.sh` both span clusters, so this
  is cosmetic rather than a gap.
- DNS for the two new ingress names needs `setup_bm_host.yaml --tags dns` after
  any change to `udn_proxy_clusters`. The demo uses `Host:` headers so it
  passes without it — which is how the gap went unnoticed once already.
- Phase 5, cross-cluster **Layer3** tenants, is not built. It needs its own
  subnet, VNI and route target per cluster — not a second copy of an existing
  tenant, which would put two origins on one route target.

## Traps this session cost time on

Each of these reported success while doing nothing. Worth knowing before
debugging anything here.

| Symptom | Cause |
| --- | --- |
| `--tags nodenics` ran and changed nothing, `skipped=0` | `include_tasks` does not pass tags to included tasks without `apply:`. Fixed, but the pattern recurs |
| NNCP stuck `Failing` forever after the cause was fixed | nmstate re-enacts on `metadata.generation` only; `oc apply` of an identical policy changes nothing. The play now deletes and recreates |
| Manifest had `excludeSubnets`, live object did not | Wrong field name for `layer2` (it is `reservedSubnets`), and CRD pruning drops unknown fields **silently**. The play now asks the API for the name |
| A shell probe always returned empty | `cmd: >-` folds lines with spaces, which breaks any multi-line script. Use `cmd: |` |
| Client namespaces got phase-3 addressing on an EVPN fabric | `clab_topology` defaults to `bgp` and must be passed on every fabric command. A guard now refuses a mismatched run |
| Hot-plugged fabric NIC had forwarding off | Writing `net.ipv4.ip_forward` reaches interfaces that exist at that moment and does not set `conf.default.forwarding` |

## Key variables

All in `vars.yaml`:

- `clab_clusters` — per cluster: nodes, kubeconfig, ASN, tenants, advertise_default
- `clab_fabric_clusters` — which of them are wired into the fabric
- `udn_proxy_clusters` / `udn_proxy_names` — ingress hostnames, one rule, two consumers
- `evpn_l2_excludes` — the per-cluster IPAM split, sized to exactly what
  ovn-kubernetes needs at the bottom of the subnet

Cluster-half runs take `-e udn_bgp_cluster=<name>`; fabric-half runs span every
cluster at once and take `-e clab_topology=evpn`.
