# Disconnected three-node compact cluster on bare metal (agent-based installer)

This guide installs a **three-node compact OpenShift cluster on physical
servers that have no internet access**. Every image comes from a **mirror
registry** on your network. The cluster is built from a single **agent ISO**:
three schedulable masters, `platform: baremetal` with two VIPs, and every
server's address on an **LACP bond (IEEE 802.3ad, bonding mode 4)** over two
NICs.

What makes the install disconnected:

- **`openshift-install` is extracted from the release image in the mirror**
  with `oc adm release extract --idms-file=...`. The extracted binary
  has the mirror's release image built in, so the ISO and the cluster use the
  mirror instead of quay.io.
- **`install-config.yaml` carries the mirror configuration**: the
  `imageDigestSources` from the same IDMS file, the mirror's CA certificate,
  and a pull secret for the mirror.
- **`openshift-install agent create image` has no `--idms` flag.** It reads
  `imageDigestSources` from `install-config.yaml`. It uses them for its own
  pulls when it builds the ISO, and writes them into the ISO so the servers
  pull from the mirror too. Details in [Step 14](#step-14---build-the-agent-iso).
- **Operator mirrors, catalogs and signatures are added on day 2**, with one
  `oc apply` of everything `oc mirror` produced.

All names, addresses, IDs and paths are **examples**. Replace them with your
own values in [Step 6](#step-6---record-the-plan-as-shell-variables). Every
later command reads them from there.

- [What you get](#what-you-get)
- [Before you start](#before-you-start)
- [Manual deployment](#manual-deployment)
  1. [Check the hardware](#step-1---check-the-hardware)
  2. [Prepare the switches](#step-2---prepare-the-switches)
  3. [Collect each server's MACs and disk ID](#step-3---collect-each-servers-macs-and-disk-id)
  4. [Prepare the firmware](#step-4---prepare-the-firmware)
  5. [Prepare the installer host](#step-5---prepare-the-installer-host)
  6. [Record the plan as shell variables](#step-6---record-the-plan-as-shell-variables)
  7. [Check the addresses are free](#step-7---check-the-addresses-are-free)
  8. [DNS](#step-8---dns)
  9. [Check that the mirror has the release](#step-9---check-that-the-mirror-has-the-release)
  10. [Extract openshift-install and oc from the mirror](#step-10---extract-openshift-install-and-oc-from-the-mirror)
  11. [Turn the IDMS into imageDigestSources](#step-11---turn-the-idms-into-imagedigestsources)
  12. [Write install-config.yaml](#step-12---write-install-configyaml)
  13. [Write agent-config.yaml with the bonds](#step-13---write-agent-configyaml-with-the-bonds)
  14. [Build the agent ISO](#step-14---build-the-agent-iso)
  15. [Boot the three servers from the ISO](#step-15---boot-the-three-servers-from-the-iso)
  16. [Watch the install](#step-16---watch-the-install)
  17. [Verify the cluster, the bonds and the mirror](#step-17---verify-the-cluster-the-bonds-and-the-mirror)
  18. [Day 2: catalogs, tag mirrors and signatures](#step-18---day-2-catalogs-tag-mirrors-and-signatures)
  19. [Test bond failover](#step-19---test-bond-failover)
  20. [After the install](#step-20---after-the-install)
- [Troubleshooting](#troubleshooting)

---

## What you get

```
      ┌────────────┐                           ┌────────────┐
      │  switch A  │══ MLAG / vPC peer link ═══│  switch B  │
      └─────┬──────┘       (node VLAN)         └─────┬──────┘
            │ port 1 (active)                        │ port 2 (active)
            │ ens1f0 ── one LACP port-channel ──     │ ens2f0
      ┌─────┴────────────────────────────────────────┴─────┐
      │  bond0   LACP / 802.3ad (mode 4)   10.20.30.11     │
      │  master1 (rendezvous host)                         │
      └────────────────────────────────────────────────────┘
      master2 (10.20.30.12) and master3 (10.20.30.13) are cabled the same way

      API VIP 10.20.30.5 (api, api-int) and ingress VIP 10.20.30.6 (*.apps)
      float between the three masters (keepalived)

      Every image is pulled from mirror.example.com:8443. No internet access.
```

The diagram shows the recommended cabling: each server's two bond ports go to
**two different switches** that act as one LACP partner (an MLAG pair, Cisco
vPC, or a switch stack), and where possible to **two different NIC cards**.
Both ports carry traffic. A failed cable, NIC, switch port or whole switch
removes one port from the bond, and the traffic continues on the other.

| What | Example value | Your value |
|---|---|---|
| Cluster name / base domain | `compact` / `example.com` | |
| Machine network / prefix | `10.20.30.0/24` | |
| Gateway | `10.20.30.1` | |
| DNS server(s) | `10.20.30.10` | |
| NTP server(s), inside your network | `10.20.30.10` | |
| master1 (rendezvous host) | `10.20.30.11` | |
| master2 | `10.20.30.12` | |
| master3 | `10.20.30.13` | |
| API VIP: `api`, `api-int` | `10.20.30.5` | |
| Ingress VIP: `*.apps` | `10.20.30.6` | |
| Bond | `bond0`, `802.3ad` (LACP), `miimon=100`, `lacp_rate=fast`, `xmit_hash_policy=layer3+4` | |
| Bond port 1 / port 2 names | `ens1f0` / `ens2f0` | |
| Node VLAN | untagged (access port-channel) | |
| Switch port-channel per server | `port-channel11/12/13`, vPC/MLAG ID 11/12/13 | |
| Mirror registry | `mirror.example.com:8443` | |

Two choices shape the install:

- **`platform: baremetal` with two VIPs.** The masters run keepalived, haproxy
  and CoreDNS and move the API and ingress VIPs between them. You do not need
  an external load balancer, and `api` and `*.apps` keep working when one
  server goes down. The VIPs must be free addresses in the same subnet as the
  servers.
- **LACP (802.3ad, mode 4) bonding.** Both ports carry traffic, so a server
  gets the bandwidth of both links, spread across flows. LACP also checks the
  link end to end: a port is used only while the switch answers with LACP
  packets, so a port with link but a broken path is taken out of the bond.
  The cost is **switch configuration**: each server's two ports must be one
  LACP port-channel on the switch side. When the ports go to two switches,
  those switches must be an MLAG pair, vPC pair or stack.

---

## Before you start

This guide assumes the mirror registry **already exists and is populated**.
Before you start, you need:

| What | Example | Notes |
|---|---|---|
| Mirror registry | `mirror.example.com:8443` | Reachable from the installer host and from the servers' node network |
| The release, mirrored | `mirror.example.com:8443/openshift/release-images:4.22.10-x86_64` | The whole payload, mirrored with `oc mirror`. The version must be the one you install. |
| The IDMS file from `oc mirror` | `~/oc-mirror-output/working-dir/cluster-resources/idms-oc-mirror.yaml` | `ImageDigestMirrorSet`: maps each quay.io source to its mirror |
| The mirror's CA certificate | `~/mirror-ca.pem` | PEM. The servers and the installer host must trust it. |
| Credentials for the mirror | `~/mirror-auth.json` | A `{"auths": {...}}` file with an entry for the mirror registry |
| Other `oc mirror` output | `~/oc-mirror-output/working-dir/cluster-resources/` | IDMS, ITMS, CatalogSources and the release signature ConfigMap, all applied on day 2 (Step 18) |

`oc mirror` (v2) writes the IDMS and the other cluster resources under
`<workspace>/working-dir/cluster-resources/`. Older `oc mirror` (v1) writes an
`imageContentSourcePolicy.yaml` instead. If that is all you have, use
`--icsp-file` wherever this guide uses `--idms-file`, and convert its
`repositoryDigestMirrors` the same way in Step 11.

You do **not** need a pull secret from console.redhat.com. The servers pull
only from the mirror, with the mirror's own credentials.

---

## Manual deployment

You run most steps from an **installer host**. This is a RHEL 9 or Fedora
x86_64 machine (a laptop, a bastion or a VM) that can reach the mirror
registry, the server BMCs and the node network. It does not need internet
access if you can copy an `oc` binary onto it (Step 5). You also work on the
switches and in each server's BMC.

### Step 1 - Check the hardware

Each of the three servers needs:

| Resource | Minimum for a compact control plane | Recommended |
|---|---|---|
| CPU | 4 physical cores (8 threads) | 16 cores or more. These nodes also run all workloads. |
| RAM | 16 GB | 64 GB or more |
| Install disk | 120 GB | 240 GB or more, SSD or NVMe. etcd is sensitive to fsync latency. |
| NICs | 2 ports of the same speed for the bond | 2 ports on 2 different cards, each 10 GbE or faster, same speed |
| BMC | Optional | Redfish-capable (iDRAC, iLO, XCC, ...) for virtual media and remote console |
| Firmware | UEFI | UEFI. Secure Boot can be on or off. |

Also check:

- **Same architecture.** All three servers must be x86_64 if you use the
  `agent.x86_64.iso` built in Step 14.
- **No other OS you need.** The install overwrites the disk you select in
  Step 13.
- **Clocks.** The servers' clocks must be close to the real time. TLS
  certificates fail on a node whose clock is hours off. Step 13 adds an NTP
  server, but fix a badly wrong RTC in the BIOS first.
- **Switches.** The switches must support LACP (802.3ad). To spread a bond
  across two switches, they must support multi-chassis link aggregation:
  MLAG, Cisco vPC, Juniper MC-LAG or ESI-LAG, or a stack/virtual chassis. Two
  independent switches without one of these cannot form one LACP bond.
- **What the node network must reach.** The **mirror registry** (port 8443 in
  the example), your **DNS** server and an **NTP** server inside your network.
  Nothing outside your network is needed.

### Step 2 - Prepare the switches

LACP needs matching configuration on the switch. For each server, its two
switch ports become **one port-channel running LACP**.

> **Note:** Please consult your network admin to get the switches properly
> configured for LACP. Switch vendors, models, OS versions and MLAG/vPC
> variants all differ in commands and defaults. The settings and the example
> below are **for reference only**: they describe what the server side
> expects, not the exact configuration for your switches.

For each server:

- Create **one port-channel** with both of the server's ports as members,
  in LACP **active** mode (`channel-group <n> mode active`). Do not use
  `mode on` (a static LAG without LACP): the server sends LACP and expects
  the switch to answer.
- If the two ports go to **two switches**, configure the port-channel on
  both switches with the **same MLAG / vPC ID**, so the server sees one LACP
  partner. The MLAG / vPC peer link must carry the node VLAN.
- Put the **port-channel** in the **node VLAN**. Use an access port-channel
  for untagged traffic, or a trunk whose native VLAN is the node VLAN. For a
  tagged VLAN, see the
  [VLAN variant in Step 13](#if-the-node-network-is-a-tagged-vlan).
- Set the **LACP rate to fast** on the member ports, to match
  `lacp_rate: fast` on the server. Both sides then send LACP packets every
  second and detect a dead partner in about 3 seconds instead of 90.
- Enable **edge / portfast** (STP edge port) on the port-channel, so it
  forwards traffic as soon as LACP is up. Otherwise a node that just booted
  can spend 30 seconds or more blocked by spanning tree, and the agent's
  network checks fail.
- Let the member ports work **individually when there is no LACP**:
  `no lacp suspend-individual` on Cisco NX-OS, `port-channel lacp fallback
  individual` on Arista, `force-up` on Juniper. Before the bond is configured
  (in the firmware, during PXE, or in a live environment), the server sends no
  LACP packets. With the default `suspend-individual`, the switch blocks the
  ports, so PXE boot and anything else that needs the network before the bond
  is up fails. The agent ISO itself configures the bond before it uses the
  network, so it works either way.

For reference only, on Cisco NX-OS with a vPC pair, master1's configuration
could look like this. Use the same `port-channel11` and `vpc 11` on **both**
switches. On switch A the member is the port cabled to `ens1f0`, and on
switch B the port cabled to `ens2f0`:

```
interface port-channel11
  description master1 bond0
  switchport mode access
  switchport access vlan 30
  spanning-tree port type edge
  no lacp suspend-individual
  vpc 11

interface Ethernet1/11
  description master1 bond0 member
  switchport mode access
  switchport access vlan 30
  channel-group 11 mode active
  lacp rate fast
  no shutdown
```

Repeat with `port-channel12` / `vpc 12` for master2 and `port-channel13` /
`vpc 13` for master3. If both ports go to the **same switch**, leave out the
`vpc` line. The bond then still survives a cable, NIC or port failure, but
not the loss of that switch.

Until the servers run the bond, the port-channels show as down or
individual (`show port-channel summary`). That is expected. They come up when
the agent ISO boots in Step 15.

Make sure you know which server port goes to which switch port. You need that
in Step 19 to test failover by shutting down a switch port.

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

Use the **permanent** MAC of each port (`ethtool -P`). In an LACP bond, every
port uses the bond's MAC, so if an earlier OS left a bond configured, a port
can report the bond's MAC instead of its own.

The live environment does not need network access for this. If the
port-channels are already configured without the individual fallback from
Step 2, the ports may have no connectivity here. That is expected.

Choose **port 1 and port 2 on different NIC cards** if the server has two
cards. Note which switch port each one is cabled to.

### Step 4 - Prepare the firmware

In each server's BIOS or UEFI setup, or through the BMC:

- **Boot mode:** UEFI.
- **Boot order:** the install disk **before** the CD/virtual media and before
  network boot. In Step 15 you boot the ISO with a **one-time** boot override.
  After RHCOS is written to disk, the server must boot from the disk, not back
  into the agent.
- **PXE:** disable network boot on the bond ports, unless you boot this way on
  purpose (see Step 15). A server that PXE-boots into some other environment
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
# before it builds the ISO. python3-pyyaml: Steps 11 and 12.
sudo dnf install -y nmstate jq curl python3-pyyaml

# An SSH key for the core user on every node
ssh-keygen -t ed25519 -N '' -f ~/.ssh/compact
```

If the installer host has no internet access, install these packages from
your internal RHEL repositories.

**An `oc` client, 4.13 or newer.** You need it for `oc adm release extract
--idms-file` in Step 10. Older clients only have `--icsp-file`. If the
installer host has no internet access, download
`openshift-client-linux.tar.gz` from mirror.openshift.com on a connected
machine and copy it over. Step 10 then extracts an `oc` that exactly matches
the release.

```bash
oc version --client
oc adm release extract --help | grep -- --idms-file    # must print the flag
```

**Trust the mirror's CA** on the installer host, so `oc` can talk to the
registry without `--insecure`:

```bash
sudo cp ~/mirror-ca.pem /etc/pki/ca-trust/source/anchors/mirror-ca.pem
sudo update-ca-trust
curl -s -o /dev/null -w '%{http_code}\n' https://mirror.example.com:8443/v2/   # 200 or 401, NOT a TLS error
```

The installer host needs to reach:

| Destination | Port | Why |
|---|---|---|
| Mirror registry | 8443/tcp | Extract the installer (Step 10), build the ISO (Step 14) |
| Each BMC | 443 | Virtual media, power, remote console |
| master1 (rendezvous host) | 8090/tcp | `agent wait-for` reads install progress from the assisted service |
| API VIP | 6443/tcp | `agent wait-for install-complete` and `oc` |
| Ingress VIP | 443/tcp | Web console |
| Each node | 22/tcp | `ssh core@<node>` for debugging and for the bond checks |

The **servers** need to reach only the mirror registry, DNS and NTP.

### Step 6 - Record the plan as shell variables

Set these once, in the shell you will use for the rest of the install. Fill in
the inventory from Step 3: one line per server, with master1 (the rendezvous
host) first.

```bash
export DOMAIN=example.com
export CLUSTER=compact
export ZONE=$CLUSTER.$DOMAIN
export OCP=4.22.10                      # must be a release that is in the mirror
export WORK=~/compact_install

export MACHINE_NET=10.20.30.0/24
export PREFIX=24
export GATEWAY=10.20.30.1
export DNS1=10.20.30.10
export NTP1=10.20.30.10                 # must be inside your network
export API_VIP=10.20.30.5
export INGRESS_VIP=10.20.30.6

export PORT1=ens1f0                     # bond port 1, as named on the servers
export PORT2=ens2f0                     # bond port 2

# The mirror
export MIRROR=mirror.example.com:8443                                   # host:port, as in the auth file
export RELEASE=$MIRROR/openshift/release-images:$OCP-x86_64             # the mirrored release image
export MIRROR_CA=~/mirror-ca.pem
export MIRROR_AUTH=~/mirror-auth.json

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

If `oc mirror` wrote more than one IDMS file, for example one for the release
and one for operators, set `IDMS` to the one whose sources include
`quay.io/openshift-release-dev`. That is the file `oc adm release extract`
needs. Step 11 takes only the release mappings from them for the install, and
Step 18 applies all of them on day 2. Find them by content, because the file
names differ between `oc mirror` releases:

```bash
export CR=~/oc-mirror-output/working-dir/cluster-resources
grep -lE '^\s*kind:\s*ImageDigestMirrorSet' $CR/*                                  # every IDMS file
export IDMS=$(grep -lE '^\s*kind:\s*ImageDigestMirrorSet' $CR/* | xargs grep -l openshift-release-dev | head -1)
echo $IDMS                                                                         # the release one
```

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

The resolver in `$DNS1` does **not** need to answer internet names. It
**must** resolve the mirror registry's name, because the agent and every node
pull from it by name.

Check the records from the installer host, and from a host on the node
network, which uses the same resolver as the servers:

```bash
dig +short api.$ZONE                    # API VIP
dig +short api-int.$ZONE                # API VIP
dig +short anything.apps.$ZONE          # ingress VIP
dig +short -x $RENDEZVOUS               # master1.compact.example.com.
dig +short @$DNS1 ${MIRROR%%:*}         # the mirror registry - from the NODE network's resolver
```

### Step 9 - Check that the mirror has the release

Before you build anything, confirm the mirror really has this release:

```bash
oc adm release info -a $MIRROR_AUTH $RELEASE | head -20
```

The output names the version (`Name: 4.22.10`) and lists the component
images. The component pullspecs still say `quay.io/openshift-release-dev/...`.
That is expected: the payload always lists the original names, and the IDMS
maps them to the mirror. If this command fails, fix the mirror first. Nothing
later in this guide can work around a missing or incomplete release.

### Step 10 - Extract openshift-install and oc from the mirror

Do not download `openshift-install` from mirror.openshift.com. Extract it
from the release image **in the mirror**.

Start from an **empty** `$WORK`. If you reuse it from an earlier attempt, the
installer would otherwise reuse the old cluster's certificates and `auth/`
files. Emptying it also deletes the old cluster's `auth/kubeconfig`, so back
that up first if you still need it.

```bash
rm -rf $WORK
mkdir -p $WORK && cd $WORK

oc adm release extract -a $MIRROR_AUTH \
  --idms-file=$IDMS \
  --command=openshift-install \
  $RELEASE

oc adm release extract -a $MIRROR_AUTH \
  --idms-file=$IDMS \
  --command=oc \
  $RELEASE

./openshift-install version
./oc version --client
```

Why this matters:

- **The release image is built into the binary.** `openshift-install`
  installs the release it was extracted from. Extracted from the mirror, its
  default release image is the **mirror's** pullspec. Check this in the
  output of `./openshift-install version`:

  ```
  ./openshift-install 4.22.10
  ...
  release image mirror.example.com:8443/openshift/release-images@sha256:...
  ```

  If this line says `quay.io/...`, you are using a downloaded installer, not
  the extracted one. The ISO would then try to pull the release from quay.io.
- **`--idms-file` lets `oc` find the installer inside the mirror.** The
  payload refers to the installer image by its quay.io name. Without the IDMS,
  `oc` tries quay.io. On a host without internet access that fails. On a host
  with internet access it succeeds silently and gives you an installer you
  did not take from your mirror.
- **`--command=oc`** gives you a client that exactly matches the release.
  Step 14 puts it on `PATH` for the ISO build.

`oc adm release extract` takes **one** `--idms-file`. Use the file that maps
`quay.io/openshift-release-dev` (Step 6).

### Step 11 - Turn the IDMS into imageDigestSources

`install-config.yaml` describes source-to-mirror mappings in its
`imageDigestSources` key, in the same form as the IDMS. For the install, it
needs **only the release payload's mappings**, the sources under
`quay.io/openshift-release-dev/`. Those are all the cluster pulls until it is
up. The **operator** mappings (and any other mirrored images) are left for
day 2, where they arrive with `oc mirror`'s own IDMS and ITMS and the
CatalogSources that use them (Step 18).

Generate the release mappings **from the IDMS** instead of typing them, so the
two cannot drift apart. The filter goes by source, not by file, because
`oc mirror` can write the release and operator mappings into one combined
file:

```bash
python3 - $(grep -lE '^\s*kind:\s*ImageDigestMirrorSet' $CR/*) \
  > ~/idms-sources.yaml <<'EOF'
import sys, yaml
RELEASE = 'quay.io/openshift-release-dev/'
out = []
for path in sys.argv[1:]:
    for doc in yaml.safe_load_all(open(path)):
        if doc and doc.get('kind') == 'ImageDigestMirrorSet':
            for m in doc['spec']['imageDigestMirrors']:
                if not m['source'].startswith(RELEASE):
                    continue                      # operators etc.: day 2
                entry = {'mirrors': m['mirrors'], 'source': m['source']}
                if entry not in out:
                    out.append(entry)
if not out:
    sys.exit('no quay.io/openshift-release-dev mappings found - is the release mirrored?')
print(yaml.safe_dump({'imageDigestSources': out}, default_flow_style=False, sort_keys=False), end='')
EOF
cat ~/idms-sources.yaml
```

For a release mirrored with `oc mirror` v2 to the root of the registry, the
result looks like this:

```yaml
imageDigestSources:
- mirrors:
  - mirror.example.com:8443/openshift/release
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
- mirrors:
  - mirror.example.com:8443/openshift/release-images
  source: quay.io/openshift-release-dev/ocp-release
```

Both entries are required: `ocp-release` is the release image itself, and
`ocp-v4.0-art-dev` holds every component image. Nothing else belongs here. The
script skips every other source (for example `registry.redhat.io/...` for
operators). It also drops IDMS-only fields such as `mirrorSourcePolicy`, which
`install-config.yaml` does not accept.

### Step 12 - Write install-config.yaml

**The pull secret needs only the mirror's credentials.** Reduce the auth file
to that one entry:

```bash
jq -c --arg r "$MIRROR" '{auths: {($r): .auths[$r]}}' $MIRROR_AUTH > ~/pull-secret-mirror.json
jq -e --arg r "$MIRROR" '.auths[$r].auth' ~/pull-secret-mirror.json >/dev/null && echo OK
```

If your mirror's auth file has no entry for `$MIRROR` (`jq` prints `null`),
create one from the registry user and password:

```bash
printf '{"auths":{"%s":{"auth":"%s"}}}' "$MIRROR" "$(printf '%s' 'user:password' | base64 -w0)" > ~/pull-secret-mirror.json
```

Do not add your quay.io or registry.redhat.io credentials. With
`imageDigestSources`, the cluster pulls everything from the mirror and never
needs them. Leaving them out means a missing mirror entry fails clearly, and
the cluster cannot quietly pull from the internet if a route exists.

Then write the file:

```bash
cat > $WORK/install-config.yaml <<EOF
apiVersion: v1
baseDomain: $DOMAIN
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 3
metadata:
  name: $CLUSTER
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: $MACHINE_NET
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  baremetal:
    apiVIPs:
    - $API_VIP
    ingressVIPs:
    - $INGRESS_VIP
    provisioningNetwork: Disabled
pullSecret: $(jq -c . ~/pull-secret-mirror.json | jq -R .)
sshKey: '$(cat ~/.ssh/compact.pub)'
$(cat ~/idms-sources.yaml)
additionalTrustBundlePolicy: Always
additionalTrustBundle: |
$(sed 's/^/  /' $MIRROR_CA)
EOF

python3 -c "import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print(len(c['imageDigestSources']), 'mirror entries; CA lines:', len(c['additionalTrustBundle'].splitlines()))" $WORK/install-config.yaml
```

What the cluster settings do:

- **`compute: 0` with `controlPlane: 3`** makes this a compact cluster: the
  agent installer builds three masters and makes them schedulable.
- **`platform: baremetal`** needs only the two VIPs. The agent ISO installs
  the servers, so you do not list BMC addresses or credentials here.
  `provisioningNetwork: Disabled` means there is no separate provisioning
  network.
- **`machineNetwork`** must contain every node address **and** both VIPs.
- Change **`clusterNetwork`** and **`serviceNetwork`** if `10.128.0.0/14` or
  `172.30.0.0/16` is already used in your network. Pods cannot reach an
  outside network that overlaps one of these ranges, and that includes the
  mirror registry.

What the mirror settings do:

- **`pullSecret`** holds only the mirror's credentials. `jq -R .` writes the
  JSON as one quoted YAML string, so no character in the credentials can
  break the file.
- **`imageDigestSources`** (from Step 11) is what makes the install use the
  mirror. The installer uses it when it builds the ISO, writes it into the
  ISO's `/etc/containers/registries.conf` for the agent, and turns it into the
  cluster's own `ImageDigestMirrorSet`, which configures the nodes after the
  install.
- **`additionalTrustBundle`** is the mirror's CA. It is added to the trust
  store of every node, so CRI-O can pull from the mirror over TLS. The ISO
  gets it too.
- **`additionalTrustBundlePolicy: Always`** also adds the CA to the
  cluster-wide trusted CA bundle, for pods that talk to the registry
  themselves. The default (`Proxyonly`) adds it there only when a proxy is
  configured.

Do **not** copy `oc mirror`'s IDMS into the `$WORK/openshift/` extra-manifests
directory (Step 14) as well. The installer already creates an
`ImageDigestMirrorSet` from `imageDigestSources`. A second copy of the same
mirrors has to match it exactly, or the nodes fail their first configuration
check. The IDMS, ITMS and CatalogSources go on the cluster on day 2 (Step 18).

### Step 13 - Write agent-config.yaml with the bonds

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
  - `bond0`, `type: bond`, `mode: 802.3ad` (LACP, mode 4), with both ports
    and the static IP **on the bond**.
  - `miimon: "100"` checks the link every 100 ms, so a port whose link goes
    down leaves the bond at once instead of after the LACP timeout.
  - `lacp_rate: fast` sends and expects an LACP packet every second, so a
    port whose link stays up but whose partner stops answering leaves the
    bond after about 3 seconds. Set the same rate on the switch (Step 2).
  - `xmit_hash_policy: layer3+4` chooses the port for each flow from its IP
    addresses and ports, which spreads traffic across both ports better than
    the default (`layer2`, MAC addresses only). A single flow still uses only
    one port, so one TCP connection never goes faster than one link.
  - `mac-address` on the bond is fixed to **port 1's MAC**. In an LACP bond
    both ports send with the bond's MAC, and LACP uses it as the server's
    system ID. Without this setting the bond takes the MAC of whichever port
    joins first, which can change between boots. Your switch tables, DHCP
    snooping and ARP caches then always see one MAC for this address.
  - Both ports are listed as `type: ethernet` with no IP of their own.
  - The default route uses `next-hop-interface: bond0`, so it survives the
    loss of either port.
- **`additionalNTPSources`** (once for the cluster) gives every node a time
  source from the first boot. This matters even more without internet
  access: the agent does not install a host whose clock is not synced, and
  the servers cannot reach a public NTP pool.

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
            mode: 802.3ad
            options:
              miimon: "100"
              lacp_rate: fast
              xmit_hash_policy: layer3+4
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
            mode: 802.3ad
            options:
              miimon: "100"
              lacp_rate: fast
              xmit_hash_policy: layer3+4
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

### Step 14 - Build the agent ISO

**Extra manifest.** The agent installer applies everything in
`$WORK/openshift/` during the install. One manifest goes there: it turns off
the default OperatorHub catalogs. They point at registry.redhat.io, which the
servers cannot reach, so without it their pods would fail to pull from the
first boot until day 2. All of `oc mirror`'s own resources go on in Step 18.

```bash
mkdir -p $WORK/openshift
cat > $WORK/openshift/operatorhub-disable-default-sources.yaml <<'EOF'
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
EOF
ls $WORK/openshift
```

**Keep a copy of both config files.** The build deletes them:

```bash
mkdir -p $WORK/rendered && cp $WORK/install-config.yaml $WORK/agent-config.yaml $WORK/rendered/
```

Then build the ISO with the **extracted** installer and `oc`:

```bash
cd $WORK
PATH=$WORK:$PATH ./openshift-install --dir $WORK agent create image --log-level=debug 2>&1 | tee $WORK/create-image.log
ls -lh $WORK/agent.x86_64.iso
```

The installer checks each host's `networkConfig` with `nmstatectl` at this
point. A mistake in the bond config fails here, before you touch a server:
for example, a port in `port:` that is not listed under `interfaces:`, a
misspelt mode, or a wrong indent.

The ISO is about 1 GB. It contains the configuration for all three servers.

**There is no `--idms` flag on this command, and it does not need one.**
`openshift-install agent create image` takes the mirror configuration from
`install-config.yaml`:

1. **For its own pulls.** To build the ISO, the installer pulls the RHCOS
   base ISO and some agent files out of the release payload. It does this by
   running `oc` (`oc adm release info` and `oc image extract`). It turns
   `imageDigestSources` into a temporary mirror file and passes it to those
   `oc` commands as `--icsp-file`. This is the same job `--idms-file` did
   for you in Step 10, done automatically. It authenticates with the
   `pullSecret`.
2. **For the servers.** It writes the same mirrors into the ISO as
   `/etc/containers/registries.conf`, and the CA from `additionalTrustBundle`
   into the ISO's trust store. The agent on each server then pulls the release
   from the mirror.

With `--log-level=debug`, you can see this in the log:

```bash
grep -iE 'mirror|icsp|release image' $WORK/create-image.log | head
```

That is why the `oc` from Step 10 must be first on `PATH`. If `oc` is missing,
the installer cannot apply the mirror configuration for these pulls.

### Step 15 - Boot the three servers from the ISO

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
`PATH=$WORK:$PATH ./openshift-install --dir $WORK agent create pxe-files`.
You serve the kernel, initrd and rootfs from your own PXE/iPXE
infrastructure. Use this only if that infrastructure is already in place, and
boot the servers through PXE only for the first boot. PXE runs before the bond
exists, so it needs the individual fallback on the port-channels (Step 2).

#### What you should see

Each server boots RHCOS from the ISO and shows a login prompt on the console.
Within a few minutes it should answer `ping` on its own address. If a server
boots but never gets its address, the agent did not find any of its MACs in
`agent-config.yaml`, so it applied no network config. Go back to Step 3.

On the switches, the server's port-channel should now be up with both
members bundled (`show port-channel summary` on NX-OS shows `(P)` for each
member). A member that stays individual or suspended is not receiving LACP
from the server, or is in the wrong port-channel.

Once the rendezvous host is up on the ISO, check that it uses the mirror
before you wait for the whole install:

```bash
ssh -i ~/.ssh/compact core@$RENDEZVOUS "
  grep -c 'location = \"$MIRROR' /etc/containers/registries.conf                      # mirrors are configured
  curl -s -o /dev/null -w 'mirror: %{http_code}\n' https://$MIRROR/v2/                 # 200 or 401, not a TLS error
  curl -s -m 5 -o /dev/null -w 'quay:   %{http_code}\n' https://quay.io/ || echo 'quay:   unreachable'   # expected
  chronyc -n sources | grep '^\^\*'                                                   # synced to your NTP server
"
```

### Step 16 - Watch the install

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

Every image in these steps comes from the mirror.

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
- If the agent reports that it cannot pull the release image, the problem is
  between the servers and the mirror: DNS for the mirror's name, the CA, the
  credentials or a firewall. See [Troubleshooting](#troubleshooting).

### Step 17 - Verify the cluster, the bonds and the mirror

```bash
export KUBECONFIG=$WORK/auth/kubeconfig
alias oc=$WORK/oc

oc get nodes -o wide        # three nodes, ROLES control-plane,master,worker
oc get clusteroperators     # all Available=True, Degraded=False
oc get clusterversion
```

**The bonds.** Check the bond on every server:

```bash
while read -r name ip _; do
  echo "== $name ($ip)"
  ssh -n -i ~/.ssh/compact core@$ip \
    "grep -E 'Bonding Mode|Transmit Hash|LACP rate|Number of ports|Partner Mac|Slave Interface|MII Status|Aggregator ID' /proc/net/bonding/bond0"
done < ~/compact-nodes.txt
```

For each server you should see:

```
Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
LACP rate: fast
	Aggregator ID: 1
	Number of ports: 2
	Partner Mac Address: 00:de:fb:00:00:01
Slave Interface: ens1f0
MII Status: up
Aggregator ID: 1
Slave Interface: ens2f0
MII Status: up
Aggregator ID: 1
```

Check three things on every server:

- **`Number of ports: 2`**, and both ports show the **same `Aggregator ID`**
  as the active aggregator. Both ports are then in one LACP bundle with the
  switch.
- **`Partner Mac Address` is not `00:00:00:00:00:00`.** All zeros means the
  switch is not answering with LACP: the port-channel is missing, in `mode on`,
  or on the wrong ports.
- Both ports show **`MII Status: up`**.

If the two ports show **different** aggregator IDs, the server sees two
different LACP partners. This usually means the two switches are not
configured as one MLAG / vPC pair for this port-channel. The bond then uses
only one of the ports. Fix it **now**, not when the working port fails.

The same information from inside the cluster:

```bash
oc debug node/master1 -- chroot /host nmcli -f NAME,TYPE,DEVICE con show --active
oc debug node/master1 -- chroot /host ovs-vsctl list-ports br-ex      # shows bond0
oc debug node/master1 -- chroot /host ip -br addr show br-ex          # the node IP
```

After the install, the node IP is on **`br-ex`**, not on `bond0`. On the first
boot, OVN-Kubernetes moves the address from the interface that holds the
default route (`bond0`) onto the `br-ex` bridge, and adds `bond0` as the
bridge's uplink. `bond0` still balances traffic and handles port failures
underneath it.

Check which master holds each VIP:

```bash
while read -r name ip _; do
  ssh -n -i ~/.ssh/compact core@$ip "ip -br addr | grep -E '$API_VIP|$INGRESS_VIP'" && echo "  ^ on $name"
done < ~/compact-nodes.txt
```

**The mirror.** Check that the cluster pulls from it:

```bash
# The cluster's release image is the mirror's
oc get clusterversion version -o jsonpath='{.status.desired.image}{"\n"}'

# The ImageDigestMirrorSet the installer created from imageDigestSources
oc get imagedigestmirrorset
oc get imagedigestmirrorset -o yaml | grep -E 'source:|- ' | head -20

# The nodes pull through the mirror
oc debug node/master1 -- chroot /host grep -c "location = \"$MIRROR" /etc/containers/registries.conf
```

Log in to the console:

```bash
cat $WORK/auth/kubeadmin-password
echo https://console-openshift-console.apps.$ZONE
```

### Step 18 - Day 2: catalogs, tag mirrors and signatures

First make sure the default OperatorHub catalogs are off. The Step 14
manifest already did this, but the patch is safe to run again, and it covers
a cluster installed without that manifest:

```bash
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}{"\n"}'   # true
```

Then apply everything `oc mirror` produced in one go, the way `oc mirror`
documents it:

```bash
ls $CR
oc apply -f $CR/ --dry-run=server     # check first
oc apply -f $CR/
sleep 90                              # let the MCO render the new configuration
oc get machineconfigpool -w           # wait until master is UPDATED=True, UPDATING=False
```

This applies:

- the **ImageDigestMirrorSet**: the operator images' digest mappings (the
  install had only the release's, Step 11)
- the **ImageTagMirrorSet**: lets the nodes pull images referenced by tag
- the **CatalogSources**: replace the default OperatorHub catalogs that
  Step 14 turned off
- the **release signature ConfigMap**: needed to upgrade the cluster from the
  mirror

This is where the cluster first learns the operator mirrors, so do not
install operators before this step.

`oc mirror` writes some resources as both `.json` and `.yaml`. Applying both
is harmless, because they describe the same object. The release mappings in
`oc mirror`'s IDMS repeat the ones the installer already created, which is
also harmless.

The mirror sets are a node configuration change: **the three masters reboot
one at a time**. Applying everything at once makes it a single round. The
cluster stays available, but expect the API to drop briefly while each
master reboots.

### Step 19 - Test bond failover

Run this test on each server before you put workloads on the cluster. A
cabling, VLAN or port-channel mistake on one port can stay hidden while the
other port carries the traffic.

In a second terminal, keep pinging the server and the API VIP:

```bash
ping 10.20.30.11
ping $API_VIP
```

Then fail **port 1**. The realistic way is on the switch. Shut down the member
port that master1's port 1 is cabled to:

```
interface Ethernet1/11
  shutdown
```

You can also pull the cable. Or, if you cannot reach the switch, take the link
down on the server itself. This tests the bond, but not the switch path:

```bash
ssh -i ~/.ssh/compact core@10.20.30.11 'sudo ip link set ens1f0 down'
```

Check that the bond now runs on port 2 alone:

```bash
ssh -i ~/.ssh/compact core@10.20.30.11 "grep -E 'Number of ports|Slave Interface|MII Status' /proc/net/bonding/bond0"
# Number of ports: 1
# Slave Interface: ens1f0 / MII Status: down
# Slave Interface: ens2f0 / MII Status: up
```

Expect no lost pings, or only one or two. The flows that were hashed to
port 1 move to port 2 as soon as miimon sees the link go down (within
100 ms). Flows already on port 2 are not affected.

Restore the port (`no shutdown` on the switch, or
`sudo ip link set ens1f0 up` on the server). Within a few seconds, LACP adds
it back to the bundle, and `Number of ports` returns to 2.

Then fail **port 2** in the same way and check that the bond runs on port 1
alone. Restore it, and repeat both tests on master2 and master3.

If the ports go to an MLAG / vPC pair, also test the loss of a **whole
switch**, in a maintenance window: reload switch B, or shut down all of its
member ports. All three servers should continue on their switch-A ports, and
return to two ports each when switch B is back.

### Step 20 - After the install

- **Eject the virtual media** in each BMC, and remove any USB sticks. The
  one-time boot override has already been used, but a mounted ISO is a risk if
  someone changes the boot order later.
- **Back up `$WORK/auth/`.** `kubeconfig` and `kubeadmin-password` are the
  only admin credentials until you configure an identity provider. Also keep
  `$WORK/rendered/`: it is the only record of the exact configuration used.
- **Stop the HTTP server** from Step 15, if you used one (`kill %1`).
- **Keep the mirror registry running.** The cluster pulls every image from it
  for its whole life: when a pod is rescheduled, when a node reboots, and for
  upgrades. To upgrade, mirror the new release with `oc mirror` and apply its
  new output as in Step 18.
- **Reinstall a server or the whole cluster:** build a new ISO (Steps 10-14)
  and boot the servers from it again (Step 15). The agent overwrites the disk
  selected by `rootDeviceHints`. If a server still boots its old RHCOS from
  the disk, wipe the disk first from a live environment
  (`wipefs -a /dev/disk/by-id/wwn-...`), or use a one-time boot as in Step 15.
- **Decommission:** power off the servers, wipe their disks, and remove the
  DNS records from Step 8.

---

## Troubleshooting

### Mirror and disconnected install

| Symptom | Likely cause | Check |
|---|---|---|
| `oc adm release extract` fails with `unknown flag: --idms-file` | `oc` is older than 4.13 | Use a newer `oc` (Step 5), or use `--icsp-file` with an ImageContentSourcePolicy |
| `oc adm release extract` fails to find the installer image, or tries quay.io | `--idms-file` is missing, or it is the operator IDMS and not the release IDMS | Pass the file whose sources include `quay.io/openshift-release-dev` (Step 6) |
| `x509: certificate signed by unknown authority` on the installer host | The mirror's CA is not trusted on the installer host | Step 5: add it to `/etc/pki/ca-trust/source/anchors/` and run `update-ca-trust` |
| `openshift-install version` shows a `quay.io` release image | You are using a downloaded installer, not the one extracted from the mirror | Use `$WORK/openshift-install` from Step 10 |
| `agent create image` fails with `Failed to extract base ISO from release payload` | The installer could not pull from the mirror: no `oc` on `PATH`, missing `imageDigestSources`, or a pull secret without the mirror entry | Read `create-image.log` (debug). Check `which oc` with `PATH=$WORK:$PATH`, the `imageDigestSources` in `rendered/install-config.yaml`, and `jq '.auths' ~/pull-secret-mirror.json`. |
| `agent create image` warns `Using older version of "oc" that does not support mirroring` | The `oc` on `PATH` is too old for the installer's mirror handling | Put the `oc` extracted in Step 10 first on `PATH` |
| `install-config.yaml` fails to parse, or the pull secret is rejected | The pull secret broke the YAML quoting, or `additionalTrustBundle` is not indented | Write `pullSecret` with `jq -R .` and indent the CA as in Step 12. Run the `python3` check from Step 12. |
| A host stays *Insufficient*: `Host couldn't synchronize with any NTP server` | The servers cannot reach the NTP server in `additionalNTPSources` | On the node: `chronyc -n sources`. Check the NTP server and any firewall between them. Fix a badly wrong RTC in the BIOS. |
| The agent's validation fails on DNS (`api` or the mirror's name does not resolve) | The resolver in `networkConfig` cannot answer the cluster names or the mirror registry's name | `dig @$DNS1 api.$ZONE` and `dig @$DNS1 ${MIRROR%%:*}` from the node network (Step 8) |
| The agent reports it cannot pull the release image | The servers cannot reach the mirror: DNS for the mirror's name, the CA, the credentials or a firewall | On a node: `getent hosts <mirror host>`, `curl -v https://$MIRROR/v2/`, and `/etc/containers/registries.conf` |
| Pods are stuck in `ImagePullBackOff` for an image under `quay.io/...` or `registry.redhat.io/...` | That image is not in the mirror, or it is pulled by tag and only an IDMS (digest) mapping exists | Mirror the image. For tag pulls, apply `oc mirror`'s ImageTagMirrorSet (Step 18). |
| An operator's pods are in `ImagePullBackOff` for `registry.redhat.io/...` right after the install | The operator mappings are added only on day 2 | Apply Step 18 before installing operators. `oc get imagedigestmirrorset` should list `oc mirror`'s IDMS. |
| OperatorHub shows no operators, or catalog pods fail to pull | The default catalogs are still enabled (Step 14, or the `oc patch OperatorHub` in Step 18), or the mirrored CatalogSources are not applied (Step 18) | `oc get operatorhub cluster -o yaml`, `oc get catalogsource -n openshift-marketplace` |
| Nodes report `rendered-master-... do not match` on first boot | An IDMS was also placed in `$WORK/openshift/` and does not match the one from `imageDigestSources` | Remove the extra manifest and rebuild the ISO (Step 14) |
| `oc adm upgrade` refuses an update with a signature error | The release signature ConfigMap from `oc mirror` is missing | Apply `oc mirror`'s output (Step 18): `oc apply -f $CR/` |

### Hardware, LACP and boot

| Symptom | Likely cause | Check |
|---|---|---|
| `agent create image` fails with `failed to validate network yaml for host N` | `nmstatectl` is missing on the installer host, or the bond YAML is invalid | `which nmstatectl`. Check the indentation of `link-aggregation`. Every name under `port:` must also be listed under `interfaces:`. |
| A server boots the ISO but never gets its address or never registers | None of its MACs are in `agent-config.yaml`: a typo, an uppercase MAC, or a MAC read from the wrong port | Compare `ethtool -P <port>` (from a live environment) with `rendered/agent-config.yaml` |
| The bond comes up but the server cannot reach the gateway | Wrong VLAN on the switch ports, or the ports are tagged and the config expects untagged traffic (or the other way round) | Switch port config. See the [VLAN variant](#if-the-node-network-is-a-tagged-vlan). |
| `Partner Mac Address: 00:00:00:00:00:00` in `/proc/net/bonding/bond0` | The switch is not running LACP on these ports: no port-channel, a static `mode on` port-channel, or the wrong ports in the channel | `show port-channel summary` / `show lacp neighbor`. Members must use `channel-group <n> mode active` (or passive). |
| The two ports show different `Aggregator ID`s, and `Number of ports: 1` | The server sees two LACP partners: the two switches are not one MLAG / vPC pair for this port-channel, or the vPC/MLAG IDs differ | `show vpc` (or the MLAG equivalent). Use the same port-channel and vPC/MLAG ID on both switches. |
| Some flows or hosts work and others do not | One member port is in the wrong VLAN, or the MLAG / vPC peer link does not carry the node VLAN. Flows hashed to that port fail. | Test each port alone (Step 19). Check the VLAN on both members and on the peer link. |
| Switch logs show the bond MAC flapping between ports, or the member ports are suspended | The switch ports are not in a port-channel while the server bonds them, or the members are in two separate port-channels | Put both members of each server in one port-channel (one vPC/MLAG ID across both switches) |
| PXE or a live environment has no network, but the agent ISO works | The port-channel suspends ports that send no LACP (`lacp suspend-individual`) | Enable the individual fallback from Step 2 |
| Ports are blocked for 30+ seconds after every reboot | Spanning tree is running on the port-channel without edge/portfast | Enable `spanning-tree port type edge` (or portfast) on all three port-channels |
| A port with a working link but a broken path stays in the bond for about 90 seconds | `lacp_rate` is slow on the server or the switch | Set `lacp_rate: fast` (Step 13) and `lacp rate fast` on the member ports (Step 2) |
| All traffic uses one port | `xmit_hash_policy` is `layer2` and most traffic goes to one MAC (the gateway), or a test uses a single flow | Check `Transmit Hash Policy` in `/proc/net/bonding/bond0`. A single TCP flow always uses one port. |
| The install fails with certificate errors | A server's clock is wrong | Fix the RTC in the BIOS. Check from the node with `chronyc sources`. |
| RHCOS is installed on the wrong disk | The `rootDeviceHints` WWN is wrong, or a non-unique hint matched another disk | `lsblk -d -o NAME,WWN,SERIAL` on the server. Use `wwn` or `serialNumber`. |
| A server boots back into the agent after it was installed | CD/virtual media or PXE comes before the disk in the boot order | Step 4: disk first. Use one-time boot overrides for the ISO. |
| A server boots an old operating system after the install | Another disk with a bootable OS comes first in the UEFI boot order | Remove the old boot entry, or wipe that disk |
| `wait-for` cannot connect to the API | `api.$ZONE` does not resolve to the API VIP from the installer host, or a firewall blocks 6443 | `dig api.$ZONE` and `curl -k https://api.$ZONE:6443/version` |
| Ingress and console operators are degraded | `*.apps` does not resolve to the ingress VIP, or something else on the network uses the ingress VIP | `dig x.apps.$ZONE`. Check that only one MAC answers ARP for the ingress VIP. |
| Failover works but takes many seconds | `miimon` is 0, so the bond waits for the LACP timeout | `grep 'MII Polling' /proc/net/bonding/bond0` must not be 0 |
| The bond comes up with a different MAC on each reboot | `mac-address` is missing on `bond0` | Pin it to port 1's MAC, as in Step 13 |
