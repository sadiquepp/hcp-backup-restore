# UDN over BGP and EVPN - Workshop

You build two OpenShift clusters on one AWS metal host, wire them to a
simulated datacenter fabric, and then - by hand, one object at a time - turn
their user-defined networks into tenants that the fabric routes, isolates and
stretches across both clusters. By the end a VM live-migrates between nodes
while a pod in the *other* cluster pings it without losing a packet.

**What is automated and what you type.** Everything that is plumbing - the
host, the helper VM, both cluster installs, the containerlab fabric, NMState,
OpenShift Virtualization - is one command. Everything that *is* BGP, EVPN or
UDN - enabling the feature, every `FRRConfiguration`, the `VTEP`, every
`ClusterUserDefinedNetwork`, the `RouteAdvertisements`, the node interfaces,
the workloads - you create yourself from the blocks below. Each one writes a
manifest to a file and then applies that file, so you can read exactly what
your shell produced before it reaches the cluster, and it stays on disk
afterwards.

> **`ClusterUserDefinedNetwork`, never `cudn`.** The short name does not work
> reliably against this API. Every `oc` line here spells it out.

---

## Contents

- [The lab you are building](#the-lab-you-are-building)
- [Part A - Day 0: build the lab](#part-a---day-0-build-the-lab)
  - [A1. A metal host on AWS](#a1-a-metal-host-on-aws)
  - [A2. Prerequisites, by hand](#a2-prerequisites-by-hand)
  - [A3. One command: helper, clusters, fabric](#a3-one-command-helper-clusters-fabric)
  - [A4. While it runs: the five ideas](#a4-while-it-runs-the-five-ideas)
  - [A5. When it finishes](#a5-when-it-finishes)
- [Part B - Hands-on: EVPN](#part-b---hands-on-evpn)
  - [Lab 1. Turn on BGP in OVN-Kubernetes](#lab-1-turn-on-bgp-in-ovn-kubernetes)
  - [Lab 2. Peer every node with the fabric](#lab-2-peer-every-node-with-the-fabric)
  - [Lab 3. Give every node a VTEP](#lab-3-give-every-node-a-vtep)
  - [Lab 4. The session EVPN will use](#lab-4-the-session-evpn-will-use)
  - [Lab 5. Two tenants, one subnet: blue and red](#lab-5-two-tenants-one-subnet-blue-and-red)
  - [Lab 6. Advertise them](#lab-6-advertise-them)
  - [Lab 7. Layer2 tenants: green and purple](#lab-7-layer2-tenants-green-and-purple)
  - [Lab 8. The SNO's half of green and purple](#lab-8-the-snos-half-of-green-and-purple)
  - [Lab 9. A routed tenant on both clusters, with the internet: violet](#lab-9-a-routed-tenant-on-both-clusters-with-the-internet-violet)
  - [Lab 10. A web page per tenant](#lab-10-a-web-page-per-tenant)
  - [Lab 11. The tenant ingress](#lab-11-the-tenant-ingress)
  - [Lab 12. Live migration across a stretched Layer2](#lab-12-live-migration-across-a-stretched-layer2)
- [Explore - Optional: look closer at what you built](#explore---optional-look-closer-at-what-you-built)
- [Part C - Optional: the same tenants over VRF-Lite](#part-c---optional-the-same-tenants-over-vrf-lite)
- [The minimal test set](#the-minimal-test-set)
- [Catching up, checking, and when something is wrong](#catching-up-checking-and-when-something-is-wrong)
- [Tearing it down](#tearing-it-down)

---

## The lab you are building

```
                         AWS c5.metal (96 vCPU, 192 GiB) - the "lab host"
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │  helper VM          DNS, load balancer              192.168.122.21           │
 │  hub cluster        3 masters, 3 workers  AS 64512  192.168.122.31-36        │
 │  SNO                1 node                AS 64515  192.168.122.20           │
 │  namespace client   one netns per tenant, the ingress  192.168.122.88        │
 │                                                                              │
 │  containerlab VM (192.168.122.40)                                            │
 │                                                                              │
 │        spine  AS 65000   (route reflector for EVPN, next hop unchanged)      │
 │         /   \                                                                │
 │   leaf1       leaf2  AS 64514, VTEP 10.0.0.2                                 │
 │   AS 64513    tenant VRFs, tenant external endpoints (<tenant>-ext),         │
 │     │         the internet exit for violet                                   │
 │     │ 192.168.140.1                                                          │
 └─────┼────────────────────────────────────────────────────────────────────────┘
       │ fabric network 192.168.140.0/24 - a second NIC on every worker and the SNO
   hub workers .34 .35 .36          SNO .20
   VTEPs 100.64.0.<same octet>/32
```

| Tenant | Topology | Subnet | VNI | What it shows |
| --- | --- | --- | --- | --- |
| blue | Layer3 | 10.200.0.0/16 | L3VNI 101 | two tenants, one address space... |
| red | Layer3 | 10.200.0.0/16 | L3VNI 201 | ...kept apart by route target alone |
| green | Layer2 | 10.204.0.0/16 | L2VNI 400 | one broadcast domain across both clusters; live migration |
| purple | Layer2 | 10.204.0.0/16 | L2VNI 500 | the same, overlapping green |
| violet | Layer3 | 10.206.0.0/16 | L3VNI 601 | one routed tenant on both clusters, and the internet |

The route target of every tenant is `65000:<VNI>`. That one number is what
makes blue blue.

---

## Part A - Day 0: build the lab

About two and a half hours, nearly all of it unattended. Start it first
thing; [A4](#a4-while-it-runs-the-five-ideas) is what to read while it runs.

### A1. A metal host on AWS

**What you need on your laptop:** `terraform` 1.5 or later,
`ansible-playbook`, the AWS CLI with working credentials
(`aws sts get-caller-identity` answers), an SSH key pair, and the RHEL 9 KVM
guest image `rhel-9.8-x86_64-kvm.qcow2` downloaded from
[access.redhat.com/downloads](https://access.redhat.com/downloads/content/479)
- it needs your Red Hat login, which is why nothing downloads it for you.

```bash
git clone https://github.com/sadiquepp/hcp-backup-restore.git
cd hcp-backup-restore/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Three settings matter:

```hcl
allowed_ssh_cidrs = ["<your ip>/32"]        # curl -s https://checkip.amazonaws.com
ssh_public_key       = "ssh-ed25519 AAAA... you@laptop"
ssh_private_key_path = "~/.ssh/id_ed25519"
```

Leave the rest: one `c5.metal`, a 1000 GiB root volume, and worker sizing that
fits 192 GiB. `allowed_ssh_cidrs` has no default on purpose - SSH is the only
port opened, and everything else is tunnelled over it.

```bash
./lab-up.sh                                                # plan, apply, bootstrap
./lab-up.sh stage-image ~/Downloads/rhel-9.8-x86_64-kvm.qcow2
./lab-up.sh ssh                                            # you are ec2-user on the host
```

`lab-up.sh` checks your tools and credentials before it spends anything, then
creates the VPC and the instance and runs a bootstrap that installs Ansible,
tmux and the libvirt bindings, clones this repository to
`/root/hcp-backup-restore`, and writes `/root/hcp-backup-restore/vars-metal.yaml`
- the sizing and image location for this host. `./lab-up.sh status` repeats
the next steps; `./lab-up.sh destroy` when you are done. Details:
[terraform/README.md](../terraform/README.md).

> **Not on AWS?** Any RHEL 9 host with at least 192 GiB of RAM, ~1 TB of disk
> and nested virtualisation works. Clone the repository to
> `/root/hcp-backup-restore`, install `ansible-core`, `tmux` and `git`, put the
> image in `/opt/lab-images/`, and create this host's overrides from the
> example - it lists what the host needs and sizes the workers to its memory:
>
> ```bash
> cd /root/hcp-backup-restore
> cp vars-metal.yaml.example vars-metal.yaml && vi vars-metal.yaml
> ```
>
> Then continue at A2.

### A2. Prerequisites, by hand

Everything from here on runs **as root on the lab host**, from
`udn-bgp-evpn/`, inside tmux - the build takes hours and an ssh drop would
otherwise take it with it.

```bash
sudo -i
tmux new -s lab                  # ctrl-b d detaches; tmux attach -t lab returns
cd /root/hcp-backup-restore
```

**1. `vault.yaml` - your secrets.** Three keys:

```bash
ansible-vault create vault.yaml
```

```yaml
org_id: "XXXXXXXX"                    # console.redhat.com/insights/connector/activation-keys
activation_key: "your-activation-key" # same page
pull_secret: '{"auths":{...}}'        # console.redhat.com/openshift/install/pull-secret, one line
```

The helper VM and the containerlab VM are bare RHEL, so `org_id` and
`activation_key` are what let them install packages.

**2. The vault password file**, so the build does not prompt at every step:

```bash
install -m 600 /dev/null ~/.vault_pass
read -rsp 'Vault password: ' pw && printf '%s' "$pw" > ~/.vault_pass && unset pw; echo
ansible-vault view vault.yaml --vault-password-file ~/.vault_pass >/dev/null && echo OK
```

**3. Check the image and the sizing.**

```bash
ls -l /opt/lab-images/          # rhel-9.8-x86_64-kvm.qcow2
cat vars-metal.yaml             # base_image_dir, worker_memory, worker_cpu, VNC
cat udn-bgp-evpn/workshop/vars-workshop.yaml
```

> **Why overrides, not a new `vars.yaml`.** `vars.yaml` is 2,800 lines that
> also drive the rest of this repository, and every value in it is used
> somewhere. The workshop changes very little of it, so it changes it with
> two small override files, both passed automatically by `build-lab.sh`:
>
> | File | Written by | What it changes |
> | --- | --- | --- |
> | `vars-metal.yaml` | the terraform bootstrap, for this host | where the image is, worker size (24 GiB / 16 vCPU instead of 48 / 32 - the defaults would oversubscribe 192 GiB), VNC |
> | `udn-bgp-evpn/workshop/vars-workshop.yaml` | this repository | drops the `orange` tenant (`udn_tenants_skip`), so the checks and the ingress expect exactly the tenants you build |
>
> Change sizing in `vars-metal.yaml`, not in `vars.yaml`: it keeps
> `git pull` conflict-free and keeps this host's settings in one place.

### A3. One command: helper, clusters, fabric

```bash
cd /root/hcp-backup-restore/udn-bgp-evpn
./build-lab.sh --workshop
```

| Step | What it builds | About |
| --- | --- | --- |
| `bmhost` | libvirt, the helper VM (DNS for `mylab.com`, load balancer), `inventory/hosts`, and `/etc/hosts` entries for every cluster API and console | 15 min |
| `clusters` | the hub (3 masters, 3 workers) and the SNO, **in parallel**, each logging to `build-logs/hub.log` / `sno.log` | 75 min |
| `fabric` | the containerlab VM, the EVPN fabric inside it (leaf1, spine, leaf2, one `<tenant>-ext` endpoint per tenant), the `fabric` libvirt network, and a second NIC on every worker and the SNO | 15 min |
| `nsclient` | the namespace client VM: one network namespace per tenant, each on that tenant's client segment | 10 min |
| `prep` | per cluster, in parallel: the NMState operator, IP forwarding on the fabric NIC, the fabric NIC's address (an NNCP), OpenShift Virtualization on the hub, and `/root/workshop.env` | 20 min |

What it deliberately leaves **undone** - this is the workshop: the network
operator's BGP switches, every `FRRConfiguration`, the `VTEP` and its node
addresses, every `ClusterUserDefinedNetwork`, `RouteAdvertisements`,
namespace and workload. `oc get frrconfiguration -A` finds nothing, because
the API for it does not exist yet.

**If a step fails**, the script names it and prints the command that resumes
from it, e.g. `./build-lab.sh --evpn --workshop --from fabric`. The two
cluster installs log to `build-logs/`; the other steps log to the terminal.

#### The three fabric shapes

The same containerlab fabric is built in one of three shapes, chosen by the
mode flag. The workshop uses the first; Part C switches to the second.

| `build-lab.sh` flag | Fabric (`clab_topology`) | Where tenant VRFs live | How a node reaches a tenant | Used for |
| --- | --- | --- | --- | --- |
| `--workshop` (= `--evpn`) | `evpn`: leaf1 - spine - leaf2 | **leaf2**, and on every node | one BGP session per node carrying EVPN; VXLAN between node VTEPs and leaf2 | Part B |
| `--workshop --vrflite` | `bgp`: leaf1 only | **leaf1**, and on every node | one VLAN and one BGP session **per tenant** per node | Part C |
| `--shared` (no workshop) | `bgp` | nowhere - every UDN goes into the default VRF | the one untagged session | the reference build only |

In both shapes every node also has one untagged session to leaf1 on
`192.168.140.1` - the underlay. Rebuilding the fabric in another shape does
not touch the clusters.

### A4. While it runs: the five ideas

Everything in Part B is one of these five ideas made concrete. Five minutes
here saves an hour of wondering why a manifest has the field it has.

1. **A primary UDN gives a namespace its own network.** A pod in a namespace
   selected by a `ClusterUserDefinedNetwork` gets its main interface
   (`ovn-udn1`) on that network, and the cluster's default network only for
   what Kubernetes itself needs. Two UDNs are two separate networks, even
   with identical subnets. **Layer3** gives each node its own `/24` and
   routes between them; **Layer2** is one flat subnet stretched across every
   node - which is what lets a VM keep its address when it moves.

2. **OVN-Kubernetes can speak BGP.** With the FRR provider enabled, every
   node runs an FRR instance (`frr-k8s`). You tell it who to peer with
   (`FRRConfiguration`), and you tell OVN-Kubernetes which networks to
   advertise over it (`RouteAdvertisements`). OVN-Kubernetes then *generates*
   more FRR configuration of its own. No NAT anywhere: pods keep their
   addresses on the fabric.

3. **Every UDN is a VRF on the node.** OVN-Kubernetes gives each
   `ClusterUserDefinedNetwork` a Linux VRF named after it. A VRF is a
   separate routing table, so blue's `10.200.4.0/24` and red's
   `10.200.4.0/24` never meet.

4. **EVPN carries VRFs between routers without a VLAN per tenant.** Each VRF
   is tagged with a **VNI** (the number in the VXLAN header) and a **route
   target** (the tag on its BGP routes). A router imports a route into a VRF
   only when the route target matches. Traffic goes in **VXLAN**, from one
   **VTEP** (an IP address on a node, or on leaf2) to another. Layer3 tenants
   exchange prefix routes (type-5) on an **L3VNI**; Layer2 tenants exchange
   MAC routes (type-2) on an **L2VNI**, which is how one broadcast domain
   spans two clusters.

5. **The fabric is the control plane, not a tunnel broker.** Nothing ever
   "opens a tunnel". A node encapsulates a packet toward whatever VTEP the
   route for its destination names. No route, no tunnel - the packet is
   dropped in the node's VRF and the pod sees `Destination Host Unreachable`.

Deeper: [bgp-evpn.md](bgp-evpn.md) follows single packets through each phase.

### A5. When it finishes

**Once:** point the lab host's DNS at the helper, so any route you create
later resolves from the host as well as from inside the cluster
(`/etc/hosts` already covers every name the lab itself uses):

```bash
CON=$(nmcli -g GENERAL.CONNECTION device show "$(ip route show default | awk '{print $5; exit}')")
nmcli con mod "$CON" ipv4.dns 192.168.122.21 ipv4.dns-options timeout:1
nmcli con up "$CON"
```

**Every new shell:**

```bash
source /root/workshop.env
lab hub          # oc -> the hub, and $ASN / $CLUSTER to match
```

`workshop.env` gives you the numbers every manifest uses (`$ASN`, `$LEAF1_IP`,
`$VTEP_CIDR`, ...) and a few helpers. They are shorthand, nothing more: each
one is a command you could type yourself, and the right-hand column is that
command.

The fabric routers (leaf1, leaf2, spine) and the tenants' external endpoints
are containers, run by containerlab on its own VM (`$CLAB_IP`) and named
`clab-$CLAB_LAB-<name>`. So "run something on leaf1" means ssh to that VM,
then `docker exec` into the container - which is two hops the helpers save
you on every check.

| Helper | Does | Same as |
| --- | --- | --- |
| `lab hub` / `lab sno` | switches `oc`, `$ASN`, `$CLUSTER` and `$M` to that cluster | `export KUBECONFIG=$HUB_KUBECONFIG ASN=$HUB_ASN CLUSTER=hub M=$WS_MANIFESTS/hub` |
| `leaf1 '<cmd>'` (`leaf2`, `spine`) | one FRR command on that fabric router | `ssh root@$CLAB_IP`, then `docker exec -it clab-$CLAB_LAB-leaf1 vtysh` and type `<cmd>` at its prompt |
| `onleaf1 <cmd>`, `onleaf2 <cmd>` | any Linux command inside that router - `ip route show vrf blue`, `bridge fdb`, `tcpdump` | `ssh root@$CLAB_IP`, then `docker exec -it clab-$CLAB_LAB-leaf2 sh` and run `<cmd>` there |
| `ext <tenant> <cmd>` | a command on that tenant's external host behind leaf2 - the "outside world" the tenant talks to | `ssh root@$CLAB_IP`, then `docker exec -it clab-$CLAB_LAB-blue-ext sh` and run `<cmd>` |
| `labssh <ip> <cmd>` | root on any other lab VM (the namespace client, the helper) | `ssh -i $LAB_SSH_KEY root@<ip> '<cmd>'` - the lab's own key, not yours |
| `nodevtysh <node> '<cmd>'` | one FRR command on a cluster node - the cluster's side of each BGP session | find the `frr-k8s` pod on `<node>` (`oc -n $FRR_NS get pods -l component=frr-k8s -o wide`), then `oc -n $FRR_NS rsh -c frr <pod>`, `vtysh`, and type `<cmd>` |
| `inpod <tenant> <cmd>` | a command in that tenant's test pod | `oc -n udn-<tenant> rsh <first udn-test pod>` and run `<cmd>` there - so from inside the tenant's network |
| `podip <tenant> [node]` | that tenant's test pod's UDN address, optionally the pod on `<node>` | `oc -n udn-<tenant> rsh <pod> ip -4 addr show ovn-udn1`. Not `oc get pod -o wide`: that shows the pod's cluster-default-network address, not the tenant one |

`inpod` runs the command without a terminal (`oc exec`, not `oc exec -it`),
so ctrl-c stops your local `oc`, not the command in the pod - a ping killed
that way never prints its statistics. Give anything long-running a count
(`-c`) or a deadline (`-w`) instead.

`inpod` always picks the tenant's *first* test pod, on whichever node that
happens to be. When the node matters, `podip <tenant> <node>` gives you the
address of the one on a particular node to aim at.

To see exactly what a helper runs, ask the shell:

```bash
type nodevtysh
```

**Every manifest is a file.** Each block below writes its manifest into
`$M` - `/root/workshop-manifests/hub` or `.../sno`, set by `lab` - and then
applies it:

```text
cat > "$M/lab02-frrconfiguration-default.yaml" <<EOF   # 1. write it: your shell expands $ASN etc.
...
EOF
oc apply -f "$M/lab02-frrconfiguration-default.yaml"    # 2. apply it
```

Between the two, look at what you are about to apply - every variable
expanded, nothing left to guess:

```bash
cat "$M/lab02-frrconfiguration-default.yaml"
oc apply --dry-run=server -f "$M/lab02-frrconfiguration-default.yaml"   # the API's verdict, nothing changed
```

Afterwards `ls -tr $M` is the record of what you built on that cluster, in
the order you wrote it, and `diff $WS_MANIFESTS/hub $WS_MANIFESTS/sno` shows how the two
clusters differ.

**Look before you touch anything:**

```bash
oc get nodes
oc get nncp                      # fabric-untagged-worker1..3: Available
oc get network.operator cluster -o jsonpath='{.spec.additionalRoutingCapabilities}{"\n"}'
                                 # empty - BGP is not on yet
leaf1 'show bgp summary'         # every node listed, none Established
```

leaf1 already expects a session from every node on `192.168.140.x`; nothing
on the cluster side answers yet. That is the starting line.

---

## Part B - Hands-on: EVPN

**Every `oc` command goes to whichever cluster you last named with `lab`.**
So every lab starts with a **Where:** line, and every switch is a small block
of its own - `lab hub` or `lab sno` - that you run *before* the blocks it
applies to. The manifest blocks themselves never switch cluster, which is
what lets you paste the same block on both.

| Lab | Hub | SNO |
| --- | --- | --- |
| 1-4 the foundation: BGP on, peering, VTEPs, EVPN | yes | yes - right after the hub, in the same lab |
| 5 blue and red | yes | - |
| 6 the `RouteAdvertisements` | yes | in Lab 8 |
| 7 green and purple, low half | yes | - |
| 8 green and purple, high half | - | yes |
| 9 violet | yes | yes |
| 10 web pages | yes (5 tenants) | yes (3 tenants) |
| 11 the ingress | - (a script on the lab host) | - |
| 12 live migration | the VM | the observer |

The helper functions you define along the way (`workload` in Lab 5,
`violet` in Lab 9, `webpod` in Lab 10) are written to
`$WS_MANIFESTS/functions/` as well as defined, and `workshop.env` loads
everything in that directory - so a new shell has them after
`source /root/workshop.env`, like the rest. Each lab ends with a **Check**: the fewest commands that prove it worked,
and what they should print.

### Lab 1. Turn on BGP in OVN-Kubernetes

> **Where:** the hub, then the SNO.

Three switches on the cluster network operator, in one patch. Start on the
hub:

```bash
lab hub
```

```bash
cat > "$M/lab01-network-operator-patch.yaml" <<'EOF'
spec:
  additionalRoutingCapabilities:
    providers: [FRR]                  # deploy frr-k8s on every node
  defaultNetwork:
    ovnKubernetesConfig:
      routeAdvertisements: Enabled    # the RouteAdvertisements API
      gatewayConfig:
        routingViaHost: true          # local gateway mode
        ipForwarding: Global          # let the host forward for the fabric NIC
EOF
oc patch network.operator.openshift.io cluster --type=merge --patch-file="$M/lab01-network-operator-patch.yaml"
```

- **`providers: [FRR]`** deploys the `frr-k8s` DaemonSet in
  `openshift-frr-k8s` and the `FRRConfiguration` API.
- **`routeAdvertisements: Enabled`** installs the `RouteAdvertisements` API
  and the controller that turns it into FRR configuration.
- **`routingViaHost: true`** is *local gateway mode*: traffic leaving a UDN
  goes through the node's own routing tables - its VRFs - instead of straight
  out of OVN. VRF-Lite and EVPN both need it, because the VRF is where the
  fabric's routes are.
- **`ipForwarding: Global`**: by default OVN-Kubernetes forwards only on the
  interfaces it manages, and the fabric NIC is not one of them. Replies from
  the fabric would reach the node and be dropped in the routing decision with
  every other signal green.

The operator now restarts `ovnkube-node` on every node. Wait for it - first
for the rollout to start, then to finish, then for frr-k8s to exist and be
ready:

```bash
oc wait co/network --for=condition=Progressing=True --timeout=2m || true
oc wait co/network --for=condition=Progressing=False --timeout=15m
until oc -n openshift-frr-k8s get ds/frr-k8s >/dev/null 2>&1; do sleep 10; done
oc -n openshift-frr-k8s rollout status ds/frr-k8s --timeout=10m
```

**Check**

```bash
oc get crd routeadvertisements.k8s.ovn.org vteps.k8s.ovn.org   # both exist
oc -n openshift-frr-k8s get pods -o wide                        # one frr-k8s per node, Running
```

**Now the SNO.** Switch, then paste the patch block and the wait block above
again, and the check:

```bash
lab sno
```

The rollout takes a few minutes per cluster. To overlap them, run the SNO's
in a second tmux window (`ctrl-b c`, then `source /root/workshop.env; lab sno`)
while the hub's runs.

### Lab 2. Peer every node with the fabric

> **Where:** the hub, then the SNO.

One BGP session from every node to leaf1, in the default VRF. This is the
underlay: EVPN will ride on it from Lab 6. Start on the hub:

```bash
lab hub
```

**First: does this fabric authenticate its sessions?**

```bash
echo "${BGP_AUTH_SECRET:-none}"
```

`none` is the workshop's default - skip to the manifest. A name
(`udn-bgp-fabric-key`) means `vault.yaml` has a `udn_bgp_password`, so leaf1
signs every BGP segment with it (TCP-MD5), and a node without the same key is
never answered. Put the key where frr-k8s can read it, as a Secret:

```bash
if [ -n "$BGP_AUTH_SECRET" ]; then
  ansible-vault view /root/hcp-backup-restore/vault.yaml --vault-password-file ~/.vault_pass \
    | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["udn_bgp_password"], end="")' \
    | oc -n $FRR_NS create secret generic $BGP_AUTH_SECRET --type=kubernetes.io/basic-auth \
        --from-file=password=/dev/stdin --dry-run=client -o yaml \
    | oc apply -f -
fi
```

This is the one object the workshop does **not** write to `$M`: it would put
the key on disk in the clear. The manifests refer to it by name instead
(`$BGP_AUTH_YAML` below becomes `passwordSecret: {name, namespace}`), so the
key itself is never in a file you keep.

**The peering:**

```bash
cat > "$M/lab02-frrconfiguration-default.yaml" <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: fabric-peering-default
  namespace: $FRR_NS
  labels:
    routeAdvertisements: fabric-default
spec:
  nodeSelector: {}                    # every node
  bgp:
    routers:
      - asn: $ASN                     # this cluster's AS
        neighbors:
          - address: $LEAF1_IP        # leaf1, on the fabric network
            asn: $LEAF1_ASN
$BGP_AUTH_YAML
            port: 179
            holdTime: 9s              # lab timers: converge in seconds
            keepaliveTime: 3s
            toReceive:
              allowed:
                mode: all
            toAdvertise:
              allowed:
                mode: filtered        # advertise nothing of our own
EOF
oc apply -f "$M/lab02-frrconfiguration-default.yaml"
```

`toAdvertise: filtered` with no prefixes is deliberate. Everything these
sessions will advertise comes later from `RouteAdvertisements`, which
generates its own FRR configuration. `mode: all` here would put the node's
connected routes - the lab's management network among them - into the fabric.

The unquoted `<<EOF` matters: `$ASN`, `$LEAF1_IP` and `$FRR_NS` are expanded
by your shell from `workshop.env` as the file is written. `cat` the file to
see the numbers that actually went in. Blocks with nothing to expand use
`<<'EOF'`, which writes the text exactly as shown.

**Check**

```bash
leaf1 'show bgp summary'
# 192.168.140.34 ... 64512 ... <uptime> ... 0      <- hub workers: Established
# 192.168.140.20 ... 64515 ... Connect             <- the SNO: next
```

A number (prefixes received, 0 for now) in the last column means
Established; a word means it is not. From the cluster's side:

```bash
nodevtysh worker1 'show bgp summary'
```

> A node stuck in `Active`/`Connect` while the others are up: restart that
> node's `frr-k8s` pod
> (`oc -n $FRR_NS delete pod -l component=frr-k8s --field-selector spec.nodeName=<node>`).
> The fabric NIC is hot-plugged and addressed after frr-k8s starts, and zebra
> sometimes keeps a stale view of it - `show bgp nexthop` on that node says
> `invalid`. A restart makes it re-read the kernel.

**Now the SNO.** It joins the same fabric with its own AS, 64515 - `lab sno`
sets `$ASN` for you. **Every cluster needs its own AS**: share one and leaf1
reflects one cluster's routes to the other, which drops them all as a loop,
silently.

```bash
lab sno
```

Paste again, in order: the authentication block (the Secret lives in each
cluster, so the SNO needs its own) and the peering block. Then:

```bash
leaf1 'show bgp summary'         # 192.168.140.20 (AS 64515) Established too
```

### Lab 3. Give every node a VTEP

> **Where:** the hub, then the SNO.

A VTEP is the address VXLAN packets are sent *to* and *from*. Each node gets
one `/32` on a dummy interface - loopback-shaped, so it belongs to no subnet
and is reached only by routing. leaf1 already has a static `/32` for each of
them via the node's fabric address.

The address is `100.64.0.<last octet of the node's InternalIP>`, and it goes
on **every** node, masters included - the VTEP CR is only accepted once every
node has one. Start on the hub:

```bash
lab hub
```

```bash
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' |
while read -r node ip; do
cat > "$M/lab03-nncp-vtep-$node.yaml" <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: vtep-$node
spec:
  nodeSelector:
    kubernetes.io/hostname: $node
  desiredState:
    interfaces:
      - name: $VTEP_IFACE
        type: dummy
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: $VTEP_PREFIX.${ip##*.}
              prefix-length: 32
        ipv6:
          enabled: false
EOF
oc apply -f "$M/lab03-nncp-vtep-$node.yaml"
done
oc wait nncp --all --for=condition=Available --timeout=5m
```

Now tell OVN-Kubernetes where to find them:

```bash
cat > "$M/lab03-vtep.yaml" <<EOF
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  cidrs:
    - $VTEP_CIDR
  mode: Unmanaged
EOF
oc apply -f "$M/lab03-vtep.yaml"
```

`mode: Unmanaged` means "the addresses are already on the nodes; find each
node's one inside this CIDR". **Do not drop the `mode` line**: the API's
default is `Managed`, which this release does not implement - the CR is
accepted and nothing ever happens.

**Check**

```bash
oc get nodes -o custom-columns='NODE:.metadata.name,VTEP:.metadata.annotations.k8s\.ovn\.org/vteps'
# every node has one, e.g. {"evpn-vtep":{"ips":["100.64.0.34"]}}
oc get vtep evpn-vtep -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'
# True
```

> A node with the address (`oc debug node/<node> -- chroot /host ip -br addr show vtep0`)
> but no annotation after a minute: restart its ovnkube-node pod,
> `oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node --field-selector spec.nodeName=<node>`.
> An address that is missing entirely is an NMState problem:
> `oc get nnce | grep vtep`.

**Now the SNO.** Switch, and paste the NNCP loop and the `VTEP` block again,
then the check. Its one node gets `100.64.0.20`:

```bash
lab sno
```

### Lab 4. The session EVPN will use

> **Where:** the hub, then the SNO.

The same session to leaf1, now about the VTEP block: the node learns
leaf1's route for `$VTEP_CIDR`, which is how its VXLAN packets reach every
other VTEP. Start on the hub:

```bash
lab hub
```

```bash
cat > "$M/lab04-frrconfiguration-evpn.yaml" <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: fabric-peering-evpn
  namespace: $FRR_NS
  labels:
    routeAdvertisements: fabric-evpn
spec:
  nodeSelector: {}
  bgp:
    routers:
      - asn: $ASN
        prefixes:
          - $VTEP_CIDR
        neighbors:
          - address: $LEAF1_IP
            asn: $LEAF1_ASN
$BGP_AUTH_YAML
            port: 179
            holdTime: 9s
            keepaliveTime: 3s
            toReceive:
              allowed:
                mode: all
            toAdvertise:
              allowed:
                prefixes:
                  - $VTEP_CIDR
EOF
oc apply -f "$M/lab04-frrconfiguration-evpn.yaml"
```

- **`toReceive: mode: all`** - takes leaf1's `$VTEP_CIDR`. leaf1 originates
  it and holds a static `/32` per node VTEP behind it, so a packet to any VTEP
  goes to leaf1 and leaf1 hands it to the right node.
- **`prefixes` and `toAdvertise`: `$VTEP_CIDR` only** - an explicit list, not
  `mode: all`, which would also offer the lab's management network.
- **The label** is how Lab 6's `RouteAdvertisements` finds this
  configuration; it must match exactly one.

Two `FRRConfiguration`s for one neighbor is fine: frr-k8s merges them.

**What this manifest does *not* say: `l2vpn evpn`.** Nothing you write turns
on the EVPN address family. OVN-Kubernetes does, in a configuration of its
own (`ovnk-generated-*`), once a `RouteAdvertisements` selects an EVPN network
and names this `FRRConfiguration` - that is Lab 6. For every neighbor in the
configurations it names, it writes:

```
router bgp 64512
 address-family ipv4 unicast
  neighbor 192.168.140.1 allowas-in origin    <- every hub node is AS 64512
 exit-address-family
 address-family l2vpn evpn
  neighbor 192.168.140.1 activate             <- this is what ends NoNeg
  neighbor 192.168.140.1 allowas-in origin
  advertise-all-vni
  vni 400                                     <- one per Layer2 tenant (MAC-VRF)
   route-target import 65000:400
   route-target export 65000:400
  exit-vni
 exit-address-family
```

and a `vrf`/`router bgp 64512 vrf <tenant>` pair per Layer3 tenant (IP-VRF).
`allowas-in origin` matters: a route one hub node originates comes back to
another through leaf1 with 64512 already in its path, and BGP's loop
prevention would drop it. `origin` accepts it when our AS is only the
originator.

Ask the API: there is no per-neighbor address-family field to write any of
this yourself.

```bash
oc explain frrconfiguration.spec.bgp.routers.neighbors | grep -iE 'famil|allow'
# dualStackAddressFamily <boolean>    <- IPv4 + IPv6 unicast, not EVPN
```

Write `addressFamilies: [unicast, evpn]` or `allowAsIn: origin` here anyway -
older write-ups of this lab did - and `oc apply` accepts it without a word:
the API server drops fields its schema doesn't have. The only trace is the
`last-applied-configuration` annotation, which records what you *sent*, not
what was kept. Comparing the two is how you catch it:

```bash
oc -n $FRR_NS get frrconfiguration fabric-peering-evpn -o jsonpath='{.spec.bgp.routers[0].neighbors[0]}{"\n"}'
# what the cluster kept - the fields frr-k8s will act on
```

**Check**

```bash
leaf1 'show bgp summary'                         # ipv4 unicast: the hub workers, Established
nodevtysh worker1 "show ip route $VTEP_CIDR"    # B>* ... via 192.168.140.1 - the way to every VTEP
leaf1 'show bgp l2vpn evpn summary'              # the hub workers: NoNeg - and that is right
```

`NoNeg` means the session is up but the address family was not negotiated:
leaf1 offers `l2vpn evpn`, the node doesn't yet. From the node's side it
reads `Address Family L2VPN EVPN: received` - received, not advertised:

```bash
nodevtysh worker1 'show bgp neighbor 192.168.140.1' | grep -A1 'L2VPN EVPN'
```

It turns into numbers in Lab 6. Don't reset sessions or restart pods over it.

**Now the SNO.** Switch, paste the block above again, and check:

```bash
lab sno
```

```bash
leaf1 'show bgp summary'                         # all four up: three hub workers and 192.168.140.20
nodevtysh sno "show ip route $VTEP_CIDR"         # B>* ... via 192.168.140.1
```

No EVPN yet on either cluster - there are no tenants to advertise. The
foundation is done on both clusters; from here each lab says which cluster it
is for.

### Lab 5. Two tenants, one subnet: blue and red

> **Where:** the hub only.

```bash
lab hub
```

A tenant is three things: the **network** (`ClusterUserDefinedNetwork`), a
**namespace** it selects, and something running there. Blue and red get the
*same* subnet on purpose.

```bash
cat > "$M/lab05-cudn-blue-red.yaml" <<'EOF'
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: blue
  labels:
    bgp: enabled                   # Lab 6 selects networks by this label
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: blue
  network:
    topology: Layer3
    layer3:
      role: Primary                # the pod's main interface, not an extra one
      subnets:
        - cidr: 10.200.0.0/16
          hostSubnet: 24           # each node gets its own /24 of it
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      ipVRF:                       # Layer3 -> a routed VRF on an L3VNI
        vni: 101
        routeTarget: "65000:101"
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: red
  labels:
    bgp: enabled
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: red
  network:
    topology: Layer3
    layer3:
      role: Primary
      subnets:
        - cidr: 10.200.0.0/16      # the SAME subnet as blue
          hostSubnet: 24
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      ipVRF:
        vni: 201                   # a different VNI...
        routeTarget: "65000:201"   # ...and a different route target: a different network
EOF
oc apply -f "$M/lab05-cudn-blue-red.yaml"
```

`ipVRF` is required for Layer3 and rejected for Layer2 (which takes `macVRF`,
Lab 7). `transport` is immutable: changing it later means deleting the CUDN.

Now the namespace and a test pod on every worker. Defined as a function,
because every tenant gets the same shape - and saved to a file, which
`workshop.env` loads, so it is still there in your next shell. The quoted
`'FN'` keeps `$1` and `$M` literal in the file; they are filled in each time
you call it:

```bash
mkdir -p "$WS_MANIFESTS/functions"
cat > "$WS_MANIFESTS/functions/workload.sh" <<'FN'
workload() {
cat > "$M/workload-$1.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: udn-$1
  labels:
    udn-tenant: $1                                   # what the CUDN selects
    k8s.ovn.org/primary-user-defined-network: ""     # must be set at creation
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: udn-test
  namespace: udn-$1
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: udn-test-privileged
  namespace: udn-$1
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: udn-test
    namespace: udn-$1
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: udn-test
  namespace: udn-$1
spec:
  selector:
    matchLabels: {app: udn-test, tenant: $1}
  template:
    metadata:
      labels: {app: udn-test, tenant: $1}
    spec:
      serviceAccountName: udn-test
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      tolerations:
        - operator: Exists
          effect: NoSchedule
      containers:
        - name: shell
          image: registry.redhat.io/rhel9/support-tools:latest
          command: ["/bin/bash", "-c", "sleep infinity"]
          securityContext:
            capabilities:
              add: ["NET_RAW", "NET_ADMIN"]         # ping, tcpdump, ip
          resources:
            requests: {cpu: 10m, memory: 32Mi}
EOF
oc apply -f "$M/workload-$1.yaml"
oc -n udn-$1 rollout status ds/udn-test --timeout=10m
}
FN
source "$WS_MANIFESTS/functions/workload.sh"

workload blue
workload red
```

- **The `primary-user-defined-network` label must exist when the namespace is
  created.** Adding it later does not move a namespace onto a UDN.
- **The privileged SCC** is for `NET_RAW`/`NET_ADMIN`. Without the binding the
  DaemonSet is accepted and never creates a pod - `desired=3 scheduled=0`.

**Check**

```bash
oc get clusteruserdefinednetwork            # blue, red
oc get clusteruserdefinednetwork blue -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
                                            # a condition True, e.g. NetworkCreated=True
inpod blue ip -br addr                      # eth0 (default network) AND ovn-udn1 10.200.x.y/24
echo "blue $(podip blue)   red $(podip red)" # quite possibly the SAME address
```

On a node, each is a VRF with its own table:

```bash
oc debug node/worker1 -- chroot /host ip -br link show type vrf   # blue, red
```

### Lab 6. Advertise them

> **Where:** the hub now (you are still on it). The SNO gets the same object
> in Lab 8, once it has tenants.

The object that ties it together: *these* networks, over *that* FRR
configuration, into their own VRFs.

```bash
cat > "$M/lab06-routeadvertisements-udn-evpn.yaml" <<'EOF'
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: udn-evpn
spec:
  targetVRF: auto                  # each network into its OWN VRF
  advertisements:
    - PodNetwork
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            bgp: enabled
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      routeAdvertisements: fabric-evpn   # Lab 4's configuration
EOF
oc apply -f "$M/lab06-routeadvertisements-udn-evpn.yaml"
```

`targetVRF: auto` is the isolation: blue's routes go out of blue's VRF with
blue's route target. Every network labelled `bgp: enabled` from now on is
advertised the moment it exists - you will not touch this object again.

This is also the object that turns EVPN on at the node. OVN-Kubernetes now
writes its own `FRRConfiguration`s next to yours - the `l2vpn evpn` section
Lab 4 showed, on the neighbor Lab 4's configuration names, with a `vni` or a
VRF per tenant - and frr-k8s merges them into one running FRR.

**Check: EVPN is negotiated**

```bash
oc get routeadvertisements udn-evpn -o jsonpath='{.status.status}{"\n"}'   # Accepted
oc -n $FRR_NS get frrconfiguration      # yours two, and ovnk-generated-* next to them
leaf1 'show bgp l2vpn evpn summary'     # hub workers: numbers, not NoNeg. The SNO: NoNeg until Lab 8
oc get frrnodestate worker1 -o jsonpath='{.status.runningConfig}' \
  | sed -n '/address-family l2vpn evpn/,/exit-address-family/p'   # activate, allowas-in, advertise-all-vni
```

If the hub workers still read `NoNeg`, the `RouteAdvertisements` did not
match Lab 4's label, or selected no network - `oc get ra udn-evpn -o yaml`
says which in its status.

**Check: routes and traffic**

```bash
leaf2 'show bgp l2vpn evpn route type prefix'
# (abbreviated) every 10.200.x.0/24 appears twice, from the same node VTEP:
#   [5]:[0]:[24]:[10.200.3.0]  100.64.0.34  ...  RT:65000:101   <- blue
#   [5]:[0]:[24]:[10.200.3.0]  100.64.0.34  ...  RT:65000:201   <- red, same prefix
onleaf2 ip route show vrf blue | grep 10.200    # one /24 per worker
onleaf2 ip route show vrf red  | grep 10.200    # the same /24s, in another table
```

Now the data plane, from each tenant's external endpoint behind leaf2:

```bash
ext blue ping -c3 $(podip blue)      # blue-ext -> blue pod: replies
ext red  ping -c3 $(podip red)       # red-ext  -> red pod: replies, maybe to the same address
inpod blue ping -c3 10.210.10.10     # blue pod -> blue-ext: replies
inpod blue ping -c2 -W2 10.211.10.10 # blue pod -> red-ext: SILENT - different route target
```

The last line is the tenancy. The packet leaves blue's VRF with no route to
red's external network, because red's routes were never imported into blue's
VRF anywhere. No ACL, no firewall - just which routes exist.

**Checkpoint.** Let the lab's own checks confirm the hub, and repair the
three platform faults it knows about (forwarding on the fabric NIC, a stale
BGP nexthop, a missing SNAT exclusion) if any appeared:

```bash
cd /root/hcp-backup-restore/udn-bgp-evpn
./build-lab.sh --workshop --only check-hub
```

It checks only the tenants that exist so far and says which it skipped.

### Lab 7. Layer2 tenants: green and purple

> **Where:** the hub only. The SNO's half is Lab 8.

```bash
lab hub
```

A Layer2 tenant is one subnet across every node - and, with EVPN, across
every cluster on its L2VNI. Two clusters sharing one subnet need to agree who
allocates what, because there is no cross-cluster IPAM: the hub takes the low
half of `10.204.0.0/16`, the SNO the high half.

First, ask the API what the reservation field is called on Layer2 - it has
changed name before, and a field the CRD does not know is **silently
dropped**:

```bash
oc explain clusteruserdefinednetwork.spec.network.layer2 | grep -iE 'reserved|exclude'
# reservedSubnets <[]string>
```

```bash
cat > "$M/lab07-cudn-green-purple.yaml" <<'EOF'
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: green
  labels:
    bgp: enabled
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
      reservedSubnets:
        - 10.204.128.0/17          # the SNO's half, and the external hosts at .255.x
      ipam:
        lifecycle: Persistent      # an address belongs to the workload, not the pod
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF:                      # Layer2 -> a bridged domain on an L2VNI
        vni: 400
        routeTarget: "65000:400"
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: purple
  labels:
    bgp: enabled
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: purple
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets:
        - 10.204.0.0/16            # the same subnet as green
      reservedSubnets:
        - 10.204.128.0/17
      ipam:
        lifecycle: Persistent
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF:
        vni: 500
        routeTarget: "65000:500"
EOF
oc apply -f "$M/lab07-cudn-green-purple.yaml"
workload green
workload purple
```

`ipam.lifecycle: Persistent` is what Lab 12 depends on: a live migration
replaces the pod, and without it the VM would arrive with a new address.

**Check**

```bash
oc get clusteruserdefinednetwork green -o jsonpath='{.spec.network.layer2.reservedSubnets}{"\n"}'
                                   # ["10.204.128.0/17"] - if empty, the field name was wrong
echo "green $(podip green)   purple $(podip purple)"   # 10.204.0.x, both from the low half
ext green  ping -c3 $(podip green)     # green-ext (10.204.255.10) -> green pod
ext purple ping -c3 $(podip purple)    # purple-ext (10.204.255.20) -> purple pod
```

Look at the TTL in the replies: **64**. No router decremented it, because
nothing routed it - the frame was bridged across VXLAN from leaf2's `br400`
straight into the pod's Layer2 switch. Compare Lab 6's blue ping, which
arrives with less. On leaf2 the pod is a MAC, not a prefix:

```bash
leaf2 'show evpn mac vni 400'      # the green pods' MACs, each behind a node VTEP
```

### Lab 8. The SNO's half of green and purple

> **Where:** the SNO only.

```bash
lab sno
```

The SNO allocates from the high half of `10.204.0.0/16`. Its reservation is everything *else*, and it cannot just be
`10.204.0.0/17`: `.1` is the switch's gateway and `.2` the node's management
port, and reserving either crashes ovnkube-node on start. So it reserves the
low half *except* those two, which takes fifteen CIDRs - plus the external
hosts at `.255.x`:

```bash
for t in green:400 purple:500; do
cat > "$M/lab08-cudn-${t%:*}.yaml" <<EOF
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: ${t%:*}
  labels:
    bgp: enabled
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: ${t%:*}
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets:
        - 10.204.0.0/16
      reservedSubnets:             # 10.204.0.3 - 10.204.127.255, and 10.204.255.0/24
        - 10.204.0.3/32
        - 10.204.0.4/30
        - 10.204.0.8/29
        - 10.204.0.16/28
        - 10.204.0.32/27
        - 10.204.0.64/26
        - 10.204.0.128/25
        - 10.204.1.0/24
        - 10.204.2.0/23
        - 10.204.4.0/22
        - 10.204.8.0/21
        - 10.204.16.0/20
        - 10.204.32.0/19
        - 10.204.64.0/18
        - 10.204.255.0/24
      ipam:
        lifecycle: Persistent
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF:
        vni: ${t#*:}
        routeTarget: "65000:${t#*:}"
EOF
oc apply -f "$M/lab08-cudn-${t%:*}.yaml"
done
workload green
workload purple
```

Then the same `RouteAdvertisements` as Lab 6, unchanged. It is the SNO's
first, and it advertises every tenant the SNO has from here on. `lab sno` set
`$M` to the SNO's directory, so this writes the SNO's own copy:

```bash
cat > "$M/lab06-routeadvertisements-udn-evpn.yaml" <<'EOF'
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: udn-evpn
spec:
  targetVRF: auto                  # each network into its OWN VRF
  advertisements:
    - PodNetwork
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            bgp: enabled
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      routeAdvertisements: fabric-evpn   # Lab 4's configuration
EOF
oc apply -f "$M/lab06-routeadvertisements-udn-evpn.yaml"
```

It is also what turns EVPN on for the SNO's session:

```bash
leaf1 'show bgp l2vpn evpn summary'   # 192.168.140.20 now shows numbers, like the hub workers
```

**Check: one broadcast domain, two clusters.**

```bash
HUB_GREEN=$(KUBECONFIG=$HUB_KUBECONFIG podip green)
echo "sno green $(podip green)   hub green $HUB_GREEN"   # 10.204.128.x and 10.204.0.x
inpod green ping -c3 $HUB_GREEN
# 64 bytes from 10.204.0.x: icmp_seq=1 ttl=64      <- bridged, cluster to cluster
```

TTL 64 again: the SNO node put the frame in VXLAN addressed to the hub
node's VTEP directly. Neither leaf decapsulated it.

```bash
./build-lab.sh --workshop --only check-sno
```

### Lab 9. A routed tenant on both clusters, with the internet: violet

> **Where:** both. The block below switches between them itself, because the
> two clusters get different slices.

A Layer3 tenant can span clusters too - as one routed network with one route
target - as long as the two clusters never originate the same prefix. So
each gets its own **slice** of `10.206.0.0/16`: the hub `/17`, the SNO the
other `/17`. Without slices, both allocate the same `/24`s first and leaf2
ends up with two paths to one prefix, one of them wrong.

```bash
mkdir -p "$WS_MANIFESTS/functions"
cat > "$WS_MANIFESTS/functions/violet.sh" <<'FN'
violet() {   # violet <slice>
cat > "$M/lab09-cudn-violet.yaml" <<EOF
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: violet
  labels:
    bgp: enabled
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: violet
  network:
    topology: Layer3
    layer3:
      role: Primary
      subnets:
        - cidr: $1
          hostSubnet: 24
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      ipVRF:
        vni: 601
        routeTarget: "65000:601"
EOF
oc apply -f "$M/lab09-cudn-violet.yaml"
workload violet
}
FN
source "$WS_MANIFESTS/functions/violet.sh"

lab hub; violet 10.206.0.0/17
lab sno; violet 10.206.128.0/17
```

Violet also has a way out to the internet: leaf2 originates a **default
route** into violet's VRF (`default-originate ipv4` - day 0 configured it),
sends that traffic out of the fabric, and the lab host NATs it. "No NAT"
means inside the cluster; the internet cannot route to `10.206.x`, so the NAT
sits at the border. leaf2 keeps private ranges unreachable in violet's VRF,
so the default is not a way round tenancy.

**Check**

```bash
lab sno
HUB_VIOLET=$(KUBECONFIG=$HUB_KUBECONFIG podip violet)
inpod violet ping -c3 $HUB_VIOLET
# ttl=61 - ROUTED this time, cluster to cluster

oc debug node/sno --quiet -- chroot /host ip route show vrf violet
# 10.206.3.0/24 via 100.64.0.34 dev ... proto bgp onlink    <- straight to a hub node's VTEP
# default via 10.0.0.2 dev ... proto bgp onlink              <- leaf2's default

inpod violet curl -sI -m5 http://1.1.1.1/ | head -1   # HTTP/1.1 301 - the internet
inpod violet ping -c2 -W2 $(KUBECONFIG=$HUB_KUBECONFIG podip blue)   # SILENT
```

Green crossed at TTL 64 and violet at 61: bridged versus routed, on the same
fabric, chosen by one field - `macVRF` or `ipVRF`. The route table shows why
the tunnel goes node to node: the SNO holds each hub node's `/24` with that
node's own VTEP as next hop.

```bash
./build-lab.sh --workshop --only check-hub
./build-lab.sh --workshop --only check-sno
```

### Lab 10. A web page per tenant

> **Where:** both. The last lines of the block switch between them.

A ping reply proves something answered, not *what* did - and blue and red
share addresses. A page that names its tenant, cluster, pod and node settles
it. One per tenant, on both clusters:

```bash
mkdir -p "$WS_MANIFESTS/functions"
cat > "$WS_MANIFESTS/functions/webpod.sh" <<'FN'
webpod() {   # webpod <tenant> - on the cluster `lab` points at
cat > "$M/lab10-web-banner-$1.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: udn-web-banner
data:
  banner: "I am $1 on $CLUSTER"
  tenant: "$1"
  cluster: "$CLUSTER"
EOF
oc apply -n udn-$1 -f "$M/lab10-web-banner-$1.yaml"
cat > "$M/lab10-web-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: udn-web
spec:
  replicas: 1
  selector:
    matchLabels: {app: udn-web}
  template:
    metadata:
      labels: {app: udn-web}
    spec:
      initContainers:
        - name: render-page
          image: registry.redhat.io/rhel9/support-tools:latest
          command:
            - /bin/bash
            - -c
            - |
              udn=$(ip -o -4 addr show ovn-udn1 | awk '{print $4}')
              { echo "$BANNER"; echo
                printf '%-9s %s\n' tenant: "$TENANT" cluster: "$CLUSTER" \
                       pod: "$POD_NAME" node: "$NODE_NAME" udn: "${udn:-(not on its UDN)}"
              } > /page/index.html
          env:
            - {name: BANNER,    valueFrom: {configMapKeyRef: {name: udn-web-banner, key: banner}}}
            - {name: TENANT,    valueFrom: {configMapKeyRef: {name: udn-web-banner, key: tenant}}}
            - {name: CLUSTER,   valueFrom: {configMapKeyRef: {name: udn-web-banner, key: cluster}}}
            - {name: POD_NAME,  valueFrom: {fieldRef: {fieldPath: metadata.name}}}
            - {name: NODE_NAME, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
          volumeMounts: [{name: page, mountPath: /page}]
      containers:
        - name: httpd
          image: registry.access.redhat.com/ubi9/httpd-24:latest
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /, port: 8080}, periodSeconds: 5}
          volumeMounts: [{name: page, mountPath: /var/www/html}]
      volumes: [{name: page, emptyDir: {}}]
EOF
oc apply -n udn-$1 -f "$M/lab10-web-deployment.yaml"
oc -n udn-$1 rollout status deploy/udn-web --timeout=5m
}
FN
source "$WS_MANIFESTS/functions/webpod.sh"

lab hub; for t in blue red green purple violet; do webpod $t; done
lab sno; for t in green purple violet; do webpod $t; done
```

Two files, two kinds of heredoc, on purpose: the ConfigMap's `<<EOF` lets your
shell fill in the tenant and cluster (one file per tenant); the Deployment's
`<<'EOF'` keeps `$BANNER`, `$udn` and friends for the container to expand at
run time, so it is the same file for every tenant - `cat` it and you will see
them unexpanded.

**Check**

```bash
lab hub
BLUE_WEB=$(oc -n udn-blue get pod -l app=udn-web -o jsonpath='{.items[0].metadata.name}')
oc -n udn-blue exec $BLUE_WEB -- cat /var/www/html/index.html    # "I am blue on hub" ...
```

### Lab 11. The tenant ingress

> **Where:** the lab host. No cluster switching: the build script reads both
> clusters' web pods itself.

One address, one port, a hostname per tenant - in front of tenants whose pods
share addresses. The ingress runs on the namespace client VM, which already
has one network namespace per tenant; haproxy opens each backend connection
*inside* that tenant's namespace, so two backends can name the identical
`10.200.4.5:8080` and reach two different pods. Building it is plumbing:

```bash
cd /root/hcp-backup-restore/udn-bgp-evpn
./build-lab.sh --workshop --only nsproxy
```

It reads the web pods' live addresses, so re-run it if you recreate them.

**Check** - by hand first:

```bash
for h in blue red green purple violet green-sno purple-sno violet-sno; do
  printf '%-12s ' $h; curl -s -m5 http://$h.hub.mylab.com/ | head -1
done
# blue         I am blue on hub
# red          I am red on hub
# ...
# violet-sno   I am violet on sno
labssh 192.168.122.88 grep -E '^backend|server' /etc/haproxy/udn-tenants.cfg
# blue and red backends: the same kind of address, different "namespace"
```

`.hub.mylab.com` names resolve through the helper, which is what the
nmcli step in A5 was for; without it, add `-H "Host: blue.hub.mylab.com"` and
curl `http://192.168.122.88/`.

Then the lab's full tests - every tenant from outside, and every tenant pod to
pod across the two clusters:

```bash
KUBECONFIG=$HUB_KUBECONFIG scripts/udn-web-demo.sh --proxy
scripts/udn-xcluster-curl.sh $HUB_KUBECONFIG $SNO_KUBECONFIG
```

The second prints a matrix. Read it for: each tenant answering itself in the
other cluster (green and purple bridged, violet routed), and silence
everywhere else - including between green and purple, whose addresses
overlap.

### Lab 12. Live migration across a stretched Layer2

> **Where:** the VM runs on the hub; the SNO watches it move. Every block
> below names its cluster (`lab hub`, `lab sno`, or `KUBECONFIG=$SNO_KUBECONFIG`
> on a single command).

OpenShift Virtualization is installed (day 0). A VM on green, on the hub:

```bash
lab hub
cat > "$M/lab12-green-vm.yaml" <<'EOF'
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
            - {name: rootdisk, disk: {bus: virtio}}
            - {name: cloudinit, disk: {bus: virtio}}
          interfaces:
            - name: green-net
              binding:
                name: l2bridge       # on the UDN's switch itself - its own MAC and IP
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: green-net
          pod: {}                    # "the namespace's primary network" = green
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
oc apply -f "$M/lab12-green-vm.yaml"
oc -n udn-green wait vm/green-vm --for=condition=Ready --timeout=10m
```

A `containerDisk` is migratable: the disk is an immutable image present on
every node.

#### Before: where does the other cluster think the VM is?

Three views of one fact, from the VM outward. Save the output of each; you
will run the same three again after the migration and compare.

**1. The VM itself** - its address, its MAC, and the node it runs on:

```bash
lab hub
oc -n udn-green get vmi green-vm -o custom-columns=\
NAME:.metadata.name,IP:.status.interfaces[0].ipAddress,MAC:.status.interfaces[0].mac,NODE:.status.nodeName
MAC=$(oc -n udn-green get vmi green-vm -o jsonpath='{.status.interfaces[0].mac}')
VMIP=$(oc -n udn-green get vmi green-vm -o jsonpath='{.status.interfaces[0].ipAddress}')
```

```
NAME       IP           MAC                 NODE
green-vm   10.204.0.9   0a:58:0a:cc:00:09   worker1
```

> **The outputs in this lab are examples.** Your VM may get a different IP,
> and so a different MAC, and land on a different worker - and with it a
> different VTEP (`100.64.0.<worker's octet>`). The commands read the MAC and
> IP into `$MAC` and `$VMIP`, so they need no editing; compare your output
> with the pattern, not the numbers.

The MAC is not random: OVN-Kubernetes derives it from the IP - `0a:58`
followed by `10.204.0.9` in hex. So a VM that keeps its IP keeps its MAC.

**2. The SNO's VXLAN forwarding table** - which VTEP the SNO node sends
frames for that MAC to. This is the *other cluster's* data plane:

```bash
KUBECONFIG=$SNO_KUBECONFIG oc debug node/sno --quiet -- chroot /host \
  bridge fdb show dev evx4-evpn-vtep | grep $MAC
```

```
0a:58:0a:cc:00:09 vlan 2 extern_learn master evbr-evpn-vtep
0a:58:0a:cc:00:09 dst 100.64.0.34 src_vni 400 self extern_learn
```

`evx4-evpn-vtep` is the VXLAN device OVN-Kubernetes created for the VTEP
named `evpn-vtep` in Lab 3. `dst 100.64.0.34` is worker1's VTEP - the node the
VM is on.

**3. The BGP route that programmed it** - from the SNO's own FRR, which runs
in the `frr-k8s` pod rather than on the host:

```bash
KUBECONFIG=$SNO_KUBECONFIG oc -n $FRR_NS exec ds/frr-k8s -c frr -- \
  vtysh -c 'show bgp l2vpn evpn route type macip' | grep -A2 "$MAC"
```

```
 *>  [2]:[0]:[48]:[0a:58:0a:cc:00:09]
                    100.64.0.34                            0 64513 64512 i
                    RT:65000:400 ET:8
 *>  [2]:[0]:[48]:[0a:58:0a:cc:00:09]:[32]:[10.204.0.9]
                    100.64.0.34                            0 64513 64512 i
                    RT:65000:400 ET:8
```

A **type-2** (MAC/IP) route: "MAC `0a:58:0a:cc:00:09` is reachable at VTEP
`100.64.0.34`, in the tenant with route target `65000:400`". Its next hop is
worker1's own VTEP, the AS path `64513 64512` says it came from the hub
(64512) through leaf1 (64513), and `ET:8` marks VXLAN encapsulation. There are two because a type-2 route
can carry the MAC alone - which programs the FDB above - or the MAC and IP,
which lets the SNO answer ARP for `10.204.0.9` locally instead of flooding.

#### Migrate, while the other cluster watches

In a second window, start a ping **from the SNO** - another cluster, across
the L2VNI - and leave it running:

```bash
source /root/workshop.env; lab sno
VMIP=$(KUBECONFIG=$HUB_KUBECONFIG oc -n udn-green get vmi green-vm -o jsonpath='{.status.interfaces[0].ipAddress}')
inpod green ping -i 0.2 -w 120 $VMIP     # 5 a second, for two minutes
```

`-w 120` is a deadline: ping stops itself after two minutes and prints its
statistics. Don't plan on ctrl-c here - `inpod` runs the command with no
terminal, so ctrl-c stops your local `oc`, and ping inside the pod is killed
without printing the summary that is the whole point. If the migration needs
longer, raise the deadline and start again.

Then migrate - within the two minutes:

```bash
lab hub
cat > "$M/lab12-green-vm-migrate-1.yaml" <<'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: green-vm-migrate-1
  namespace: udn-green
spec:
  vmiName: green-vm
EOF
oc apply -f "$M/lab12-green-vm-migrate-1.yaml"
oc -n udn-green get vmim green-vm-migrate-1 -w     # ... Running, Succeeded; ctrl-c
```

#### After: the same three commands

```bash
oc -n udn-green get vmi green-vm -o custom-columns=\
NAME:.metadata.name,IP:.status.interfaces[0].ipAddress,MAC:.status.interfaces[0].mac,NODE:.status.nodeName
KUBECONFIG=$SNO_KUBECONFIG oc debug node/sno --quiet -- chroot /host \
  bridge fdb show dev evx4-evpn-vtep | grep $MAC
KUBECONFIG=$SNO_KUBECONFIG oc -n $FRR_NS exec ds/frr-k8s -c frr -- \
  vtysh -c 'show bgp l2vpn evpn route type macip' | grep -A2 "$MAC"
```

```
NAME       IP           MAC                 NODE
green-vm   10.204.0.9   0a:58:0a:cc:00:09   worker2

0a:58:0a:cc:00:09 vlan 2 extern_learn master evbr-evpn-vtep
0a:58:0a:cc:00:09 dst 100.64.0.35 src_vni 400 self extern_learn

 *>  [2]:[0]:[48]:[0a:58:0a:cc:00:09]
                    100.64.0.35                            0 64513 64512 i
                    RT:65000:400 ET:8 MM:1
 *>  [2]:[0]:[48]:[0a:58:0a:cc:00:09]:[32]:[10.204.0.9]
                    100.64.0.35                            0 64513 64512 i
                    RT:65000:400 ET:8 MM:1
```

And the ping in the other window, once its deadline is up. Two runs on this
lab:

```
--- 10.204.0.9 ping statistics ---
144 packets transmitted, 144 received, 0% packet loss, time 145983ms          <- one a second

--- 10.204.0.12 ping statistics ---
597 packets transmitted, 595 received, 0.335008% packet loss, time 119884ms   <- -i 0.2 -w 120
```

**Expect none, or a few lost - not a stream of losses.** A live migration ends
with a short switchover: the VM is paused on worker1 for the last memory copy
and resumed on worker2, and worker2's new route has to reach the SNO. At five
pings a second, that window can catch one or two; two lost here is about 0.4 s
of gap. A gap of seconds, or losses that keep going after the migration
`Succeeded`, would mean the SNO kept sending to worker1 - check the FDB
entry below. `ping -D` timestamps each reply if you want to see exactly
where the gap fell.

The *after* output and the ping are measured on this lab (see
[bgp-evpn.md](bgp-evpn.md#live-migration-on-the-layer2-tenant)); the FDB read
`dst 100.64.0.34` before, and the *before* route is what that entry implies.
Your node names and addresses may differ; the pattern will not.

#### Compare: how BGP moved the MAC

| | Before | After | What changed it |
| --- | --- | --- | --- |
| VM IP / MAC | `10.204.0.9` / `0a:58:0a:cc:00:09` | the same | `ipam.lifecycle: Persistent` (Lab 7) kept the IP; the MAC follows from the IP |
| VM node | worker1 | worker2 | the migration |
| BGP next hop | `100.64.0.34` | `100.64.0.35` | a **different originator**: worker2 now advertises the MAC with its own VTEP, and worker1 withdrew its route |
| `MM:` | absent (sequence 0) | `MM:1` | **MAC Mobility**: the sequence number goes up each time the MAC moves, so every router prefers the newer location even if the old withdraw arrives late |
| SNO FDB `dst` | `100.64.0.34` | `100.64.0.35` | zebra on the SNO reprogrammed the VXLAN device from the new route |

Read it bottom-up and it is the whole mechanism:

1. The VM lands on worker2. OVN-Kubernetes on worker2 sees the MAC locally
   and FRR on worker2 advertises a type-2 route for it, next hop its own VTEP,
   with the MAC-mobility sequence number raised to 1.
2. worker1 withdraws its route for the MAC.
3. leaf1 passes both to the spine and on to every EVPN speaker - including
   the SNO, in another AS, which is why the two clusters must not share one.
4. The SNO's FRR picks the route with the higher sequence number, and zebra
   rewrites the FDB entry from `dst 100.64.0.34` to `dst 100.64.0.35`.
5. The SNO's next frame to the VM is encapsulated to worker2. The ping lost
   at most the few frames sent during the switchover.

`extern_learn` on both lines is what proves step 4 rather than a data-plane
guess: the VXLAN device is on a bridge port with learning **off**, so the only
thing that can write this entry is zebra acting on a BGP route. Nothing
between the SNO and worker2 could have made the change either - leaf1 and the
spine only ever see the outer packet, addressed to a `/32`.

leaf2 sees the same move for its own copy of the domain:
`leaf2 'show evpn mac vni 400'` before and after shows the MAC behind the new
VTEP.

---

## Explore - Optional: look closer at what you built

Nothing to build here - a set of short explorations on the finished EVPN lab,
each answering one question the labs raised and left in passing. They read
state; only X9 changes anything, and it puts it back. Take any of them, in
any order. Each ends with where the repo goes deeper.

| | Question | Where |
| --- | --- | --- |
| X1 | What are the three EVPN route types, and who sends which? | the fabric |
| X2 | How does a frame for a MAC nobody has seen yet get anywhere? | the SNO |
| X3 | Why are the pod MACs so regular? | anywhere |
| X4 | Can you tell bridged from routed without reading any state? | both |
| X5 | What does the tunnel look like on the wire? | the lab host |
| X6 | Why does the SNO talk to a hub node without going through leaf1? | the SNO |
| X7 | Blue and red advertise the same prefix - how does BGP keep them apart? | the fabric, the hub |
| X8 | How big a packet does the overlay carry? | the SNO |
| X9 | What happens when the advertisement goes away? | the hub |
| X10 | How does a packet get from the SNO to a hub worker - bridged, and routed? | the SNO |

### X1. Three route types, one table

```bash
leaf2 'show bgp l2vpn evpn route type multicast'   # type-3
leaf2 'show bgp l2vpn evpn route type macip'       # type-2
leaf2 'show bgp l2vpn evpn route type prefix'      # type-5
```

The first bracket of each route is its type; the rest is lengths and values:

```
[3]:[0]:[32]:[100.64.0.35]                          type-3: "VTEP 100.64.0.35 is in this VNI"
[2]:[0]:[48]:[0a:58:0a:cc:00:09]                    type-2: "this MAC is behind this VTEP"
[2]:[0]:[48]:[0a:58:0a:cc:00:09]:[32]:[10.204.0.9]  type-2, with the IP as well
[5]:[0]:[24]:[10.210.10.0]                          type-5: "this prefix is behind this VTEP"
```

Look for the pattern, not the numbers:

- **Type-3 and type-2 come only from the Layer2 tenants** (green VNI 400,
  purple VNI 500) - they have a broadcast domain to join and MACs to place.
  **Type-5 comes only from the Layer3 ones** (blue, red, violet). A type-3 for
  blue does not exist and is not missing: an L3VNI has nothing to flood.
- **Count the type-3s for VNI 400:** one per VTEP in that VNI - each hub
  worker, the SNO, and leaf2 itself, which has green's external host on it.
- Type-2 grows with every pod and VM; type-3 changes only when a VTEP joins
  or leaves.

leaf2's summary of the same thing:

```bash
leaf2 'show evpn vni 400'        # "Remote VTEPs" - built from type-3
leaf2 'show evpn mac vni 400'    # every MAC and the VTEP it is behind - from type-2
```

Deeper: [bgp-evpn.md, 4g](bgp-evpn.md#4g-the-route-types-side-by-side).

### X2. The flood list

An endpoint nobody has seen yet is reached by flooding - ARP is a broadcast.
There is no multicast in this underlay, so a VTEP floods by sending one
unicast copy to every other VTEP in the VNI. That list comes from nothing
but type-3 routes, and it is in the kernel next to the MACs:

```bash
lab sno
oc debug node/sno --quiet -- chroot /host bridge fdb show dev evx4-evpn-vtep | grep -v '^00:00:00:00:00:00'
# real MACs, each "dst <a VTEP>"                  <- type-2
oc debug node/sno --quiet -- chroot /host bridge fdb show dev evx4-evpn-vtep | grep '^00:00:00:00:00:00'
# the all-zeros MAC, once per remote VTEP per VNI <- type-3: "flood BUM here"
```

That ordering is the point: **type-3 first**. Without the flood list the
first ARP goes nowhere, so the reply that would produce a type-2 never
happens, and the tenant has no connectivity at all - with every session up.

Deeper: [bgp-evpn.md, "Type-3 comes first"](bgp-evpn.md#type-3-comes-first-and-that-ordering-is-the-point).

### X3. The MAC is the IP

```bash
printf '0a:58:%02x:%02x:%02x:%02x\n' 10 204 0 9      # 0a:58:0a:cc:00:09
```

OVN-Kubernetes derives a pod's MAC from its address: `0a:58` and then the
four octets in hex. Pick any `10.204.x.y` from `podip green` and find its MAC
in `leaf2 'show evpn mac vni 400'` without looking anything up. It is also
why Lab 12's VM kept its MAC: it kept its IP.

The flip side: green and purple overlap, so a green pod and a purple pod can
hold the same IP - and therefore the same MAC. Compare
`leaf2 'show evpn mac vni 400'` with `... vni 500`. X10 shows what keeps
them apart.

### X4. The TTL tells you the path

```bash
lab sno
inpod green  ping -c1 $(KUBECONFIG=$HUB_KUBECONFIG podip green)    # ttl=64
inpod violet ping -c1 $(KUBECONFIG=$HUB_KUBECONFIG podip violet)   # ttl=61
lab hub
inpod blue   ping -c1 10.210.10.10                                  # ttl=62
```

| | TTL | Why |
| --- | --- | --- |
| green, SNO to hub | 64 | Bridged. The inner frame crosses in VXLAN untouched; nothing routes it |
| blue, pod to `blue-ext` | 62 | Routed twice: into the L3VNI at the node, out of it at leaf2 (symmetric IRB) |
| violet, SNO to hub | 61 | Routed: each cluster's copy of the violet VRF routes it, over a node-to-node tunnel on the L3VNI (Lab 9) |

A Layer3 ping that comes back with TTL 64 did not take the path you think.

Deeper: [bgp-evpn.md, one packet routed](bgp-evpn.md#following-one-packet-in-phase-4-routed)
and [cluster to cluster](bgp-evpn.md#following-one-packet-cluster-to-cluster).

### X5. The tunnel on the wire

**Node to node, green.** Every node's fabric NIC is on the lab host's
`virbr1`, so the host sees every VXLAN packet between them. In one window, on
the lab host (`dnf -y install tcpdump` if it is missing):

```bash
tcpdump -ni virbr1 -c 6 'udp port 4789'
```

In another, from the SNO:

```bash
lab sno; inpod green ping -c3 $(KUBECONFIG=$HUB_KUBECONFIG podip green)
```

```
IP 100.64.0.20.xxxxx > 100.64.0.3x.4789: VXLAN, flags [I] (0x08), vni 400
IP 10.204.128.x > 10.204.0.y: ICMP echo request ...
```

tcpdump decodes the VXLAN header and prints the inner packet under it. The
outer addresses are the SNO's VTEP and a hub worker's, directly - no leaf is
a tunnel endpoint. The VNI is green's, and the inner packet is the pod's own,
addresses untouched.

**Out to the internet, violet.** Inside leaf2, where the tunnel ends and the
packet leaves as plain IP. The FRR image has no tcpdump, so it runs from the
containerlab VM in leaf2's network namespace; the filter keeps VNI 601 with
ICMP inside:

```bash
_clab bash -c "nsenter -t \$(docker inspect -f '{{.State.Pid}}' clab-$CLAB_LAB-leaf2) -n \
  tcpdump -lni any -c 8 '(udp port 4789 and (udp[12:4] >> 8) = 601 and udp[39] = 1) or icmp'"
```

and in another window `lab sno; inpod violet ping -c2 1.1.1.1`:

```
eth10  In  100.64.0.20 > 10.0.0.2 VXLAN vni 601   10.206.128.4 > 1.1.1.1 echo request
eth0   Out                                         10.206.128.4 > 1.1.1.1 echo request
eth0   In                                          1.1.1.1 > 10.206.128.4 echo reply
eth10  Out 10.0.0.2 > 100.64.0.20 VXLAN vni 601   1.1.1.1 > 10.206.128.4 echo reply
```

Encapsulated in, plain out, and the reverse. The source is still the pod's
own address on `eth0`: the NAT is one hop further, on the containerlab host.

Deeper: [README, "Reaching the internet from a UDN"](README.md#reaching-the-internet-from-a-udn).

### X6. The shortcut leaf1 teaches

The SNO learned one route for every VTEP, the aggregate, via leaf1. Ask the
kernel where a hub worker's VTEP actually goes:

```bash
lab sno
oc debug node/sno --quiet -- chroot /host ip route show 100.64.0.0/24   # via 192.168.140.1 (leaf1), proto bgp
oc debug node/sno --quiet -- chroot /host ip route get 100.64.0.34
# 100.64.0.34 via 192.168.140.34 dev ... src 192.168.140.20
#     cache                                <- not via leaf1
```

Both VTEPs are on one segment. The first packet went to leaf1, leaf1 saw it
had to send it straight back out the interface it arrived on, and answered
with an **ICMP redirect**; the SNO cached it, and from then on sends
node-to-node. `cache` is the tell: an exception in front of the BGP route,
which is unchanged. A real fabric, with nodes behind different leaves, routes
the whole way and never redirects.

Deeper: [bgp-evpn.md, "Confirming each hop yourself"](bgp-evpn.md#confirming-each-hop-yourself).

### X7. Route distinguisher and route target

Blue and red both originate `10.200.x.0/24`. In one BGP table, two routes
for one prefix would have to compete; these do not, because each carries a
**route distinguisher** that makes it unique, and a **route target** that
decides which VRF may import it:

```bash
leaf2 'show bgp l2vpn evpn route type prefix'
```

Pick one of the `10.200.x.0/24`s and find both copies. Each sits under its
own `Route Distinguisher:` line (`<router-id>:<n>`), and each carries a
different `RT:` - `65000:101` for blue, `65000:201` for red. Read the RD from
the heading the route is under, not from the line next to it: the output is
grouped, and a `grep -A` pairs routes with the wrong heading.

```bash
onleaf2 ip route show vrf blue | grep 10.200    # the /24s, in blue's table
onleaf2 ip route show vrf red  | grep 10.200    # the same /24s, in red's
```

**The RD answers "which route is this", the RT answers "who gets it".** Two
routes can share a prefix and an RT (one tenant on two nodes); they cannot
share an RD. Isolation comes from the RT alone - which is why violet and blue,
on different RTs, never see each other's routes anywhere.

What you wrote versus what OVN-Kubernetes wrote from it - the VRF, VNI and
RTs in the node's FRR, from your `ClusterUserDefinedNetwork`:

```bash
lab hub
oc -n $FRR_NS get frrconfiguration                       # yours two, and ovnk-generated-*
oc get frrnodestate worker1 -o jsonpath='{.status.runningConfig}' | grep -E '^vrf|^ vni|route-target|^router bgp'
```

### X8. How big a packet the overlay carries

The fabric runs at MTU 9000; the pods do not:

```bash
lab sno
inpod green ip link show ovn-udn1 | grep -o 'mtu [0-9]*'          # mtu 1400 on this lab
HUB_GREEN=$(KUBECONFIG=$HUB_KUBECONFIG podip green)
inpod green ping -c2 -M do -s 1372 $HUB_GREEN    # 1372 + 28 = 1400: arrives
inpod green ping -c2 -M do -s 1373 $HUB_GREEN    # ping: local error: message too long, mtu=1400
```

VXLAN adds 50 bytes to every frame, so the pod MTU has to leave room for
them wherever the path is smallest. A failure *below* 1372 would mean the path
is smaller than OVN-Kubernetes assumed - and it would not show up in any web
test, because TCP clamps its segment size and only UDP and DF traffic would
notice. That exact trap, on the client side of this lab, went unseen for
months.

Deeper: [troubleshooting.md, "client segments ran at MTU 9000"](troubleshooting.md#closed--client-segments-ran-at-mtu-9000-against-a-path-carrying-1400).

### X9. Take the advertisement away

Everything a tenant reaches, it reaches because a route for it exists. Remove
the one object that advertises the hub's tenants and watch the fabric catch
up. It is not instant - OVN-Kubernetes has to notice, rewrite its generated
FRR configuration, and FRR has to withdraw - so watch rather than look once:

```bash
lab hub
leaf2 'show bgp l2vpn evpn route type prefix' | grep -c 10.200    # before: blue's and red's /24s
ext blue ping -c2 -W2 $(podip blue)                               # before: replies
oc delete routeadvertisements udn-evpn
for i in $(seq 24); do                    # up to two minutes
  n=$(leaf2 'show bgp l2vpn evpn route type prefix' | grep -c 10.200)
  echo "$(date +%T)  10.200 routes on leaf2: $n"; [ "$n" -eq 0 ] && break; sleep 5
done
ext blue ping -c2 -W2 $(podip blue)       # now silent
leaf1 'show bgp l2vpn evpn summary'       # the hub workers?
```

Measured on this lab - 12 routes before, and a minute after the delete:

```
worker1(192.168.140.34) 4  64512 ... 00:00:48   NoNeg   NoNeg worker1 [hub]
worker2(192.168.140.35) 4  64512 ... 00:00:48   NoNeg   NoNeg worker2 [hub]
worker3(192.168.140.36) 4  64512 ... 00:00:48   NoNeg   NoNeg worker3 [hub]
```

Nothing you wrote changed: the CUDNs, the pods, the VTEP and Lab 4's peering
are all still there. What went is everything OVN-Kubernetes generated from
the `RouteAdvertisements` - the tenant VRFs' routes, and, as Lab 4 showed,
the `l2vpn evpn` activation itself. So the hub workers are back to `NoNeg`,
and `Up/Down` restarted: a BGP session cannot drop an address family in
place, so FRR reset it to renegotiate without one. The SNO's row keeps its
numbers - its own `RouteAdvertisements` is untouched.

Put it back from the file Lab 6 left, and watch it return:

```bash
oc apply -f "$WS_MANIFESTS/hub/lab06-routeadvertisements-udn-evpn.yaml"
for i in $(seq 24); do
  n=$(leaf2 'show bgp l2vpn evpn route type prefix' | grep -c 10.200)
  echo "$(date +%T)  10.200 routes on leaf2: $n"; [ "$n" -gt 0 ] && break; sleep 5
done
leaf1 'show bgp l2vpn evpn summary'     # numbers again - after another session reset
ext blue ping -c2 $(podip blue)         # replies
```

If anything is still off a minute later, `./build-lab.sh --workshop --only
check-hub` repairs the three platform faults it knows about.

### X10. One packet, SNO to hub: green, then violet

Both tenants cross the same underlay between the same two nodes, and take
opposite decisions in the overlay: green is **bridged** on a MAC, violet is
**routed** on a prefix. Follow one ping from the SNO to worker1 for each,
step by step, on the SNO's side where every decision is made.

Aim at the pods on worker1, so the VTEP to expect is known (`100.64.0.34`):

```bash
lab sno
GREEN_DST=$(KUBECONFIG=$HUB_KUBECONFIG podip green worker1)
VIOLET_DST=$(KUBECONFIG=$HUB_KUBECONFIG podip violet worker1)
echo "green -> $GREEN_DST   violet -> $VIOLET_DST"
inpod green ping -c2 $GREEN_DST; inpod violet ping -c2 $VIOLET_DST   # ttl 64, ttl 61
```

#### green, Layer2 - one broadcast domain, VNI 400

```bash
# 1. In the pod: the destination is ON-LINK - same /16, no gateway
inpod green ip route get $GREEN_DST
#    10.204.0.y dev ovn-udn1 src 10.204.128.x          <- no "via"

# 2. So the pod ARPs for it, and gets the MAC - which is the IP in hex (X3)
inpod green ip neigh show $GREEN_DST
GREEN_MAC=$(printf '0a:58:%02x:%02x:%02x:%02x' ${GREEN_DST//./ })

# 3. The node bridges on that MAC: which VTEP is it behind? A type-2 route put it there
oc debug node/sno --quiet -- chroot /host bridge fdb show dev evx4-evpn-vtep | grep $GREEN_MAC

# 4. Encapsulate: outer 100.64.0.20 -> 100.64.0.34, VNI 400. How the OUTER packet leaves:
oc debug node/sno --quiet -- chroot /host ip route get 100.64.0.34
#    via 192.168.140.34 ... cache    <- leaf1's redirect (X6), or via 192.168.140.1 before it
```

Expect **two** answers for one MAC - measured on this lab:

```
0a:58:0a:cc:00:07 vlan 6 extern_learn master evbr-evpn-vtep
0a:58:0a:cc:00:07 vlan 5 extern_learn master evbr-evpn-vtep
0a:58:0a:cc:00:07 dst 100.64.0.34 src_vni 400 self extern_learn    <- green's pod, on worker1
0a:58:0a:cc:00:07 dst 100.64.0.36 src_vni 500 self extern_learn    <- purple's pod, on worker3
```

Green and purple share `10.204.0.0/16` on purpose, so each has a pod at
`10.204.0.7` - and since the MAC is the IP (X3), each has MAC
`0a:58:0a:cc:00:07` too. One MAC, two tenants, two different VTEPs, and no
conflict: the table is keyed by **MAC and VNI**, not MAC alone. The
`src_vni 400` line is the one green's frame uses. The first two lines are the
same split on the bridge side, where each VNI is a local VLAN (the numbers
are the node's own and mean nothing outside it); the mapping between them:

```bash
oc debug node/sno --quiet -- chroot /host bridge vlan tunnelshow dev evx4-evpn-vtep
```

That is tenancy at Layer2: overlapping addresses are fine as long as every
lookup includes the VNI. It is also why a type-2 route carries the route
target and the VNI with the MAC, never the MAC alone.

worker1 finds `100.64.0.34` on its own VTEP interface, so it is *delivered*,
not forwarded: decapsulated into green's switch, and handed to the pod by
MAC. Nothing routed it at any point - TTL 64.

#### violet, Layer3 - one routed network, VNI 601

```bash
# 1. In the pod: the destination is OFF-LINK - a different node's /24, so via the gateway
inpod violet ip route get $VIOLET_DST
#    10.206.3.y via <violet's gateway> dev ovn-udn1 ...

# 2. OVN routes it and hands it to the SNO's violet VRF. That table's
#    route for the hub node's /24 names a VTEP - no MAC anywhere:
oc debug node/sno --quiet -- chroot /host ip route show vrf violet | grep '^10.206.3'
#    10.206.3.0/24 via 100.64.0.34 dev svl3-violet proto bgp onlink

# 3. Where that route came from: a type-5, RT 65000:601, next hop worker1's VTEP
nodevtysh sno 'show bgp l2vpn evpn route type prefix' | grep -A2 '10.206.3.0'

# 4. Encapsulate: outer 100.64.0.20 -> 100.64.0.34, VNI 601 - the same underlay
#    decision as green's step 4
oc debug node/sno --quiet -- chroot /host ip route get 100.64.0.34
```

worker1 decapsulates VNI 601 into its own violet VRF, which routes it to its
node subnet, and OVN delivers it to the pod. Three routing hops across the
two nodes in all - TTL 61.

(`10.206.3` is worker1's slice on this lab; use the first three octets of
your `$VIOLET_DST`.)

#### Side by side

| | green (Layer2, macVRF) | violet (Layer3, ipVRF) |
| --- | --- | --- |
| Pod's first decision | on-link: ARP for the destination | off-link: send to the gateway |
| What the SNO looks up | the destination **MAC** | the destination **prefix** |
| Where that lives | the FDB of `evx4-evpn-vtep` | the violet VRF's routing table |
| Put there by | a **type-2** route | a **type-5** route |
| VNI | 400, an L2VNI | 601, an L3VNI |
| Routed on the way? | never - TTL 64 | on both nodes, three hops - TTL 61 |
| Outer packet, tunnel ends | `100.64.0.20 -> 100.64.0.34` | `100.64.0.20 -> 100.64.0.34` - identical |
| leaf1 / leaf2 | leaf1 carries the outer packet (or redirects it, X6); leaf2 is not involved | same |

The last two rows are the point: **the underlay cannot tell them apart.** Both
are node-to-node VXLAN between the same two VTEPs. Only the VNI and what the
node did before encapsulating differ - which is exactly what EVPN's route
types exist to program.

To see both on the wire, run X5's `tcpdump -ni virbr1 -c 8 'udp port 4789'`
on the lab host while the two pings run: the same outer addresses, `vni 400`
and `vni 601`.

Deeper: [bgp-evpn.md, cluster to cluster](bgp-evpn.md#following-one-packet-cluster-to-cluster)
for green, and [README, a routed Layer3 UDN across two clusters](README.md#what-a-routed-layer3-udn-across-two-clusters-does)
for violet.

---

## Part C - Optional: the same tenants over VRF-Lite

The design many fabrics already run: no VXLAN, no VTEPs - a VLAN and a BGP
session **per tenant** between each node and the leaf, each in its own VRF.
It uses the fabric's other shape, with the tenant VRFs on leaf1. About an
hour, the web pages and the ingress included.

Part C is a **hub** exercise. The SNO's only part in it is C1: its EVPN
tenants are removed, so nothing of theirs is left on the fabric, and it then
sits idle - VRF-Lite has no stretched Layer2 for it to join.

| Step | Where |
| --- | --- |
| C1. Clear the EVPN tenants | the hub, then the SNO |
| C2. Rebuild the fabric | the lab host - no cluster, no `lab` |
| C3-C6. Tenants, VRFs, VLANs, sessions | the hub only |
| Check | the hub only |
| C7. A web page per tenant | the hub only |
| C8. The tenant ingress | the lab host |

**C1. Clear the EVPN tenants** (the clusters' BGP enablement, the fabric NIC
and the underlay session stay).

> **Where:** the hub, then the SNO.

On the hub - all five tenants, and the Lab 12 VM:

```bash
lab hub
oc delete routeadvertisements udn-evpn
oc delete frrconfiguration -n $FRR_NS fabric-peering-evpn
oc delete vm -n udn-green green-vm --ignore-not-found
for t in blue red green purple violet; do oc delete namespace udn-$t --wait=true; done
oc delete clusteruserdefinednetwork blue red green purple violet
```

**Now the SNO** - it has three of them, and its routes would otherwise stay
on the fabric:

```bash
lab sno
oc delete routeadvertisements udn-evpn
oc delete frrconfiguration -n $FRR_NS fabric-peering-evpn
for t in green purple violet; do oc delete namespace udn-$t --wait=true; done
oc delete clusteruserdefinednetwork green purple violet
```

That is the last thing Part C does on the SNO. `transport` is immutable, so
a CUDN cannot be switched from EVPN - it is deleted and created again.

**C2. Rebuild the fabric in the VRF-Lite shape.**

> **Where:** the lab host. This rebuilds the containerlab fabric and leaves
> both clusters alone, so it does not matter which one `lab` points at.

```bash
cd /root/hcp-backup-restore/udn-bgp-evpn
./build-lab.sh --workshop --vrflite --from fabric --switch-topology
```

`--switch-topology` says the change of shape is deliberate: without it the
fabric role refuses, because a forgotten `--vrflite` on an EVPN fabric looks
exactly like this. `--from fabric` also re-runs `nsclient` and `prep`, both
of which are no-ops apart from the client namespaces, which follow the new
shape.

leaf1 now holds a VRF per tenant, with gateway `<vrf_prefix>.1` on VLAN
`<vlan>` of the fabric NIC:

| Tenant | VLAN | Peer (leaf1) | Node address |
| --- | --- | --- | --- |
| blue | 110 | 192.168.141.1 | 192.168.141.<node octet> |
| red | 120 | 192.168.142.1 | 192.168.142.<node octet> |
| green | 140 | 192.168.144.1 | 192.168.144.<node octet> |
| purple | 150 | 192.168.145.1 | 192.168.145.<node octet> |

**C3. The tenants, without transport.** Same subnets, no `transport`/`evpn`,
and no reservation - no second cluster shares these here. `workload` is
Lab 5's function; `type workload` should say it is defined.

> **Where:** the hub only - and from here to the end of Part C.

```bash
lab hub
```

```bash
for t in blue:Layer3 red:Layer3 green:Layer2 purple:Layer2; do
  n=${t%:*}
  if [ "${t#*:}" = Layer3 ]; then
    net="topology: Layer3
    layer3:
      role: Primary
      subnets:
        - cidr: 10.200.0.0/16
          hostSubnet: 24"
  else
    net="topology: Layer2
    layer2:
      role: Primary
      subnets:
        - 10.204.0.0/16
      ipam:
        lifecycle: Persistent"
  fi
cat > "$M/partc-cudn-$n.yaml" <<EOF
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: $n
  labels:
    bgp: enabled
spec:
  namespaceSelector:
    matchLabels:
      udn-tenant: $n
  network:
    $net
EOF
oc apply -f "$M/partc-cudn-$n.yaml"
  workload $n
done
```

**C4. Find the VRFs OVN-Kubernetes made.** Each node has one per tenant,
named after the CUDN, with its own routing table and some ports already in
it.

> **Where:** the hub, on one of its workers.

```bash
W=worker1
oc debug node/$W --quiet -- chroot /host ip -d link show type vrf | grep -A1 -E '^[0-9]+: (blue|red)'
# ... vrf table 1012 ...
oc debug node/$W --quiet -- chroot /host ip -br link show master blue
```

**C5. Put a VLAN into each VRF, on each worker.** One NNCP per node per
tenant. The VRF must be restated with **every port it already has**: an NNCP
declares the whole VRF, and a port it leaves out is removed from it. The
fabric NIC is found by MAC, which the lab derives from the node's address.

> **Where:** the hub. The loop covers every hub worker; you run it once.

```bash
for t in blue:110:192.168.141 red:120:192.168.142 green:140:192.168.144 purple:150:192.168.145; do
  IFS=: read -r n vlan pfx <<<"$t"
  oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' |
  while read -r node ip; do
    o=${ip##*.}
    table=$(oc debug node/$node --quiet -- chroot /host ip -d link show dev $n | grep -o 'table [0-9]*' | cut -d' ' -f2)
    ports=$(oc debug node/$node --quiet -- chroot /host ip -o link show master $n | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v "\.$vlan$" | sed 's/^/            - /')
cat > "$M/partc-nncp-vrflite-$n-$node.yaml" <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: vrflite-$n-$node
spec:
  nodeSelector:
    kubernetes.io/hostname: $node
  capture:
    fabric-nic: interfaces.mac-address=="52:54:00:E2:55:$o"
  desiredState:
    interfaces:
      - name: "{{ capture.fabric-nic.interfaces.0.name }}.$vlan"
        type: vlan
        state: up
        mtu: 9000
        vlan:
          base-iface: "{{ capture.fabric-nic.interfaces.0.name }}"
          id: $vlan
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: $pfx.$o
              prefix-length: 24
        ipv6:
          enabled: false
      - name: $n
        type: vrf
        state: up
        vrf:
          route-table-id: $table
          port:
$ports
            - "{{ capture.fabric-nic.interfaces.0.name }}.$vlan"
EOF
oc apply -f "$M/partc-nncp-vrflite-$n-$node.yaml"
  done
done
oc wait nncp --all --for=condition=Available --timeout=5m
```

**C6. A BGP session per tenant, inside its VRF, and the advertisement.**

> **Where:** the hub.

```bash
cat > "$M/partc-vrflite-frr-and-ra.yaml" <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: fabric-peering-vrflite
  namespace: $FRR_NS
  labels:
    routeAdvertisements: fabric-vrflite
spec:
  nodeSelector: {}
  bgp:
    routers:
$(for t in blue:192.168.141 red:192.168.142 green:192.168.144 purple:192.168.145; do cat <<R
      - asn: $ASN
        vrf: ${t%%:*}
        neighbors:
          - address: ${t#*:}.1
            asn: $LEAF1_ASN
$BGP_AUTH_YAML
            port: 179
            holdTime: 9s
            keepaliveTime: 3s
            toReceive: {allowed: {mode: all}}
            toAdvertise: {allowed: {mode: filtered}}
R
done)
---
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: udn-vrflite
spec:
  targetVRF: auto
  advertisements: [PodNetwork]
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels: {bgp: enabled}
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      routeAdvertisements: fabric-vrflite
EOF
oc apply -f "$M/partc-vrflite-frr-and-ra.yaml"
```

**Check**

> **Where:** the hub (`podip` reads the hub's pods); `leaf1`, `onleaf1` and
> `ext` go to the fabric whichever cluster `lab` points at.

```bash
leaf1 'show bgp vrf all summary'      # one session per tenant per HUB worker, Established - no SNO rows
onleaf1 ip route show vrf blue | grep 10.200
ext blue ping -c3 $(podip blue)       # blue-ext, now behind leaf1
ext red  ping -c3 $(podip red)
cd /root/hcp-backup-restore/udn-bgp-evpn
./build-lab.sh --workshop --vrflite --only check-hub
```

> Tenant sessions sitting in `Active` with the VLANs up: frr-k8s started its
> VRF instances before the VRFs had their VLAN, and bgpd does not rebind.
> `oc -n $FRR_NS rollout restart ds/frr-k8s` - the check above does the same
> when it finds it.

**C7. A web page per tenant.** Lab 10's `webpod`, unchanged - the page, the
Deployment and the way it finds its own UDN address know nothing about how
the tenant reaches the fabric. C1 deleted the Lab 10 pods with their
namespaces, so these are new ones.

> **Where:** the hub only.

```bash
lab hub
type webpod >/dev/null || echo "webpod missing: paste Lab 10's block first"
for t in blue red green purple; do webpod $t; done
```

**Check** - each tenant's external host fetches its own tenant's page, now
through leaf1's VRFs rather than leaf2's. The address to fetch is the pod's
UDN address, which the page itself reports (`oc get pod -o wide` shows the
default-network one, which `blue-ext` has no route to). The `-ext` hosts
are plain Alpine, so it is busybox `wget`, not `curl`:

```bash
for t in blue red green purple; do
  pod=$(oc -n udn-$t get pod -l app=udn-web -o jsonpath='{.items[0].metadata.name}')
  ip=$(oc -n udn-$t exec $pod -c httpd -- cat /var/www/html/index.html | awk '/^udn:/ {split($2,a,"/"); print a[1]}')
  printf '%-7s %-13s ' $t $ip; ext $t wget -qO- -T5 http://$ip:8080/ | head -1
done
# blue    10.200.x.y    I am blue on hub
# red     10.200.x.y    I am red on hub      <- quite possibly the same address as blue's
# green   10.204.x.y    I am green on hub
# purple  10.204.x.y    I am purple on hub
```

**C8. The tenant ingress.** Lab 11's, rebuilt for this shape. The ingress
runs on the namespace client, whose per-tenant namespaces C2 re-plumbed onto
leaf1's VRF-Lite VLANs; haproxy does not care which - it dials each backend
from inside its tenant's namespace, exactly as before.

> **Where:** the lab host. No cluster switching.

```bash
cd /root/hcp-backup-restore/udn-bgp-evpn
./build-lab.sh --workshop --vrflite --only nsproxy -e '{"udn_proxy_clusters": ["hub"]}'
```

- **`--vrflite`** makes the ingress read the VRF-Lite tenant lists. On its
  own, the default is to front the hub *and* the SNO.
- **`udn_proxy_clusters: [hub]`** - hub only, because Part C left the SNO
  without tenants. The full automated VRF-Lite build puts violet on the SNO
  (a cluster-local tenant: with no VNI or route target, green and purple
  cannot be shared the way Lab 8 shared them), and without this override the
  ingress stops on `no udn-web pod in udn-violet on sno`.

Re-run it whenever you recreate the web pods; it records their addresses.

**Check**

```bash
for h in blue red green purple; do
  printf '%-8s ' $h; curl -s -m5 http://$h.hub.mylab.com/ | head -1
done
# blue     I am blue on hub
# red      I am red on hub
# green    I am green on hub
# purple   I am purple on hub
labssh 192.168.122.88 grep -E '^backend|server' /etc/haproxy/udn-tenants.cfg
KUBECONFIG=$HUB_KUBECONFIG scripts/udn-web-demo.sh --proxy
```

Four hostnames, one address, and two pairs of backends with overlapping
addresses - the same result as Lab 11, over a fabric with no VXLAN at all.
The cross-cluster matrix (`udn-xcluster-curl.sh`) needs a tenant on the SNO,
which Part C does not build. The automated VRF-Lite build does - violet on
the SNO, with deliberate leaks on leaf1 to blue, green and orange - and its
measured matrix is in
[udn-bgp-evpn-steps.md 6.4](udn-bgp-evpn-steps.md#64-test-the-leak-matrix-from-inside-a-pod-across-clusters).

**What changed, compared with EVPN:** four VLANs, four addresses and four
BGP sessions per node where EVPN needed one session and one VTEP; and no
stretched Layer2 - green is reachable, but it is not one domain with the SNO.
That is the argument for EVPN, now measured on your own lab.

**To go back to EVPN:**

1. **The hub** - clear the VRF-Lite objects, the way C1 cleared the EVPN
   ones:

   ```bash
   lab hub
   oc delete routeadvertisements udn-vrflite
   oc delete frrconfiguration -n $FRR_NS fabric-peering-vrflite
   oc get nncp -o name | grep /vrflite- | xargs -r oc delete
   for t in blue red green purple; do oc delete namespace udn-$t --wait=true; done
   oc delete clusteruserdefinednetwork blue red green purple
   ```

2. **The lab host** - rebuild the fabric in the EVPN shape:

   ```bash
   cd /root/hcp-backup-restore/udn-bgp-evpn
   ./build-lab.sh --workshop --from fabric --switch-topology
   ```

3. **Both clusters** - Lab 4 on each (C1 deleted its `FRRConfiguration` on
   both), then Labs 5-9, each on the cluster it names.

---

## The minimal test set

If time is short, these prove the whole of Part B:

| # | Command | Proves |
| --- | --- | --- |
| 1 | `leaf1 'show bgp l2vpn evpn summary'` | every node of both clusters peers EVPN |
| 2 | `oc get vtep evpn-vtep` + the node annotations | every node has a VTEP OVN-Kubernetes accepted |
| 3 | `leaf2 'show bgp l2vpn evpn route type prefix'` | blue and red advertise the same prefixes under different route targets |
| 4 | `inpod blue ping -c2 -W2 10.211.10.10` | silent - tenancy by route target |
| 5 | `inpod green ping -c3 $(KUBECONFIG=$HUB_KUBECONFIG podip green)` from the SNO | TTL 64: one Layer2 domain across clusters |
| 6 | `inpod violet ping -c3 $(KUBECONFIG=$HUB_KUBECONFIG podip violet)` from the SNO | TTL 61: one routed tenant across clusters |
| 7 | `inpod violet curl -sI http://1.1.1.1/` | internet egress through the fabric |
| 8 | `curl http://blue.hub.mylab.com/` and `red` | overlapping tenants told apart from outside |
| 9 | the Lab 12 ping during a migration | a VM moved and the fabric followed |

And one command that checks the control plane of a whole cluster:
`./build-lab.sh --workshop --only check-hub` (or `check-sno`).

---

## Catching up, checking, and when something is wrong

**Fallen behind?** The automation can do any lab's work for you, on both
clusters, and you carry on from there:

```bash
./build-lab.sh --workshop --only tenants   # Labs 1-9, on the hub and the SNO
./build-lab.sh --workshop --only web       # Lab 10
```

`tenants` is the reference build of everything in Labs 1-9. It **replaces**
your tenants rather than adding to them - it deletes every tenant namespace
and CUDN first and creates them again - so use it to catch up, not to check.
Its manifests are written to `udn-bgp/hub/` and `udn-bgp/sno/`: compare them
with yours.

**Checking** - `--only check-hub` / `check-sno` runs the phase's own
verification against what you built, for the tenants that exist. It changes
nothing of yours. It *does* repair three platform faults you were not here to
learn about, and says so when it does: forwarding switched off on a fabric
NIC, a BGP session stuck on a stale nexthop (frr-k8s restarted on that node),
and a missing SNAT exclusion.

**Symptoms**

| You see | Look at |
| --- | --- |
| `no matches for kind "FRRConfiguration"` | Lab 1 has not finished rolling out |
| A node `Active` on leaf1 while others are up | Lab 2's note: restart that node's frr-k8s pod |
| **Every** node `Connect` on leaf1, `MsgRcvd 0`, though `onleaf1 ping` reaches them and the node's `show bgp nexthop` is `valid` | TCP-MD5 on one end only: `leaf1 'show bgp neighbor <ip>' \| grep -i auth`. Lab 2's first step - the Secret, and `$BGP_AUTH_YAML` in the manifest |
| `NoNeg` in `leaf1 'show bgp l2vpn evpn summary'` | before Lab 6 (the hub) or Lab 8 (the SNO): expected - OVN-Kubernetes turns EVPN on when the `RouteAdvertisements` exists. After it: the RA's `frrConfigurationSelector` does not match Lab 4's label, or it selected no network - `oc get ra udn-evpn -o yaml` |
| `VTEP` never `Accepted` | a node without a `100.64.0.x` address or annotation - Lab 3's note |
| DaemonSet `desired=3 scheduled=0` | the privileged SCC binding in `workload` |
| CUDN applied, `reservedSubnets` missing from the live object | the field name - `oc explain`, Lab 7 |
| Ping from a pod: `Destination Host Unreachable` from `10.x.y.2` | nothing advertises that destination into this tenant's VRF: `oc debug node/<node> -- chroot /host ip route get <dst> vrf <tenant>` |
| `ext <tenant> ping <pod>` silent, routes present everywhere | forwarding on the fabric NIC: run the check |
| Ping works, `curl` hangs after connecting | the SNAT exclusion: run the check |
| Two clusters, EVPN routes on leaf1 but none on the far cluster | the two clusters share an ASN |

The long form of every one of these, with how it was found:
[README.md](README.md#troubleshooting) and [troubleshooting.md](troubleshooting.md).

---

## Tearing it down

From your laptop:

```bash
cd hcp-backup-restore/terraform
./lab-up.sh destroy
```

The instance, its volume and everything on it go, and billing stops. On a
host you keep, `ansible-playbook -i ../inventory/hosts ../cleanup.yaml
--vault-password-file ~/.vault_pass` removes the lab's VMs instead.
