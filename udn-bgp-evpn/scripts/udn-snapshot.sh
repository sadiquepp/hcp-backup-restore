#!/usr/bin/env bash
#
# Capture the whole UDN/BGP state to a directory, so one phase can be diffed
# against the next.
#
#   scripts/udn-snapshot.sh phase2
#   scripts/udn-snapshot.sh phase3
#   diff -ru snapshots/phase2-* snapshots/phase3-*
#
# Run it BEFORE moving to the next phase. --tags vrflite deletes the
# namespaces and the CUDNs and changes every tenant's subnet, so phase 2's
# state is not recoverable afterwards - and the phase 2 to phase 3 difference
# is most of what this lab exists to show.
#
# Everything here is read-only.
set -uo pipefail

LABEL="${1:-snapshot}"
OUT="snapshots/${LABEL}-$(date +%Y%m%d-%H%M%S)"
CLAB="${CLAB_HOST:-192.168.122.40}"
LAB_NAME="${CLAB_LAB_NAME:-udnbgp}"
SSH_KEY="${UDN_CLIENT_SSH_KEY:-$HOME/.ssh/lab_rsa}"
SSH_USER="${UDN_CLIENT_SSH_USER:-root}"

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
# oc being on PATH says nothing about whether it can reach a cluster. There is
# no `set -e` here, so without a usable KUBECONFIG every oc call below fails
# quietly, the discovery loops iterate over nothing, and the run finishes
# looking clean while having checked nothing at all.
oc get ns >/dev/null 2>&1 || {
    echo "oc cannot reach a cluster - is KUBECONFIG exported?" >&2
    echo "  export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig" >&2
    exit 1
}
mkdir -p "$OUT"
echo "Writing to $OUT"

leaf() {  # vtysh command -> file
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@${CLAB}" \
        "docker exec clab-${LAB_NAME}-leaf1 vtysh -c '$1'" 2>&1
}

clab_exec() {  # container-suffix, command -> stdout (non-vtysh)
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@${CLAB}" \
        "docker exec clab-${LAB_NAME}-$1 ${*:2}" 2>&1
}

node() {  # node, command -> stdout
    oc debug "node/$1" --quiet -- chroot /host sh -c "$2" 2>&1
}

# ---------------------------------------------------------------------------
# The fabric. In phase 2 every tenant prefix sits in leaf1's DEFAULT VRF; in
# phase 3 they move into per-tenant VRFs and blue and red carry the SAME
# prefix in different ones. Capturing both views is what makes that visible.
# ---------------------------------------------------------------------------
echo "  leaf1 ..."
leaf 'show bgp ipv4 unicast'          > "$OUT/leaf1-bgp-default-vrf.txt"
leaf 'show bgp vrf all ipv4 unicast'  > "$OUT/leaf1-bgp-all-vrfs.txt"
leaf 'show bgp summary'               > "$OUT/leaf1-bgp-summary.txt"
leaf 'show bgp vrf all summary'       > "$OUT/leaf1-bgp-all-vrf-summary.txt"
leaf 'show ip route'                  > "$OUT/leaf1-route-default-vrf.txt"
leaf 'show ip route vrf all'          > "$OUT/leaf1-route-all-vrfs.txt"
clab_exec leaf1 'ip -o -4 addr show'  > "$OUT/leaf1-addrs.txt"
clab_exec leaf1 'ip -d link show type vrf' > "$OUT/leaf1-vrfs.txt"
leaf 'show running-config'            > "$OUT/leaf1-running-config.txt"

# ---------------------------------------------------------------------------
# The cluster side.
# ---------------------------------------------------------------------------
echo "  cluster objects ..."
oc get clusteruserdefinednetwork -o yaml            > "$OUT/cluster-cudn.yaml"        2>&1
oc get routeadvertisements -o yaml                  > "$OUT/cluster-ra.yaml"          2>&1
oc get frrconfiguration -A -o yaml                  > "$OUT/cluster-frrconfig.yaml"   2>&1
oc get nncp -o yaml                                 > "$OUT/cluster-nncp.yaml"        2>&1
oc get net-attach-def -A -o yaml                    > "$OUT/cluster-nad.yaml"         2>&1

