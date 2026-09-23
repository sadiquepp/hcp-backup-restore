# Quick build — the three `build-lab.sh` phases

Three labs, one script, one command each. This page is the short version:
what each phase actually builds, what it proves, what it cannot do, and what
has to be true before you start. The long version is `README.md`; the hard
debugs are in `troubleshooting.md`.

```bash
cd udn-bgp-evpn
./build-lab.sh --shared      # phase 2 - UDN over BGP, one default VRF
./build-lab.sh --vrflite     # phase 3 - per-tenant VRFs over VLANs
./build-lab.sh --evpn        # phase 4 - nodes as VTEPs, stretched Layer2
```

`--evpn` is the default, so a bare `./build-lab.sh` is the EVPN lab.

---

## Before any of them

**Run it under tmux.** A full build installs two OpenShift clusters and takes
hours. If the ssh session drops the shell gets SIGHUP and takes the build
with it, usually mid-install, leaving VMs that `--from` cannot resume
cleanly.

```bash
tmux new -s lab      # then ./build-lab.sh ...
# ctrl-b d to detach, tmux attach -t lab to come back
```

| Prerequisite | Detail |
| --- | --- |
| **Bare-metal host** | KVM/libvirt, enough disk and RAM for a 3-worker hub plus an SNO plus the helper and containerlab VMs. Run from the host itself. |
| **`vault.yaml`** | Encrypted, at the repo root, **git-ignored**. Holds the pull secret, `org_id`, `activation_key`, `ssh_key`, and `dns_forwarders`. Resolver addresses belong here and **never** in `vars.yaml` — that file is committed to a public repo. |
| **Vault password file** | Outside the repo. `$ANSIBLE_VAULT_PASSWORD_FILE`, or `--vault-password-file`, or the default `~/.vault_pass`. The script never reads it, only passes it on. |
| **OpenShift 4.19+** | For `--shared` and `--vrflite`. `--evpn` needs **4.22** — `vars.yaml` sets `ocp_major_version: "4.22"`, which covers all three. |
| **Local gateway mode** | `--vrflite` and `--evpn` require `routingViaHost: true`. `udn_bgp_set_local_gateway: true` in `vars.yaml` makes the `tenants` step do it. Flipping it is a second full `ovnkube-node` rollout. |
| **`clusters` step is destructive-by-omission** | The cluster playbooks are not idempotent. A bare run refuses if a hub kubeconfig or the libvirt domains already exist. With clusters already up, start at `--from fabric`. |

Useful before committing to a run:

```bash
./build-lab.sh --shared --list      # the steps this mode will run
./build-lab.sh --shared --dry-run   # print every command, run nothing
```

---

## `--shared` — phase 2, one default VRF

**What it builds.** Every UDN is leaked into the node's **one default VRF**,
where the existing untagged BGP session to leaf1 picks the prefixes up. No
VLANs, no per-tenant VRFs, no NMState. Six tenants: five on the hub
(`blue red orange green purple`) and `violet` on the SNO.

**What it proves.** That UDN-over-BGP works at all, isolated from any VLAN or
VRF plumbing. Every web pod is reachable from one fabric client, and the
`advertised-network-subnets` ACL still separates tenants inside a cluster.

**What it cannot do, by design:**

- **No cross-cluster pod-to-pod.** Phase 2 advertises pod subnets *outward*;
  it does not give pods a path *out* to the fabric. The tenant's gateway
  router holds its own `/16` and a default via the **management** gateway, so
  egress toward another cluster leaves by the management NIC and dies. The
  node learns the other cluster's prefixes over BGP into its `main` table,
  which pod egress never reads. `udn-xcluster-curl.sh --shared` expects every
  such cell **silent**; see Case 4 in `troubleshooting.md`.
- **No tenant isolation at the node boundary.** One VRF means anything else
  in it can reach these pods. That is the price of the simplicity.
- **No two tenants on one subnet.** One prefix in one VRF cannot mean two
  things, and OVN-Kubernetes does not check — overlapping subnets are
  Accepted and produce one winner and one silently unreachable tenant. Hence
  `udn_subnet_shared` (10.220–10.225), unique across **all** tenants in
  **both** clusters, and the assert that enforces it.

**Steps:** `bmhost clusters fabric preflight tenants web nsclient verify xcluster`

No `nsproxy` step — there are no two tenants behind one address for an
ingress to separate. `verify` therefore curls every pod from **one client**
(`udn-web-demo.sh --host`) rather than asking an ingress by hostname. The
namespace client VM is still built: its **root** namespace carries the
phase-2 routes, so one VM serves all three labs.

---

## `--vrflite` — phase 3, per-tenant VRFs

