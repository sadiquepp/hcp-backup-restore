# From the SNO to the compact cluster

What changes when you go from the single node of
[`setup_sno.yaml`](../setup_sno.yaml) to the three nodes of
[compact-cluster.md](compact-cluster.md) - and why the move is a **new
install**, not an expansion.

## It is a reinstall

An SNO is installed with `controlPlane.replicas: 1` and a **single-member
etcd**. Workers can be added to it on day 2, but the control plane stays one
node: there is no supported path that grows that etcd to three members and
moves `api` and `*.apps` off the node's own address while the cluster runs.

So build the compact cluster **beside** the SNO - different addresses,
different zone, both playbooks can run on the same hypervisor - move the
workloads, and only then remove the SNO:

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns --ask-vault-pass
cd compact-cluster && ansible-playbook -i ../inventory/hosts setup_compact_cluster.yaml --ask-vault-pass
# once the workloads run on compact:
cd .. && ansible-playbook -i inventory/hosts cleanup.yaml --tags sno --ask-vault-pass
```

## What changes

| | SNO (`sno.mylab.com`) | Compact (`compact.mylab.com`) |
|---|---|---|
| `controlPlane.replicas` / `compute.replicas` | 1 / 0 | 3 / 0 (masters schedulable) |
| `platform` | `none: {}` | `baremetal` with `apiVIPs` + `ingressVIPs` |
| Addresses | node `.20` | nodes `.64-.66`, VIPs `.17` / `.18` |
| `api`, `api-int`, `*.apps` | all A records point at `.20` | `api`/`api-int` -> API VIP, `*.apps` -> ingress VIP |
| DNS zone template | `roles/setup-dns/templates/sno_domain.j2` | `compact_domain.j2` |
| etcd | one member; the node is the cluster | three members; survives one node |
| Networking | one NIC, `enp1s0` | two NICs bonded as `bond0` (mode 1) |
| Agent ISO | one host entry | three; the **first is the rendezvous host** |
| Cleanup tag | `cleanup.yaml --tags sno` | `cleanup.yaml --tags compact` |

Nothing moves by itself. Re-apply your manifests against the new cluster;
PVCs do not transfer, because `lvms-vg1` is local storage on each node.

## API VIP and ingress VIP

On an SNO every name resolves to the node, so there is nothing to float. With
three nodes, a name pinned to one node dies with that node - hence two
**virtual IPs**, addresses that belong to the cluster rather than to a
machine:

| VIP | Names | Carries |
|---|---|---|
| **API VIP** (`.17`) | `api.<zone>`, `api-int.<zone>` | kube-apiserver `:6443`, machine-config `:22623` |
| **Ingress VIP** (`.18`) | `*.apps.<zone>` | router traffic, `:80` / `:443` |

`platform: baremetal` runs **keepalived** on the nodes. One node holds each
VIP at a time; keepalived announces it with VRRP and gratuitous ARP, and when
that node fails a surviving node takes the address over - the API VIP wherever
an apiserver answers, the ingress VIP wherever a router pod runs. An
in-cluster **haproxy** then spreads what arrives on the API VIP across all
three apiservers. That is why this lab needs no external load balancer, where
the hub's `platform: none` clusters do.

Three rules for picking them:

- Both VIPs must be **inside `machineNetwork`** - the installer rejects them
  before it builds anything.
- Both must be **unused**: their own address each, outside every DHCP range
  and MetalLB pool (the role's pre-flight checks the reservations; ping them
  yourself, as in Step 3 of compact-cluster.md, to check the wire).
- Both must **resolve** before the install: `api.<zone>` so `agent wait-for`
  can watch it, `*.apps.<zone>` so the ingress operator settles.

Check who holds them:

```bash
for n in 64 65 66; do
  ssh -i ~/.ssh/lab_rsa core@192.168.122.$n "ip -br addr | grep -E '\.17|\.18'" \
    && echo "  ^ on .$n"
done
```
