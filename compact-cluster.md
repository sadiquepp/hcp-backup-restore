# Three-node compact cluster with bonded NICs (agent-based installer)

This guide builds a **three-node compact OpenShift cluster** on the lab
hypervisor from a single **agent ISO**. Every node has **two NICs bonded in
active-backup mode (mode 1)**, and the node's address lives on the bond.

The whole flow is automated by `setup_compact_cluster.yaml` and the
`roles/setup-compact-cluster` role. This document walks through the same steps
by hand, so you can see what each one does, run them one at a time, or debug a
step that failed. Each section names the role task file that automates it.

- [What you get](#what-you-get)
- [The automated path](#the-automated-path)
- [Manual deployment](#manual-deployment)
  1. [Prerequisites](#step-1---prerequisites)
  2. [Set the shell variables](#step-2---set-the-shell-variables)
  3. [Check the addresses are free](#step-3---check-the-addresses-are-free)
  4. [DNS](#step-4---dns)
  5. [Get the installer and client](#step-5---get-the-installer-and-client)
  6. [Write install-config.yaml](#step-6---write-install-configyaml)
  7. [Write agent-config.yaml with the bonds](#step-7---write-agent-configyaml-with-the-bonds)
  8. [Build the agent ISO](#step-8---build-the-agent-iso)
  9. [Create the three VMs, each with two NICs](#step-9---create-the-three-vms-each-with-two-nics)
  10. [Watch the install](#step-10---watch-the-install)
  11. [Verify the cluster and the bonds](#step-11---verify-the-cluster-and-the-bonds)
  12. [Test bond failover](#step-12---test-bond-failover)
  13. [Clean up](#step-13---clean-up)
- [Troubleshooting](#troubleshooting)

---

## What you get

```
                       libvirt 'default' network (virbr0, 192.168.122.0/24)
   ───────┬──────────────┬─────────────────┬──────────────┬───────────────┬─────────
          │              │                 │              │               │
     ┌────┴────┐   enp1s0│  enp2s0   enp1s0│  enp2s0 enp1s0│  enp2s0      .1 gateway + dnsmasq
     │ helper  │   ┌─────┴──┴──┐     ┌─────┴──┴──┐   ┌────┴──┴───┐        (resolver for the nodes)
     │  .21    │   │   bond0   │     │   bond0   │   │   bond0   │
     │ named   │   │  mode 1   │     │  mode 1   │   │  mode 1   │
     └─────────┘   │ master1   │     │ master2   │   │ master3   │
                   │   .64     │     │   .65     │   │   .66     │
                   └───────────┘     └───────────┘   └───────────┘
                     rendezvous
              API VIP .17 (api, api-int)  and  ingress VIP .18 (*.apps)
              float between the three masters (keepalived)
```

| What | Value | Where it is set |
|---|---|---|
| Cluster name / zone | `compact` / `compact.mylab.com` | `compact_name`, `base_domain` in `vars.yaml` |
| master1 (rendezvous host) | `192.168.122.64` | `ip_list.compact_master1` |
| master2 | `192.168.122.65` | `ip_list.compact_master2` |
| master3 | `192.168.122.66` | `ip_list.compact_master3` |
| API VIP: `api`, `api-int` | `192.168.122.17` | `ip_list.compact_api` |
| Ingress VIP: `*.apps` | `192.168.122.18` | `ip_list.compact_ingress` |
| Bond | `bond0`, `active-backup`, `miimon=100`, `primary=enp1s0` | `compact_bond_*` in role defaults |
| Bond port 1 (primary) | `enp1s0`, MAC `52:54:00:e2:54:<octet>` | `compact_primary_mac_prefix` |
| Bond port 2 (backup) | `enp2s0`, MAC `52:54:00:e2:56:<octet>` | `compact_secondary_mac_prefix` |
| Per node | 8 vCPU, 24 GiB RAM, 150 GB disk | `compact_vcpus`, `compact_memory`, `compact_disk_gb` |

**Why these addresses.** They were five of the last six free two-digit octets
on the lab network. They are clear of every hosted-cluster MetalLB pool
(`hosted_cluster_metallb_pools`: .60-.62, .67-.69, .90-.95) and of both DHCP
ranges (dhcpd .100-.200, libvirt .201-.249). They are two digits because this
lab builds MACs by appending the octet: `52:54:00:e2:54:100` is not a MAC.
`.63` is the only free two-digit octet left.

**Why `e2:56` for the second NIC.** `52:54:00:e2:54:<octet>` is the lab-wide
scheme, and `52:54:00:e2:55:<octet>` is already taken by the containerlab
fabric NIC. The backup port of the bond takes the next prefix.

**How it differs from the SNO** (`setup_sno.yaml`). The structure is the same:
connected install, static addressing, one agent ISO, four stages. Two things
change:

- **`platform: baremetal` with two VIPs instead of `platform: none`.** Three
  nodes need `api` and `*.apps` to survive one node going down. The baremetal
  platform runs keepalived, haproxy and CoreDNS on the nodes and moves the VIPs
  between them, so there is no external load balancer to build.
- **Bonded networking.** Each VM gets two NICs on the same network. The agent
  configures `bond0` (mode 1) over them before the install starts, and the
  node's address, default route and DNS all live on the bond.

---

## The automated path

```bash
# 1. DNS: the zone on the helper, and api/*.apps in the hypervisor's /etc/hosts
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns --ask-vault-pass

# 2. The cluster: pre-flight, ISO, three VMs, then wait for the install
ansible-playbook -i inventory/hosts setup_compact_cluster.yaml --ask-vault-pass
```

| Tag | What it does | Role file |
|---|---|---|
| `compactpreflight` | Checks only. Always runs before the other stages. | `tasks/preflight.yml` |
| `compactimage` | Downloads the installer, renders the manifests and builds the ISO. | `tasks/image.yml` |
| `compactvm` | Builds the three VMs from the ISO that is already there. | `tasks/vm.yml` |
| `compactwait` | Waits for bootstrap and for install-complete, then checks the bonds. | `tasks/wait.yml` |

To rebuild over an existing cluster, add `-e compact_force_reinstall=true`.
The rebuild wipes `auth/kubeconfig`. To remove the cluster, run
`ansible-playbook -i inventory/hosts cleanup.yaml --tags compact`.

The rendered `install-config.yaml` and `agent-config.yaml` are kept in
`/var/lib/libvirt/images/compact_install/rendered/`. The installer deletes the
originals when it builds the ISO.

---

## Manual deployment

Run every step **on the hypervisor as root**, unless the step says otherwise.

### Step 1 - Prerequisites

*Automated by: `tasks/preflight.yml`*

```bash
# libvirt tooling: this has to be the hypervisor
which virsh qemu-img virt-install

# nmstatectl: openshift-install runs it on THIS host to validate each node's
# bond configuration. Without it, `agent create image` fails with
# "failed to validate network yaml for host 0, install nmstate package".
which nmstatectl || dnf install -y nmstate

# The lab ssh key, injected into every node for `ssh core@<node>`
ls ~/.ssh/lab_rsa ~/.ssh/lab_rsa.pub
```

You also need the **pull secret** from
[console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).
This is a connected install, so the nodes pull the release payload from
quay.io. In the lab it is in `vault.yaml` as `pull_secret`. For the manual
steps, save it to a file:

```bash
ansible-vault view vault.yaml   # copy the pull_secret value
vi /root/pull-secret.json       # paste it here, as one line of JSON
```

### Step 2 - Set the shell variables

The commands in the rest of this guide use these variables. Set them once in
the shell you will use for the whole build.

```bash
export LAB=192.168.122                       # lab_network_prefix
export DOMAIN=mylab.com                      # base_domain
export CLUSTER=compact                       # compact_name
export ZONE=$CLUSTER.$DOMAIN
export OCP=4.22.10                           # ocp_major_version.ocp_minor_version
export WORK=/var/lib/libvirt/images/compact_install
export VMDIR=/var/lib/libvirt/images/compact

export API_VIP=$LAB.17
export INGRESS_VIP=$LAB.18
export NODES="master1:64 master2:65 master3:66"   # hostname:octet, rendezvous host first
export RENDEZVOUS=$LAB.64

export MAC1=52:54:00:e2:54                   # bond port 1 (enp1s0), the lab-wide scheme
export MAC2=52:54:00:e2:56                   # bond port 2 (enp2s0)
```

### Step 3 - Check the addresses are free

*Automated by: `tasks/preflight.yml` (the ip_list, MetalLB, MAC and existing-VM checks)*

The agent sets every address statically, so nothing tells you about a
conflict. A duplicate address shows up much later as a cluster that is
reachable only some of the time.

```bash
# Nothing should answer on any of the five addresses
for o in 17 18 64 65 66; do
  ping -c1 -W1 $LAB.$o >/dev/null && echo "$LAB.$o IS IN USE" || echo "$LAB.$o free"
done

# No other DHCP reservation should hold them. setup-bm-host already reserves
# them for these MACs, so finding these exact MACs here is expected.
virsh net-dumpxml default | grep -E "\.(17|18|64|65|66)'"

# No domain with these names should exist yet
virsh list --all | grep -E 'compact_master[123]'
```

### Step 4 - DNS

*Automated by: `setup_bm_host.yaml --tags dns` (roles `setup-dns` and `setup-bm-host`)*

The nodes do not need this zone for the install itself. The baremetal
platform runs CoreDNS on each node for `api-int` and `*.apps`, and the nodes
use libvirt's dnsmasq (`.1`) to reach quay.io. **The hypervisor** does need
it: `openshift-install agent wait-for` connects to `api.compact.mylab.com`,
and so does every `oc` command afterwards.

**4a. The zone on the helper** (`ssh root@$LAB.21`):

```bash
cat > /var/named/compact.mylab.com.db <<'EOF'
$TTL 1D
@	IN SOA	helper.hub.mylab.com. root.hub.mylab.com. (
					0	; serial
					1D	; refresh
					1H	; retry
					1W	; expire
					3H )	; minimum
		NS	helper.hub.mylab.com.
master1        A	192.168.122.64
master2        A	192.168.122.65
master3        A	192.168.122.66
api		A	192.168.122.17
api-int		A	192.168.122.17
*.apps		A	192.168.122.18
EOF

cat >> /etc/named.rfc1912.zones <<'EOF'
zone "compact.mylab.com" IN {
	type master;
	file "compact.mylab.com.db";
	allow-update { none; };
};
EOF

# Reverse records: add these lines to /var/named/named-reverse.hub.mylab.com.db
#   64 		IN PTR 		master1.compact.mylab.com.
#   65 		IN PTR 		master2.compact.mylab.com.
#   66 		IN PTR 		master3.compact.mylab.com.
#   17 		IN PTR 		api.compact.mylab.com.
#   18 		IN PTR 		ingress.apps.compact.mylab.com.

chown root:named /var/named/compact.mylab.com.db
named-checkzone compact.mylab.com /var/named/compact.mylab.com.db
named-checkconf && systemctl restart named

dig +short @localhost api.compact.mylab.com            # 192.168.122.17
dig +short @localhost test.apps.compact.mylab.com      # 192.168.122.18
```

**4b. The hypervisor's `/etc/hosts`** (back on the hypervisor). The hypervisor
does not resolve through the helper, so put the names in `/etc/hosts`.
`*.apps` cannot be a wildcard there, so list each route you need:

```bash
cat >> /etc/hosts <<EOF
$API_VIP  api.$ZONE api-int.$ZONE
$INGRESS_VIP  console-openshift-console.apps.$ZONE
$INGRESS_VIP  oauth-openshift.apps.$ZONE
$INGRESS_VIP  downloads-openshift-console.apps.$ZONE
EOF

getent hosts api.$ZONE    # must print the API VIP, not anything else
```

**4c. (Optional) A libvirt forwarder.** This lets *other* VMs on the network
resolve `compact.mylab.com` through dnsmasq. The playbook adds a
`<forwarder domain='compact.mylab.com' addr='192.168.122.21'/>` line in
`default-network.xml.j2`, and it takes effect when you run
`setup_bm_host.yaml --tags virtnet`. **Be careful: that tag redefines the
default network, which disconnects every running VM from virbr0.** The install
does not need the forwarder, so you can add it later.

### Step 5 - Get the installer and client

*Automated by: `tasks/image.yml`*

Use the installer that matches the cluster version. The ISO records the
release image of the installer that built it.

```bash
mkdir -p $WORK $VMDIR
cd $WORK
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP/openshift-install-linux.tar.gz
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP/openshift-client-linux.tar.gz
tar xzf openshift-install-linux.tar.gz
tar xzf openshift-client-linux.tar.gz
./openshift-install version
./oc version --client
```

`agent create image` runs `oc` to extract the base ISO from the release
payload. Step 8 puts this directory at the front of `PATH` so the installer
uses this `oc`.

If this directory was used for an earlier build, remove its generated state
first. Stale `.openshift_install_state.json` and `auth/` files get reused in
the new ISO:

```bash
cd $WORK && find . -mindepth 1 -maxdepth 1 ! -name '*.tar.gz' ! -name openshift-install \
  ! -name oc ! -name kubectl ! -name README.md -exec rm -rf {} +
```

### Step 6 - Write install-config.yaml

*Automated by: `templates/install-config.yaml.j2`*

```bash
cat > $WORK/install-config.yaml <<EOF
apiVersion: v1
baseDomain: $DOMAIN
compute:
- name: worker
  replicas: 0                 # no workers ...
controlPlane:
  name: master
  replicas: 3                 # ... and three masters = compact; masters become schedulable
metadata:
  name: $CLUSTER
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: $LAB.0/24           # must contain every node address AND both VIPs
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  baremetal:
    apiVIPs:
    - $API_VIP                # api / api-int, held by keepalived on one master
    ingressVIPs:
    - $INGRESS_VIP            # *.apps, held by keepalived where a router runs
    provisioningNetwork: Disabled
pullSecret: '$(cat /root/pull-secret.json)'
sshKey: '$(cat ~/.ssh/lab_rsa.pub)'
EOF
```

Notes:

- The agent installer reads `compute: 0` with `controlPlane: 3` and builds a
  compact cluster. You do not need to edit `mastersSchedulable`.
- With the agent installer, `platform: baremetal` needs only the VIPs. There
  are no BMCs and no `hosts:` list here. `agent-config.yaml` describes the
  hosts.

### Step 7 - Write agent-config.yaml with the bonds

*Automated by: `templates/agent-config.yaml.j2`*

This is the step that adds the bonds. Each host entry has two parts:

- **`interfaces`** lists the host's two MACs. The agent compares them with the
  NICs it finds when it boots, picks the host entry that matches, and maps the
  NIC names in `networkConfig` to the real interfaces. Both bond ports are
  listed, so the agent can identify the host from either NIC.
- **`networkConfig`** is the [nmstate](https://nmstate.io) configuration that
  is applied before the install starts:
  - `bond0`, `type: bond`, `mode: active-backup` (mode 1), with both NICs as
    ports and the static IP **on the bond**.
  - `miimon: "100"`. Without link monitoring the bond never detects a dead
    port, so active-backup never fails over.
  - `primary: enp1s0`. The bond goes back to the first NIC when that NIC
    recovers.
  - `mac-address` on the bond is pinned to the **first NIC's MAC**. Otherwise
    the bond takes the MAC of whichever port is enslaved first, and that can
    change from one boot to the next. The DHCP reservation and every ARP cache
    know this address by the first NIC's MAC.
  - Both NICs are listed as `type: ethernet` with no IP of their own. This
    ties each name to its MAC.
  - The default route uses `next-hop-interface: bond0`, so it survives the
    loss of either port.

Generate the file for all three hosts:

```bash
host_block() {   # $1 = hostname, $2 = last octet
cat <<EOF
  - hostname: $1
    role: master
    interfaces:
      - name: enp1s0
        macAddress: $MAC1:$2
      - name: enp2s0
        macAddress: $MAC2:$2
    rootDeviceHints:
      deviceName: /dev/vda
    networkConfig:
      interfaces:
        - name: bond0
          type: bond
          state: up
          mac-address: $MAC1:$2
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: $LAB.$2
                prefix-length: 24
          ipv6:
            enabled: false
          link-aggregation:
            mode: active-backup
            options:
              miimon: "100"
              primary: enp1s0
            port:
              - enp1s0
              - enp2s0
        - name: enp1s0
          type: ethernet
          state: up
          mac-address: $MAC1:$2
          ipv4:
            enabled: false
          ipv6:
            enabled: false
        - name: enp2s0
          type: ethernet
          state: up
          mac-address: $MAC2:$2
          ipv4:
            enabled: false
          ipv6:
            enabled: false
      dns-resolver:
        config:
          server:
            - $LAB.1
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: $LAB.1
            next-hop-interface: bond0
            table-id: 254
EOF
}

{
cat <<EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: $CLUSTER
rendezvousIP: $RENDEZVOUS
hosts:
EOF
for n in $NODES; do host_block ${n%%:*} ${n##*:}; done
} > $WORK/agent-config.yaml
```

**Why the DNS server is `.1` and not the helper (`.21`).** named on the helper
forwards to a resolver that cannot be reached from this lab, so it returns
SERVFAIL for quay.io. The agent's pre-flight check then refuses to start the
install. libvirt's dnsmasq at `.1` resolves both external names and the lab
zones. See the comment on `sno_dns_server` in `roles/setup-sno/defaults/main.yml`.

**Keep a copy.** The next step deletes both files:

```bash
mkdir -p $WORK/rendered && cp $WORK/install-config.yaml $WORK/agent-config.yaml $WORK/rendered/
```

### Step 8 - Build the agent ISO

*Automated by: `tasks/image.yml`*

```bash
cd $WORK
PATH=$WORK:$PATH ./openshift-install --dir $WORK agent create image --log-level=info
ls -lh $WORK/agent.x86_64.iso
chmod 0644 $WORK/agent.x86_64.iso      # qemu reads it as its own user
```

The installer validates each host's `networkConfig` with `nmstatectl` at this
point. A mistake in the bond (a port name that is not in `interfaces`, a
misspelt `mode`, a wrong indent) fails here, before any VM exists. The same
ISO boots all three nodes. Each node picks its own configuration by MAC.

### Step 9 - Create the three VMs, each with two NICs

*Automated by: `tasks/vm.yml`*

For each node: create a fresh disk, reserve the address for the first NIC's
MAC, and create a domain with **two `--network` options on the default
network**. These are the two bond ports. libvirt assigns PCI slots in the
order the NICs are listed, so the first NIC becomes `enp1s0` and the second
`enp2s0`.

```bash
for n in $NODES; do
  host=${n%%:*}; oct=${n##*:}; dom=compact_$host

  # Always a fresh disk. A disk left from an earlier install already has
  # RHCOS on it, so with boot order hd,cdrom the VM would boot that and never
  # start the agent.
  rm -f $VMDIR/${dom}_disk.qcow2
  qemu-img create -f qcow2 $VMDIR/${dom}_disk.qcow2 150G

  # Reserve the address for the bond's MAC (the first NIC's MAC). Skip this if
  # setup-bm-host already did it.
  virsh net-dumpxml default | grep -qi "$MAC1:$oct" || \
    virsh net-update default add ip-dhcp-host \
      "<host mac='$MAC1:$oct' name='$host.$ZONE' ip='$LAB.$oct'/>" --live --config

  virt-install \
    --import \
    --name $dom \
    --memory 24576 \
    --vcpus 8 \
    --cpu host-passthrough \
    --os-variant=rhel9.4 \
    --disk $VMDIR/${dom}_disk.qcow2,format=qcow2,cache=none,bus=virtio \
    --disk $WORK/agent.x86_64.iso,device=cdrom,bus=sata,readonly=on \
    --boot hd,cdrom \
    --network network:default,mac=$MAC1:$oct,model=virtio \
    --network network:default,mac=$MAC2:$oct,model=virtio \
    --memballoon model=virtio,freePageReporting=on \
    --noautoconsole
done

# Each domain should list two interfaces with the expected MACs
for n in $NODES; do virsh domiflist compact_${n%%:*}; done
```

The VMs use `--import` with `--boot hd,cdrom` instead of `--cdrom`. While the
disk is empty, the VM falls through to the ISO. Once RHCOS is on the disk, the
VM boots from the disk. With `--cdrom`, each node would reboot back into the
agent after it installs.

### Step 10 - Watch the install

*Automated by: `tasks/wait.yml`*

The install goes like this:

1. All three nodes boot the ISO. Each one configures `bond0` from its
   `networkConfig` and starts the agent.
2. master1 (the rendezvous host, `.64`) runs the assisted service.
   master2 and master3 register with it.
3. When all three hosts pass validation, master1 installs master2 and
   master3, which reboot from disk.
4. master1 then installs itself and reboots, and the three masters form the
   control plane. This is **bootstrap-complete**.
5. The operators settle. This is **install-complete**.

```bash
cd $WORK
./openshift-install --dir $WORK agent wait-for bootstrap-complete --log-level=info
./openshift-install --dir $WORK agent wait-for install-complete  --log-level=info
```

While you wait:

```bash
virsh console compact_master1                                     # Ctrl-] to leave
ssh -i ~/.ssh/lab_rsa core@$RENDEZVOUS 'ip -br addr show bond0'   # the bond came up with the IP
ssh -i ~/.ssh/lab_rsa core@$RENDEZVOUS 'sudo journalctl -u assisted-service -u agent -f'
# Agent UI on newer releases: http://$RENDEZVOUS:8080
```

A compact install takes longer than an SNO. The role allows 75 minutes for
bootstrap and 120 minutes for completion.

### Step 11 - Verify the cluster and the bonds

*Automated by: `tasks/wait.yml` (the `/proc/net/bonding` check)*

```bash
export KUBECONFIG=$WORK/auth/kubeconfig
alias oc=$WORK/oc

oc get nodes -o wide        # three nodes, ROLES control-plane,master,worker
oc get clusteroperators     # all Available=True, Degraded=False
oc get clusterversion
```

Check the bond on every node:

```bash
for n in $NODES; do
  ip=$LAB.${n##*:}
  echo "== ${n%%:*} ($ip)"
  ssh -i ~/.ssh/lab_rsa core@$ip "grep -E 'Bonding Mode|Currently Active|MII Status|Slave Interface|Primary Slave' /proc/net/bonding/bond0"
done
```

You should see this for each node:

```
Bonding Mode: fault-tolerance (active-backup)
Primary Slave: enp1s0 (primary_reselect always)
Currently Active Slave: enp1s0
MII Status: up
Slave Interface: enp1s0
MII Status: up
Slave Interface: enp2s0
MII Status: up
```

The same information from inside the cluster:

```bash
oc debug node/master1 -- chroot /host nmcli -f NAME,TYPE,DEVICE con show --active
# br-ex is the OVN-Kubernetes external bridge, and bond0 is its port
oc debug node/master1 -- chroot /host ovs-vsctl list-ports br-ex      # shows bond0
oc debug node/master1 -- chroot /host ip -br addr show br-ex          # the node IP
```

After the install, the node IP is on **`br-ex`**, not on `bond0`. During the
first boot, OVN-Kubernetes moves the address from the interface that holds the
default route (here `bond0`) onto the `br-ex` bridge and adds `bond0` as the
bridge's uplink port. `bond0` still does the failover underneath: if a port
fails, the bond switches to the other port and `br-ex` is not affected.
During the agent phase (Step 10), before this happens, the IP is still on
`bond0`.

Check which master holds each VIP:

```bash
for n in $NODES; do
  ssh -i ~/.ssh/lab_rsa core@$LAB.${n##*:} "ip -br addr | grep -E '$API_VIP|$INGRESS_VIP'" \
    && echo "  ^ on ${n%%:*}"
done
```

Log in to the console:

```bash
cat $WORK/auth/kubeadmin-password
# https://console-openshift-console.apps.compact.mylab.com
```

### Step 12 - Test bond failover

Take down the active port of master1 and check that the bond moves to the
other port and the node stays reachable.

```bash
# In a second terminal, keep pinging the node and the API VIP
ping $LAB.64
ping $API_VIP

# Take the PRIMARY port's link down (enp1s0 inside the guest)
virsh domif-setlink compact_master1 $MAC1:64 down

ssh -i ~/.ssh/lab_rsa core@$LAB.64 "grep -E 'Currently Active|Slave Interface|MII Status' /proc/net/bonding/bond0"
# Currently Active Slave: enp2s0
# Slave Interface: enp1s0 / MII Status: down

# Put it back. Because primary=enp1s0, the bond moves back to enp1s0.
virsh domif-setlink compact_master1 $MAC1:64 up
```

Expect at most one or two lost pings while the miimon interval (100 ms)
detects the dead link and the bridge learns the bond's MAC on the other port.
Run the same test with `$MAC2:64` to take down the backup port: nothing should
change, because traffic is not using that port.

### Step 13 - Clean up

*Automated by: `cleanup.yaml --tags compact`*

```bash
for n in $NODES; do
  virsh destroy compact_${n%%:*}  2>/dev/null
  virsh undefine compact_${n%%:*} 2>/dev/null
done
rm -rf $VMDIR $WORK
```

`virsh undefine` is run without `--remove-all-storage` on purpose. The three
domains share the agent ISO as their cdrom, and removing the folders deletes
the disks anyway.

The DHCP reservations, DNS zone and `/etc/hosts` entries stay in place, as
they do for every other cluster in this lab. They are derived from `ip_list`,
and a rebuild reuses them.

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `agent create image` fails with `failed to validate network yaml for host N` | `nmstatectl` is missing, or the bond YAML is invalid | `which nmstatectl`. Check the indentation of `link-aggregation`. Every name under `port:` must also be listed under `interfaces:`. |
| A node boots the ISO but never gets an address | Its MACs do not match `agent-config.yaml`, so the agent found no host entry | `virsh domiflist compact_masterN` and compare with `rendered/agent-config.yaml` |
| The bond is up, but only one port is enslaved | The second NIC got a different name, for example after you added a device before it | `ssh core@<ip> ip -br link`. Set `compact_bond_secondary_nic` to the name the node uses. The MAC mapping in `interfaces` handles most of these cases. |
| master2/master3 never appear in the rendezvous host's list | They cannot reach `.64`, or a stale disk booted an old RHCOS instead of the ISO | `virsh console compact_master2`. Check for an old login prompt instead of the agent. |
| The agent's pre-flight reports `SERVFAIL` for quay.io | The node's DNS server points at the helper instead of `.1` | `compact_dns_server`. See Step 7. |
| `wait-for` cannot connect to the API | `api.compact.mylab.com` does not resolve to `.17` on the hypervisor | `getent hosts api.compact.mylab.com`. Run `setup_bm_host.yaml --tags dns` again. |
| Ingress and console operators are degraded | `*.apps` does not resolve to the ingress VIP, or the VIP is held by something else | `dig @192.168.122.21 x.apps.compact.mylab.com` and `ping 192.168.122.18` with the cluster down |
| Pings drop during failover and do not recover | `miimon` is 0, so the bond is not monitoring link state | `grep 'MII Polling' /proc/net/bonding/bond0`. It must not be 0. |
| The bond comes up with a different MAC on each reboot | `mac-address` is missing on `bond0` | Pin it to the primary NIC's MAC, as in Step 7 |
