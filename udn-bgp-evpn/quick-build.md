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

Optional but worth it if you build this lab more than once: **[the prebuilt
image](#optional-once-the-prebuilt-lab-image)**, which removes four
subscription-manager registrations and four rounds of `dnf` from every build.

Useful before committing to a run:

```bash
./build-lab.sh --shared --list      # the steps this mode will run
./build-lab.sh --shared --dry-run   # print every command, run nothing
```

---

## Optional, once: the prebuilt lab image

Every guest this lab builds — the containerlab VM, the phase-2 client, the
per-tenant clients, the namespace client — is a bare copy of
`rhel9_kvm_image` with **no entitlement**. Each therefore has to be
registered with subscription-manager before its first `dnf`. That is four
registrations per build, each a network round trip to Red Hat that can fail
on its own.

Do it once instead:

```bash
./build-lab.sh --only image
# or, the same thing directly:
ansible-playbook -i ../inventory/hosts build-lab-image.yaml \
    --vault-password-file ~/.vault_pass
```

That copies the base image, registers **the copy**, installs everything,
then unregisters and cleans, and publishes the result as
`rhel-9.8-x86_64-kvm-udnlab.qcow2` beside the original.

**It does not touch the original.** `rhel9_kvm_image` is only ever a `cp`
source; `virt-customize` — which does edit in place — is pointed at a
`.partial` copy, and the rename to the real name happens last, so an
interrupted run leaves nothing the lab would detect and trust. The build
refuses outright if `udn_lab_image` resolves to the same filename as the
base image (they share `base_image_dir`, and building onto the base name
would delete it), and it re-reads the base image afterwards and asserts the
size and mtime are unchanged. So no backup of the base image is needed — but
if you want one anyway it is one command:

```bash
cp --sparse=always /var/lib/libvirt/images/rhel-9.8-x86_64-kvm.qcow2{,.orig}
```

**The image's presence is the switch.** There is no enable flag to set or
forget. Build it and every guest is created from it with no registration and
no `dnf`; delete it and the lab goes straight back to the normal path. That
is also the whole rollback procedure.

| | |
| --- | --- |
| **What is in it** | `curl git haproxy iproute iptables-nft policycoreutils-python-utils tar tcpdump`, plus `docker-ce docker-ce-cli containerd.io` unless `udn_lab_image_with_docker: false` |
| **Where the list comes from** | `udn_pkgs_clab`, `udn_pkgs_client`, `udn_pkgs_nsclient`, `udn_pkgs_nsproxy` in `vars.yaml`. The image installs their union and each guest verifies its own list — one source, so the two halves cannot drift |
| **Rebuild** | `-e udn_lab_image_force=true`. It will not overwrite silently |
| **Needs** | `guestfs-tools` (for `virt-customize` — the same package as the `virt-resize` the lab already uses), and `org_id`/`activation_key` in `vault.yaml` |

**Docker is in the image on purpose.** It comes from `download.docker.com`
rather than a Red Hat repository, but `containerd.io` pulls
`container-selinux` out of AppStream, so installing it still needs an
entitled guest. Only the clab VM uses it; the client VMs carry it and never
start it, which costs disk and nothing else.

### What a stale image looks like

The guests do **not** blindly skip their package step — each runs
`rpm -q --whatprovides` for its own list instead, and fails by name:

```
This guest was built from rhel-9.8-x86_64-kvm-udnlab.qcow2, which is
missing a package it needs:

  package tshark is not installed

The image has no entitlement, so dnf cannot fix it here. Rebuild it: ...
```

So adding a package to `vars.yaml` without rebuilding the image is caught at
the point the assumption is made, not later inside whatever needed the
package. (`--whatprovides` rather than a bare `rpm -q` because RHEL 9
satisfies `dnf install curl` with the already-installed `curl-minimal`,
which provides `curl` under another name — a bare `rpm -q curl` would fail
on a perfectly good image.)

### What it costs you

The image carries **no entitlement**, deliberately — otherwise every guest
cloned from it would share one consumer identity in Red Hat's inventory. A
guest built from it therefore cannot `dnf install` anything at all. If you
want to add a package by hand on a running guest, register it first, or
delete the image and rebuild that guest the normal way.

During the build, `org_id` and `activation_key` appear in the lab host's
process table for the length of the `virt-customize` run (the Ansible task
is `no_log`). On a single-user lab host that is fine; it is the reason this
is not something to run on a shared machine.

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
