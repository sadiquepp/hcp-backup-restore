#!/usr/bin/env bash
#
# Phase 3 (VRF-Lite) isolation test. Proves three things the phase-2
# reachability matrix cannot:
#
#   1. each tenant reaches its OWN external network          (diagonal: ok)
#   2. and no other tenant's                                 (off-diagonal: FAIL)
#   3. blue and red keep their IDENTICAL subnets apart       (identity check)
#
#   scripts/udn-vrf-isolation.sh
#   scripts/udn-vrf-isolation.sh --count 3
#
# Run it after --tags vrflite. In phase 2 every tenant is in leaf1's default
# VRF and every cell is reachable, so the off-diagonal "failures" this looks
# for will all be green and the script will correctly call that a leak - the
# leak is just the phase working as designed. It is a phase 3 tool.
#
# Why no client VM
# ----------------
# The *-ext containers ARE the multi-client rig. udnbgp.clab.yml.j2 enslaves
# each tenant's ext link to that tenant's VRF on leaf1:
#
#     ip link add blue type vrf table 1110
#     ip link set blue-ext master blue
#
# so a packet from blue-ext enters leaf1 already in the blue VRF, and the same
# destination from red-ext enters in the red VRF. A VM would have to be
# plumbed identically to prove anything, and a single multi-VRF VM would add a
# client-side VRF that fails indistinguishably from the leaf-side VRF under
# test. The client wants to be dumb.
#
# Why reachability alone is not enough here
# -----------------------------------------
# Once blue and red share 10.200.0.0/16, blue-ext pinging 10.200.0.5 gets a
# reply whether that address belongs to a blue pod or a red one. ICMP carries
# no identity, so "the ping worked" proves nothing about isolation - it is the
# precise failure VRF-Lite exists to prevent. Where two tenants hold the same
# pod address, this reads ICMP InEchos out of /proc/net/snmp on BOTH pods and
# reports which one actually counted the packet. That is an identity proof,
# not a reachability one.
set -uo pipefail

CLAB="${CLAB_HOST:-192.168.122.40}"
LAB_NAME="${CLAB_LAB_NAME:-udnbgp}"
SSH_KEY="${UDN_CLIENT_SSH_KEY:-$HOME/.ssh/lab_rsa}"
SSH_USER="${UDN_CLIENT_SSH_USER:-root}"
COUNT=2
WITH_VMS=0
WITH_NETNS=0
NETNS_ENV="${UDN_NETNS_ENV:-$(dirname "$0")/../udn-bgp/netns-client.env}"
CLIENTS_ENV="${UDN_CLIENTS_ENV:-$(dirname "$0")/../udn-bgp/tenant-clients.env}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count|-c) COUNT="$2"; shift 2 ;;
        --vms|-v)   WITH_VMS=1; shift ;;
        --netns)    WITH_VMS=1; WITH_NETNS=1; shift ;;
        -h|--help)  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
if (( BASH_VERSINFO[0] < 4 )); then
    echo "This needs bash 4+; found ${BASH_VERSION}." >&2
    echo "On macOS: brew install bash, then run it with /opt/homebrew/bin/bash" >&2
    exit 1
fi

ssh_clab() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@${CLAB}" "$@"
}
ext_exec() {  # tenant, then command
    local t="$1"; shift
    ssh_clab "docker exec clab-${LAB_NAME}-${t}-ext $*" 2>&1
}

declare -A EXTHOST POD PODNS PODADDR
declare -A M1 M2 OKC TOT VM SERVES CLIENTIP ADDR_OWNERS PREFIX
clients=()
tenants=()
records=()

add_unique() {
    local -n arr="$1"; local v="$2" e
    for e in ${arr[@]+"${arr[@]}"}; do [[ "$e" == "$v" ]] && return; done
    arr+=("$v")
}

# ---------------------------------------------------------------------------
# Discover tenants and pods from the cluster, ext addresses from the fabric
# ---------------------------------------------------------------------------
# The ext address is read off the container rather than out of vars.yaml for
# the same reason the pod address is read off the pod: it is what the
# interface actually has, not what something intended it to have.
echo "Discovering tenants, pods and external endpoints"

