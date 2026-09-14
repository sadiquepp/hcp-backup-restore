#!/usr/bin/env bash
#
# Curl every tenant's web pod from every per-tenant client VM, and print what
# came back.
#
#   scripts/udn-web-demo.sh
#
# This is the demo the matrices in udn-vrf-isolation.sh imply but cannot show.
# A ping tells you something answered; it cannot tell you WHAT. Once blue and
# red carry the same subnet that distinction is the entire question, and an
# HTTP response settles it - the page names its own tenant, pod, node and
# address.
#
# What to look at: every address below is inside ONE subnet, and each client VM
# reaches exactly one of them. Nothing differs between the two machines but the
# VLAN tag on their fabric interface.
#
# Needs --tags web for the pods and --tags clabtenantclients for the VMs.
set -uo pipefail

PORT="${UDN_WEB_PORT:-8080}"
SSH_KEY="${UDN_CLIENT_SSH_KEY:-$HOME/.ssh/lab_rsa}"
SSH_USER="${UDN_CLIENT_SSH_USER:-root}"
CLIENTS_ENV="${UDN_CLIENTS_ENV:-$(dirname "$0")/../udn-bgp/tenant-clients.env}"
NETNS_ENV="${UDN_NETNS_ENV:-$(dirname "$0")/../udn-bgp/netns-client.env}"
WITH_NETNS=0
WITH_VMS=1
for arg in "$@"; do
    case "$arg" in
        --netns)      WITH_NETNS=1 ;;
        --netns-only) WITH_NETNS=1; WITH_VMS=0 ;;
        --vms-only)   WITH_NETNS=0; WITH_VMS=1 ;;
        -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
if (( BASH_VERSINFO[0] < 4 )); then
    echo "This needs bash 4+; found ${BASH_VERSION}." >&2; exit 1
fi
if (( WITH_VMS )) && [[ ! -r "$CLIENTS_ENV" ]]; then
    echo "No per-tenant client manifest at $CLIENTS_ENV; continuing without it." >&2
    echo "Build them with --tags clabtenantclients, or set UDN_CLIENTS_ENV." >&2
    WITH_VMS=0
fi
if (( WITH_NETNS )) && [[ ! -r "$NETNS_ENV" ]]; then
    echo "No namespace-client manifest at $NETNS_ENV." >&2
    echo "Build it with --tags clabnsclient, or set UDN_NETNS_ENV." >&2
    exit 1
fi
if (( ! WITH_VMS && ! WITH_NETNS )); then
    echo "No clients to test. Build --tags clabtenantclients or --tags clabnsclient." >&2
    exit 1
fi

declare -A WEBADDR RESULT SERVES CLIENTIP ADDR_TENANTS PREFIX
tenants=(); clients=(); addrs=()

on_client() {  # client-ip, command
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@$1" "$2" 2>&1
}

# ---------------------------------------------------------------------------
# Where the pages are. Read off the interface, not the annotation.
# ---------------------------------------------------------------------------
for ns in $(oc get ns -l udn-tenant -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    tenant=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.udn-tenant}')
    pod=$(oc -n "$ns" get pods -l app=udn-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$pod" ]] || continue
    # From the page, not from `ip`: the httpd image is ubi9/httpd-24 and has no
    # iproute in it. The init container already read ovn-udn1 and wrote the
    # address into the page, which is also the more honest source - it is what
    # the pod that will answer says about itself.
    addr=$(oc -n "$ns" exec "$pod" -c httpd -- cat /var/www/html/index.html 2>/dev/null \
             | awk '/^udn:/ {print $2}')
    [[ -n "$addr" && "$addr" != "(no"* ]] || continue
    tenants+=("$tenant")
    a="${addr%%/*}"
    WEBADDR["$tenant"]="$a"
    # Keyed by ADDRESS, not by tenant, because two tenants sharing a subnet can
    # land on the same one - which is the entire point of green and purple. A
    # loop over tenants would then curl one URL twice and judge the second
    # answer against the wrong tenant.
    # Two separate questions, and conflating them listed a shared address
    # twice: "is this ADDRESS new" decides whether it joins the probe list,
    # "is this TENANT already recorded against it" decides whether to extend
    # the owner list. The old single case matched on the tenant, so the second
    # tenant on one address appended the address again - one extra column, one
    # duplicated banner, and every client curling that URL twice.
    if [[ -z "${ADDR_TENANTS[$a]:-}" ]]; then
        addrs+=("$a")
        ADDR_TENANTS["$a"]="$tenant"
    else
        case " ${ADDR_TENANTS[$a]} " in
            *" $tenant "*) ;;
            *) ADDR_TENANTS["$a"]+=" $tenant" ;;
        esac
    fi
done

