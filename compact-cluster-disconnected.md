# Disconnected three-node compact cluster in the lab (agent-based installer)

This guide builds **`compactd`**: a three-node compact OpenShift cluster on the
lab hypervisor, installed **only from the lab's mirror registry**. The cluster
is the same as [compact-cluster.md](compact-cluster.md): one agent ISO, three
schedulable masters, `platform: baremetal` with two VIPs, and every node's
address on an **active-backup (mode 1) bond** over two NICs. Four things are
different:

1. **The mirror registry comes first.** `setup_mirror_registry.yaml` builds the
   registry VM, mirrors the release and operators with `oc mirror`, and trusts
   the registry's CA and credentials on the hypervisor.
2. **`openshift-install` is extracted from the mirrored release** with
   `oc adm release extract --idms-file=...`. `install-config.yaml` carries the
   mirror as `imageDigestSources`, plus the mirror's CA and a pull secret
   for the mirror only.
3. **iptables rules cut the nodes' egress** past the lab subnet before they
   boot, the same way as for the disconnected hub (hubd). A fallback to
   quay.io fails instead of quietly succeeding.
4. **The hypervisor serves NTP.** The agent does not install a host whose
   clock is not synced, and the nodes cannot reach the public NTP pool.

`compactd` has its own addresses, folders and DNS zone. It can run beside
the connected `compact` cluster.

The whole flow is automated by `setup_compact_cluster_disconnected.yaml`. It
uses the same `roles/setup-compact-cluster` role as the connected cluster, with
`compact_disconnected: true`. This guide walks through the same steps by hand.
Each step names the role file that automates it.

