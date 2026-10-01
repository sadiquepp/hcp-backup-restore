#!/usr/bin/env bash
#
# Ping between the UDN test pods and the external client, and print the result
# as a tenant x node matrix.
#
#   scripts/udn-reachability.sh                    # pods -> client
#   scripts/udn-reachability.sh --reverse          # client -> pods
#   scripts/udn-reachability.sh --both             # both, two matrices
#   scripts/udn-reachability.sh --both 192.168.122.47 5
#
# The matrix is the point. A failure in this lab is almost always shaped like
# a whole ROW or a whole COLUMN, and the two mean completely different things:
#
#   a row fails      one tenant, every node      -> that network's config:
#                                                   a missing ip rule, an
#                                                   unrealised CUDN, no NAD
#   a column fails   every tenant, one node      -> that node: strict
#                                                   rp_filter, forwarding off,
#                                                   fabric NIC unaddressed
#   one cell fails   that pod                    -> the pod, or its node's
#                                                   slice of that network
#
# Reading one ping at a time hides that completely. Both of the failures this
# was written after - blue missing its rule on all three nodes, and one node
# left with strict reverse-path filtering - are a glance in this layout.
#
# --both earns its place in phase 2 specifically, where the two directions are
# NOT equivalent: inbound is decided by the leaf from BGP, outbound by the node
# from the tenant VRF's own table. A tenant that answers the client but cannot
# reach it, or the reverse, is that asymmetry showing - see bgp-evpn.md,
# "Following one packet in phase 2".
#
# No jq: each pod's address is read from the pod itself, which is also more
# honest than the annotation - it is what the interface actually has.
set -uo pipefail

CLIENT="192.168.122.47"
COUNT=3
MODE="pods"
SSH_KEY="${UDN_CLIENT_SSH_KEY:-$HOME/.ssh/lab_rsa}"
SSH_USER="${UDN_CLIENT_SSH_USER:-root}"

positional=()
for arg in "$@"; do
    case "$arg" in
        --reverse|-r) MODE="reverse" ;;
        --both|-b)    MODE="both" ;;
        --pods|-p)    MODE="pods" ;;
        -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           echo "unknown option: $arg" >&2; exit 1 ;;
        *)            positional+=("$arg") ;;
    esac