(( ${#tenants[@]} )) || { echo "No udn-web pods found. Run --tags web first." >&2; exit 1; }

if (( WITH_VMS )); then
    while IFS='|' read -r name ip serves; do
        [[ -n "${name:-}" && "$name" != \#* ]] || continue
        clients+=("$name"); CLIENTIP["$name"]="$ip"
        SERVES["$name"]="${serves//,/ }"; PREFIX["$name"]=""
    done < "$CLIENTS_ENV"
fi

# The namespace client is one machine with one namespace per tenant, so it
# contributes one pseudo-client per namespace: same address, different command
# prefix. Everything downstream - the address-keyed probing, the matrix, the
# verdict - is identical, because "which tenants does this client serve" is the
# only thing any of it asks.
if (( WITH_NETNS )); then
    while IFS='|' read -r name ip nslist; do
        [[ -n "${name:-}" && "$name" != \#* ]] || continue
        for ns in ${nslist//,/ }; do
            clients+=("netns/${ns}"); CLIENTIP["netns/${ns}"]="$ip"
            SERVES["netns/${ns}"]="$ns"; PREFIX["netns/${ns}"]="ip netns exec ${ns} "
        done
    done < "$NETNS_ENV"
fi

echo "Web pods"
for t in "${tenants[@]}"; do
    printf '  %-8s http://%s:%s/\n' "$t" "${WEBADDR[$t]}" "$PORT"
done
for a in "${addrs[@]}"; do
    if [[ "${ADDR_TENANTS[$a]}" == *" "* ]]; then
        echo
        echo "  *** ${a} is served by ${ADDR_TENANTS[$a]} - ONE address, two pods."
        echo "      This is the case a ping cannot resolve and a page can."
    fi
done

# ---------------------------------------------------------------------------
# Curl each from each, and print the first line of whatever came back.
# ---------------------------------------------------------------------------
for c in "${clients[@]}"; do
    echo
    echo "=== from ${c} (${CLIENTIP[$c]}), serves ${SERVES[$c]} ==="
    for a in "${addrs[@]}"; do
        printf '  curl http://%-22s ' "${a}:${PORT}/"
        out=$(on_client "${CLIENTIP[$c]}" \
                "${PREFIX[$c]}curl -s --max-time 5 http://${a}:${PORT}/")
        if [[ -n "$out" && "$out" == I\ am\ * ]]; then
            RESULT["$c,$a"]="${out%%$'\n'*}"
            echo "-> ${RESULT[$c,$a]}   [${ADDR_TENANTS[$a]}]"
        else
            RESULT["$c,$a"]="(no answer)"
            echo "-> (no answer)"
        fi
    done
done

# ---------------------------------------------------------------------------
echo
echo "What answered"
printf '%-18s' 'client'
for a in "${addrs[@]}"; do printf ' %-14s' "$a"; done
echo
printf '%-18s' '(served by)'
for a in "${addrs[@]}"; do printf ' %-14s' "${ADDR_TENANTS[$a]}"; done
echo
for c in "${clients[@]}"; do
    printf '%-18s' "$c"
    for a in "${addrs[@]}"; do printf ' %-14s' "${RESULT[$c,$a]:--}"; done
    echo
done

# The verdict is about identity, not reachability: a page from the wrong tenant
# is a leak that every ping-based test in this repo would report as a pass.
echo
bad=0
for c in "${clients[@]}"; do
    for a in "${addrs[@]}"; do
        got="${RESULT[$c,$a]:-}"
        # Which tenant on this address does this client actually serve? At most
        # one - two tenants sharing an address can never share a client, since
        # one host holds one route to the prefix.
        expect=""
        for t in ${ADDR_TENANTS[$a]}; do
            case " ${SERVES[$c]} " in *" $t "*) expect="$t" ;; esac
        done
        if [[ -n "$expect" ]]; then
            if [[ "$got" != "I am $expect" ]]; then
                echo "  BROKEN  $c serves $expect at $a but got: $got"; bad=$((bad+1))
            fi
        else
            if [[ "$got" != "(no answer)" ]]; then
                echo "  LEAK    $c serves none of [${ADDR_TENANTS[$a]}] but $a answered: $got"
                bad=$((bad+1))
            fi
        fi
    done
done
if (( bad == 0 )); then
    echo "  clean: every page came from the tenant that was supposed to serve it,"
    echo "         and no page came from one that was not."
    echo
    echo "  Note every address curled above is inside one subnet. The only"
    echo "  difference between these machines is the VLAN tag on their fabric"
    echo "  interface, and that is what decided which document came back."
    for a in "${addrs[@]}"; do
        if [[ "${ADDR_TENANTS[$a]}" == *" "* ]]; then
            echo
            echo "  And ${a} is ONE address serving ${ADDR_TENANTS[$a]}: the same URL"
            echo "  returned a different document to each client. No ping-based test"
            echo "  can distinguish those two cases - both would simply answer."
        fi
    done
fi
exit $(( bad > 0 ? 1 : 0 ))
