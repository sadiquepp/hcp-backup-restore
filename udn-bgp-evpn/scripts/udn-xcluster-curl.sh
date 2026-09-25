#!/usr/bin/env bash
# Pod-to-pod HTTP across two clusters. Two labs, two different questions.
#
#   scripts/udn-xcluster-curl.sh <kubeconfig> <kubeconfig> [...]
#   UDN_KUBECONFIGS="/a/kubeconfig /b/kubeconfig" scripts/udn-xcluster-curl.sh
#   scripts/udn-xcluster-curl.sh --vrflite <kubeconfig> <kubeconfig>
#
# EVPN asks: does a tenant reach ITSELF in the other cluster, and does nothing
# else answer at all. Two shapes of "itself", both built on this lab:
#
#   Layer2 (green, purple)  one stretched broadcast domain on an L2VNI -
#                           bridged, MAC routes (type-2), one subnet shared
#   Layer3 (violet)         one routed tenant on an L3VNI - each cluster owns
#                           a slice of the subnet (evpn_udn_subnets) and routes
#                           to the other's over prefix routes (type-5)
#
# The Layer3 row has a control built in: blue is on the hub beside violet with
# a different route target, so violet on the SNO must reach violet on the hub
# and NOT blue. Same fabric, same VTEPs - the route target is the boundary.
#
# VRF-Lite asks a different question, because there is no stretched Layer2 and
# no tenant exists in both clusters. It asks whether the OPENINGS in
# udn_vrf_leaks are real pod to pod, and - the part that matters - whether the
# pairs left out are genuinely shut. Expected, and asserted:
#
#   same cluster, same tenant        answers   its own UDN
#   same cluster, different tenant   silent    the advertised-network-subnets
#                                              ACL, whatever the leaks say
#   other cluster, leaked pair       answers   leaf1 imports the route, and
#                                              neither cluster's ACL sees both
#                                              sides as locally advertised
#   other cluster, not leaked        silent    no route in that tenant's VRF
#
# That last row is the point. Every other test in this lab asks from a fabric
# netns client, whose address is NOT an advertised UDN subnet and therefore
# never meets the ACL at all. This is the only test where both endpoints are
# pods, which is the case the isolation claim is actually about.
#
# The mode is auto-detected and printed: a tenant present in two clusters
# means EVPN, none means VRF-Lite. --evpn / --vrflite force it.
#
# WHERE THE LEAK PAIRS COME FROM. ../vars.yaml:udn_vrf_leaks, read with
# python3, or UDN_VRF_LEAKS="blue:green violet:orange ..." / --leaks to
# override. Deliberately the CONFIG and not leaf1's tables: checking the
# datapath against the fabric that programs it would only prove they agree.
#
# Every other test in this repo asks the question from outside the clusters -
# the fabric client, the ingress, the -ext containers. This one asks it from
# inside: a pod in one cluster curling a pod in the other, over the L2VNI, with
# nothing in the path that belongs to either cluster's host networking.
#
# WHY CURL AND NOT PING. Two tenants on a stretched Layer2 network can hold the
# SAME address - green and purple both carry 10.204.0.0/16, and on this lab
# both their SNO pods sit on 10.204.128.2. scripts/udn-vrf-isolation.sh has to
# mark those cells AMBIG, because ICMP cannot say which of the two answered. A
# page can: it names its own tenant and its own cluster. So the cell that is
# unresolvable by ping is the most informative one here.
#
# WHAT A PASS MEANS. Same tenant reaches same tenant in either cluster, and
# nothing else answers at all. For a Layer2 tenant that is one broadcast domain
# spanning two clusters; for a Layer3 tenant it is one routed network spanning
# them; in both, tenant isolation intact across the boundary.
set -uo pipefail

PORT="${UDN_WEB_PORT:-8080}"
# Under VRF-Lite most cells are EXPECTED to time out, so the timeout is the
# runtime. 30 cells at 5s is two and a half minutes of waiting for silence.
TIMEOUT="${UDN_CURL_TIMEOUT:-5}"
MODE="${UDN_XCLUSTER_MODE:-}"
LEAKS="${UDN_VRF_LEAKS:-}"

