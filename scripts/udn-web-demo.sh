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

command -v oc >/dev/null || { echo "oc not found in PATH" >&2; exit 1; }
if (( BASH_VERSINFO[0] < 4 )); then
    echo "This needs bash 4+; found ${BASH_VERSION}." >&2; exit 1
fi
[[ -r "$CLIENTS_ENV" ]] || {
    echo "No client manifest at $CLIENTS_ENV." >&2
    echo "Build the VMs with --tags clabtenantclients, or set UDN_CLIENTS_ENV." >&2
    exit 1
}

declare -A WEBADDR RESULT SERVES CLIENTIP
tenants=(); clients=()

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
    WEBADDR["$tenant"]="${addr%%/*}"
done

(( ${#tenants[@]} )) || { echo "No udn-web pods found. Run --tags web first." >&2; exit 1; }

while IFS='|' read -r name ip serves; do
    [[ -n "${name:-}" && "$name" != \#* ]] || continue
    clients+=("$name"); CLIENTIP["$name"]="$ip"; SERVES["$name"]="${serves//,/ }"
done < "$CLIENTS_ENV"

echo "Web pods"
for t in "${tenants[@]}"; do
    printf '  %-8s http://%s:%s/\n' "$t" "${WEBADDR[$t]}" "$PORT"
done

# ---------------------------------------------------------------------------
# Curl each from each, and print the first line of whatever came back.
# ---------------------------------------------------------------------------
for c in "${clients[@]}"; do
    echo
    echo "=== from ${c} (${CLIENTIP[$c]}), serves ${SERVES[$c]} ==="
    for t in "${tenants[@]}"; do
        printf '  curl http://%-16s ' "${WEBADDR[$t]}:${PORT}/"
        out=$(on_client "${CLIENTIP[$c]}" \
                "curl -s --max-time 5 http://${WEBADDR[$t]}:${PORT}/")
        if [[ -n "$out" && "$out" == I\ am\ * ]]; then
            RESULT["$c,$t"]="${out%%$'\n'*}"
            echo "-> ${RESULT[$c,$t]}"
        else
            RESULT["$c,$t"]="(no answer)"
            echo "-> (no answer)"
        fi
    done
done

# ---------------------------------------------------------------------------
echo
echo "What answered"
printf '%-16s' 'client'
for t in "${tenants[@]}"; do printf ' %-14s' "$t"; done
echo
for c in "${clients[@]}"; do
    printf '%-16s' "$c"
    for t in "${tenants[@]}"; do printf ' %-14s' "${RESULT[$c,$t]:--}"; done
    echo
done

# The verdict is about identity, not reachability: a page from the wrong tenant
# is a leak that every ping-based test in this repo would report as a pass.
echo
bad=0
for c in "${clients[@]}"; do
    for t in "${tenants[@]}"; do
        got="${RESULT[$c,$t]:-}"
        case " ${SERVES[$c]} " in
            *" $t "*)
                if [[ "$got" != "I am $t" ]]; then
                    echo "  BROKEN  $c serves $t but got: $got"; bad=$((bad+1))
                fi ;;
            *)
                if [[ "$got" != "(no answer)" ]]; then
                    echo "  LEAK    $c has no VLAN for $t but got: $got"; bad=$((bad+1))
                fi ;;
        esac
    done
done
if (( bad == 0 )); then
    echo "  clean: every page came from the tenant that was supposed to serve it,"
    echo "         and no page came from one that was not."
    echo
    echo "  Note every address curled above is inside one subnet. The only"
    echo "  difference between these machines is the VLAN tag on their fabric"
    echo "  interface, and that is what decided which document came back."
fi
exit $(( bad > 0 ? 1 : 0 ))
