# Hosted control planes on the compact cluster (connected)

This guide turns the connected compact cluster (`compact`, from
[compact-cluster.md](compact-cluster.md)) into a **management cluster**:

- ACM (with MCE), MetalLB and OADP;
- one **hosted cluster, `hcp-compact1`**, whose control plane runs as pods on
  the compact cluster;
- two worker VMs that join the hosted cluster as Agents.

It reuses the hub's roles and playbooks, extended so the hub and the compact
cluster can both run hosted clusters **at the same time** without either one
touching the other's.

Ingress is different from the hub's hosted clusters. The hosted cluster's
`*.apps` does **not** go through the helper's haproxy. MetalLB runs **inside
the hosted cluster** and gives the address to a LoadBalancer Service in front
of the router pods, which use HostNetwork:

```
client -> *.apps VIP .101 (MetalLB L2, on a worker)
       -> Service openshift-ingress/metallb-ingress
       -> router pod (HostNetwork, :80/:443 on the worker) -> route -> Service -> pods
```

- [What you get](#what-you-get)
- [How it coexists with the hub](#how-it-coexists-with-the-hub)
- [Before you start](#before-you-start)
- Steps
  1. [DNS](#step-1---dns)
  2. [ACM, MCE and MetalLB on the compact cluster](#step-2---acm-mce-and-metallb-on-the-compact-cluster)
  3. [Apply the AgentServiceConfig](#step-3---apply-the-agentserviceconfig)
  4. [The InfraEnv](#step-4---the-infraenv)
  5. [The two worker VMs](#step-5---the-two-worker-vms)
  6. [Approve the Agents](#step-6---approve-the-agents)
  7. [Create the hosted cluster](#step-7---create-the-hosted-cluster)
  8. [Ingress: MetalLB inside the hosted cluster](#step-8---ingress-metallb-inside-the-hosted-cluster)
  9. [Verify](#step-9---verify)
- [Remove the hosted cluster](#remove-the-hosted-cluster)
- [Troubleshooting](#troubleshooting)

---

## What you get

| What | Value | Where it is set |
|---|---|---|
| Management cluster | `compact` (ACM, MCE, MetalLB, OADP) | `compact-cluster/setup_compact_cluster.yaml --tags acm` |
| Hosted cluster | `hcp-compact1`, control plane in namespace `hcp-compact1-hcp-compact1` on `compact` | `hosted_clusters` in `vars.yaml` |
| Its DNS domain | `hcp-compact1.compact.mylab.com` | `hosted_cluster_domains` |
| API VIP: `api`, `api-int` | `192.168.122.100`, from MetalLB on **compact** | `hosted_cluster_metallb_pools['hcp-compact1'].ip.compact` |
| Ingress VIP: `*.apps` | `192.168.122.101`, from MetalLB **inside hcp-compact1** | `hosted_cluster_node_keys['hcp-compact1'].apps_vip` |
| Worker 1 | VM `hcp_compact1_worker1`, `192.168.122.8`, MAC `52:54:00:e2:54:08` | `ip_list.hcpc1worker1`, `compact_hosted_cluster_workers` |
| Worker 2 | VM `hcp_compact1_worker2`, `192.168.122.9`, MAC `52:54:00:e2:54:09` | `ip_list.hcpc1worker2` |
| Worker size | 4 vCPU, 8.5 GiB, 120 GB disk, booted from the compact InfraEnv's ISO | `compact_hosted_cluster_cpu/_memory` |
| Agents | InfraEnv `bminfra` in namespace `bminfra` **on compact** | `setup_bminfra.yaml -e target_hub=compact` |

**Why these addresses.**

- **The workers need MAC reservations,** so they take two of the last free
  octets below .10. They are zero-padded into the MAC, as for `compactd`.
- **The two VIPs are MetalLB addresses.** No VM owns them and they need no MAC
  reservation, so they come from `.100`-`.199`. Nothing hands out that range:
  - libvirt's DHCP range is `.201`-`.249`;
  - the helper's dhcpd (`roles/setup-dhcp`, `.100`-`.200`) is not deployed by
    any playbook.

**Why `compact.mylab.com` and not a zone of its own.** The libvirt network
already forwards `compact.mylab.com`, and every name under it, to the helper.
A new top-level zone would need a new forwarder. Adding one means redefining
the libvirt network, which disconnects the running compact cluster. As a
sub-zone, `hcp-compact1`'s names resolve from every VM with no network change.

---

## How it coexists with the hub

The hub's roles were extended rather than copied. One key, `compact`, in the
existing MetalLB address map is what keeps the two management clusters apart:

| Piece | Hub run | Compact run |
|---|---|---|
| MetalLB API pools (`roles/setup-hub-acm`) | `metallb_hub=hub`: `hcp-cluster1/2/3` only | `metallb_hub=compact`: `hcp-compact1` only |
| Hosted cluster bundle (`create_hosted_cluster.yaml`) | renders `hcp-cluster1/2/3`, skips `hcp-compact1` | `-e target_hub=compact`: renders `hcp-compact1` only |
| InfraEnv (`setup_bminfra.yaml`) | on the hub | `-e target_hub=compact`: on the compact cluster |
| Discovery ISO cache | `bminfra-discovery-<ver>.iso` | `compact-bminfra-discovery-<ver>.iso` |
| Helper PXE files | copied | left alone (the compact workers boot the ISO) |
| Worker VMs (`setup_hosted_cluster_vm.yaml`) | `c1_worker1..3` | `-e target_hub=compact`: `hcp_compact1_worker1..2` |
| `*.apps` | helper haproxy (`c1lb` ...) | MetalLB inside the hosted cluster, no haproxy |
| DNS | `hcp-clusterN.mylab.com` zones | `hcp-compact1.compact.mylab.com` zone, rendered in the same run |

A cluster is rendered for a management cluster only if it has a MetalLB
address there. So the hub's flow renders exactly what it did before,
byte for byte. `hcp-compact1` has no `hub` or `hub2` address, and that alone
keeps it off every hub.

---

## Before you start

- **The compact cluster is up, with LVM Storage.** The AgentServiceConfig
  claims three PVCs from the default StorageClass, `lvms-vg1`. See
  [compact-cluster.md](compact-cluster.md), Steps 1-12.
- **The libvirt network forwards `compact.mylab.com`.** Check from the
  hypervisor:

  ```bash
  dig +short @192.168.122.1 api.compact.mylab.com     # 192.168.122.17
  ```

  If this prints nothing, the running network predates the compact forwarder.
  Add it live before Step 1, or none of `hcp-compact1`'s names will resolve
  from the workers.

- **Capacity.** On top of OpenShift itself, the compact cluster now runs:
  - ACM;
  - a highly available hosted control plane (three etcd, three
    kube-apiservers, ...).

  With 3 x 24 GiB that is tight. Watch `oc adm top nodes`. To halve the
  control plane, set `availability_policy: SingleReplica` on the
  `hcp-compact1` entry in `hosted_clusters` before Step 7:

  ```yaml
  hosted_clusters:
    ...
    - name: hcp-compact1
      availability_policy: SingleReplica
  ```

Set these in the shell you run the `oc` steps from:

```bash
export KUBECONFIG=/var/lib/libvirt/images/compact_install/auth/kubeconfig
export PATH=/var/lib/libvirt/images/compact_install:$PATH     # the cluster's own oc
```

Commands marked **(root)** run from the repository root. Commands marked
**(compact-cluster/)** run from inside `compact-cluster/`.

---

### Step 1 - DNS

**(root)** Renders the `hcp-compact1.compact.mylab.com` zone on the helper:

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns --ask-vault-pass
```

`--tags dns` only rewrites the helper's zones and this host's `/etc/hosts`. It
does not touch the libvirt network.

```bash
dig +short @192.168.122.1 api.hcp-compact1.compact.mylab.com        # 192.168.122.100
dig +short @192.168.122.1 anything.apps.hcp-compact1.compact.mylab.com  # 192.168.122.101
dig +short @192.168.122.1 hcpc1worker1.hcp-compact1.compact.mylab.com   # 192.168.122.8
```

### Step 2 - ACM, MCE and MetalLB on the compact cluster

**(compact-cluster/)** The hub's day-2 role, `roles/setup-hub-acm`, pointed at
the compact cluster:

```bash
ansible-playbook -i ../inventory/hosts setup_compact_cluster.yaml --ask-vault-pass --tags acm
```

This installs the same set as the hub's `--tags acm`:

- ACM and its MultiClusterHub, which brings MCE and HyperShift;
- MetalLB;
- OADP;
- the Provisioning configuration.

LVM Storage is in that role too. It is the same operator and LVMCluster
`--tags compactstorage` already applied, so that part changes nothing.
`metallb_hub=compact` makes MetalLB's only pool `hcp-compact1-api-pool`
(`.100`), restricted to `hcp-compact1`'s control-plane namespace.

`acm` is also tagged `never`, so a plain run of the playbook, or
`--tags compact`, never turns the compact cluster into a management cluster.

```bash
oc get multiclusterhub -n open-cluster-management      # Running (10-15 minutes)
oc get ipaddresspool -n metallb-system                 # hcp-compact1-api-pool
oc get csv -A | grep -E 'advanced-cluster|multicluster-engine|metallb|lvms|oadp'
```

### Step 3 - Apply the AgentServiceConfig

As on the hub, the role only **renders** the AgentServiceConfig and leaves it
for you to review. Once the MultiClusterHub is `Running`:

```bash
less ../roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc apply -f ../roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc -n multicluster-engine rollout status deploy/assisted-service --timeout=15m
oc get pvc -n multicluster-engine                      # three, Bound on lvms-vg1
```

### Step 4 - The InfraEnv

**(root)** Creates the `bminfra` namespace, its pull secret, the InfraEnv and
the CAPI RBAC **on the compact cluster**. It then downloads the discovery ISO
as `compact-bminfra-discovery-<version>.iso`:

```bash
ansible-playbook -i inventory/hosts setup_bminfra.yaml --ask-vault-pass -e target_hub=compact
```

It fails at once if Step 3 was skipped: an InfraEnv without assisted-service
never builds an ISO. The helper's PXE files are left alone; they serve the
hub's workers.

### Step 5 - The two worker VMs

**(root)**

```bash
ansible-playbook -i inventory/hosts setup_hosted_cluster_vm.yaml --ask-vault-pass -e target_hub=compact
```

This playbook:

1. adds the DHCP reservations for `.8` and `.9` to the **running** network
   (`virsh net-update ... --live --config`). The compact cluster stays
   connected throughout.
2. creates `hcp_compact1_worker1` and `hcp_compact1_worker2`, booted from the
   compact InfraEnv's ISO.

```bash
virsh list | grep hcp_compact1
oc get agents -n bminfra -w        # both appear within a few minutes
```

### Step 6 - Approve the Agents

The hub flow approves Agents in the ACM/MCE web UI. That works here too. From
the command line:

```bash
oc get agents -n bminfra -o wide
for a in $(oc get agents -n bminfra -o name); do
  oc -n bminfra patch $a --type merge -p '{"spec":{"approved":true}}'
done
oc get agents -n bminfra -o custom-columns=NAME:.metadata.name,HOST:.spec.hostname,APPROVED:.spec.approved,STATE:.status.debugInfo.state
```

### Step 7 - Create the hosted cluster

**(root)** Renders the HostedCluster, NodePool (2 replicas), pull and ssh
secrets, ManagedCluster and KlusterletAddonConfig for `hcp-compact1` only.
The compact cluster's kubeconfig is used for the checks:

```bash
ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass -e target_hub=compact
```

As on the hub, the bundle is rendered for review, not applied:

```bash
less roles/create-hosted-cluster/templates/.rendered-hcp-compact1.yaml
oc apply -f roles/create-hosted-cluster/templates/.rendered-hcp-compact1.yaml
```

What to look for in it:

- `dns.baseDomain: compact.mylab.com`;
- the APIServer `loadBalancer.hostname: api.hcp-compact1.compact.mylab.com`;
- the `metallb.io/address-pool: hcp-compact1-api-pool` annotation.

Watch it come up:

```bash
oc get hostedcluster,nodepool -n hcp-compact1
oc get svc -n hcp-compact1-hcp-compact1 kube-apiserver   # EXTERNAL-IP 192.168.122.100
oc get agents -n bminfra                                 # bound to the cluster, then installing, then Done
```

The control plane is up in about 10 minutes. The two Agents then install and
join, typically in 20-40 minutes.

### Step 8 - Ingress: MetalLB inside the hosted cluster

**(compact-cluster/)** Once the NodePool reports two ready nodes:

```bash
ansible-playbook -i ../inventory/hosts setup_compact_cluster.yaml --ask-vault-pass --tags hcpingress
```

`roles/setup-hcp-ingress-metallb` does this, for each hosted cluster with a
`compact` address:

1. extracts the hosted cluster's admin kubeconfig to
   `/var/lib/libvirt/images/hcp-compact1/kubeconfig`;
2. waits for both workers to be `Ready`;
3. installs the MetalLB operator in the **hosted** cluster, from its
   `redhat-operators` catalog, and starts MetalLB;
4. creates the pool, the advertisement and the Service below;
5. waits for the Service to hold `.101`.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: hcp-compact1-ingress
  namespace: metallb-system
spec:
  addresses:
  - 192.168.122.101/32
  autoAssign: false              # only the Service below asks for it, by name
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: hcp-compact1-ingress-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - hcp-compact1-ingress
---
apiVersion: v1
kind: Service
metadata:
  name: metallb-ingress
  namespace: openshift-ingress
  annotations:
    metallb.io/address-pool: hcp-compact1-ingress
spec:
  type: LoadBalancer
  selector:                      # the default IngressController's router pods
    ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
  ports:
  - {name: http,  protocol: TCP, port: 80,  targetPort: 80}
  - {name: https, protocol: TCP, port: 443, targetPort: 443}
```

The router pods use HostNetwork, so `targetPort` 80/443 is the workers' own
ports, where the router's haproxy listens. MetalLB answers ARP for `.101` from
one worker and moves it to the other if that worker goes away.

### Step 9 - Verify

```bash
export HCP_KUBECONFIG=/var/lib/libvirt/images/hcp-compact1/kubeconfig
oc --kubeconfig $HCP_KUBECONFIG get nodes                         # two workers, Ready
oc --kubeconfig $HCP_KUBECONFIG get clusteroperators              # ingress, console Available
oc --kubeconfig $HCP_KUBECONFIG -n openshift-ingress get svc metallb-ingress   # EXTERNAL-IP 192.168.122.101
curl -kI https://console-openshift-console.apps.hcp-compact1.compact.mylab.com
oc get managedcluster hcp-compact1                                # on compact: JOINED, AVAILABLE True
```

The console's kubeadmin password is in the `kubeadmin-password` secret, in
the `hcp-compact1` namespace on the compact cluster:

```bash
oc -n hcp-compact1 extract secret/hcp-compact1-kubeadmin-password --to=-
```

---

## Remove the hosted cluster

On the compact cluster, delete the HostedCluster first. The NodePool goes with
it, and the Agents are released:

```bash
oc delete managedcluster hcp-compact1
oc delete hostedcluster hcp-compact1 -n hcp-compact1 --wait
```

Then, **(root)**, remove the worker VMs and the cached ISO:

```bash
ansible-playbook -i inventory/hosts cleanup.yaml --tags compacthcp
```

`cleanup.yaml --tags compact` removes the compact cluster, and these workers
with it.

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `setup_bminfra.yaml` fails: `No AgentServiceConfig on this hub` | Step 3 was skipped, or `-e target_hub=compact` was left off and it looked at the hub | `oc get agentserviceconfig agent` on compact |
| The AgentServiceConfig's PVCs stay `Pending` | No default StorageClass on compact | `oc get sc`: `lvms-vg1 (default)`. Run `--tags compactstorage` (compact-cluster.md, Step 12). |
| The workers boot but no Agent appears | They booted the hub's ISO, or cannot reach assisted-service through compact's `*.apps` | `virsh dumpxml hcp_compact1_worker1 \| grep iso` names `compact-bminfra-discovery-...`; `dig @192.168.122.1 x.apps.compact.mylab.com` |
| A worker gets an address from `.201`-`.249` | Its DHCP reservation is missing | `virsh net-dumpxml default \| grep 54:08`; re-run Step 5 |
| The HostedCluster waits on `kube-apiserver` with no EXTERNAL-IP | The MetalLB pool on compact is missing, or names another namespace | `oc get ipaddresspool hcp-compact1-api-pool -n metallb-system -o yaml`; re-run `--tags acm` |
| Nodes never join; kubelet cannot reach the API | `api.hcp-compact1.compact.mylab.com` does not resolve from the workers | `dig @192.168.122.1 api.hcp-compact1.compact.mylab.com`: Step 1, and the forwarder check in [Before you start](#before-you-start) |
| `--tags hcpingress` waits forever for Ready workers | The NodePool has not finished, or Agents are unapproved | `oc get nodepool,agents -A` on compact (Step 6) |
| `metallb-ingress` stays `<pending>` | The pool or advertisement is missing in the hosted cluster, or MetalLB's speakers are not running | `oc --kubeconfig $HCP_KUBECONFIG -n metallb-system get ipaddresspool,l2advertisement,pods` |
| Ingress and console operators in the hosted cluster are Degraded | `*.apps` does not resolve to `.101`, or `.101` is not answering | `dig x.apps.hcp-compact1.compact.mylab.com`, `arping -c2 -I virbr0 192.168.122.101` |
| The hub's `--tags acm` now lists `hcp-compact1` as not rendered | Expected: it has no `hub` address | Nothing to fix |
