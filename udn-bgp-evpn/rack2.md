# A second rack: sno2 behind its own leaf

> **Status: built and render-checked, not yet run on a lab.** Every command
> below is what the automation does, but none of the expected outputs has been
> measured yet. Replace them with real ones on the first run.

## What this adds, and why

In the main lab every VTEP sits on one segment, `virbr1`. Hub and SNO
traffic for green (VNI 400) still passes through leaf1, but only because the
VTEPs are /32s on dummy interfaces, and leaf1 answers the first packet with
an ICMP redirect (workshop X6). That shows stretched Layer2, but not
stretched Layer2 across a **routed** underlay.

sno2 is a third cluster in a second rack. Its fabric NIC is on `virbr2`, and
the only way out of its rack is up through leaf3 and the spine:

```
hub workers, sno -- virbr1 (192.168.140.0/24) -- leaf1 --+
                                                          spine -- leaf2 (green-ext, purple-ext)
sno2             -- virbr2 (192.168.160.0/24) -- leaf3 --+
                    VTEP 100.64.1.18                       10.1.0.8/30
```

green and purple are built on sno2 too. A pod on sno2 and a pod on the hub
are then in one broadcast domain, while their VTEPs are three routers apart:
leaf3, the spine and leaf1.

## What it does not touch

`sno2_enabled` is false in `vars.yaml`. With it false, every template this
change touches renders byte for byte what `main` renders. That was checked by
rendering them with Ansible from both trees and diffing the output.

With it true:

| Piece | Change |
| --- | --- |
| hub, sno | nothing. Nothing on them is re-run. They pick up sno2's EVPN routes because they already import green's and purple's route targets |
| leaf1, leaf2 | nothing. Their config renders the same; leaf3's routes reach them through the spine |
| spine | two neighbours added live with `vtysh -f`. Its sessions to leaf1 and leaf2 are not restated, so they are not touched |
| containerlab VM | one NIC hot-plugged (`virsh attach-interface --live`) and one bridge, `br-fabric2` |
| leaf3 | a new containerlab lab, `udnbgp-rack2`. `deploy --reconfigure` on it can only touch leaf3 |
| libvirt | a new network `fabric2` (`virbr2`). `default` (`virbr0`) is not redefined |
| helper DNS | a new zone `sno2.mylab.com` and a PTR. named restarts, as on any `--tags dns` run |
| lab host | four lines added to the managed `/etc/hosts` block |

## Before you start

- The EVPN lab is up: `./build-lab.sh` has run, and the fabric was deployed
  with `clab_topology=evpn`.
- The lab host has room for another SNO: 32 GiB and 12 vCPUs by default
  (`sno2_memory`, `sno2_vcpus` in `vars.yaml`).
- Turn it on for every command below. Either set `sno2_enabled: true` in
  `vars.yaml` on the lab host, or add `-e sno2_enabled=true` to each command.
  The commands here show the `-e`.

## Steps

### 1. DNS

From the repository root:

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns \
  --ask-vault-pass -e sno2_enabled=true
```

This renders `sno2.mylab.com` on the helper and adds sno2's names to the lab
host's `/etc/hosts`.

sno2 resolves through the **helper**, not through libvirt's dnsmasq the way
the SNO does. Adding a dnsmasq forwarder for a new zone means redefining the
`default` network, which restarts `virbr0` under every VM in the lab. The
helper forwards external names to the lab host's own resolvers, so it can
serve a connected install. `setup_sno2.yaml` checks that before it builds
anything.

### 2. Build sno2

```bash
ansible-playbook -i inventory/hosts setup_sno2.yaml --ask-vault-pass \
  -e sno2_enabled=true
```

This uses the same role as `setup_sno.yaml`, with sno2's own name, install
folder (`sno2_install`) and VM folder. Expect about the same time as the
SNO's install.

The SNO's install folder holds its only kubeconfig. The role's pre-flight now
refuses any install folder whose kubeconfig belongs to another cluster, so
`setup_sno.yaml -e sno_name=sno2` fails instead of overwriting it.

### 3. The rack: virbr2, leaf3, the spine link

From `udn-bgp-evpn/`:

```bash
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags rack -e clab_topology=evpn -e sno2_enabled=true
```

Use `--tags rack` and nothing else. `fabric`, `clabdeploy` and `nodenics`
also work, but `fabric` and `clabdeploy` redeploy leaf1, leaf2 and the spine
first, which is the disruption this is built to avoid.

It ends by waiting for the spine's two sessions to leaf3 (underlay and EVPN)
and printing leaf3's summary. leaf3's session to sno2 stays down until step 4.

### 4. sno2's side

```bash
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags evpn -e clab_topology=evpn -e udn_bgp_cluster=sno2 -e sno2_enabled=true
ansible-playbook -i ../inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass \
  --tags web -e udn_bgp_cluster=sno2 -e sno2_enabled=true