namespaces=$(oc get ns -l udn-tenant -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ -n "$namespaces" ]] || { echo "No namespaces labelled udn-tenant. Run --tags vrflite first." >&2; exit 1; }

if ! ssh_clab true 2>/dev/null; then
    echo "Cannot ssh to ${SSH_USER}@${CLAB} with ${SSH_KEY}." >&2
    echo "Set CLAB_HOST / UDN_CLIENT_SSH_KEY if the fabric is elsewhere." >&2
    exit 1
fi

for ns in $namespaces; do
    tenant=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.udn-tenant}')
    add_unique tenants "$tenant"

    addr=$(ext_exec "$tenant" ip -o -4 addr show eth1 | awk '{print $4}' | head -1)
    EXTHOST["$tenant"]="${addr%%/*}"

    pods=$(oc -n "$ns" get pods -l app=udn-test \
             -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')
    while read -r pod node; do
        [[ -n "${pod:-}" ]] || continue
        paddr=$(oc -n "$ns" exec "$pod" -- ip -o -4 addr show ovn-udn1 2>/dev/null | awk '{print $4}')
        paddr="${paddr%%/*}"
        records+=("${tenant}"$'\t'"${node}"$'\t'"${ns}"$'\t'"${pod}"$'\t'"${paddr}")
        # One representative pod per tenant, for the ext -> pod direction.
        [[ -n "${POD[$tenant]:-}" ]] || { POD["$tenant"]="$pod"; PODNS["$tenant"]="$ns"; PODADDR["$tenant"]="$paddr"; }
    done <<< "$pods"
done

# Which tenants share a pod address. Layer2 tenants on one subnet can land on
# the same one - green and purple are in the lab to make that happen - and once
# they do, a ping to that address answers for BOTH of them. ICMP carries no
# identity, so those cells are not "ok" or "FAIL", they are unanswerable, and
# calling them either would be a lie in the direction of a false leak.
for t in "${tenants[@]}"; do
    a="${PODADDR[$t]:-}"
    [[ -n "$a" ]] || continue
    ADDR_OWNERS["$a"]="${ADDR_OWNERS[$a]:-}${ADDR_OWNERS[$a]:+ }$t"
done

# does $1 (a source tenant or client) own any tenant sharing $2's pod address,
# other than $2 itself? if so a ping to it is indeterminate.
shared_with_owned() {  # owned-list, target-tenant
    local owned="$1" target="$2" a="${PODADDR[$2]:-}" t
    [[ -n "$a" && "${ADDR_OWNERS[$a]}" == *" "* ]] || return 1
    for t in ${ADDR_OWNERS[$a]}; do
        [[ "$t" == "$target" ]] && continue
        case " $owned " in *" $t "*) return 0 ;; esac
    done
    return 1
}

echo
printf '  %-8s %-16s %-16s %s\n' tenant ext-endpoint pod-address pod
for t in "${tenants[@]}"; do
    printf '  %-8s %-16s %-16s %s\n' "$t" "${EXTHOST[$t]:-?}" "${PODADDR[$t]:-?}" "${POD[$t]:-?}"
done