# Which network each test pod actually attached to - the only place that is
# recorded, and the addresses change completely between phases.
{
    for ns in $(oc get ns -l udn-tenant -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        for pod in $(oc -n "$ns" get pods -l app=udn-test -o jsonpath='{.items[*].metadata.name}'); do
            node_name=$(oc -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')
            echo "=== $ns/$pod on $node_name ==="
            oc -n "$ns" get pod "$pod" \
                -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}{"\n"}' 2>&1
        done
    done
} > "$OUT/pod-networks.txt" 2>&1

# ---------------------------------------------------------------------------
# Per node. The tenant VRF's route table is the centre of it: in phase 2 it
# holds the tenant's subnets and the node's default gateway and nothing else,
# which is why egress leaves by the management NIC. In phase 3 it gains a VLAN
# subinterface, a connected route to its handoff subnet and its own BGP-learned
# routes - and that is the entire difference between the phases, in one file.
# ---------------------------------------------------------------------------
nodes=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for n in $nodes; do
    echo "  $n ..."
    node "$n" 'ip rule show'                       > "$OUT/node-$n-iprule.txt"
    node "$n" 'ip -d link show type vrf'           > "$OUT/node-$n-vrf.txt"
    node "$n" 'ip -br addr show'                   > "$OUT/node-$n-addr.txt"
    node "$n" 'ip -br link show'                   > "$OUT/node-$n-link.txt"
    node "$n" 'ip route show table all'            > "$OUT/node-$n-routes-all-tables.txt"
    node "$n" 'sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.forwarding' \
                                                   > "$OUT/node-$n-sysctl.txt"
done

# ---------------------------------------------------------------------------
# The kernel's own verdict on where a tenant's egress goes. One line per
# (tenant, node, destination), and the clearest before/after in the snapshot.
#
# Two sets of destinations, and BOTH directions of the change matter:
#
#   the tenant's own       phase 2: no route (they live in leaf1's tenant VRFs,
#   (leaf1's addresses              which phase 2 never peers with)
#    inside that VRF)      phase 3: via the tenant's own VLAN subinterface
#
#   192.168.140.1          phase 2: via the node's default gateway, dev br-ex
#   192.168.122.47         phase 3: no route - the tenant table has no default
#                                   route and is not in the default VRF
#
# An earlier version probed only the second set, so a healthy phase 3 printed
# nothing but "No route to host" twelve times: correct, and useless. The
# per-tenant destinations are read off leaf1 rather than listed here, so they
# cannot drift from the topology.
# ---------------------------------------------------------------------------
# Addresses leaf1 holds inside one tenant's VRF: its handoff VLAN subinterface,
# the <tenant>-ext gateway, and (phase 3 clients) the client segment gateway.
# 'master' rather than 'vrf' because the alias is newer than some iproute2
# builds and this has to work inside whatever the FRR image ships.
leaf_vrf_addrs() {
    clab_exec leaf1 "ip -o -4 addr show master $1" 2>/dev/null \
        | awk '{split($4, a, "/"); print a[1]}' | tr '\n' ' '
}

echo "  egress decisions ..."
declare -A VRFDEST
{
    for ns in $(oc get ns -l udn-tenant -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        tenant=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.udn-tenant}')
        for pod in $(oc -n "$ns" get pods -l app=udn-test -o jsonpath='{.items[*].metadata.name}'); do
            node_name=$(oc -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')
            addr=$(oc -n "$ns" exec "$pod" -- ip -o -4 addr show ovn-udn1 2>/dev/null | awk '{print $4}')
            [[ -n "$addr" ]] || { echo "=== $tenant/$node_name: no ovn-udn1 ==="; continue; }
            ip="${addr%%/*}"
            # The tenant's management port carries .2 of the same /24, so its
            # name is derivable from the pod's address without guessing.
            pfx="${ip%.*}"
            mp=$(node "$node_name" "ip -o -4 addr show | awk '/ $pfx\./ {print \$2}' | head -1")
            mp="${mp//[$'\r\n']/}"
            echo "=== $tenant on $node_name: pod $ip via ${mp:-?} ==="
            # Cached per tenant - one ssh per tenant, not per pod.
            if [[ -z "${VRFDEST[$tenant]+set}" ]]; then
                VRFDEST["$tenant"]=$(leaf_vrf_addrs "$tenant")
            fi
            for dest in ${VRFDEST[$tenant]} "${@:2}" 192.168.122.47 192.168.140.1; do
                [[ -n "$dest" ]] || continue
                printf '  -> %-18s ' "$dest"
                node "$node_name" "ip route get $dest from $ip iif ${mp:-lo} 2>&1 | head -2 | tr '\n' ' '"
                echo
            done
        done
    done
} > "$OUT/egress-decisions.txt" 2>&1

# ---------------------------------------------------------------------------
# And the end-to-end result, if the client VM exists.
# ---------------------------------------------------------------------------
if [[ -x scripts/udn-reachability.sh ]]; then
    echo "  reachability ..."
    scripts/udn-reachability.sh --both > "$OUT/reachability.txt" 2>&1
fi

echo
echo "Snapshot written to $OUT"
echo "Compare phases with:  diff -ru snapshots/<earlier>-* $OUT"