```

The role points the fabric addressing at rack2 for this run:
`192.168.160.0/24`, leaf3 at `.1` in AS 64518, and VTEP `100.64.1.18`. It
checks sessions against leaf3 rather than leaf1. sno2 builds green and purple
only, and allocates their pods from `10.204.254.0/24` (see "Known gaps").

Only `prep`, `evpn` and `web` are allowed for sno2. rack2 has no VRF-Lite
VLANs, so the role refuses `vrflite`, `shared` and `default` there.

### 5. Helpers

`workshop.env` gains `SNO2_KUBECONFIG`, `lab sno2`, `leaf3` and `onleaf3`
the next time the hub's or the SNO's `--tags prep` writes it. sno2's own prep
run does not write it. Until then, add these lines to your shell:

```bash
export SNO2_KUBECONFIG=/var/lib/libvirt/images/sno2_install/auth/kubeconfig
leaf3()   { _clab docker exec "clab-$CLAB_LAB-rack2-leaf3" vtysh -c "$*"; }
onleaf3() { _clab docker exec "clab-$CLAB_LAB-rack2-leaf3" "$@"; }
```

## What to look at

All of these are predictions. Replace them with what the lab shows.

**The underlay is routed.** The hub reaches sno2's VTEP through leaf1 and the
spine, and leaf1 learned rack2's VTEP block from the spine:

```bash
leaf1 'show ip route 100.64.1.0/24'           # B>* via 10.1.0.2 (spine)
leaf3 'show bgp summary'                      # spine x2 and sno2: all Established
lab hub
oc debug node/worker1 --quiet -- chroot /host ip route get 100.64.1.18
#   via 192.168.140.1 (leaf1), with no "cache" line: nothing redirects this one
```

Compare with X6. There, `ip route get` toward a VTEP on the same segment
showed a cached redirect. Here leaf1's way to the next hop is the spine, not
the interface the packet came in on, so leaf1 has nothing to redirect.

**sno2 is in green's flood list.** It sent a type-3 route for VNI 400, and
every hub worker has an all-zeros FDB entry toward it:

```bash
leaf1 'show bgp l2vpn evpn route type multicast' | grep -B2 100.64.1.18
oc debug node/worker1 --quiet -- chroot /host bridge fdb show | grep 100.64.1.18
```

**One broadcast domain, three routers.** Ping from green on sno2 to green on
the hub:

```bash
lab sno2
inpod green ping -c3 $(KUBECONFIG=$HUB_KUBECONFIG podip green)
#   ttl=64 on the reply: inner packet bridged, no router in the overlay
```

Capture both rack segments on the lab host at once:

```bash
timeout 20 tcpdump -lnvi virbr2 'udp port 4789' -c 4 &
timeout 20 tcpdump -lnvi virbr1 'udp port 4789 and host 100.64.1.18' -c 4
```

Outer source and destination are the two VTEPs, `100.64.1.18` and the hub
worker's `100.64.0.3x`. The outer TTL on `virbr1` should be three lower than
on `virbr2`, one for each of leaf3, the spine and leaf1. The inner TTL is
the same on both.

**Fail the rack's uplink.**

```bash
onleaf3 ip link set eth10 down
leaf1 'show bgp l2vpn evpn route type multicast' | grep -c 100.64.1.18   # 0, after hold time
inpod green ping -c3 ...                                                   # sno2 -> hub fails
# hub <-> sno green still works: their path never used leaf3
onleaf3 ip link set eth10 up
```

## Known gaps

- **The spine-leaf3 link is a veth made after deploy.** It dies with either
  container, and a reboot of the containerlab VM takes it down with them.
  Re-run step 3 to bring it back. A full `--tags fabric` run recreates the
  spine and re-runs step 3 at the end.
- **IPAM.** sno2 allocates green and purple from `10.204.254.0/24`, which is
  inside the SNO's half. Shrinking the SNO's half would change a CUDN that is
  already running there. The SNO allocates its lowest free address first,
  from `10.204.128.0`, and a lab never gets near `.254`.
- **Three copies of `.1` and `.2`.** Every cluster on green keeps
  `10.204.0.1`, the gateway, and a single-node cluster keeps `.2`, its
  management port. sno2 adds a third copy of each to the broadcast domain.
  That is the problem already noted at green's `evpn_l2_excludes` in
  `vars.yaml`, not a new one.
- **Not in `build-lab.sh` or `cleanup.yaml`.** Both run without sno2. To
  remove it by hand:
  ```bash
  virsh destroy sno2; virsh undefine sno2 --remove-all-storage
  ssh root@192.168.122.40 'cd /root/udn-bgp-fabric-rack2 && containerlab destroy --topo udnbgp-rack2.clab.yml'
  ssh root@192.168.122.40 docker exec clab-udnbgp-spine vtysh -c 'conf t' -c 'router bgp 65000' \
      -c 'no neighbor 10.1.0.10' -c 'no neighbor 10.0.0.3'
  virsh net-destroy fabric2; virsh net-undefine fabric2
  ```
  Then set `sno2_enabled` back to false.