# ---------------------------------------------------------------------------
# Matrix 1: every pod -> every tenant's external endpoint
# ---------------------------------------------------------------------------
# Off-diagonal cells get ONE packet. They are expected to fail, so the packet
# count only buys patience; a single answered packet is already a leak and
# multiplying the timeout by COUNT across 3n^2 cells is minutes of nothing.
probe_pods_to_ext() {
    echo
    echo "Pinging every tenant's external endpoint from every udn-test pod"
    echo
    local tenant node ns pod addr dest n out rc key
    for rec in "${records[@]}"; do
        IFS=$'\t' read -r tenant node ns pod addr <<< "$rec"
        for dest in "${tenants[@]}"; do
            key="$tenant,$dest"
            if [[ -z "$addr" ]]; then M1["$key"]="NO-UDN"; continue; fi
            OKC["$key"]=$(( ${OKC["$key"]:-0} )); TOT["$key"]=$(( ${TOT["$key"]:-0} + 1 ))
            [[ "$tenant" == "$dest" ]] && n="$COUNT" || n=1
            out=$(oc -n "$ns" exec "$pod" -- ping -c"$n" -W2 "${EXTHOST[$dest]}" 2>&1); rc=$?
            if (( rc == 0 )); then
                OKC["$key"]=$(( ${OKC["$key"]} + 1 ))
                printf '  %-8s %-9s -> %-8s %-16s ok\n' "$tenant" "$node" "$dest" "${EXTHOST[$dest]}"
            else
                printf '  %-8s %-9s -> %-8s %-16s FAIL\n' "$tenant" "$node" "$dest" "${EXTHOST[$dest]}"
            fi
        done
    done

    # Collapse per-node results to one cell, and the two directions of the
    # matrix want OPPOSITE collapses. On the diagonal every node must reach
    # its own endpoint, so a single failing node is a failure and saying "ok"
    # because the other two worked would hide exactly the per-node faults
    # (strict rp_filter, a missing NNCP) this lab keeps producing. Off the
    # diagonal a single node getting through is already a leak, so any
    # success wins. n/N is printed where nodes disagree, because "2/3" and
    # "0/3" are different problems.
    local r c k
    for r in "${tenants[@]}"; do
        for c in "${tenants[@]}"; do
            k="$r,$c"
            [[ "${M1[$k]:-}" == "NO-UDN" ]] && continue
            (( ${TOT[$k]:-0} > 0 )) || { M1["$k"]="-"; continue; }
            if [[ "$r" == "$c" ]]; then
                if (( ${OKC[$k]} == ${TOT[$k]} )); then M1["$k"]="ok"
                elif (( ${OKC[$k]} == 0 ));        then M1["$k"]="FAIL"
                else M1["$k"]="${OKC[$k]}/${TOT[$k]}"; fi
            else
                if (( ${OKC[$k]} > 0 )); then M1["$k"]="ok(${OKC[$k]}/${TOT[$k]})"
                else M1["$k"]="FAIL"; fi
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Matrix 2: every external endpoint -> one pod of every tenant
# ---------------------------------------------------------------------------
probe_ext_to_pods() {
    echo
    echo "Pinging one pod of every tenant from every tenant's external endpoint"
    echo
    local src dest n out rc
    for src in "${tenants[@]}"; do
        for dest in "${tenants[@]}"; do
            if [[ -z "${PODADDR[$dest]:-}" ]]; then M2["$src,$dest"]="NO-UDN"; continue; fi
            if [[ "$src" != "$dest" ]] && shared_with_owned "$src" "$dest"; then
                M2["$src,$dest"]="AMBIG"
                printf '  %-12s -> %-8s %-16s AMBIG (address shared with %s)\n' \
                    "${src}-ext" "$dest" "${PODADDR[$dest]}" "${ADDR_OWNERS[${PODADDR[$dest]}]}"
                continue
            fi
            [[ "$src" == "$dest" ]] && n="$COUNT" || n=1
            out=$(ext_exec "$src" ping -c"$n" -W2 "${PODADDR[$dest]}"); rc=$?
            if (( rc == 0 )); then
                M2["$src,$dest"]="ok"
                printf '  %-12s -> %-8s %-16s ok\n' "${src}-ext" "$dest" "${PODADDR[$dest]}"
            else
                M2["$src,$dest"]="FAIL"
                printf '  %-12s -> %-8s %-16s FAIL\n' "${src}-ext" "$dest" "${PODADDR[$dest]}"
            fi
        done
    done
}

print_matrix() {
    local title="$1"; local -n res="$2"; local rowlabel="$3"
    echo
    echo "$title"
    printf '%-12s' "$rowlabel"
    for c in "${tenants[@]}"; do printf ' %-10s' "$c"; done
    echo
    for r in "${tenants[@]}"; do
        printf '%-12s' "$r"
        for c in "${tenants[@]}"; do
            printf ' %-10s' "${res["$r,$c"]:--}"
        done
        echo
    done
}

verdict() {
    local -n res="$1"; local what="$2" r c v leaks=0 broken=0
    for r in "${tenants[@]}"; do
        for c in "${tenants[@]}"; do
            v="${res["$r,$c"]:-}"
            [[ "$v" == "AMBIG" ]] && continue
            if [[ "$r" == "$c" && "$v" != "ok" ]]; then
                echo "  BROKEN  $r cannot reach its own $what ($v)"
                broken=$((broken + 1))
            elif [[ "$r" != "$c" && "$v" == ok* ]]; then
                echo "  LEAK    $r reached $c's $what - the VRFs are not separating"
                leaks=$((leaks + 1))
            fi
        done
    done
    (( leaks == 0 && broken == 0 )) && echo "  clean: every tenant reached its own $what and nobody else's"
    return $(( leaks + broken ))
}

# ---------------------------------------------------------------------------
# Matrix 3: the per-tenant client VMs (--vms)
# ---------------------------------------------------------------------------
# Three real machines behind leaf1, each on the client VLAN(s) for the tenants
# it serves and on no others. Same finding as matrix 2, from hosts rather than
# containers - and with one path to the fabric each, so there is no management
# network alongside as a second route between them.
#
# udnclient-blue and udnclient-red are separate machines because blue and red
# share 10.200.0.0/16: one routing table holds one route to that prefix, so a
# single host could reach one of them and never the other. udnclient-og serves
# orange and green from one host because theirs differ. The grouping is read
# from the manifest the role renders, not guessed here.
probe_from_vms() {
    echo
    echo "Pinging one pod of every tenant from every per-tenant client VM"
    echo
    if [[ ! -r "$CLIENTS_ENV" ]] && { (( ! WITH_NETNS )) || [[ ! -r "$NETNS_ENV" ]]; }; then
        echo "  No client manifest at $CLIENTS_ENV." >&2
        echo "  Build the VMs with --tags clabtenantclients, or set UDN_CLIENTS_ENV." >&2
        return 1
    fi
    local name ip tenants ns
    if [[ -r "$CLIENTS_ENV" ]]; then
        while IFS='|' read -r name ip tenants; do
            [[ -n "${name:-}" && "$name" != \#* ]] || continue
            add_unique clients "$name"
            CLIENTIP["$name"]="$ip"
            SERVES["$name"]="${tenants//,/ }"
            PREFIX["$name"]=""
        done < "$CLIENTS_ENV"
    fi

    # One machine, one namespace per tenant: one pseudo-client each, same
    # address, different command prefix.
    if (( WITH_NETNS )) && [[ -r "$NETNS_ENV" ]]; then
        while IFS='|' read -r name ip tenants; do
            [[ -n "${name:-}" && "$name" != \#* ]] || continue
            for ns in ${tenants//,/ }; do
                add_unique clients "netns/${ns}"
                CLIENTIP["netns/${ns}"]="$ip"
                SERVES["netns/${ns}"]="$ns"
                PREFIX["netns/${ns}"]="ip netns exec ${ns} "
            done
        done < "$NETNS_ENV"
    fi

    local src dest n rc
    for src in "${clients[@]}"; do
        if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@${CLIENTIP[$src]}" true 2>/dev/null; then
            echo "  Cannot ssh to ${src} at ${CLIENTIP[$src]} - skipping." >&2
            for dest in "${tenants_all[@]}"; do VM["$src,$dest"]="NO-SSH"; done
            continue
        fi
        for dest in "${tenants_all[@]}"; do
            if [[ -z "${PODADDR[$dest]:-}" ]]; then VM["$src,$dest"]="NO-UDN"; continue; fi
            case " ${SERVES[$src]} " in
                *" $dest "*) ;;
                *) if shared_with_owned "${SERVES[$src]}" "$dest"; then
                       VM["$src,$dest"]="AMBIG"
                       printf '  %-16s -> %-8s %-16s AMBIG (address shared with %s)\n' \
                           "$src" "$dest" "${PODADDR[$dest]}" "${ADDR_OWNERS[${PODADDR[$dest]}]}"
                       continue
                   fi ;;
            esac
            # A cell this client is supposed to reach gets the full count; one
            # it must not reach gets a single packet, since one answered packet
            # is already a leak.
            case " ${SERVES[$src]} " in *" $dest "*) n="$COUNT" ;; *) n=1 ;; esac
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@${CLIENTIP[$src]}" \
                "${PREFIX[$src]}ping -c$n -W2 ${PODADDR[$dest]}" >/dev/null 2>&1; rc=$?
            if (( rc == 0 )); then
                VM["$src,$dest"]="ok"
                printf '  %-16s -> %-8s %-16s ok\n' "$src" "$dest" "${PODADDR[$dest]}"
            else
                VM["$src,$dest"]="FAIL"
                printf '  %-16s -> %-8s %-16s FAIL\n' "$src" "$dest" "${PODADDR[$dest]}"
            fi
        done
    done
}

print_vm_matrix() {
    echo
    echo "client VM -> pod   (expect ok only for the tenants each VM serves)"
    printf '%-16s' 'client'
    for c in "${tenants_all[@]}"; do printf ' %-10s' "$c"; done
    echo
    for r in "${clients[@]}"; do
        printf '%-16s' "$r"
        for c in "${tenants_all[@]}"; do printf ' %-10s' "${VM["$r,$c"]:--}"; done
        echo
    done
}

vm_verdict() {
    local r c v expected bad=0
    for r in "${clients[@]}"; do
        for c in "${tenants_all[@]}"; do
            v="${VM["$r,$c"]:-}"
            [[ "$v" == "NO-SSH" || "$v" == "NO-UDN" || "$v" == "AMBIG" ]] && continue
            case " ${SERVES[$r]} " in *" $c "*) expected=ok ;; *) expected=FAIL ;; esac
            if [[ "$expected" == "ok" && "$v" != "ok" ]]; then
                echo "  BROKEN  $r serves $c but cannot reach its pods"
                bad=$((bad + 1))
            elif [[ "$expected" == "FAIL" && "$v" == "ok" ]]; then
                echo "  LEAK    $r reached $c, which it has no VLAN for"
                bad=$((bad + 1))
            fi
        done
    done
    (( bad == 0 )) && echo "  clean: every client VM reached exactly the tenants it serves"
    return $bad
}