**What it builds.** `targetVRF: auto`. Each network's subnet is advertised
inside the VRF that corresponds to it — blue's pod subnet goes out the blue
VRF over the blue VLAN and is never seen by red or by the default VRF. Client
VLAN subinterfaces are enslaved to leaf1's tenant VRFs.

**What it proves.**

- Real isolation: a blue pod reaches blue's external endpoint and **not**
  red's, even though both leaf-side networks are one hop away on the same
  link.
- Because each tenant has its own VRF, blue and red can legitimately carry
  the **same** pod subnet (`udn_subnet`, 10.200–10.206) — which phase 2
  cannot.
- **Cross-cluster pod-to-pod works here.** Giving the tenant VRF its own
  fabric path is exactly what this phase adds. `udn_vrf_leaks` in `vars.yaml`
  decides which pairs are open; `udn-xcluster-curl.sh` asserts the openings
  are real pod-to-pod **and** that the pairs left out are shut.
- Within a cluster the ACL is still the backstop, whatever the leaks say.

**Requires local gateway mode.** In shared gateway mode the CR is Accepted
and VRF-Lite simply does not work.

**Tenants.** The SNO builds `violet` only (`tenants_vrflite`), not green and
purple. With no VNI and no route target, two clusters advertising
`10.204.0.0/16` into leaf1's green VRF means one of them loses.

**Steps:** all ten, including `nsproxy`. `verify` uses `--proxy` — the tenant
ingress asked by hostname.

---

## `--evpn` — phase 4, nodes as VTEPs

**What it builds.** The cluster nodes are VTEPs. VXLAN runs between them and
type-5 routes carry a per-tenant VNI. `green` and `purple` exist in **both**
clusters as one stretched Layer2 domain.

**What it proves.** That a tenant reaches **itself** in the other cluster
over one stretched broadcast domain — a macVRF on one L2VNI is *meant* to
exist in both clusters, which is the whole point. `udn-xcluster-curl.sh`
auto-detects this mode from the duplicate tenants and asks that question.

**Needs 4.22** and local gateway mode. The border-leaf handoff variant works
on 4.21 and is described in `README.md`.

**Watch out:** addresses stay unambiguous only because `evpn_l2_excludes`
gives each cluster its own half of the prefix to allocate from. Infrastructure
addresses (`10.204.0.1` gateway, `10.204.0.2` management port) collide across
clusters and **cannot** be split — OVN-Kubernetes derives the MAC from the IP,
so one cluster's is shadowed at the VTEP.

**Steps:** all ten, `verify` with `--proxy`.

---

## Resuming, and doing one step

```bash
./build-lab.sh --vrflite --from fabric     # clusters already up
./build-lab.sh --shared  --only xcluster   # re-run one test
./build-lab.sh --evpn    --only tenants
```

`--from evpn`, `--from vrflite` and `--from shared` all resolve to the
`tenants` step, which is what they were called before there was more than one
mode.

To really rebuild the clusters:

```bash
./build-lab.sh --rebuild-clusters      # cleanup.yaml first, then everything
./build-lab.sh --rebuild-clusters -y   # ... skipping the 10s abort window
```

`cleanup.yaml` destroys **every VM of this lab** on the host, the helper and
the containerlab VM included.

`--parallel-tenants` overlaps the hub and SNO halves of the `tenants` step.

---

## Switching between phases

The three are not additive — each one wants a different fabric topology and
different tenant subnets, and `--shared`/`--vrflite` use different subnet
variables (`udn_subnet_shared` vs `udn_subnet`). Rebuild the tenants rather
than layering:

```bash
./build-lab.sh --vrflite --from fabric
```

`fabric` re-renders the containerlab topology (`clab_topology=bgp` for
`--shared` and `--vrflite`, `evpn` for `--evpn`), and `tenants` recreates the
CUDNs on the right subnets. Only the `bgp` topology puts the per-tenant
`<vrf_prefix>.1` addresses on leaf1 that VRF-Lite peers with.

---

## What each phase's last two steps assert

| | `verify` | `xcluster` |
| --- | --- | --- |
| `--shared` | `--host`: every pod from one client, root namespace | every cross-cluster cell **silent**; same-cluster cross-tenant silent (the ACL) |
| `--vrflite` | `--proxy`: the tenant ingress by hostname | the `udn_vrf_leaks` matrix — openings real, shut pairs shut |
| `--evpn` | `--proxy` | same tenant, both clusters, over the stretched Layer2 |

`xcluster` needs **both** kubeconfigs and `web` on both clusters. Built with
the SNO skipped, it says so and moves on rather than failing the run.