- [What you get](#what-you-get)
- [The automated path](#the-automated-path)
- [Manual deployment](#manual-deployment)
  1. [Prerequisites](#step-1---prerequisites)
  2. [Build the mirror registry](#step-2---build-the-mirror-registry)
  3. [Set the shell variables](#step-3---set-the-shell-variables)
  4. [DNS](#step-4---dns)
  5. [Block the nodes' egress to the internet](#step-5---block-the-nodes-egress-to-the-internet)
  6. [Serve NTP from the hypervisor](#step-6---serve-ntp-from-the-hypervisor)
  7. [Get oc and the oc-mirror output](#step-7---get-oc-and-the-oc-mirror-output)
  8. [Extract openshift-install from the mirror](#step-8---extract-openshift-install-from-the-mirror)
  9. [Write install-config.yaml](#step-9---write-install-configyaml)
  10. [Write agent-config.yaml and the extra manifests](#step-10---write-agent-configyaml-and-the-extra-manifests)
  11. [Build the agent ISO](#step-11---build-the-agent-iso)
  12. [Create the three VMs](#step-12---create-the-three-vms)
  13. [Watch the install and check it is really disconnected](#step-13---watch-the-install-and-check-it-is-really-disconnected)
  14. [Day 2: mirror sets and catalogs](#step-14---day-2-mirror-sets-and-catalogs)
  15. [Add LVM Storage](#step-15---add-lvm-storage)
  16. [Clean up](#step-16---clean-up)
- [Troubleshooting](#troubleshooting)

---

## What you get

| What | Value | Where it is set |
|---|---|---|
| Cluster name / zone | `compactd` / `compactd.mylab.com` | `compactd_name` in `vars.yaml` |
| master1 (rendezvous host) | `192.168.122.3` | `ip_list.compactd_master1` |
| master2 | `192.168.122.4` | `ip_list.compactd_master2` |
| master3 | `192.168.122.5` | `ip_list.compactd_master3` |
| API VIP: `api`, `api-int` | `192.168.122.6` | `ip_list.compactd_api` |
| Ingress VIP: `*.apps` | `192.168.122.7` | `ip_list.compactd_ingress` |
| Bond | `bond0`, `active-backup`, `miimon=100`, `primary=enp1s0` | role defaults, as for `compact` |
| Bond port 1 / port 2 MACs | `52:54:00:e2:54:0N` / `52:54:00:e2:56:0N` (N = 3, 4, 5) | `compact_*_mac_prefix` |
| Mirror registry | `registry.hub.mylab.com:8443` (`192.168.122.22`) | `mirror_registry_domain`, `ip_list.registry` |
| Mirrored release | `registry.hub.mylab.com:8443/openshift/release-images:<version>-x86_64` | `mirror_release_repository`, `mirror_ocp_version` |
| NTP server for the nodes | `192.168.122.1` (the hypervisor) | `compact_ntp_server` |
| Storage disk per node | 100 GB, empty (`vdb`), for LVM Storage | `compact_storage_disk_gb`, `compact_lvm_storage` |
| Default StorageClass | `lvms-vg1` (LVM Storage), from the mirrored catalog | `roles/setup-lvm-storage`, `use_lvm_storage` in `vars.yaml` |
| Egress block | `LAB_NO_NAT` (nat) and `LAB_NO_EGRESS` (filter) chains | shared with hubd |

**Why `.3`-`.7`.** All but one of the free two-digit octets are now in use.
`.2`-`.9` are free and sit below both DHCP ranges (dhcpd `.100`-`.200`,
libvirt `.201`-`.249`) and outside every MetalLB pool. The lab builds each MAC
from the octet, so a single digit is **zero-padded**: `.3` becomes
`52:54:00:e2:54:03`. The role and libvirt's DHCP reservations both pad this
way. Every two-digit octet renders exactly as before.

---

## The automated path

```bash
# 1. DNS for compactd (zone on the helper, /etc/hosts here)
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns --ask-vault-pass

# 2. Mirror registry, then the cluster, then day 2
ansible-playbook -i inventory/hosts setup_compact_cluster_disconnected.yaml \
  -e disconnected_install=true --ask-vault-pass
```

`-e disconnected_install=true` is required because `setup_mirror_registry.yaml`
refuses to run without it. It affects only this run. `vars.yaml` keeps the lab
connected.

| Tag | What it does | File |
|---|---|---|
| (no tags) | Mirror registry, then everything below | `setup_mirror_registry.yaml` + the role |
| `compact` | The cluster only. Skips the mirror registry. | the role |
| `compactimage` | Fetches the `oc mirror` output, extracts `openshift-install` from the mirror, renders the manifests, builds the ISO | `tasks/image.yml`, `tasks/mirror.yml` |
| `compactvm` | Egress block and NTP server, then the three VMs | `tasks/vm.yml`, `tasks/ntp-server.yml`, hubd's `block-node-nat.yml` |
| `compactwait` | Waits for bootstrap and install-complete, checks the bonds | `tasks/wait.yml` |
| `compactday2` | Applies `oc mirror`'s IDMS/ITMS/CatalogSource and waits for the rolling reboot | `tasks/day2.yml` |
| `compactstorage` | Installs LVM Storage from the mirrored catalog and waits for the `lvms-vg1` StorageClass. Attaches the storage disk to any node built without one. Needs `compactday2` to have run. | `tasks/storage.yml`, `roles/setup-lvm-storage` |

To rebuild, add `-e compact_force_reinstall=true`. To remove the cluster, run
`ansible-playbook -i inventory/hosts cleanup.yaml --tags compactd`.

---

## Manual deployment

Run every step **on the hypervisor as root**, unless the step says otherwise.
The hypervisor keeps its own internet access, as it does for hubd. Only the
cluster's nodes are cut off.

### Step 1 - Prerequisites

*Automated by: `tasks/preflight.yml`*

The same as for the connected cluster
([compact-cluster.md, Step 1](compact-cluster.md#step-1---prerequisites)):
libvirt tooling, `nmstatectl` and the lab ssh key. Add:

```bash
dnf install -y python3-pyyaml jq chrony
```

`vault.yaml` must hold `mirror_registry_password`, `org_id` and
`activation_key`, because the mirror registry VM registers with
subscription-manager. The cluster itself does not use your Red Hat pull secret.
It pulls only from the mirror.

### Step 2 - Build the mirror registry

*Automated by: `setup_mirror_registry.yaml` (roles `setup-mirror-registry-vm`, `setup-rhsm`, `setup-mirror-registry`, `setup-mirror-registry-trust`)*

```bash
ansible-playbook -i inventory/hosts setup_mirror_registry.yaml \
  -e disconnected_install=true --ask-vault-pass
```

This playbook:

1. builds the `registry` VM at `192.168.122.22`
2. installs the mirror registry on it
3. runs `oc mirror --v2` for release `mirror_ocp_version` and the operators in
   `mirror_catalog_operator_packages`. The first run downloads tens of GB.
   A re-run only pulls what is missing.
4. trusts the registry's CA on the hypervisor, in
   `/etc/pki/ca-trust/source/anchors/mirror-registry-rootCA.pem`
5. logs podman in to the registry, writing the credentials to
   `/root/.docker/config.json`

Check the result before you go on:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://registry.hub.mylab.com:8443/v2/      # 200 or 401, not a TLS error
jq -r '.auths | keys[]' /root/.docker/config.json | grep registry.hub.mylab.com:8443
```

### Step 3 - Set the shell variables

```bash
export LAB=192.168.122
export DOMAIN=mylab.com
export CLUSTER=compactd
export ZONE=$CLUSTER.$DOMAIN
export OCP=4.22.10                         # ocp_major_version.ocp_minor_version; must be mirrored
export WORK=/var/lib/libvirt/images/compactd_install
export VMDIR=/var/lib/libvirt/images/compactd

export API_VIP=$LAB.6
export INGRESS_VIP=$LAB.7
export NODES="master1:3 master2:4 master3:5"   # hostname:octet, rendezvous host first
export RENDEZVOUS=$LAB.3

export MAC1=52:54:00:e2:54                     # bond port 1 (enp1s0)
export MAC2=52:54:00:e2:56                     # bond port 2 (enp2s0)

export REGISTRY=registry.hub.mylab.com:8443
export RELEASE=$REGISTRY/openshift/release-images:$OCP-x86_64
export AUTHFILE=/root/.docker/config.json
export MIRROR_CA=/etc/pki/ca-trust/source/anchors/mirror-registry-rootCA.pem
export CR=/tmp/compactd-cluster-resources       # where the oc-mirror output is staged
```

The octets are single digits, so **always zero-pad them in MACs**. In
this guide, `$MAC1:0$oct` does that.

### Step 4 - DNS

*Automated by: `setup_bm_host.yaml --tags dns` (`compact_clusters` in `vars.yaml`)*

The same records as for the connected cluster
([compact-cluster.md, Step 4](compact-cluster.md#step-4---dns)), for zone
`compactd.mylab.com`:

| Name | Address |
|---|---|
| `api`, `api-int` | `192.168.122.6` |
| `*.apps` | `192.168.122.7` |
| `master1`, `master2`, `master3` | `192.168.122.3`, `.4`, `.5` (plus PTRs) |

`setup_bm_host.yaml --tags dns` renders the zone and reverse records on the
helper, and puts `api`/`*.apps` in the hypervisor's `/etc/hosts`.

The nodes use libvirt's dnsmasq (`192.168.122.1`) as their resolver. It
already resolves `registry.hub.mylab.com` through the `hub.mylab.com`
forwarder, which is the one name a disconnected node must resolve. The nodes
do not need any internet names.

```bash
getent hosts api.$ZONE                                  # 192.168.122.6 on the hypervisor
dig +short @$LAB.1 registry.hub.mylab.com               # 192.168.122.22, as the nodes see it
```

### Step 5 - Block the nodes' egress to the internet

*Automated by: `tasks/vm.yml` → `roles/setup-hub-cluster-disconnected/tasks/block-node-nat.yml`*

Do this **before** the VMs boot. Otherwise a node that cannot find an image in
the mirror can fetch it from quay.io instead, and the install succeeds for the
wrong reason.

libvirt gives the lab network internet access by masquerading it (NAT) in its
`LIBVIRT_PRT` chain. Two rules per node take that away:

- **nat `LAB_NO_NAT`:** `ACCEPT`, so packets from the node to anything off
  the lab subnet are never masqueraded.
- **filter `LAB_NO_EGRESS`:** `REJECT`, so those un-NATed packets do not leave
  the hypervisor either. The node gets an immediate error instead of a
  timeout.

Both chains are **our own**, hooked in at the **top** of `POSTROUTING` and
`FORWARD`. If the rules sat inside libvirt's chains, the next
`virsh net-destroy`/`net-start` would move libvirt's own rules above them and
quietly give the nodes their internet back. The hubd role uses the same
chains; see the comments in `block-node-nat.yml` for the details.

```bash
# Our chains (no error if they already exist)
iptables -t nat -N LAB_NO_NAT 2>/dev/null || true
iptables -N LAB_NO_EGRESS 2>/dev/null || true

# Jump to them FIRST, ahead of libvirt's chains
iptables -t nat -C POSTROUTING -j LAB_NO_NAT 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j LAB_NO_NAT
iptables -C FORWARD -j LAB_NO_EGRESS 2>/dev/null || iptables -I FORWARD 1 -j LAB_NO_EGRESS

# One pair of rules per node. Everything on the lab subnet stays reachable:
# the mirror registry, the helper's DNS and the other nodes.
for n in $NODES; do
  host=${n%%:*}; oct=${n##*:}
  iptables -t nat -A LAB_NO_NAT -s $LAB.$oct/32 ! -d $LAB.0/24 \
    -m comment --comment "compactd disconnected: no NAT for compactd_$host" -j ACCEPT
  iptables -A LAB_NO_EGRESS -s $LAB.$oct/32 ! -d $LAB.0/24 \
    -m comment --comment "compactd disconnected: no egress for compactd_$host" \
    -j REJECT --reject-with icmp-admin-prohibited
done
```

Check the order. Our chain must come **before** libvirt's:

```bash
iptables -t nat -L POSTROUTING -n --line-numbers | head -5   # 1  LAB_NO_NAT ... then LIBVIRT_PRT
iptables -L FORWARD -n --line-numbers | head -5              # 1  LAB_NO_EGRESS ... then LIBVIRT_*
iptables -t nat -L LAB_NO_NAT -n | grep compactd
iptables -L LAB_NO_EGRESS -n | grep compactd
```

`iptables -C` finds a rule wherever it is in the chain. If the jump exists but
is **below** `LIBVIRT_PRT` or `LIBVIRT_FW*`, delete it and insert it again at
position 1.

These rules live only in the running ruleset. A hypervisor reboot or an
`iptables -F` removes them. Run them again (or `--tags compactvm`) before you
boot the nodes again.

### Step 6 - Serve NTP from the hypervisor

*Automated by: `tasks/ntp-server.yml`*

The agent checks that each host's clock is synced. A host that "couldn't
synchronize with any NTP server" stays *Insufficient* and is never installed.
RHCOS uses an internet NTP pool by default, which the nodes can no longer
reach. The hypervisor is on the lab network and has good time. Traffic to it
is local, so the egress block does not affect it.

```bash
cat >> /etc/chrony.conf <<EOF
# BEGIN hcp-lab: serve time to $LAB.0/24 (setup-compact-cluster)
allow $LAB.0/24
local stratum 10
# END hcp-lab: serve time to $LAB.0/24 (setup-compact-cluster)
EOF
systemctl restart chronyd && systemctl enable chronyd

# Only if firewalld is running: open NTP in the lab bridge's zone (usually 'libvirt')
if systemctl is-active -q firewalld; then
  zone=$(firewall-cmd --get-zone-of-interface=virbr0)
  firewall-cmd --zone=$zone --add-service=ntp
  firewall-cmd --permanent --zone=$zone --add-service=ntp
fi

ss -lun | grep ':123 '        # chronyd is listening
```

Step 10 gives the nodes `192.168.122.1` as their NTP source.

### Step 7 - Get oc and the oc-mirror output

*Automated by: `tasks/image.yml` (oc) and `tasks/mirror.yml` (staging)*

Start from an **empty** `$WORK`. Back up an old `auth/kubeconfig` first if you
still need it. Then download a version-matched `oc`. The hypervisor is still
connected, and only `oc` is downloaded. `openshift-install` comes from the
mirror in Step 8.

```bash
rm -rf $WORK && mkdir -p $WORK $VMDIR && cd $WORK
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP/openshift-client-linux.tar.gz
tar xzf openshift-client-linux.tar.gz
./oc version --client
./oc adm release extract --help | grep -- --idms-file      # must exist (oc 4.13+)
```

Copy the `oc mirror` output from the registry VM. It contains the
**ImageDigestMirrorSet (IDMS)** that maps each quay.io source to its mirror:

```bash
REMOTE=$(ssh -i ~/.ssh/lab_rsa root@$LAB.22 'find /root/mirror/oc-mirror-output -type d -name cluster-resources | head -1')
echo $REMOTE
rm -rf $CR && mkdir -p $CR
scp -i ~/.ssh/lab_rsa -r root@$LAB.22:$REMOTE/. $CR/
ls $CR

# The IDMS files, the release one (the one that maps quay.io/openshift-release-dev) first
grep -lE '^\s*kind:\s*ImageDigestMirrorSet' $CR/* | xargs grep -l openshift-release-dev
export IDMS=$(grep -lE '^\s*kind:\s*ImageDigestMirrorSet' $CR/* | xargs grep -l openshift-release-dev | head -1)
```

### Step 8 - Extract openshift-install from the mirror

*Automated by: `tasks/mirror.yml`*

First confirm the mirror really has this release. The component pullspecs it
lists still say `quay.io/...`; that is expected, because the IDMS maps them to
the mirror:

```bash
cd $WORK
./oc adm release info -a $AUTHFILE $RELEASE | head -20      # Name: <your version>
```

Then extract the installer:

```bash
./oc adm release extract -a $AUTHFILE \
  --idms-file=$IDMS \
  --command=openshift-install \
  $RELEASE

./openshift-install version
```

The `release image` line of the output must name **the mirror**:

```
release image registry.hub.mylab.com:8443/openshift/release-images@sha256:...
```

Why this matters:

- **The release image is built into the binary.** `openshift-install`
  installs the release it was extracted from. Extracted from the mirror, the
  agent ISO and the cluster use the mirror's release image. A downloaded
  installer would point at quay.io.
- **`--idms-file` is how `oc` finds the installer inside the mirror.**
  `oc mirror` v2 puts the release image in `openshift/release-images` and
  every component image in `openshift/release`. The payload refers to the
  installer image by its quay.io name. Without the IDMS, `oc` looks for it on
  quay.io, not in the mirror.
- `oc adm release extract` takes **one** `--idms-file`: the release one.

### Step 9 - Write install-config.yaml

*Automated by: `templates/install-config.yaml.j2`*

First turn every IDMS into `imageDigestSources`. Generating them from the
IDMS means the two cannot drift apart. The script drops duplicates and the
IDMS-only `mirrorSourcePolicy` field:

```bash
python3 - $(grep -lE '^\s*kind:\s*ImageDigestMirrorSet' $CR/*) > $WORK/idms-sources.yaml <<'EOF'
import sys, yaml
out = []
for path in sys.argv[1:]:
    for doc in yaml.safe_load_all(open(path)):
        if doc and doc.get('kind') == 'ImageDigestMirrorSet':
            for m in doc['spec']['imageDigestMirrors']:
                e = {'mirrors': m['mirrors'], 'source': m['source']}
                if e not in out:
                    out.append(e)
print(yaml.safe_dump({'imageDigestSources': out}, default_flow_style=False, sort_keys=False), end='')
EOF
cat $WORK/idms-sources.yaml
```

Then a pull secret with **only the mirror's credentials**, so the nodes have
no credentials for the real registries:

```bash
jq -c --arg r "$REGISTRY" '{auths: {($r): .auths[$r]}}' $AUTHFILE > $WORK/pull-secret-mirror.json
```

And the file itself:

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
  - cidr: $LAB.0/24
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
$(cat $WORK/idms-sources.yaml)
pullSecret: $(jq -c . $WORK/pull-secret-mirror.json | jq -R .)
sshKey: '$(cat ~/.ssh/lab_rsa.pub)'
additionalTrustBundlePolicy: Always
additionalTrustBundle: |
$(sed 's/^/  /' $MIRROR_CA)
EOF
python3 -c "import yaml; c=yaml.safe_load(open('$WORK/install-config.yaml')); print(len(c['imageDigestSources']), 'mirror entries')"
```

Compared with the connected `install-config.yaml`:

- **`imageDigestSources`** is the only place the mirror is configured for the
  install. The installer uses it for its own pulls while it builds the ISO,
  writes it into the ISO for the agents, and creates the cluster's
  ImageDigestMirrorSet from it.
- **`pullSecret`** holds only the mirror's credentials. `jq -R .` writes the
  JSON as one quoted YAML string, so no character in it can break the file.
- **`additionalTrustBundle`** is the mirror's CA, for the agent ISO and every
  node.
- **`additionalTrustBundlePolicy: Always`** also adds the CA to the
  cluster-wide trusted CA bundle, for pods that talk to the registry
  themselves. The default (`Proxyonly`) adds it there only when a proxy is
  configured.

### Step 10 - Write agent-config.yaml and the extra manifests

*Automated by: `templates/agent-config.yaml.j2` and `tasks/image.yml`*

**`agent-config.yaml`** is the same as for the connected cluster
([compact-cluster.md, Step 7](compact-cluster.md#step-7---write-agent-configyaml-with-the-bonds)),
with the bond on every host. There are two differences:

- **`additionalNTPSources`**, pointing at the hypervisor from Step 6.
- **zero-padded MACs**, because the octets are single digits.

Generate it with this block. It is the connected guide's `host_block`
function with one change: it zero-pads the octet for the MACs itself, so you
pass plain `3`, `4`, `5`. The IP address keeps the plain octet.

```bash
host_block() {   # $1 = hostname, $2 = last octet (3, 4, 5)
local m=$(printf '%02d' "$2")   # MAC byte, zero-padded: 3 -> 03
cat <<EOF
  - hostname: $1
    role: master
    interfaces:
      - name: enp1s0
        macAddress: $MAC1:$m
      - name: enp2s0
        macAddress: $MAC2:$m
    rootDeviceHints:
      deviceName: /dev/vda
    networkConfig:
      interfaces:
        - name: bond0
          type: bond
          state: up
          mac-address: $MAC1:$m
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
          mac-address: $MAC1:$m
          ipv4:
            enabled: false
          ipv6:
            enabled: false
        - name: enp2s0
          type: ethernet
          state: up
          mac-address: $MAC2:$m
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
additionalNTPSources:
  - $LAB.1
hosts:
EOF
for n in $NODES; do host_block ${n%%:*} ${n##*:}; done
} > $WORK/agent-config.yaml

grep -E 'macAddress|mac-address' $WORK/agent-config.yaml | sort -u    # 52:54:00:e2:54:03..05 and 52:54:00:e2:56:03..05
grep -E '^ +- ip:' $WORK/agent-config.yaml                            # 192.168.122.3, .4, .5
```

**Extra manifests.** The agent installer applies everything in
`$WORK/openshift/`. Two things go there:

```bash
mkdir -p $WORK/openshift

# oc mirror's install-time resources: everything EXCEPT the IDMS, ITMS and
# CatalogSources (the release signature ConfigMap, for example). If a resource
# exists as both .json and .yaml, copy only one: two copies of one object make
# the installer refuse the directory.
for f in $CR/*.yaml $CR/*.yml; do
  [ -e "$f" ] || continue
  grep -qE '^\s*kind:\s*(ImageDigestMirrorSet|ImageTagMirrorSet|CatalogSource)\s*$' "$f" || cp "$f" $WORK/openshift/
done

# Turn off the default OperatorHub catalogs: they point at registry.redhat.io,
# which the nodes cannot reach. Written here rather than copied from the repo,
# so it does not depend on which directory you are in.
cat > $WORK/openshift/operatorhub-disable-default-sources.yaml <<'EOF'
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
EOF
ls -l $WORK/openshift      # must list operatorhub-disable-default-sources.yaml
```

The installer reads only `*.yaml` and `*.yml` from `openshift/`. A file that
is not there when you run `agent create image` (Step 11) does not reach the
cluster, and nothing reports it as missing. Step 14 sets the same flag again
on the running cluster in case it did not.

Do **not** put `oc mirror`'s IDMS or ITMS in `openshift/`. The installer
already creates an ImageDigestMirrorSet from `imageDigestSources`. A second
copy of the same mirrors has to match it byte for byte, or the nodes fail
their first configuration check (`rendered-master-... do not match`). They are
applied on day 2 instead (Step 14).

Keep a copy of both files, because the build deletes them:

```bash
mkdir -p $WORK/rendered && cp $WORK/install-config.yaml $WORK/agent-config.yaml $WORK/rendered/
```

### Step 11 - Build the agent ISO

*Automated by: `tasks/image.yml`*

```bash
cd $WORK
PATH=$WORK:$PATH ./openshift-install --dir $WORK agent create image --log-level=debug 2>&1 | tee $WORK/create-image.log
ls -lh $WORK/agent.x86_64.iso && chmod 0644 $WORK/agent.x86_64.iso
```

**There is no `--idms` flag on `openshift-install agent create image`, and it
does not need one.** The installer reads `imageDigestSources` from
`install-config.yaml`:

- **For its own pulls.** To build the ISO, it pulls the RHCOS base ISO out of
  the release payload by running `oc`. It passes `imageDigestSources` to
  those `oc` calls as a temporary `--icsp-file`, which is the same job
  `--idms-file` did in Step 8. It authenticates with the `pullSecret`. This
  is why `$WORK`, with its matching `oc`, must be first on `PATH`.
- **For the nodes.** It writes the mirrors into the ISO's
  `/etc/containers/registries.conf`, and the CA into the ISO's trust store.

### Step 12 - Create the three VMs

*Automated by: `tasks/vm.yml`*

The same as for the connected cluster
([compact-cluster.md, Step 9](compact-cluster.md#step-9---create-the-three-vms-each-with-two-nics)):
a fresh disk for RHCOS, a second **empty disk for LVM Storage**, and **two
NICs on the default network** per node. Use the zero-padded MACs and the
`compactd` names:

```bash
for n in $NODES; do
  host=${n%%:*}; oct=${n##*:}; dom=compactd_$host

  rm -f $VMDIR/${dom}_disk.qcow2 $VMDIR/${dom}_storage.qcow2
  qemu-img create -f qcow2 $VMDIR/${dom}_disk.qcow2 150G
  qemu-img create -f qcow2 -o preallocation=metadata $VMDIR/${dom}_storage.qcow2 100G   # empty, for LVM Storage (Step 15)

  virsh net-dumpxml default | grep -qi "$MAC1:0$oct" || \
    virsh net-update default add ip-dhcp-host \
      "<host mac='$MAC1:0$oct' name='$host.$ZONE' ip='$LAB.$oct'/>" --live --config

  virt-install --import --name $dom --memory 24576 --vcpus 8 --cpu host-passthrough \
    --os-variant=rhel9.4 \
    --disk $VMDIR/${dom}_disk.qcow2,format=qcow2,cache=none,bus=virtio \
    --disk $VMDIR/${dom}_storage.qcow2,format=qcow2,cache=none,bus=virtio \
    --disk $WORK/agent.x86_64.iso,device=cdrom,bus=sata,readonly=on \
    --boot hd,cdrom \
    --network network:default,mac=$MAC1:0$oct,model=virtio \
    --network network:default,mac=$MAC2:0$oct,model=virtio \
    --memballoon model=virtio,freePageReporting=on --noautoconsole
done

for n in $NODES; do virsh domblklist compactd_${n%%:*}; done   # vda (RHCOS) and vdb (storage)
```

**The order of the two disks matters.** The RHCOS disk is listed first, so it
is `vda`. The storage disk is second, so it is `vdb`. `agent-config.yaml` pins
the install to `/dev/vda` with `rootDeviceHints` (Step 10), which keeps the
installer off the storage disk. Without that pin the agent picks a disk by its
own rules, and could install RHCOS on the disk meant for LVM Storage.

### Step 13 - Watch the install and check it is really disconnected

*Automated by: `tasks/wait.yml`*

```bash
cd $WORK
./openshift-install --dir $WORK agent wait-for bootstrap-complete --log-level=info
./openshift-install --dir $WORK agent wait-for install-complete  --log-level=info
```

While the nodes are up on the ISO, check all three things that make this
disconnected:

```bash
ssh -i ~/.ssh/lab_rsa core@$RENDEZVOUS '
  grep -c "location = \"registry.hub.mylab.com" /etc/containers/registries.conf   # mirrors are configured
  curl -s -o /dev/null -w "mirror: %{http_code}\n" https://registry.hub.mylab.com:8443/v2/   # 200/401
  curl -s -m 5 -o /dev/null -w "quay:   %{http_code}\n" https://quay.io/ || echo "quay:   blocked"   # must be blocked
  chronyc -n sources | grep "^\^\*"                                                  # synced to 192.168.122.1
'
```

After the install:

```bash
export KUBECONFIG=$WORK/auth/kubeconfig
alias oc=$WORK/oc
oc get nodes -o wide
oc get clusterversion version -o jsonpath='{.status.desired.image}{"\n"}'   # the mirror's release image
oc get imagedigestmirrorset                                                 # created from imageDigestSources
```

Then check the bonds, as for the connected cluster
([compact-cluster.md, Step 11](compact-cluster.md#step-11---verify-the-cluster-and-the-bonds)).

### Step 14 - Day 2: mirror sets and catalogs

*Automated by: `tasks/day2.yml` (`--tags compactday2`)*

First make sure the default OperatorHub catalogs are off. The Step 10
manifest should already have done this. The patch is safe to run again, and
it fixes a cluster where the manifest did not reach `$WORK/openshift/`:

```bash
oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}{"\n"}'   # want: true
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}{"\n"}'   # true
```

Then apply what was held back from the install: `oc mirror`'s
ImageDigestMirrorSet, ImageTagMirrorSet and CatalogSource. The ITMS lets the
nodes pull images that are referenced by tag. The CatalogSources replace the
default OperatorHub catalogs.

```bash
mkdir -p $CR/day2
for f in $CR/*.yaml $CR/*.yml; do
  [ -e "$f" ] || continue
  grep -qE '^\s*kind:\s*(ImageDigestMirrorSet|ImageTagMirrorSet|CatalogSource)\s*$' "$f" && cp "$f" $CR/day2/
done
oc apply -f $CR/day2/
sleep 90                      # let the MCO render the new configuration
oc get machineconfigpool -w   # wait until master is UPDATED=True, UPDATING=False
```

This is a node configuration change: **the three masters reboot one at a
time**. The cluster stays available, but expect the API to drop briefly while
each master reboots.

### Step 15 - Add LVM Storage

*Automated by: `tasks/storage.yml`, which runs `roles/setup-lvm-storage` (`--tags compactstorage`)*

LVM Storage gives the cluster a default StorageClass, `lvms-vg1`, the same
one the hub and the SNO get. Its `LVMCluster` names no `deviceSelector`, so on
every node it takes **every empty disk** it finds and builds a volume group
and a thin pool on it. On a compact cluster every node is a master and a
worker, so it runs on all three. The RHCOS disk is not empty, so each node
needs the second disk from Step 12.

**Check the storage disk on every node.** It should be there, with no
partitions and no filesystem:

```bash
for n in $NODES; do
  echo "== ${n%%:*}"
  ssh -i ~/.ssh/lab_rsa core@$LAB.${n##*:} 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT /dev/vdb'
done
```

**A cluster built without the storage disk** (before Step 12 created
one) can get it now, with no reinstall and no reboot. Create it and hot-plug
it into each running VM. `--persistent` also adds it to the domain
definition, so it is still there after the next reboot:

```bash
for n in $NODES; do
  dom=compactd_${n%%:*}
  virsh domblklist $dom | grep -q "${dom}_storage.qcow2" && continue
  qemu-img create -f qcow2 -o preallocation=metadata $VMDIR/${dom}_storage.qcow2 100G
  virsh attach-disk $dom $VMDIR/${dom}_storage.qcow2 vdb \
    --driver qemu --subdriver qcow2 --cache none --targetbus virtio --persistent --live
done
```

**Install the operator from the mirrored catalog.** The default
`redhat-operators` catalog is turned off on this cluster. The operator comes
from the CatalogSource that `oc mirror` generated, which Step 14 applied, so
run this step **after** day 2. `lvms-operator` is in the mirror's operator list
(`mirror_catalog_operator_packages` in `vars.yaml`), so the catalog has it:

```bash
oc get catalogsource -n openshift-marketplace
export CATALOG=$(oc get catalogsource -n openshift-marketplace -o name | grep redhat-operator-index | head -1 | cut -d/ -f2)
echo $CATALOG                                                                        # cs-redhat-operator-index-v4-22
oc get packagemanifest lvms-operator -n openshift-marketplace \
  -o jsonpath='{.status.catalogSource}{"\n"}'                                         # the same name

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms
  namespace: openshift-storage
spec:
  installPlanApproval: Automatic
  name: lvms-operator
  source: $CATALOG
  sourceNamespace: openshift-marketplace
EOF

oc -n openshift-storage get csv -w     # wait for lvms-operator.v... PHASE Succeeded, then Ctrl-C
oc wait --for=condition=Established crd/lvmclusters.lvm.topolvm.io --timeout=300s
```

**Create the LVMCluster:**

```bash
oc apply -f - <<'EOF'
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        fstype: xfs
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
          chunkSizeCalculationPolicy: Static
EOF

# Ready once vg-manager has built the volume group on every node (a few minutes)
oc -n openshift-storage get lvmcluster my-lvmcluster -o jsonpath='{.status.state}{"\n"}'   # Ready
oc get storageclass                                                                          # lvms-vg1 (default)
```

Each node now has a volume group `vg1` on `/dev/vdb`:

```bash
oc -n openshift-storage get lvmvolumegroupnodestatus -o wide
oc debug node/master1 -- chroot /host vgs
```

`lvms-vg1` uses `volumeBindingMode: WaitForFirstConsumer`. A new PVC stays
`Pending` until a pod uses it. That is expected: LVM volumes are local to one
node, so the volume is created on whichever node the pod is scheduled to.
LVMS marks `lvms-vg1` as the default class only if no other class is already
the default.

### Step 16 - Clean up

*Automated by: `cleanup.yaml --tags compactd`*

```bash
for n in $NODES; do
  virsh destroy compactd_${n%%:*}  2>/dev/null
  virsh undefine compactd_${n%%:*} 2>/dev/null
done
rm -rf $VMDIR $WORK $CR

# Remove only compactd's iptables rules. hubd may use the same chains.
for t in "nat LAB_NO_NAT" "filter LAB_NO_EGRESS"; do
  set -- $t
  iptables -t $1 -S $2 | grep -- '--comment "compactd disconnected:' | sed 's/^-A /-D /' \
    | while read -r rule; do eval iptables -t $1 $rule; done
done
```

Removing `$VMDIR` deletes the storage disks too. The mirror registry, the
chronyd `allow`, the DNS records and the DHCP reservations are shared lab
infrastructure. Cleanup leaves them in place.

---

## Troubleshooting

For bond and VM problems, see
[compact-cluster.md's troubleshooting](compact-cluster.md#troubleshooting).
These problems are specific to the disconnected install:

| Symptom | Likely cause | Check |
|---|---|---|
| The playbook stops at once: `Pass -e disconnected_install=true` | `setup_mirror_registry.yaml` requires it | Add `-e disconnected_install=true`, or use `--tags compact` if the mirror is already built |
| Pre-flight: `mirror registry CA is not trusted on this host` | The mirror registry has not been built | Step 2 |
| `oc adm release extract` tries `quay.io/...ocp-v4.0-art-dev` | No `--idms-file`, or the operator IDMS instead of the release IDMS | Use the IDMS that maps `quay.io/openshift-release-dev` (Step 7) |
| `oc adm release extract` fails with `unknown flag: --idms-file` | The `oc` in `$WORK` is older than 4.13 | Step 7: download the `oc` for `$OCP` |
| `x509: certificate signed by unknown authority` on the hypervisor | The mirror's CA is not trusted here | Step 2: `setup_mirror_registry.yaml` (its `mirror-trust` tag) |
| `openshift-install version` shows a `quay.io` release image | The installer was downloaded, not extracted from the mirror | Step 8 |
| `agent create image` fails with `Failed to extract base ISO from release payload` | The installer could not pull from the mirror: `oc` not first on `PATH`, no `imageDigestSources`, or no mirror entry in the pull secret | `create-image.log` (debug), `PATH=$WORK:$PATH which oc`, `rendered/install-config.yaml` |
| `agent create image` warns `Using older version of "oc" that does not support mirroring` | The `oc` on `PATH` is too old for the installer's mirror handling | Put `$WORK` first on `PATH` (Step 11) |
| A host stays *Insufficient*: `Host couldn't synchronize with any NTP server` | The hypervisor is not serving time, or firewalld blocks UDP 123 | Step 6: `ss -lun \| grep :123`, `firewall-cmd --zone=libvirt --list-services`; on the node `chronyc -n sources` |
| The agent cannot pull the release image | The node cannot reach or trust the mirror | On the node: `getent hosts registry.hub.mylab.com`, `curl -v https://registry.hub.mylab.com:8443/v2/` |
| A node can still reach quay.io | The egress block is missing or below libvirt's rules (after a reboot, or a libvirtd/firewalld reload) | Step 5 checks; re-run `--tags compactvm` |
| Pods in `ImagePullBackOff` for a `registry.redhat.io` or `quay.io` image by tag | Tag mirrors are only applied on day 2, or the image was never mirrored | Step 14; add the image to the mirror's ImageSetConfiguration |
| OperatorHub shows no operators, or catalog pods fail to pull | The default catalogs are still enabled (the Step 10 manifest did not reach `$WORK/openshift/`; run the `oc patch OperatorHub` in Step 14), or the mirrored CatalogSources are not applied (Step 14) | `oc get operatorhub cluster -o yaml`, `oc get catalogsource -n openshift-marketplace` |
| `oc adm upgrade` refuses an update with a signature error | The release signature ConfigMap from `oc mirror` is missing | It goes in as an extra manifest (Step 10). On a running cluster, `oc apply` it from `$CR`. |
| Nodes report `rendered-master-... do not match` on first boot | An IDMS/ITMS was placed in `$WORK/openshift/` | Remove it, rebuild the ISO (Step 10) |
| `virt-install` or libvirt rejects a MAC like `52:54:00:e2:54:3` | The octet was not zero-padded | Use `$MAC1:0$oct` (Step 12) |
| The `lvms` Subscription stays unresolved (`ResolutionFailed`, no CSV) | It names a CatalogSource that is not on the cluster, or that catalog has no `lvms-operator` | Step 15: `oc get catalogsource -n openshift-marketplace`, `oc get packagemanifest lvms-operator -n openshift-marketplace`. Apply day 2 (Step 14) first. |
| LVMCluster stays `Progressing` or `Failed`, or `lvms-vg1` never appears | A node has no empty disk: `vdb` is missing, or it already holds partitions, a filesystem or an old volume group | `lsblk /dev/vdb` on each node (Step 15). `oc -n openshift-storage logs ds/vg-manager` names every device it skipped and why. Attach a fresh disk as in Step 15. |
| RHCOS was installed on the storage disk | `rootDeviceHints` was removed, or the storage disk was listed before the RHCOS disk in `virt-install` | `virsh domblklist compactd_masterN`: the RHCOS disk must be `vda`. Rebuild with the disk order from Step 12. |
| A PVC stays `Pending` with no pod using it | `lvms-vg1` binds when the first pod uses the PVC (`WaitForFirstConsumer`) | Expected. Start a pod that mounts it. |