# ---------------------------------------------------------------------------
# Identity check: where two tenants hold the SAME pod address, which one answers?
# ---------------------------------------------------------------------------
# This is the only part of the script that proves isolation rather than
# inferring it. Reachability says a reply came back; it cannot say from where.
# ICMP InEchos in /proc/net/snmp is counted by the kernel of the pod that
# actually received the echo request, so reading it on both candidate pods
# either side of a ping names the responder.
#
# If OVN happened to allocate distinct addresses to blue and red, there is no
# collision to test and the script says so rather than inventing a result.
# That is not a weaker outcome - the subnets are still identical, and the two
# matrices above still carry the isolation finding.
in_echos() {  # namespace, pod
    oc -n "$1" exec "$2" -- cat /proc/net/snmp 2>/dev/null |
        awk '/^Icmp:/ { if (!h) { for (i=1;i<=NF;i++) if ($i=="InEchos") c=i; h=1 } else print $c }'
}

identity_check() {
    echo
    echo "Overlapping-address identity check"
    echo
    local -A owners
    local tenant node ns pod addr
    for rec in "${records[@]}"; do
        IFS=$'\t' read -r tenant node ns pod addr <<< "$rec"
        [[ -n "$addr" ]] || continue
        case " ${owners[$addr]:-} " in
            *" $tenant "*) ;;
            *) owners["$addr"]="${owners[$addr]:-}${owners[$addr]:+ }$tenant" ;;
        esac
    done

    local shared=() a
    for a in "${!owners[@]}"; do
        [[ "${owners[$a]}" == *" "* ]] && shared+=("$a")
    done

    if (( ${#shared[@]} == 0 )); then
        echo "  No pod address is held by more than one tenant."
        echo "  blue and red share a subnet but OVN allocated them distinct"
        echo "  addresses, so there is no collision to disambiguate. The"
        echo "  matrices above are the isolation result."
        return 0
    fi

    local bad=0
    for a in "${shared[@]}"; do
        echo "  ${a} is held by: ${owners[$a]}"
        local src
        for src in ${owners[$a]}; do
            # Snapshot InEchos on every pod holding this address, ping from
            # src's ext container, snapshot again. Exactly one should move.
            local -A before after
            local t2 rec2 tn nd n2 p2 ad2
            for rec2 in "${records[@]}"; do
                IFS=$'\t' read -r tn nd n2 p2 ad2 <<< "$rec2"
                [[ "$ad2" == "$a" ]] || continue
                before["$tn/$n2/$p2"]=$(in_echos "$n2" "$p2")
            done
            ext_exec "$src" ping -c3 -W2 "$a" >/dev/null 2>&1
            local answered="" key delta
            for rec2 in "${records[@]}"; do
                IFS=$'\t' read -r tn nd n2 p2 ad2 <<< "$rec2"
                [[ "$ad2" == "$a" ]] || continue
                key="$tn/$n2/$p2"
                after["$key"]=$(in_echos "$n2" "$p2")
                delta=$(( ${after[$key]:-0} - ${before[$key]:-0} ))
                (( delta > 0 )) && answered="${answered}${answered:+ }${tn}(+${delta})"
            done
            if [[ "$answered" == "${src}(+"* && "$answered" != *" "* ]]; then
                printf '    %-10s pinged %-16s answered by %-24s correct\n' "${src}-ext" "$a" "$answered"
            elif [[ -z "$answered" ]]; then
                printf '    %-10s pinged %-16s answered by %-24s unreachable\n' "${src}-ext" "$a" "(nothing)"
            else
                printf '    %-10s pinged %-16s answered by %-24s WRONG TENANT\n' "${src}-ext" "$a" "$answered"
                bad=$((bad + 1))
            fi
        done
    done
    if (( bad == 0 )); then
        echo
        echo "  Every ext container reached its OWN tenant's pod at the shared"
        echo "  address. Same destination IP, different VRF, different pod -"
        echo "  which is the whole claim of VRF-Lite, measured rather than assumed."
    fi
    return $bad
}

# ---------------------------------------------------------------------------
tenants_all=("${tenants[@]}")

probe_pods_to_ext
probe_ext_to_pods
(( WITH_VMS )) && probe_from_vms
print_matrix "pod -> external endpoint   (expect ok on the diagonal only)" M1 "pod tenant"
print_matrix "external endpoint -> pod   (expect ok on the diagonal only)" M2 "ext tenant"
(( WITH_VMS )) && print_vm_matrix

echo
ambig=0
for a in "${!ADDR_OWNERS[@]}"; do
    [[ "${ADDR_OWNERS[$a]}" == *" "* ]] || continue
    ambig=1
    echo "NOTE  ${a} is a pod address in BOTH ${ADDR_OWNERS[$a]}."
    echo "      Cells marked AMBIG above are excluded from the verdict: a ping"
    echo "      to that address answers for either tenant and ICMP cannot say"
    echo "      which. The identity check below settles it from the pods'"
    echo "      own counters, and scripts/udn-web-demo.sh settles it from the"
    echo "      page each pod serves."
done
(( ambig )) && echo

echo "Verdict"
rc=0
echo " pod -> ext:"
verdict M1 "external network" || rc=$?
echo " ext -> pod:"
verdict M2 "pods" || rc=$?
(( WITH_VMS )) && { echo " client VM -> pod:"; vm_verdict || rc=$?; }
identity_check || rc=$?

echo
if (( rc == 0 )); then
    echo "PASS - phase 3 isolation holds in both directions."
else
    echo "FAIL - see the LEAK/BROKEN/WRONG TENANT lines above."
    echo
    echo "A whole row broken       -> that tenant's VRF-Lite handoff: check the"
    echo "                            NNCP for its VLAN subinterface, and"
    echo "                            'show bgp vrf <tenant> ipv4 unicast' on leaf1."
    echo "Everything reachable     -> targetVRF never took effect; the tenants are"
    echo "                            still in leaf1's default VRF. That is phase 2."
    echo "Right subnet, wrong pod  -> the VLAN handoff is landing in the wrong VRF."
fi
exit $(( rc > 0 ? 1 : 0 ))
