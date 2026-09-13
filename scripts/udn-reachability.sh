#!/usr/bin/env bash
#
# Ping a target from every UDN test pod and print a tenant x node matrix.
#
#   scripts/udn-reachability.sh [target] [count]
#   scripts/udn-reachability.sh 192.168.122.60 3      # the client VM (default)
#   scripts/udn-reachability.sh 192.168.140.1         # leaf1 - fails in phase 2 by design
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
# No jq: the pod's address is read from the pod itself, which is also more
# honest than the annotation - it is what the interface actually has.
set -uo pipefail

TARGET="${1:-192.168.122.60}"
COUNT="${2:-3}"

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }

# Associative arrays and namerefs are bash 4. macOS still ships 3.2 as
# /bin/bash, where this would fail in ways that look like a cluster problem.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "This needs bash 4+; found ${BASH_VERSION}." >&2
    echo "On macOS: brew install bash, then run it with /opt/homebrew/bin/bash" >&2
    exit 1
fi

declare -A RESULT ADDR
tenants=()
nodes=()

add_unique() {  # array_name value
    local -n arr="$1"
    local v="$2"
    local e
    for e in ${arr[@]+"${arr[@]}"}; do [[ "$e" == "$v" ]] && return; done
    arr+=("$v")
}

echo "Pinging ${TARGET} from every udn-test pod (${COUNT} packets each)"
echo

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
        # which is worth reporting as its own state rather than as a ping
        # failure.
        addr=$(oc -n "$ns" exec "$pod" -- ip -o -4 addr show ovn-udn1 2>/dev/null | awk '{print $4}')
        if [[ -z "$addr" ]]; then
            RESULT["$tenant,$node"]="NO-UDN"
            ADDR["$tenant,$node"]="-"
            printf '  %-8s %-9s %-16s %s\n' "$tenant" "$node" "(no ovn-udn1)" "NOT ON ITS UDN"
            continue
        fi
        ADDR["$tenant,$node"]="${addr%%/*}"

        out=$(oc -n "$ns" exec "$pod" -- ping -c"$COUNT" -W2 "$TARGET" 2>&1)
        if [[ $? -eq 0 ]]; then
            rtt=$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5 " ms"}')
            ttl=$(echo "$out" | grep -o 'ttl=[0-9]*' | head -1)
            RESULT["$tenant,$node"]="ok"
            printf '  %-8s %-9s %-16s ok   %s %s\n' "$tenant" "$node" "${addr%%/*}" "${ttl:-}" "${rtt:-}"
        else
            loss=$(echo "$out" | grep -o '[0-9]*% packet loss' | head -1)
            RESULT["$tenant,$node"]="FAIL"
            printf '  %-8s %-9s %-16s FAIL %s\n' "$tenant" "$node" "${addr%%/*}" "${loss:-}"
        fi
    done <<< "$pods"
done

echo
printf '%-8s' 'tenant'
for n in "${nodes[@]}"; do printf ' %-9s' "$n"; done
echo
for t in "${tenants[@]}"; do
    printf '%-8s' "$t"
    for n in "${nodes[@]}"; do
        case "${RESULT["$t,$n"]:-}" in
            ok)     printf ' %-9s' 'ok' ;;
            FAIL)   printf ' %-9s' 'FAIL' ;;
            NO-UDN) printf ' %-9s' 'no-udn' ;;
            *)      printf ' %-9s' '-' ;;
        esac
    done
    echo
done

echo
echo "A whole row failing is that tenant's config; a whole column is that node."