kubeconfigs=()
while (( $# )); do
    case "$1" in
        # The whole leading comment block, however long it grows - a fixed
        # line range silently truncated the help the first time it did.
        -h|--help) awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
        --evpn)    MODE="evpn"; shift ;;
        --vrflite) MODE="vrflite"; shift ;;
        --shared)  MODE="shared"; shift ;;
        --leaks)   LEAKS="$2"; shift 2 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *)  kubeconfigs+=("$1"); shift ;;
    esac
done
if (( ${#kubeconfigs[@]} == 0 )); then
    read -r -a kubeconfigs <<<"${UDN_KUBECONFIGS:-}"
fi
if (( ${#kubeconfigs[@]} < 2 )); then
    echo "Need at least two kubeconfigs - this test is about crossing between" >&2
    echo "clusters. Pass them as arguments or set UDN_KUBECONFIGS." >&2
    echo >&2
    echo "  scripts/udn-xcluster-curl.sh \\" >&2
    echo "      /var/lib/libvirt/images/hub_install/auth/kubeconfig \\" >&2
    echo "      /var/lib/libvirt/images/sno_install/auth/kubeconfig" >&2
    exit 1
fi
command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
(( BASH_VERSINFO[0] >= 4 )) || { echo "This needs bash 4+; found ${BASH_VERSION}." >&2; exit 1; }

# Keyed by "cluster/tenant" throughout. Keying by tenant alone is what makes a
# single-cluster script single-cluster, and keying by address alone cannot
# survive two pods sharing one.
declare -A WEBADDR SRCPOD SRCNS SRCKUBE TARGETS RESULT
declare -A CROSSED_T=()   # tenants that answered across the cluster boundary
keys=(); addrs=()

echo "Discovering web pods and test pods in each cluster"
echo
for kc in "${kubeconfigs[@]}"; do
    [[ -r "$kc" ]] || { echo "  cannot read kubeconfig: $kc" >&2; exit 1; }
    for ns in $(oc --kubeconfig="$kc" get ns -l udn-tenant \
                    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        tenant=$(oc --kubeconfig="$kc" get ns "$ns" -o jsonpath='{.metadata.labels.udn-tenant}')
        web=$(oc --kubeconfig="$kc" -n "$ns" get pods -l app=udn-web \
                 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        [[ -n "$web" ]] || continue
        # The page is the source of truth for both facts. The address is read
        # off ovn-udn1 by the init container, not from status.podIP, which for
        # a primary UDN is the CLUSTER network address on eth0 and has nothing
        # to do with what is being curled here.
        page=$(oc --kubeconfig="$kc" -n "$ns" exec "$web" -c httpd -- \
                  cat /var/www/html/index.html 2>/dev/null)
        addr=$(printf '%s\n' "$page" | awk '/^udn:/ {split($2, a, "/"); print a[1]}')
        cluster=$(printf '%s\n' "$page" | awk '/^cluster:/ {print $2}')
        [[ -n "$addr" && -n "$cluster" ]] || continue
        # Something to curl FROM. The udn-test DaemonSet is the right source:
        # it is on the tenant's primary UDN and its image has curl.
        src=$(oc --kubeconfig="$kc" -n "$ns" get pods -l app=udn-test \
                 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        key="${cluster}/${tenant}"
        keys+=("$key"); WEBADDR["$key"]="$addr"
        SRCPOD["$key"]="$src"; SRCNS["$key"]="$ns"; SRCKUBE["$key"]="$kc"
        # Targets are addresses, and two keys can share one - that is the case
        # this script exists to resolve.
        if [[ -z "${TARGETS[$addr]:-}" ]]; then
            addrs+=("$addr"); TARGETS["$addr"]="$key"
        else
            TARGETS["$addr"]="${TARGETS[$addr]} $key"
        fi
        printf '  %-14s web %-15s test-pod %s\n' "$key" "$addr" "${src:-(none)}"
    done
done

(( ${#keys[@]} )) || { echo "No tenants with a udn-web pod found. Run --tags web first." >&2; exit 1; }

clusters=$(printf '%s\n' "${keys[@]}" | cut -d/ -f1 | sort -u | tr '\n' ' ')
if (( $(wc -w <<<"$clusters") < 2 )); then
    echo >&2
    echo "Only found tenants in: $clusters" >&2
    echo "Both kubeconfigs resolved to the same cluster, or one has no web pods." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Mode. A tenant present in two clusters is only possible under EVPN, where
# one stretched UDN spans both; under VRF-Lite each tenant lives in exactly
# one cluster. That makes the detection a property of the lab rather than a
# flag someone has to remember to pass.
#
# Shared is the one it cannot detect: like VRF-Lite it has no tenant in two
# clusters, and telling them apart would mean recognising which subnet range
# the pods came from, which is a guess about this lab's numbering rather than
# a property of the network. --shared has to be passed.
# ---------------------------------------------------------------------------
if [[ -z "$MODE" ]]; then
    dupes=$(printf '%s\n' "${keys[@]}" | cut -d/ -f2 | sort | uniq -d)
    if [[ -n "$dupes" ]]; then MODE="evpn"; else MODE="vrflite"; fi
fi
echo
if [[ "$MODE" == "evpn" ]]; then
    echo "Mode: EVPN - tenants present in both clusters: $(tr '\n' ' ' <<<"${dupes:-}")"
elif [[ "$MODE" == "shared" ]]; then
    echo "Mode: shared VRF - every UDN is leaked into the one default VRF."
    echo "      Two questions: does the same-cluster ACL, the only tenant"
    echo "      separation left, still hold; and does anything unexpectedly"
    echo "      carry pod egress onto the fabric, which this phase does not"
    echo "      configure and phase 3 is what adds."
else
    echo "Mode: VRF-Lite - no tenant is in more than one cluster, so the"
    echo "      question is which of the udn_vrf_leaks openings are real."
fi

# Leak pairs, for the VRF-Lite verdict only.
if [[ "$MODE" == "vrflite" && -z "$LEAKS" ]]; then
    vars_yaml="$(dirname "$(readlink -f "$0")")/../../vars.yaml"
    if command -v python3 >/dev/null && [[ -r "$vars_yaml" ]]; then
        LEAKS=$(python3 - "$vars_yaml" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(' '.join('%s:%s' % (p[0], p[1])
               for p in (d.get('udn_vrf_leaks') or []) if len(p) == 2))
PY
        )
    fi
    if [[ -z "$LEAKS" ]]; then
        echo >&2
        echo "Could not read udn_vrf_leaks from $vars_yaml." >&2
        echo "Pass them instead:  --leaks 'blue:green violet:orange ...'" >&2
        echo "or set UDN_VRF_LEAKS. Without them this script cannot say which" >&2
        echo "cells are supposed to answer, and a matrix with no expectation" >&2
        echo "is a report, not a test." >&2
        exit 1
    fi
    echo "      leaks: $LEAKS"
fi

# leaked <tenantA> <tenantB> - the pairs are symmetric, and vars.yaml says so
# explicitly: a one-way import gives a path out and none back.
leaked() {
    [[ " $LEAKS " == *" ${1}:${2} "* || " $LEAKS " == *" ${2}:${1} "* ]]
}

echo
echo "Curling every web pod from every tenant's test pod, in both clusters"
echo
for src in "${keys[@]}"; do
    [[ -n "${SRCPOD[$src]}" ]] || { echo "  $src has no udn-test pod to curl from - skipped"; continue; }
    for a in "${addrs[@]}"; do
        got=$(oc --kubeconfig="${SRCKUBE[$src]}" -n "${SRCNS[$src]}" exec "${SRCPOD[$src]}" -- \
                 curl -sS --max-time "$TIMEOUT" "http://${a}:${PORT}/" 2>/dev/null \
              | awk '/I am/ {print; exit}')
        RESULT["$src,$a"]="${got:-(no answer)}"
    done
done

# ---------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------
echo "What answered"
echo
printf '  %-16s' "from \\ to"
for a in "${addrs[@]}"; do printf '%-22s' "$a"; done; echo
printf '  %-16s' "(holders)"
for a in "${addrs[@]}"; do printf '%-22s' "$(tr ' ' ',' <<<"${TARGETS[$a]}")"; done; echo
for src in "${keys[@]}"; do
    printf '  %-16s' "$src"
    for a in "${addrs[@]}"; do printf '%-22s' "${RESULT[$src,$a]:-(skipped)}"; done
    echo
done

# ---------------------------------------------------------------------------
# Verdict. What 'right' means depends on the mode, and only on the mode -
# the matrix above is the same measurement either way.
# ---------------------------------------------------------------------------
echo
bad=0; crossed=0

if [[ "$MODE" == "evpn" ]]; then
    for src in "${keys[@]}"; do
        src_tenant="${src#*/}"
        [[ -n "${SRCPOD[$src]}" ]] || continue
        for a in "${addrs[@]}"; do
            got="${RESULT[$src,$a]:-}"
            # Which of this address's holders, if any, shares the source's tenant?
            expect=""
            for holder in ${TARGETS[$a]}; do
                [[ "${holder#*/}" == "$src_tenant" ]] && expect="$holder"
            done
            if [[ -n "$expect" ]]; then
                want_cluster="${expect%%/*}"
                if [[ ! "$got" =~ ^"I am $src_tenant"( on .+)?$ ]]; then
                    echo "  BROKEN  $src -> $a  expected tenant ${src_tenant}, got: $got"
                    bad=$((bad+1))
                elif [[ "$got" != *" on ${want_cluster}" ]]; then
                    echo "  WRONGCLUSTER  $src -> $a  expected ${want_cluster}, got: $got"
                    bad=$((bad+1))
                elif [[ "${src%%/*}" != "$want_cluster" ]]; then
                    crossed=$((crossed+1))
                    CROSSED_T["$src_tenant"]=1
                fi
            elif [[ "$got" != "(no answer)" ]]; then
                echo "  LEAK    $src -> $a  serves none of [${TARGETS[$a]}] but got: $got"
                bad=$((bad+1))
            fi
        done
    done

elif [[ "$MODE" == "shared" ]]; then
    # ---------------------------------------------------------------------
    # Shared VRF (phase 2). TWO different mechanisms produce silence here,
    # and keeping them apart is the whole point of this verdict:
    #
    #   same cluster, same tenant        answers
    #   same cluster, different tenant   silent - the advertised-network-
    #                                    subnets ACL. Its address set holds
    #                                    this cluster's own advertised
    #                                    prefixes and the rule drops a packet
    #                                    whose src AND dst are both in it.
    #   other cluster, any tenant        silent - and NOT because of the ACL.
    #                                    Phase 2 gives a tenant no path to the
    #                                    fabric at all. The pod's gateway
    #                                    router holds only its own /16 and a
    #                                    default pointing at the MANAGEMENT
    #                                    gateway, so egress toward another
    #                                    cluster's UDN leaves by the
    #                                    management NIC and is dropped there.
    #                                    The node does learn the other
    #                                    cluster's prefixes over BGP, but into
    #                                    the MAIN table, which pod egress
    #                                    never reads. README.md's phase-2 row
    #                                    states this as expected behaviour.
    #                                    Giving the tenant its own path to the
    #                                    fabric is what phase 3 does, and
    #                                    there cross-cluster pod-to-pod works.
    #
    # An earlier version of this verdict expected the cross-cluster cells to
    # ANSWER, reasoning that one default VRF plus a per-cluster ACL leaves
    # nothing to stop them. The ACL half of that is correct and was measured:
    # the hub's set holds 10.220-10.224 only, so it never matches a pair that
    # spans clusters. It is simply moot - the packet dies at the gateway
    # router long before any ACL is consulted. The reasoning was extrapolated
    # from one VRF-Lite observation (violet -> green) without checking that
    # phase 2 has the path phase 3 adds.
    #
    # udn-web-demo.sh --host passing in this phase contradicts none of it:
    # that client sits ON the management segment, so pod-to-client is a
    # direct ARP off br-ex and client-to-pod arrives inbound over BGP.
    # Neither direction exercises pod egress toward the fabric.
    # ---------------------------------------------------------------------
    # One address with two holders is a phase-2 configuration error on its
    # own terms - udn_subnet_shared must be unique across ALL tenants in ALL
    # clusters - and is reported whatever the curls did, because with every
    # cross-cluster cell silent no curl can reveal it.
    for a in "${addrs[@]}"; do
        n=0; for holder in ${TARGETS[$a]}; do n=$((n+1)); done
        if (( n > 1 )); then
            echo "  DUPLICATE  $a is held by (${TARGETS[$a]})."
            echo "             Phase 2 requires udn_subnet_shared unique across ALL"
            echo "             tenants; two holders of one address means it is not."
            bad=$((bad+1))
        fi
    done
    for src in "${keys[@]}"; do
        src_cluster="${src%%/*}"; src_tenant="${src#*/}"
        [[ -n "${SRCPOD[$src]}" ]] || continue
        for a in "${addrs[@]}"; do
            got="${RESULT[$src,$a]:-}"
            expect=""
            # Why silence is expected for this cell, if it is. A holder in
            # the source's own cluster means the ACL is the mechanism;
            # otherwise it is the missing fabric path.
            silent_why="phase 2 gives the tenant no path to the fabric"
            for holder in ${TARGETS[$a]}; do
                if [[ "${holder%%/*}" == "$src_cluster" ]]; then
                    silent_why="the advertised-network-subnets ACL"
                    [[ "${holder#*/}" == "$src_tenant" ]] && expect="$holder"
                fi
            done

            if [[ -n "$expect" ]]; then
                want_tenant="${expect#*/}"; want_cluster="${expect%%/*}"
                if [[ ! "$got" =~ ^"I am $want_tenant"( on .+)?$ ]]; then
                    echo "  BROKEN  $src -> $a  expected ${want_tenant} (its own UDN), got: $got"
                    bad=$((bad+1))
                elif [[ "$got" != *" on ${want_cluster}" ]]; then
                    echo "  WRONGCLUSTER  $src -> $a  expected ${want_cluster}, got: $got"
                    bad=$((bad+1))
                fi
            elif [[ "$got" != "(no answer)" ]]; then
                if [[ "$silent_why" == "the advertised-network-subnets ACL" ]]; then
                    echo "  ACL BREACH  $src -> $a  a different tenant in the SAME cluster"
                    echo "              answered: $got"
                    echo "              In this phase the ACL is the only separation there"
                    echo "              is. If it is not holding, nothing is."
                else
                    echo "  UNEXPECTED  $src -> $a  answered across a cluster boundary: $got"
                    echo "              Phase 2 has no pod path to the fabric, so this"
                    echo "              cell should be silent. Something is routing pod"
                    echo "              egress onto the fabric that this phase does not"
                    echo "              configure - check gatewayConfig.routingViaHost"
                    echo "              and for leftover phase-3 VRF/VLAN plumbing."
                fi
                crossed=$((crossed+1))
                bad=$((bad+1))
            fi
        done
    done

else
    # ---------------------------------------------------------------------
    # VRF-Lite. For each cell work out who SHOULD answer, in this order:
    #   1. this address is the source's own tenant, in the source's cluster
    #   2. otherwise a holder in the OTHER cluster whose tenant is leaked to
    #      the source's
    # and if neither applies, nothing should answer at all. Two leaked
    # holders on one address is a configuration error, not a pass: violet's
    # table would hold two routes for one prefix and FRR would install
    # whichever won.
    # ---------------------------------------------------------------------
    for src in "${keys[@]}"; do
        src_cluster="${src%%/*}"; src_tenant="${src#*/}"
        [[ -n "${SRCPOD[$src]}" ]] || continue
        for a in "${addrs[@]}"; do
            got="${RESULT[$src,$a]:-}"
            expect=""; why=""; ambig=""; same_cluster_holder=""
            for holder in ${TARGETS[$a]}; do
                [[ "${holder%%/*}" == "$src_cluster" ]] && same_cluster_holder=yes
                [[ "${holder%%/*}" == "$src_cluster" && "${holder#*/}" == "$src_tenant" ]] \
                    && { expect="$holder"; why="its own UDN"; }
            done
            if [[ -z "$expect" ]]; then
                for holder in ${TARGETS[$a]}; do
                    [[ "${holder%%/*}" == "$src_cluster" ]] && continue
                    leaked "$src_tenant" "${holder#*/}" || continue
                    [[ -n "$expect" ]] && ambig="$expect ${holder}"
                    expect="$holder"; why="leak ${src_tenant}:${holder#*/}"
                done
            fi

            if [[ -n "$ambig" ]]; then
                echo "  AMBIG   $src -> $a  two leaked holders ($ambig) share this"
                echo "          address, so ${src_tenant}'s VRF would hold two routes for one"
                echo "          prefix. Fix udn_vrf_leaks - one partner per distinct subnet."
                bad=$((bad+1))
            elif [[ -n "$expect" ]]; then
                want_tenant="${expect#*/}"; want_cluster="${expect%%/*}"
                if [[ ! "$got" =~ ^"I am $want_tenant"( on .+)?$ ]]; then
                    echo "  BROKEN  $src -> $a  expected ${want_tenant} (${why}), got: $got"
                    bad=$((bad+1))
                elif [[ "$got" != *" on ${want_cluster}" ]]; then
                    echo "  WRONGCLUSTER  $src -> $a  expected ${want_cluster}, got: $got"
                    bad=$((bad+1))
                elif [[ "$want_cluster" != "$src_cluster" ]]; then
                    crossed=$((crossed+1))
                fi
            elif [[ "$got" != "(no answer)" ]]; then
                if [[ -n "$same_cluster_holder" ]]; then
                    echo "  ACL BREACH  $src -> $a  a different tenant in the SAME cluster"
                    echo "              answered: $got"
                    echo "              advertised-network-subnets should have dropped this,"
                    echo "              and no udn_vrf_leaks entry can legitimately open it."
                else
                    echo "  LEAK    $src -> $a  [${TARGETS[$a]}] is not leaked to ${src_tenant},"
                    echo "          so there should be no route. Got: $got"
                fi
                bad=$((bad+1))
            fi
        done
    done
fi

if (( bad )); then
    echo
    echo "FAIL - $bad cell(s) wrong."
    exit 1
fi

if [[ "$MODE" == "evpn" ]]; then
    echo "  clean: every tenant reached its own pods in BOTH clusters,"
    echo "         and nothing reached a tenant it does not belong to."
    echo
    echo "  ${crossed} of those answers crossed a cluster boundary, from:"
    echo "  ${!CROSSED_T[*]}"
    echo "  Each left one cluster's VTEP as VXLAN on the tenant's VNI and was delivered"
    echo "  inside the other cluster, with no address translation anywhere in the path."
    # Layer2 vs Layer3 is a property of the tenant, which the page does not
    # carry - read it from vars.yaml, best effort, the same way the VRF-Lite
    # verdict reads udn_vrf_leaks. Without it the two explanations print
    # unlabelled rather than guessing.
    vars_yaml="$(dirname "$(readlink -f "$0")")/../../vars.yaml"
    topo=""
    if command -v python3 >/dev/null && [[ -r "$vars_yaml" ]]; then
        topo=$(python3 - "$vars_yaml" <<'PY2' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(' '.join('%s:%s' % (t['name'], t.get('topology', 'Layer3'))
               for t in (d.get('udn_bgp_tenants') or [])))
PY2
        )
    fi
    l2=""; l3=""
    for t in "${!CROSSED_T[@]}"; do
        case " $topo " in
            *" $t:Layer2 "*) l2+="$t " ;;
            *" $t:Layer3 "*) l3+="$t " ;;
        esac
    done
    if [[ -n "$l2" || -z "$topo" ]]; then
        echo
        echo "  Layer2${l2:+ (${l2% })}: BRIDGED. One broadcast domain on an L2VNI - the"
        echo "  destination was learned as a MAC (type-2 route), and no router touched"
        echo "  the packet between the two pods."
    fi
    if [[ -n "$l3" || -z "$topo" ]]; then
        echo
        echo "  Layer3${l3:+ (${l3% })}: ROUTED. Each cluster owns a slice of the subnet and"
        echo "  advertises its node subnets as type-5 routes under the tenant's one"
        echo "  route target. The source node routed the packet into the tenant's VRF,"
        echo "  onto the L3VNI, straight to the destination node's VTEP - leaf1 only"
        echo "  carries the outer packet. A different route target on the same fabric"
        echo "  (blue beside violet on the hub) stayed silent above: the boundary is"
        echo "  the route target, not the cluster."
    fi
    for a in "${addrs[@]}"; do
        if [[ "${TARGETS[$a]}" == *" "* ]]; then
            echo
            echo "  ${a} is held by ${TARGETS[$a]} - one address, more than one pod."
            echo "  Every curl to it returned the page of the tenant that asked, which is"
            echo "  the cell scripts/udn-vrf-isolation.sh has to mark AMBIG because ICMP"
            echo "  cannot tell two identical addresses apart. The network chose, and the"
            echo "  page said so."
        fi
    done
elif [[ "$MODE" == "shared" ]]; then
    echo "  clean: every tenant reached its own pods, and every other cell stayed"
    echo "         silent - for two different reasons, both expected here."
    echo
    echo "  Same cluster, different tenant: the advertised-network-subnets ACL."
    echo "  Its address set holds this cluster's own advertised prefixes and the"
    echo "  rule drops a packet whose src AND dst are both in it. In this phase"
    echo "  that ACL is the only tenant separation there is."
    echo
    echo "  Across the cluster boundary: no path, rather than a policy. A pod's"
    echo "  gateway router in phase 2 holds its own /16 and a default pointing at"
    echo "  the MANAGEMENT gateway - nothing steers pod egress at the fabric. The"
    echo "  node learns the other cluster's prefixes over BGP into its main"
    echo "  table, which pod egress never reads. The ACL never even gets asked."
    echo
    echo "  So this phase carries pod subnets over BGP and serves them to fabric"
    echo "  clients, which the client tests prove, but it does not give pods a"
    echo "  route off the node to another cluster. That is phase 3: VRF-Lite"
    echo "  gives the tenant VRF its own fabric path, and cross-cluster pod-to-"
    echo "  pod works there, gated by udn_vrf_leaks. Or EVPN."
else
    echo "  clean: every tenant reached its own pods, every pair in udn_vrf_leaks"
    echo "         reached each other POD TO POD across the cluster boundary, and"
    echo "         every pair not in it stayed silent - including the two that"
    echo "         share a subnet with a pair that is open."
    echo
    echo "  ${crossed} answers crossed a cluster boundary. Each is an opening in"
    echo "  udn_vrf_leaks doing what it says: leaf1 imports the route into the"
    echo "  tenant's VRF, and neither cluster's advertised-network-subnets ACL"
    echo "  sees both endpoints as locally advertised, so neither drops it."
    echo
    echo "  Within a cluster that ACL is the backstop and no leak can open it;"
    echo "  the same-cluster cells above are silent for that reason, not because"
    echo "  the tenants are unrouted."
    for a in "${addrs[@]}"; do
        if [[ "${TARGETS[$a]}" == *" "* ]]; then
            echo
            echo "  LIMIT: ${a} is held by ${TARGETS[$a]}. Where only one of those is"
            echo "  leaked to a given source, this test can show the answer came from"
            echo "  that one - but it CANNOT show the other would be unreachable if it"
            echo "  had an address of its own, because there is no address to curl."
            echo "  Those cells prove the route lands in the right VRF, not isolation."
        fi
    done
fi
