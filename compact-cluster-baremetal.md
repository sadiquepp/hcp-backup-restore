# Three-node compact cluster on bare metal, with bonded NICs (agent-based installer)

This guide installs a **three-node compact OpenShift cluster on physical
servers** from a single **agent ISO**. Every server uses **two NICs bonded in
active-backup mode (mode 1)**, and the server's address lives on the bond.

This is the bare-metal version of [compact-cluster.md](compact-cluster.md),
which builds the same cluster as VMs in the lab. The cluster configuration is
the same. What changes is the hardware: you collect the MACs and disk IDs from
real servers, prepare the switch ports, and boot the ISO through each server's
BMC or from USB.

All addresses, names and IDs below are **examples**. Replace them with your
own values in [Step 6](#step-6---record-the-plan-as-shell-variables). Every
later command reads them from there.

- [What you get](#what-you-get)
- [Manual deployment](#manual-deployment)
  1. [Check the hardware](#step-1---check-the-hardware)
  2. [Prepare the switches](#step-2---prepare-the-switches)
  3. [Collect each server's MACs and disk ID](#step-3---collect-each-servers-macs-and-disk-id)
  4. [Prepare the firmware](#step-4---prepare-the-firmware)
  5. [Prepare the installer host](#step-5---prepare-the-installer-host)
  6. [Record the plan as shell variables](#step-6---record-the-plan-as-shell-variables)
  7. [Check the addresses are free](#step-7---check-the-addresses-are-free)
  8. [DNS](#step-8---dns)
  9. [Get the installer and client](#step-9---get-the-installer-and-client)
  10. [Write install-config.yaml](#step-10---write-install-configyaml)
  11. [Write agent-config.yaml with the bonds](#step-11---write-agent-configyaml-with-the-bonds)
  12. [Build the agent ISO](#step-12---build-the-agent-iso)
  13. [Boot the three servers from the ISO](#step-13---boot-the-three-servers-from-the-iso)
  14. [Watch the install](#step-14---watch-the-install)
  15. [Verify the cluster and the bonds](#step-15---verify-the-cluster-and-the-bonds)
  16. [Test bond failover](#step-16---test-bond-failover)
  17. [After the install](#step-17---after-the-install)
- [Troubleshooting](#troubleshooting)

---

## What you get

```
      ┌────────────┐                           ┌────────────┐
      │  switch A  │════ inter-switch link ════│  switch B  │
      └─────┬──────┘       (node VLAN)         └─────┬──────┘
            │ port 1 (active)                        │ port 2 (backup)
            │ ens1f0                                 │ ens2f0
      ┌─────┴────────────────────────────────────────┴─────┐
      │  bond0   active-backup (mode 1)   10.20.30.11      │
      │  master1 (rendezvous host)                         │
      └────────────────────────────────────────────────────┘
      master2 (10.20.30.12) and master3 (10.20.30.13) are cabled the same way

      API VIP 10.20.30.5 (api, api-int) and ingress VIP 10.20.30.6 (*.apps)
      float between the three masters (keepalived)
```

The diagram shows the recommended cabling: each server's two bond ports go to
**two different switches**, and where possible to **two different NIC cards**.
Then a failed cable, NIC, switch port or whole switch takes down only the
active port, and the bond moves to the other one.

| What | Example value | Your value |
|---|---|---|
| Cluster name / base domain | `compact` / `example.com` | |
| Machine network / prefix | `10.20.30.0/24` | |
| Gateway | `10.20.30.1` | |
| DNS server(s) | `10.20.30.10` | |
| NTP server(s) | `10.20.30.10` | |
| master1 (rendezvous host) | `10.20.30.11` | |
| master2 | `10.20.30.12` | |
| master3 | `10.20.30.13` | |
| API VIP: `api`, `api-int` | `10.20.30.5` | |
| Ingress VIP: `*.apps` | `10.20.30.6` | |
| Bond | `bond0`, `active-backup`, `miimon=100`, primary = port 1 | |
| Bond port 1 / port 2 names | `ens1f0` / `ens2f0` | |
| Node VLAN | untagged (access port) | |

Two choices shape the install:

- **`platform: baremetal` with two VIPs.** The masters run keepalived, haproxy
  and CoreDNS and move the API and ingress VIPs between them. You do not need
  an external load balancer, and `api` and `*.apps` keep working when one
  server goes down. The VIPs must be free addresses in the same subnet as the
  servers.
- **Active-backup (mode 1) bonding.** Only one port carries traffic at a time.
  This is the one bonding mode that needs **no configuration on the switch**:
  no LACP and no port-channel. Each port is a normal access port, so the two
  ports can go to two independent switches.

---

## Manual deployment

You run most steps from an **installer host**: any RHEL 9 or Fedora x86_64
machine (a laptop, a bastion or a VM) that can reach the server BMCs and the
node network. You also work on the switches and in each server's BMC.

### Step 1 - Check the hardware

Each of the three servers needs:

| Resource | Minimum for a compact control plane | Recommended |
|---|---|---|
| CPU | 4 physical cores (8 threads) | 16 cores or more. These nodes also run all workloads. |
| RAM | 16 GB | 64 GB or more |
| Install disk | 120 GB | 240 GB or more, SSD or NVMe. etcd is sensitive to fsync latency. |
| NICs | 2 ports for the bond | 2 ports on 2 different cards, each 10 GbE or faster |
| BMC | Optional | Redfish-capable (iDRAC, iLO, XCC, ...) for virtual media and remote console |
| Firmware | UEFI | UEFI. Secure Boot can be on or off. |

Also check:

- **Same architecture.** All three servers must be x86_64 if you use the
  `agent.x86_64.iso` built in Step 12.
- **No other OS you need.** The install overwrites the disk you select in
  Step 11.
- **Clocks.** The servers' clocks must be close to the real time. TLS
  certificates fail on a node whose clock is hours off. Step 11 adds NTP
  servers, but fix a badly wrong RTC in the BIOS first.

### Step 2 - Prepare the switches

Active-backup bonding needs **no switch-side bonding**. Each bond port is a
normal, independent switch port.

For each of the six ports (two per server):

- Put the port in the **node VLAN**. Use an access port for untagged traffic,
  or a trunk whose native VLAN is the node VLAN. For a tagged VLAN, see the
  [VLAN variant in Step 11](#if-the-node-network-is-a-tagged-vlan).
- **Do not** put the two ports of a server into a port-channel, LAG or MLAG.
  If the switch expects LACP and the server does not send it, the switch
  blocks or flaps the ports.
- Enable **edge / portfast** (STP edge port), so the port forwards traffic as
  soon as the link comes up. Otherwise a node that just booted can spend 30
  seconds or more blocked by spanning tree, and the agent's network checks
  fail.
- If you use **port security** or a MAC limit, allow the bond's MAC on
  **both** ports. When the bond fails over, the bond MAC moves from port 1 to
  port 2.
- If the two ports go to **two switches**, the inter-switch link (or the
  upstream network) must carry the node VLAN. Otherwise a server whose active
  port is on switch B cannot reach a server whose active port is on switch A.

On a Cisco-style switch, each port looks like this:

```
interface Ethernet1/11
  description master1 ens1f0 (bond0 port 1)
  switchport mode access
  switchport access vlan 30
  spanning-tree port type edge
  no shutdown
```

Make sure you know which server port goes to which switch port. You need that
in Step 16 to test failover by shutting down a switch port.

### Step 3 - Collect each server's MACs and disk ID

The agent ISO is the same for all three servers. Each server finds its own
configuration by **MAC address**, so every MAC in `agent-config.yaml` must be
correct. Collect, for each server:

- the **MAC address of bond port 1 and bond port 2**
- the **kernel name** of each port, if you can get it (for example `ens1f0`)
- a **stable ID of the install disk**: the WWN, or the serial number

**From the BMC using Redfish.** Most BMCs list the NICs and disks. The system
ID in the path differs by vendor: `System.Embedded.1` on Dell iDRAC, `1` on
HPE iLO, and so on. List `/redfish/v1/Systems` first to find it.

```bash
BMC=10.20.31.11 ; CRED='root:password'
curl -sku $CRED https://$BMC/redfish/v1/Systems | jq -r '.Members[]."@odata.id"'
SYS=/redfish/v1/Systems/System.Embedded.1     # use the path printed above

# NIC ports and their MACs
for p in $(curl -sku $CRED https://$BMC$SYS/EthernetInterfaces | jq -r '.Members[]."@odata.id"'); do
  curl -sku $CRED https://$BMC$p | jq -r '[.Id, .MACAddress, .LinkStatus] | @tsv'
done

# Disks, with serial numbers and sizes
for c in $(curl -sku $CRED https://$BMC$SYS/Storage | jq -r '.Members[]."@odata.id"'); do
  for d in $(curl -sku $CRED https://$BMC$c | jq -r '.Drives[]?."@odata.id"'); do
    curl -sku $CRED https://$BMC$d | jq -r '[.Id, .Model, .SerialNumber, (.CapacityBytes/1e9|floor|tostring)+"GB"] | @tsv'
  done
done
```

**From a live Linux environment.** Boot each server once from any live ISO
(RHEL, Fedora or a RHCOS live ISO) and run:

```bash
ip -br link                                        # kernel names and MACs
lsblk -d -o NAME,SIZE,ROTA,TYPE,WWN,SERIAL,MODEL   # install disk WWN and serial
ls -l /dev/disk/by-path/                           # stable PCI path of each disk
ethtool -P ens1f0                                  # permanent MAC of a port
```

Use the **permanent** MAC of each port (`ethtool -P`). If an earlier OS left
a bond configured, a port can report the bond's MAC instead of its own.

Choose **port 1 and port 2 on different NIC cards** if the server has two
cards. Note which switch port each one is cabled to.

### Step 4 - Prepare the firmware

In each server's BIOS or UEFI setup, or through the BMC:

- **Boot mode:** UEFI.
- **Boot order:** the install disk **before** the CD/virtual media and before
  network boot. In Step 13 you boot the ISO with a **one-time** boot override.
  After RHCOS is written to disk, the server must boot from the disk, not back
  into the agent.
- **PXE:** disable network boot on the bond ports, unless you boot this way on
  purpose (see Step 13). A server that PXE-boots into some other environment
  first is hard to diagnose.
- **Virtualization (VT-x / AMD-V):** enable it if you will run OpenShift
  Virtualization.
- **Old OS disks:** if another disk has a bootable OS, remove its boot entry
  or wipe the disk. Otherwise the server can boot that OS instead of RHCOS
  after the install.
- **BMC network:** check that the installer host can reach each BMC's web UI
  and Redfish API.

### Step 5 - Prepare the installer host

```bash
# nmstatectl: openshift-install uses it to validate each node's bond config
# before it builds the ISO
sudo dnf install -y nmstate jq curl

# An SSH key for the core user on every node
ssh-keygen -t ed25519 -N '' -f ~/.ssh/compact
```

You also need the **pull secret** from
[console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).
This is a connected install: each server pulls the release payload from
quay.io and registry.redhat.io. Save the pull secret as one line:

```bash
vi ~/pull-secret.json
```

The installer host needs to reach:

| Destination | Port | Why |
|---|---|---|
| Each BMC | 443 | Virtual media, power, remote console |
| master1 (rendezvous host) | 8090/tcp | `agent wait-for` reads install progress from the assisted service |
| API VIP | 6443/tcp | `agent wait-for install-complete` and `oc` |
| Ingress VIP | 443/tcp | Web console |
| Each node | 22/tcp | `ssh core@<node>` for debugging and for the bond checks |

The **servers** need outbound access to the internet: at least quay.io,
registry.redhat.io, `*.openshift.com` and the NTP servers. If they reach the
internet through a proxy, add a `proxy:` section to `install-config.yaml`
(see the OpenShift documentation for the agent installer).

### Step 6 - Record the plan as shell variables

Set these once, in the shell you will use for the rest of the install. Fill in
the inventory from Step 3: one line per server, with master1 (the rendezvous
host) first.

```bash
export DOMAIN=example.com
export CLUSTER=compact
export ZONE=$CLUSTER.$DOMAIN
export OCP=4.22.10                      # the OpenShift version to install
export WORK=~/compact_install

export MACHINE_NET=10.20.30.0/24
export PREFIX=24
export GATEWAY=10.20.30.1
export DNS1=10.20.30.10
export NTP1=10.20.30.10
export API_VIP=10.20.30.5
export INGRESS_VIP=10.20.30.6

export PORT1=ens1f0                     # bond port 1 (primary), as named on the servers
export PORT2=ens2f0                     # bond port 2 (backup)

# hostname  ip  port1-mac  port2-mac  install-disk-wwn
cat > ~/compact-nodes.txt <<'EOF'
master1  10.20.30.11  b8:ca:3a:00:00:11  b8:ca:3a:00:01:11  0x5000c500a0000011
master2  10.20.30.12  b8:ca:3a:00:00:12  b8:ca:3a:00:01:12  0x5000c500a0000012
master3  10.20.30.13  b8:ca:3a:00:00:13  b8:ca:3a:00:01:13  0x5000c500a0000013
EOF
export RENDEZVOUS=$(awk 'NR==1 {print $2}' ~/compact-nodes.txt)
```

Write the MACs in lowercase, with colons.

If the servers use different names for their ports (for example a different
NIC model in one server), that is still fine. The agent matches each host by
MAC and maps the names in `networkConfig` to the real ports with those MACs.
Use the same pair of names consistently inside each host's entry.

### Step 7 - Check the addresses are free

Every address is static, so nothing warns you about a conflict. A duplicate
address shows up much later as a cluster that is reachable only some of the
time.

```bash
for ip in $API_VIP $INGRESS_VIP $(awk '{print $2}' ~/compact-nodes.txt); do
  ping -c1 -W1 $ip >/dev/null && echo "$ip IS IN USE" || echo "$ip free"
done
```

`ping` does not prove an address is free, because a host can block ICMP.
Check your IPAM, and check that the DHCP server on this subnet does not hand
out these addresses. If you are on the same subnet, `arping -c2 -I <nic> <ip>`
is a stronger check.

### Step 8 - DNS

Create these records on the DNS server that serves your domain. Use the
equivalent screens if your DNS is managed through a UI or an API.

| Name | Type | Value |
|---|---|---|
| `api.compact.example.com` | A | API VIP `10.20.30.5` |
| `api-int.compact.example.com` | A | API VIP `10.20.30.5` |
| `*.apps.compact.example.com` | A | Ingress VIP `10.20.30.6` |
| `master1.compact.example.com` | A + PTR | `10.20.30.11` |
| `master2.compact.example.com` | A + PTR | `10.20.30.12` |
| `master3.compact.example.com` | A + PTR | `10.20.30.13` |

The PTR records are not strictly required, because `agent-config.yaml` sets
each hostname. Add them anyway: with a wrong or missing PTR, some tools show
the wrong name for a node.

For BIND, the zone looks like this:

```
$TTL 1H
@        IN SOA  ns1.example.com. hostmaster.example.com. ( 1 1D 1H 1W 3H )
         IN NS   ns1.example.com.
api      IN A    10.20.30.5
api-int  IN A    10.20.30.5
*.apps   IN A    10.20.30.6
master1  IN A    10.20.30.11
master2  IN A    10.20.30.12
master3  IN A    10.20.30.13
```

Check the records from the installer host, and from a host on the node
network, which uses the same resolver as the servers:

```bash
dig +short api.$ZONE                    # API VIP
dig +short api-int.$ZONE                # API VIP
dig +short anything.apps.$ZONE          # ingress VIP
dig +short -x $RENDEZVOUS               # master1.compact.example.com.
dig +short quay.io                      # the servers' resolver must also answer external names
```

The resolver in `$DNS1` must answer **both** the cluster names and external
names such as quay.io. The agent checks this before it starts the install, and
it stops if the check fails.

### Step 9 - Get the installer and client

Use the installer for the OpenShift version you want. The ISO it builds
installs that version.

```bash
mkdir -p $WORK && cd $WORK
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP/openshift-install-linux.tar.gz
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP/openshift-client-linux.tar.gz
tar xzf openshift-install-linux.tar.gz
tar xzf openshift-client-linux.tar.gz
./openshift-install version
./oc version --client
```

`agent create image` runs `oc` to extract the base ISO from the release
payload. Step 12 puts `$WORK` at the front of `PATH` so the installer uses
this `oc`.

If you reuse `$WORK` from an earlier attempt, remove the generated state
first. The installer would otherwise reuse the old cluster's certificates and
`auth/` files:

```bash
cd $WORK && find . -mindepth 1 -maxdepth 1 ! -name '*.tar.gz' ! -name openshift-install \
  ! -name oc ! -name kubectl ! -name README.md -exec rm -rf {} +
```

### Step 10 - Write install-config.yaml

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
  - cidr: 10.128.0.0/14       # must not overlap any network the cluster needs to reach
    hostPrefix: 23
  machineNetwork:
  - cidr: $MACHINE_NET        # must contain every node address AND both VIPs
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16             # must not overlap any network the cluster needs to reach
platform:
  baremetal:
    apiVIPs:
    - $API_VIP
    ingressVIPs:
    - $INGRESS_VIP
    provisioningNetwork: Disabled
pullSecret: '$(cat ~/pull-secret.json)'
sshKey: '$(cat ~/.ssh/compact.pub)'
EOF
```

Notes:

- The agent installer sees `compute: 0` with `controlPlane: 3` and builds a
  compact cluster with schedulable masters.
- `platform: baremetal` needs only the two VIPs. The agent ISO installs the
  servers, so you do not list BMC addresses or credentials here.
  `provisioningNetwork: Disabled` means there is no separate provisioning
  network.
- Change `clusterNetwork` and `serviceNetwork` if `10.128.0.0/14` or
  `172.30.0.0/16` is already used in your network. Pods cannot reach an
  outside network that overlaps one of these ranges.

### Step 11 - Write agent-config.yaml with the bonds

Each host entry has four parts:

- **`interfaces`** lists the server's two port MACs. The agent compares them
  with the NICs it finds when it boots, picks the host entry that matches, and
  maps the names in `networkConfig` to those NICs. Both ports are listed, so
  the agent can identify the server from either one.
- **`rootDeviceHints`** selects the install disk by **WWN**. Do not use
  `/dev/sda`. On a server with several disks, controller order can change
  between boots, and `/dev/sda` can become a different disk. Other stable
  hints are `serialNumber`, or `deviceName: /dev/disk/by-path/...`.
- **`networkConfig`** is the [nmstate](https://nmstate.io) configuration that
  the agent applies before the install:
  - `bond0`, `type: bond`, `mode: active-backup` (mode 1), with both ports
    and the static IP **on the bond**.
  - `miimon: "100"` checks the link every 100 ms. Without link monitoring the
    bond never sees a dead port and never fails over.
  - `primary: <port 1>`. The bond uses port 1 whenever port 1 is up, and
    returns to it after it recovers.
  - `mac-address` on the bond is fixed to **port 1's MAC**. Otherwise the bond
    takes the MAC of whichever port joins first, which can change between
    boots. Your switch tables, DHCP snooping and ARP caches then always see
    one MAC for this address.
  - Both ports are listed as `type: ethernet` with no IP of their own.
  - The default route uses `next-hop-interface: bond0`, so it survives the
    loss of either port.
- **`additionalNTPSources`** (once for the cluster) gives every node a time
  source from the first boot.

Generate the file from the inventory:

```bash
host_block() {   # $1 hostname  $2 ip  $3 port1 MAC  $4 port2 MAC  $5 disk WWN
cat <<EOF
  - hostname: $1
    role: master
    interfaces:
      - name: $PORT1
        macAddress: $3
      - name: $PORT2
        macAddress: $4
    rootDeviceHints:
      wwn: "$5"
    networkConfig:
      interfaces:
        - name: bond0
          type: bond
          state: up
          mac-address: $3
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: $2
                prefix-length: $PREFIX
          ipv6:
            enabled: false
          link-aggregation:
            mode: active-backup
            options:
              miimon: "100"
              primary: $PORT1
            port:
              - $PORT1
              - $PORT2
        - name: $PORT1
          type: ethernet
          state: up
          mac-address: $3
          ipv4:
            enabled: false
          ipv6:
            enabled: false
        - name: $PORT2
          type: ethernet
          state: up
          mac-address: $4
          ipv4:
            enabled: false
          ipv6:
            enabled: false
      dns-resolver:
        config:
          server:
            - $DNS1
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: $GATEWAY
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
additionalNTPSources:
  - $NTP1
hosts:
EOF
while read -r name ip mac1 mac2 wwn; do
  [ -n "$name" ] && host_block "$name" "$ip" "$mac1" "$mac2" "$wwn"
done < ~/compact-nodes.txt
} > $WORK/agent-config.yaml
```

Read the generated file once and check each server's MACs and WWN against
your notes from Step 3. A wrong MAC is the most common reason a server boots
the ISO and then never registers.

#### If the node network is a tagged VLAN

If the switch ports are trunks and the node network is a tagged VLAN, put the
IP on a VLAN interface on top of the bond. The bond itself gets no IP:

```yaml
      interfaces:
        - name: bond0
          type: bond
          state: up
          mac-address: <port 1 MAC>
          ipv4:
            enabled: false
          ipv6:
            enabled: false
          link-aggregation:
            mode: active-backup
            options:
              miimon: "100"
              primary: ens1f0
            port:
              - ens1f0
              - ens2f0
        - name: bond0.30
          type: vlan
          state: up
          vlan:
            base-iface: bond0
            id: 30
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 10.20.30.11
                prefix-length: 24
          ipv6:
            enabled: false
        # ... the two ethernet ports, unchanged ...
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.20.30.1
            next-hop-interface: bond0.30
            table-id: 254
```

**Keep a copy of both files.** The next step deletes them:

```bash
mkdir -p $WORK/rendered && cp $WORK/install-config.yaml $WORK/agent-config.yaml $WORK/rendered/
```

### Step 12 - Build the agent ISO

```bash
cd $WORK
PATH=$WORK:$PATH ./openshift-install --dir $WORK agent create image --log-level=info
ls -lh $WORK/agent.x86_64.iso
```

The installer checks each host's `networkConfig` with `nmstatectl` at this
point. A mistake in the bond config fails here, before you touch a server:
for example, a port in `port:` that is not listed under `interfaces:`, a
misspelt mode, or a wrong indent.

The ISO is about 1 GB. It contains the configuration for all three servers.

### Step 13 - Boot the three servers from the ISO

Boot each server **once** from the ISO. You can do this in any order and at
the same time. The other two servers wait until the rendezvous host is ready.

Pick one of these methods.

#### Option A - BMC virtual media using Redfish (remote)

Serve the ISO over HTTP from the installer host. The BMCs must be able to
reach this address:

```bash
cd $WORK && python3 -m http.server 8080 &
export ISO_URL=http://<installer-host-ip>:8080/agent.x86_64.iso
```

Then do this for each server. Like the system ID, the manager and virtual
media paths differ by vendor. List them first:

```bash
BMC=10.20.31.11 ; CRED='root:password'
curl -sku $CRED https://$BMC/redfish/v1/Managers | jq -r '.Members[]."@odata.id"'
curl -sku $CRED https://$BMC/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia | jq -r '.Members[]."@odata.id"'
# Newer iDRAC firmware lists virtual media under the system instead:
#   /redfish/v1/Systems/System.Embedded.1/VirtualMedia

SYS=/redfish/v1/Systems/System.Embedded.1                    # Dell example
VM=/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD     # Dell example; HPE iLO: /redfish/v1/Managers/1/VirtualMedia/2

# 1. Insert the ISO as a virtual CD
curl -sku $CRED -X POST -H 'Content-Type: application/json' \
  https://$BMC$VM/Actions/VirtualMedia.InsertMedia \
  -d "{\"Image\": \"$ISO_URL\", \"Inserted\": true, \"WriteProtected\": true}"

# 2. Boot from it ONCE. The following boots use the boot order: the disk first.
curl -sku $CRED -X PATCH -H 'Content-Type: application/json' \
  https://$BMC$SYS \
  -d '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}'

# 3. Power on, or restart if it is already on
curl -sku $CRED -X POST -H 'Content-Type: application/json' \
  https://$BMC$SYS/Actions/ComputerSystem.Reset -d '{"ResetType": "On"}'
# already on:                                   -d '{"ResetType": "ForceRestart"}'
```

Some BMCs need `"TransferProtocolType": "HTTP"` in the insert request, or
accept only HTTPS or NFS/CIFS sources. Others use a vendor-specific path for
the one-time boot to virtual CD. If Redfish does not work, use the BMC web UI
(Option B).

#### Option B - BMC web UI (remote)

In the iDRAC, iLO or XCC web UI: open the **virtual console**, attach
`agent.x86_64.iso` as **virtual media / virtual CD**, choose **boot once
from virtual CD**, and power on or reset the server. The virtual console also
shows you the boot, which is useful for the first server.

#### Option C - USB stick (on site)

Write the ISO to one USB stick per server (all three get the same image):

```bash
sudo dd if=$WORK/agent.x86_64.iso of=/dev/sdX bs=4M status=progress conv=fsync   # /dev/sdX = the USB stick
```

Plug one stick into each server, and use the one-time boot menu (often F11 or
F12) to boot from USB.

#### Option D - PXE

The installer can also produce PXE artifacts instead of an ISO:
`openshift-install --dir $WORK agent create pxe-files`. You serve the kernel,
initrd and rootfs from your own PXE/iPXE infrastructure. Use this only if
that infrastructure is already in place, and boot the servers through PXE
only for the first boot.

#### What you should see

Each server boots RHCOS from the ISO and shows a login prompt on the console.
Within a few minutes it should answer `ping` on its own address. If a server
boots but never gets its address, the agent did not find any of its MACs in
`agent-config.yaml`, so it applied no network config. Go back to Step 3.

### Step 14 - Watch the install

The install goes like this:

1. All three servers boot the ISO. Each one configures `bond0` from its own
   `networkConfig` and starts the agent.
2. master1 (the rendezvous host) runs the assisted service. master2 and
   master3 register with it.
3. When all three hosts pass validation (network, disk, NTP, DNS), master1
   writes RHCOS to master2 and master3. They reboot **from their disks**.
4. master1 then installs itself and reboots. The three masters form the
   control plane. This is **bootstrap-complete**.
5. The operators settle. This is **install-complete**.

```bash
cd $WORK
./openshift-install --dir $WORK agent wait-for bootstrap-complete --log-level=info
./openshift-install --dir $WORK agent wait-for install-complete  --log-level=info
```

While you wait:

```bash
ssh -i ~/.ssh/compact core@$RENDEZVOUS 'ip -br addr show bond0; cat /proc/net/bonding/bond0'
ssh -i ~/.ssh/compact core@$RENDEZVOUS 'sudo journalctl -u assisted-service -u agent -f'
```

Watch the servers' consoles through the BMC, especially when they reboot.

- A server that boots back into the agent after step 3 has the wrong boot
  order, or the virtual media is still attached as the first boot device. Go
  back to Step 4.
- Physical servers spend several minutes in POST on every reboot. A compact
  bare-metal install usually takes 60 to 90 minutes.

### Step 15 - Verify the cluster and the bonds

```bash
export KUBECONFIG=$WORK/auth/kubeconfig
alias oc=$WORK/oc

oc get nodes -o wide        # three nodes, ROLES control-plane,master,worker
oc get clusteroperators     # all Available=True, Degraded=False
oc get clusterversion
```

Check the bond on every server:

```bash
while read -r name ip _; do
  echo "== $name ($ip)"
  ssh -n -i ~/.ssh/compact core@$ip \
    "grep -E 'Bonding Mode|Primary Slave|Currently Active|MII Status|Slave Interface|Permanent HW addr' /proc/net/bonding/bond0"
done < ~/compact-nodes.txt
```

For each server you should see:

```
Bonding Mode: fault-tolerance (active-backup)
Primary Slave: ens1f0 (primary_reselect always)
Currently Active Slave: ens1f0
MII Status: up
Slave Interface: ens1f0
MII Status: up
Permanent HW addr: b8:ca:3a:00:00:11
Slave Interface: ens2f0
MII Status: up
Permanent HW addr: b8:ca:3a:00:01:11
```

Both ports must show `MII Status: up`. A port that is down here has no
redundancy behind it. Check its cable and switch port **now**, not when the
other port fails.

The same information from inside the cluster:

```bash
oc debug node/master1 -- chroot /host nmcli -f NAME,TYPE,DEVICE con show --active
oc debug node/master1 -- chroot /host ovs-vsctl list-ports br-ex      # shows bond0
oc debug node/master1 -- chroot /host ip -br addr show br-ex          # the node IP
```

After the install, the node IP is on **`br-ex`**, not on `bond0`. On the first
boot, OVN-Kubernetes moves the address from the interface that holds the
default route (`bond0`) onto the `br-ex` bridge, and adds `bond0` as the
bridge's uplink. `bond0` still does the failover underneath it.

Check which master holds each VIP:

```bash
while read -r name ip _; do
  ssh -n -i ~/.ssh/compact core@$ip "ip -br addr | grep -E '$API_VIP|$INGRESS_VIP'" && echo "  ^ on $name"
done < ~/compact-nodes.txt
```

Log in to the console:

```bash
cat $WORK/auth/kubeadmin-password
echo https://console-openshift-console.apps.$ZONE
```

### Step 16 - Test bond failover

Run this test on each server before you put workloads on the cluster. A
cabling or VLAN mistake on the backup port stays hidden until the day the
active port fails.

In a second terminal, keep pinging the server and the API VIP:

```bash
ping 10.20.30.11
ping $API_VIP
```

Then fail the **active port**. The realistic way is on the switch. Shut down
the port that master1's port 1 is cabled to:

```
interface Ethernet1/11
  shutdown
```

You can also pull the cable. Or, if you cannot reach the switch, take the link
down on the server itself. This tests the bond, but not the switch path:

```bash
ssh -i ~/.ssh/compact core@10.20.30.11 'sudo ip link set ens1f0 down'
```

Check that the bond moved to port 2:

```bash
ssh -i ~/.ssh/compact core@10.20.30.11 "grep -E 'Currently Active|Slave Interface|MII Status' /proc/net/bonding/bond0"
# Currently Active Slave: ens2f0
# Slave Interface: ens1f0 / MII Status: down
```

Expect no more than a few lost pings. miimon detects the link loss within
100 ms, and the bond sends gratuitous ARPs so that the switches learn the
bond's MAC on the new port.

Restore the port (`no shutdown` on the switch, or
`sudo ip link set ens1f0 up` on the server). Because `primary` is port 1, the
bond moves back to port 1 when it comes up. Expect another brief interruption.

Then fail **port 2** in the same way. Nothing should change, because traffic
is not using that port. Restore it, and repeat the test on master2 and
master3.

### Step 17 - After the install

- **Eject the virtual media** in each BMC, and remove any USB sticks. The
  one-time boot override has already been used, but a mounted ISO is a risk if
  someone changes the boot order later.
- **Back up `$WORK/auth/`.** `kubeconfig` and `kubeadmin-password` are the
  only admin credentials until you configure an identity provider. Also keep
  `$WORK/rendered/`: it is the only record of the exact configuration used.
- **Stop the HTTP server** from Step 13, if you used one (`kill %1`).
- **Reinstall a server or the whole cluster:** build a new ISO (Steps 9-12)
  and boot the servers from it again (Step 13). The agent overwrites the disk
  selected by `rootDeviceHints`. If a server still boots its old RHCOS from
  the disk, wipe the disk first from a live environment
  (`wipefs -a /dev/disk/by-id/wwn-...`), or use a one-time boot as in Step 13.
- **Decommission:** power off the servers, wipe their disks, and remove the
  DNS records from Step 8.

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `agent create image` fails with `failed to validate network yaml for host N` | `nmstatectl` is missing on the installer host, or the bond YAML is invalid | `which nmstatectl`. Check the indentation of `link-aggregation`. Every name under `port:` must also be listed under `interfaces:`. |
| A server boots the ISO but never gets its address or never registers | None of its MACs are in `agent-config.yaml`: a typo, an uppercase MAC, or a MAC read from the wrong port | Compare `ethtool -P <port>` (from a live environment) with `rendered/agent-config.yaml` |
| The bond comes up but the server cannot reach the gateway | Wrong VLAN on the switch ports, or the ports are tagged and the config expects untagged traffic (or the other way round) | Switch port config. See the [VLAN variant](#if-the-node-network-is-a-tagged-vlan). |
| The server works on port 1 but loses connectivity after failover to port 2 | Port 2's switch port is in the wrong VLAN, the inter-switch link does not carry the VLAN, or port security blocks the bond MAC on port 2 | Test port 2 alone (Step 16). Check the switch MAC table for the bond MAC. |
| Switch logs show the bond MAC flapping between two ports | The switch ports are in a port-channel or LAG while the server uses active-backup, or both ports are active | Remove the port-channel. Mode 1 uses plain access ports. |
| Ports are blocked for 30+ seconds after every reboot | Spanning tree is running on the ports without edge/portfast | Enable `spanning-tree port type edge` (or portfast) on all six ports |
| The agent's validation fails on NTP, or the install fails with certificate errors | The server clock is wrong, or the NTP server is unreachable | `additionalNTPSources`. Fix the RTC in the BIOS. Check from the node with `chronyc sources`. |
| The agent's validation fails on DNS (`SERVFAIL` for quay.io, or `api` does not resolve) | The resolver in `networkConfig` cannot answer external names or the cluster names | `dig @$DNS1 quay.io` and `dig @$DNS1 api.$ZONE` from the node network |
| RHCOS is installed on the wrong disk | The `rootDeviceHints` WWN is wrong, or a non-unique hint matched another disk | `lsblk -d -o NAME,WWN,SERIAL` on the server. Use `wwn` or `serialNumber`. |
| A server boots back into the agent after it was installed | CD/virtual media or PXE comes before the disk in the boot order | Step 4: disk first. Use one-time boot overrides for the ISO. |
| A server boots an old operating system after the install | Another disk with a bootable OS comes first in the UEFI boot order | Remove the old boot entry, or wipe that disk |
| `wait-for` cannot connect to the API | `api.$ZONE` does not resolve to the API VIP from the installer host, or a firewall blocks 6443 | `dig api.$ZONE` and `curl -k https://api.$ZONE:6443/version` |
| Ingress and console operators are degraded | `*.apps` does not resolve to the ingress VIP, or something else on the network uses the ingress VIP | `dig x.apps.$ZONE`. Check that only one MAC answers ARP for the ingress VIP. |
| Failover works but takes many seconds | `miimon` is 0, or the switch learns MACs slowly | `grep 'MII Polling' /proc/net/bonding/bond0` must not be 0. Check the switch MAC aging and learning settings. |
| The bond comes up with a different MAC on each reboot | `mac-address` is missing on `bond0` | Pin it to port 1's MAC, as in Step 11 |