done
[[ ${#positional[@]} -ge 1 ]] && CLIENT="${positional[0]}"
[[ ${#positional[@]} -ge 2 ]] && COUNT="${positional[1]}"

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

# Associative arrays and namerefs are bash 4. macOS still ships 3.2 as
# /bin/bash, where this would fail in ways that look like a cluster problem.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "This needs bash 4+; found ${BASH_VERSION}." >&2
    echo "On macOS: brew install bash, then run it with /opt/homebrew/bin/bash" >&2
    exit 1
fi

declare -A OUT IN
tenants=()
nodes=()
records=()

add_unique() {
    local -n arr="$1"
    local v="$2" e
    for e in ${arr[@]+"${arr[@]}"}; do [[ "$e" == "$v" ]] && return; done
    arr+=("$v")
}

ssh_client() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@${CLIENT}" "$@"
}

# ---------------------------------------------------------------------------
# Discover: one record per pod - tenant, node, namespace, pod, UDN address
# ---------------------------------------------------------------------------
namespaces=$(oc get ns -l udn-tenant -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ -n "$namespaces" ]] || { echo "No namespaces labelled udn-tenant. Run --tags shared first." >&2; exit 1; }

for ns in $namespaces; do
    tenant=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.udn-tenant}')
    add_unique tenants "$tenant"
    pods=$(oc -n "$ns" get pods -l app=udn-test \
             -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')
    while read -r pod node; do
        [[ -n "${pod:-}" ]] || continue
        add_unique nodes "$node"
        # ovn-udn1 is the primary UDN interface. eth0 is still the cluster
        # network - a pod whose UDN never attached has no ovn-udn1 at all,
        # which is worth reporting as its own state rather than as a failure
        # to reach anything.
        addr=$(oc -n "$ns" exec "$pod" -- ip -o -4 addr show ovn-udn1 2>/dev/null | awk '{print $4}')
        records+=("${tenant}"$'\t'"${node}"$'\t'"${ns}"$'\t'"${pod}"$'\t'"${addr%%/*}")
    done <<< "$pods"
done

# ---------------------------------------------------------------------------
# Direction 1: pods -> client
# ---------------------------------------------------------------------------
probe_from_pods() {
    echo "Pinging ${CLIENT} from every udn-test pod (${COUNT} packets each)"
    echo
    local tenant node ns pod addr out rc ttl rtt loss
    for rec in "${records[@]}"; do
        IFS=$'\t' read -r tenant node ns pod addr <<< "$rec"
        if [[ -z "$addr" ]]; then
            OUT["$tenant,$node"]="NO-UDN"
            printf '  %-8s %-9s %-16s %s\n' "$tenant" "$node" "(no ovn-udn1)" "NOT ON ITS UDN"
            continue
        fi
        out=$(oc -n "$ns" exec "$pod" -- ping -c"$COUNT" -W2 "$CLIENT" 2>&1); rc=$?
        if (( rc == 0 )); then
            rtt=$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5 " ms"}')
            ttl=$(echo "$out" | grep -o 'ttl=[0-9]*' | head -1)
            OUT["$tenant,$node"]="ok"
            printf '  %-8s %-9s %-16s ok   %s %s\n' "$tenant" "$node" "$addr" "${ttl:-}" "${rtt:-}"
        else
            loss=$(echo "$out" | grep -o '[0-9]*% packet loss' | head -1)
            OUT["$tenant,$node"]="FAIL"
            printf '  %-8s %-9s %-16s FAIL %s\n' "$tenant" "$node" "$addr" "${loss:-}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Direction 2: client -> pods, over ssh to the client
# ---------------------------------------------------------------------------
probe_from_client() {
    echo "Pinging every udn-test pod from ${CLIENT} (${COUNT} packets each)"
    echo
    if ! ssh_client true 2>/dev/null; then
        echo "  Cannot ssh to ${SSH_USER}@${CLIENT} with ${SSH_KEY}." >&2
        echo "  Build it with --tags clabclient, or set UDN_CLIENT_SSH_KEY." >&2
        return 1
    fi
    local tenant node ns pod addr out rc ttl rtt loss
    for rec in "${records[@]}"; do
        IFS=$'\t' read -r tenant node ns pod addr <<< "$rec"
        if [[ -z "$addr" ]]; then
            IN["$tenant,$node"]="NO-UDN"
            printf '  %-8s %-9s %-16s %s\n' "$tenant" "$node" "(no ovn-udn1)" "NOT ON ITS UDN"
            continue
        fi
        out=$(ssh_client "ping -c$COUNT -W2 $addr" 2>&1); rc=$?
        if (( rc == 0 )); then
            rtt=$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5 " ms"}')
            ttl=$(echo "$out" | grep -o 'ttl=[0-9]*' | head -1)
            IN["$tenant,$node"]="ok"
            printf '  %-8s %-9s %-16s ok   %s %s\n' "$tenant" "$node" "$addr" "${ttl:-}" "${rtt:-}"
        else
            loss=$(echo "$out" | grep -o '[0-9]*% packet loss' | head -1)
            IN["$tenant,$node"]="FAIL"
            printf '  %-8s %-9s %-16s FAIL %s\n' "$tenant" "$node" "$addr" "${loss:-}"
        fi
    done
}

print_matrix() {  # title, name of the results array
    local title="$1"
    local -n res="$2"
    echo
    echo "$title"
    printf '%-8s' 'tenant'
    for n in "${nodes[@]}"; do printf ' %-9s' "$n"; done
    echo
    for t in "${tenants[@]}"; do
        printf '%-8s' "$t"
        for n in "${nodes[@]}"; do
            case "${res["$t,$n"]:-}" in
                ok)     printf ' %-9s' 'ok' ;;
                FAIL)   printf ' %-9s' 'FAIL' ;;
                NO-UDN) printf ' %-9s' 'no-udn' ;;
                *)      printf ' %-9s' '-' ;;
            esac
        done
        echo
    done
}

case "$MODE" in
    pods)    probe_from_pods; print_matrix "pod -> ${CLIENT}" OUT ;;
    reverse) probe_from_client; print_matrix "${CLIENT} -> pod" IN ;;
    both)    probe_from_pods; echo; probe_from_client
             print_matrix "pod -> ${CLIENT}" OUT
             print_matrix "${CLIENT} -> pod" IN
             # Phase 2's two directions are decided by different routers, so
             # they can and do disagree. Saying so beats leaving two matrices
             # side by side for the reader to diff by eye.
             echo
             for t in "${tenants[@]}"; do
                 for n in "${nodes[@]}"; do
                     o="${OUT["$t,$n"]:-}"; i="${IN["$t,$n"]:-}"
                     [[ -n "$o" && -n "$i" && "$o" != "$i" ]] && \
                         echo "  ASYMMETRIC  ${t}/${n}: pod->client ${o}, client->pod ${i}"
                 done
             done ;;
esac

echo
echo "A whole row failing is that tenant's config; a whole column is that node."
