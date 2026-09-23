#!/usr/bin/env bash
#
# Curl every tenant's web pod from every per-tenant client VM, and print what
# came back.
#
#   scripts/udn-web-demo.sh                  # the five per-tenant client VMs
#   scripts/udn-web-demo.sh --netns          # the one VM's per-tenant namespaces
#   scripts/udn-web-demo.sh --vms --netns    # both sets, side by side
#   scripts/udn-web-demo.sh --proxy          # the tenant ingress, by hostname
#   scripts/udn-web-demo.sh --host           # ONE client, every pod - shared VRF
#
# The flags are additive and none implies another: --netns alone runs the
# namespaces INSTEAD OF the VMs. Ask for several explicitly to get several.
#
# --host is for the SHARED phase, and it is the only one that fits there. That
# phase leaks every UDN into the one default VRF, so there are no per-tenant
# VRFs for a VLAN to enter and no isolation for a per-tenant client to prove -
# one off-segment client reaches every tenant through one table. It curls every
# web pod from the namespace client's ROOT namespace and asserts each address
# returned its own tenant's page. No namespaces, no ingress.

# --proxy is a different axis from the other two. They ask "can a machine on
# tenant X reach anything but X"; it asks how an end user reaches EITHER of two
# tenants that share an address, which is the question the first answer
# provokes. Needs --tags clabnsproxy.
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
#
# EXPORT KUBECONFIG FIRST. Every mode, --proxy included, discovers the pods
# and their live addresses with `oc` before it probes anything:
#
#   export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
#
# For --proxy it is what makes the STALE check possible - the comparison
# between where the proxy points and where the pod actually is. Without it
# that check has nothing to compare against and silently never fires.
set -uo pipefail

PORT="${UDN_WEB_PORT:-8080}"
SSH_KEY="${UDN_CLIENT_SSH_KEY:-$HOME/.ssh/lab_rsa}"
SSH_USER="${UDN_CLIENT_SSH_USER:-root}"
CLIENTS_ENV="${UDN_CLIENTS_ENV:-$(dirname "$0")/../udn-bgp/tenant-clients.env}"
NETNS_ENV="${UDN_NETNS_ENV:-$(dirname "$0")/../udn-bgp/netns-client.env}"
PROXY_ENV="${UDN_PROXY_ENV:-$(dirname "$0")/../udn-bgp/tenant-proxy.env}"
WITH_NETNS=0
WITH_VMS=1
WITH_PROXY=0
WITH_HOST=0
EXPLICIT=0
for arg in "$@"; do
    case "$arg" in
        # Additive once the default is out of the way: --vms --netns runs both.
        # WITH_VMS defaults to 1, so the first explicit choice has to clear it,
        # otherwise --netns would silently keep the VMs - the bug this fixes.
        --netns|--netns-only) (( EXPLICIT )) || WITH_VMS=0; EXPLICIT=1; WITH_NETNS=1 ;;
        --vms|--vms-only)     (( EXPLICIT )) || WITH_NETNS=0; EXPLICIT=1; WITH_VMS=1 ;;
        --proxy)              (( EXPLICIT )) || { WITH_VMS=0; WITH_NETNS=0; }; EXPLICIT=1; WITH_PROXY=1 ;;
        # The namespace client's ROOT namespace, curling every tenant directly.
        # For the shared phase, where there are no per-tenant VRFs to enter and
        # no ingress to prove: one client, one table, every pod.
        --host|--shared)      (( EXPLICIT )) || { WITH_VMS=0; WITH_NETNS=0; }; EXPLICIT=1; WITH_HOST=1 ;;
        # Print the whole comment header rather than a fixed line range: a
        # hard-coded '2,30p' silently truncated --help the moment the header
        # grew. sed stops at the first line that is not a comment.
        -h|--help)    sed -n '2,/^[^#]/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

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
if (( BASH_VERSINFO[0] < 4 )); then
    echo "This needs bash 4+; found ${BASH_VERSION}." >&2; exit 1
fi
if (( WITH_VMS )) && [[ ! -r "$CLIENTS_ENV" ]]; then
    echo "No per-tenant client manifest at $CLIENTS_ENV; continuing without it." >&2
    echo "Build them with --tags clabtenantclients, or set UDN_CLIENTS_ENV." >&2
    WITH_VMS=0
fi
# --host reads the same manifest: it is the same VM, asked in its root
# namespace instead of per-namespace.
if (( WITH_NETNS || WITH_HOST )) && [[ ! -r "$NETNS_ENV" ]]; then
    echo "No namespace-client manifest at $NETNS_ENV." >&2
    echo "Build it with --tags clabnsclient, or set UDN_NETNS_ENV." >&2
    exit 1
fi
if (( WITH_PROXY )) && [[ ! -r "$PROXY_ENV" ]]; then
    echo "No tenant-ingress manifest at $PROXY_ENV." >&2
    echo "Build it with --tags clabnsproxy, or set UDN_PROXY_ENV." >&2
    exit 1
fi
# Every mode has to be listed here. --host was added and this was not updated,
# so `--host` alone exited with "Nothing to test" having built nothing - the
# guard for an empty run firing on a run that was fully specified.
if (( ! WITH_VMS && ! WITH_NETNS && ! WITH_PROXY && ! WITH_HOST )); then
    echo "Nothing to test. Build --tags clabtenantclients, --tags clabnsclient" >&2
    echo "or --tags clabnsproxy." >&2
    exit 1
fi

declare -A WEBADDR RESULT SERVES CLIENTIP ADDR_TENANTS PREFIX ANSWERED_BY WEBCLUSTER
tenants=(); clients=(); addrs=()

on_client() {  # client-ip, command
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "${SSH_USER}@$1" "$2" 2>&1
}

# ---------------------------------------------------------------------------
# Where the pages are. Read off the interface, not the annotation.
# ---------------------------------------------------------------------------
# This script is otherwise single-cluster: it reads whatever KUBECONFIG points
# at. Under the shared phase the SNO carries a tenant of its own (violet), and
# a client that is supposed to reach EVERY tenant has to be asked about that
# one too - otherwise the run is green having never tested the tenant the
# phase was extended for. UDN_EXTRA_KUBECONFIGS adds clusters to discovery.
#
# Keyed by tenant name, which is safe only where tenant names do not repeat
# across clusters - true under shared and VRF-Lite, false under EVPN, where a
# stretched tenant exists in both. The duplicate is kept and noted rather than
# silently overwriting an address with another cluster's.
KC_ARGS=("")
for _kc in ${UDN_EXTRA_KUBECONFIGS:-}; do
    if [[ -r "$_kc" ]]; then KC_ARGS+=("--kubeconfig=$_kc")
    else echo "skipping unreadable kubeconfig: $_kc" >&2; fi
done

for _kc in "${KC_ARGS[@]}"; do
for ns in $(oc ${_kc:+$_kc} get ns -l udn-tenant -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    tenant=$(oc ${_kc:+$_kc} get ns "$ns" -o jsonpath='{.metadata.labels.udn-tenant}')
    if [[ -n "${WEBADDR[$tenant]:-}" ]]; then
        echo "  note: tenant '$tenant' is in more than one cluster; keeping ${WEBADDR[$tenant]}" >&2
        continue
    fi
    pod=$(oc ${_kc:+$_kc} -n "$ns" get pods -l app=udn-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$pod" ]] || continue
    # From the page, not from `ip`: the httpd image is ubi9/httpd-24 and has no
    # iproute in it. The init container already read ovn-udn1 and wrote the
    # address into the page, which is also the more honest source - it is what
    # the pod that will answer says about itself.
    page=$(oc ${_kc:+$_kc} -n "$ns" exec "$pod" -c httpd -- cat /var/www/html/index.html 2>/dev/null)
    addr=$(printf '%s\n' "$page" | awk '/^udn:/ {print $2}')
    # Which cluster this pod is in, straight off the page. Only routes in THIS
    # cluster can be judged stale below - the others are served by a kubeconfig
    # this run never looked at, and their recorded address is all we know.
    WEBCLUSTER["$tenant"]=$(printf '%s\n' "$page" | awk '/^cluster:/ {print $2}')
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
done   # per kubeconfig

(( ${#tenants[@]} )) || { echo "No udn-web pods found. Run --tags web first." >&2; exit 1; }

# ---------------------------------------------------------------------------
# The tenant ingress (--proxy)
#
# A different axis from the client matrix. The clients answer "can a machine on
# tenant X reach anything but X"; this answers the question that provokes:
# given that green and purple really do share an address, how does an end user
# reach either? One hostname each, one proxy, one backend address - and the
# namespace keyword picks which pod serves it.
#
# Judged the same way as everything else here: by WHICH page came back. A proxy
# that returns 200 from the wrong tenant is this design's characteristic
# failure, and it is invisible to a health check.
# ---------------------------------------------------------------------------
declare -A PROXY_RECORDED PROXY_HOST_PAGE PROXY_PATH_PAGE PROXY_TENANT PROXY_CLUSTER
PROXY_IP=""; PROXY_PORT=""; PROXY_DOMAIN=""; PROXY_VM=""
proxy_names=()

read_proxy_manifest() {
    local vm ip port domain pairs pair n t c a nf
    while IFS='|' read -r vm ip port domain pairs; do
        [[ -n "${vm:-}" && "$vm" != \#* ]] || continue
        PROXY_VM="$vm"; PROXY_IP="$ip"; PROXY_PORT="$port"; PROXY_DOMAIN="$domain"
        for pair in ${pairs//,/ }; do
            # name:tenant:cluster:addr once the ingress fronts more than one
            # cluster, because the hostname and the network namespace stop
            # being the same word - green-sno is served out of netns green.
            # The older two-field form is still read, so a manifest rendered
            # before that change does not have to be regenerated to be legible.
            nf=$(awk -F: '{print NF}' <<<"$pair")
            n="${pair%%:*}"; a="${pair##*:}"
            if (( nf >= 4 )); then
                t=$(cut -d: -f2 <<<"$pair"); c=$(cut -d: -f3 <<<"$pair")
            else
                t="$n"; c=""
            fi
            proxy_names+=("$n")
            PROXY_RECORDED["$n"]="$a"; PROXY_TENANT["$n"]="$t"; PROXY_CLUSTER["$n"]="$c"
        done
    done < "$PROXY_ENV"
}

probe_proxy() {
    local t
    for t in "${proxy_names[@]}"; do
        PROXY_HOST_PAGE["$t"]=$(curl -sS --max-time 10 -H "Host: ${t}.${PROXY_DOMAIN}" \
            "http://${PROXY_IP}:${PROXY_PORT}/" 2>/dev/null \
            | awk "/I am/ {print; exit}")
        PROXY_PATH_PAGE["$t"]=$(curl -sS --max-time 10 \
            "http://${PROXY_IP}:${PROXY_PORT}/${t}/" 2>/dev/null \
            | awk "/I am/ {print; exit}")
        : "${PROXY_HOST_PAGE[$t]:=(no answer)}"
        : "${PROXY_PATH_PAGE[$t]:=(no answer)}"
    done
}

print_proxy() {
    local t stale=0 rc=0 got live
    echo
    echo "Tenant ingress on ${PROXY_VM} (${PROXY_IP}:${PROXY_PORT})"
    echo
    printf '  %-26s %-14s %-8s %-18s %s\n' "hostname" "backend" "netns" "via Host:" "via /path/"
    for t in "${proxy_names[@]}"; do
        printf '  %-26s %-14s %-8s %-18s %s\n' \
            "${t}.${PROXY_DOMAIN}" "${PROXY_RECORDED[$t]}" "${PROXY_TENANT[$t]}" \
            "${PROXY_HOST_PAGE[$t]}" "${PROXY_PATH_PAGE[$t]}"
    done

    # One backend address serving two hostnames is the thing worth naming.
    local a seen_dup=0
    for a in $(printf '%s\n' "${PROXY_RECORDED[@]}" | sort | uniq -d); do
        seen_dup=1
        echo
        echo "  *** ${a} is the backend for more than one hostname above."
        echo "      Same address, same port, different pages - the namespace"
        echo "      keyword on each server line is what separates them."
    done

    echo
    local tenant cluster
    for t in "${proxy_names[@]}"; do
        got="${PROXY_HOST_PAGE[$t]}"
        tenant="${PROXY_TENANT[$t]}"; cluster="${PROXY_CLUSTER[$t]}"
        # Staleness is only answerable for routes in the cluster this run
        # discovered. A route into the other cluster was read with a kubeconfig
        # we never opened, so its recorded address is the only address we have
        # and comparing it to this cluster's pod would report every one of them
        # stale.
        live=""
        if [[ -z "$cluster" || "${WEBCLUSTER[$tenant]:-}" == "$cluster" ]]; then
            live="${WEBADDR[$tenant]:-}"
        fi
        if [[ -n "$live" && "$live" != "${PROXY_RECORDED[$t]}" ]]; then
            echo "  STALE   ${t}: proxy points at ${PROXY_RECORDED[$t]}, the pod is now ${live}."
            echo "          Re-run --tags clabnsproxy; any --tags web replaces the pods."
            stale=1; rc=1
        fi
        # Against the TENANT, not the hostname: green-sno's page says "I am
        # green on sno", because the pod knows which tenant and cluster it is
        # in and nothing about what hostname reached it.
        if [[ ! "$got" =~ ^"I am $tenant"( on .+)?$ ]]; then
            if (( stale )); then
                echo "  BROKEN  ${t}.${PROXY_DOMAIN} returned: ${got}  (see STALE above)"
            else
                echo "  BROKEN  ${t}.${PROXY_DOMAIN} returned: ${got}"
                echo "          Expected a page from tenant '${tenant}'. A page naming"
                echo "          ANOTHER tenant means the wrong 'namespace' keyword on"
                echo "          that backend - the failure this design introduces and"
                echo "          the fabric cannot catch."
            fi
            rc=1
        elif [[ -n "$cluster" && "$got" != *" on ${cluster}" ]]; then
            echo "  WRONGCLUSTER  ${t}.${PROXY_DOMAIN} returned: ${got}"
            echo "          Right tenant, wrong cluster - this route names ${cluster}."
            echo "          Both clusters' pods are on one L2VNI and one subnet, so"
            echo "          only the backend address separates them: check"
            echo "          ${PROXY_RECORDED[$t]} is still ${cluster}'s pod and not the"
            echo "          other cluster's. This is the failure a shared Layer2"
            echo "          network introduces that a single-cluster ingress cannot."
            rc=1
        fi
        stale=0
    done
    (( rc == 0 )) && {
        echo "  clean: every hostname returned its own tenant's page."
        (( seen_dup )) && echo "         including the two sharing one backend address."
    }
    return $rc
}

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

# --host: one pseudo-client, the namespace client's ROOT namespace. Under the
# shared phase every UDN is leaked into the one default VRF, so a single
# off-segment client reaches every tenant through one table - there are no
# per-tenant VLANs to tag and no ingress in the path. The routes come from
# udn-client-routes.sh, which nsclient-config.yml installs alongside the
# namespaces; PREFIX is empty because the commands run in the root namespace.
if (( WITH_HOST )); then
    while IFS='|' read -r name ip _rest; do
        [[ -n "${name:-}" && "$name" != \#* ]] || continue
        clients+=("host/${name}"); CLIENTIP["host/${name}"]="$ip"
        SERVES["host/${name}"]="${tenants[*]}"; PREFIX["host/${name}"]=""
        break
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

proxy_rc=0
if (( WITH_PROXY )); then
    read_proxy_manifest
    probe_proxy
    print_proxy || proxy_rc=1
fi

if (( ! ${#clients[@]} )); then
    exit $proxy_rc
fi

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
# Path MTU. Every page above would pass whether this is right or wrong, so it
# has to be asked separately.
#
# TCP is protected by MSS clamping: each end sends no more than the other
# advertised, so a client whose segment is far larger than the pod's interface
# still exchanges small segments and every curl succeeds. Nothing else is
# protected. A UDP datagram, or any DF-set packet above the real path MTU, is
# dropped at the OVN gateway's check_pkt_len - and on this lab the ICMP
# too-big did not come back, so path-MTU discovery could not correct it. The
# segments ran at 9000 against a ~1400 path for months of builds and no test
# noticed.
#
# One ping, DF set, sized to exactly the client interface's MTU. It must
# arrive. A failure here is that black hole returning, and it is invisible to
# every other check in this repo.
# ---------------------------------------------------------------------------
# The probe runs on the client, so it is built once as a literal and the
# target substituted in. No $( ) inside a double-quoted bash string, and no
# single quotes inside the script itself - it is wrapped in them for sh -c,
# and the first attempt at this broke on exactly that.
read -r -d '' MTU_PROBE <<'EOS' || true
d=$(ip route get __TARGET__ | sed -n "s/.* dev \\([^ ]*\\).*/\\1/p" | head -1)
m=$(cat /sys/class/net/$d/mtu)
if ping -c1 -W2 -M do -s $((m-28)) __TARGET__ >/dev/null 2>&1
then echo "$d mtu=$m ok"
else echo "$d mtu=$m BLACKHOLE"
fi
EOS

mtu_bad=0
echo
echo "Path MTU (one DF packet at the interface MTU - must arrive)"
for c in "${clients[@]}"; do
    # Only against a pod this client ACTUALLY reached. A DF ping to somewhere
    # unreachable fails for the same reason everything else did, and reporting
    # that as an MTU black hole blames the wrong thing - this printed
    # "BLACKHOLE ... the web pages above still passed, because MSS clamping hid
    # it" on a run where not one page had passed.
    target=""
    for t in ${SERVES[$c]}; do
        a="${WEBADDR[$t]:-}"
        [[ -n "$a" ]] || continue
        [[ "${RESULT[$c,$a]:-}" == I\ am\ * ]] || continue
        target="$a"; break
    done
    if [[ -z "$target" ]]; then
        printf '  %-18s -> %s\n' "$c" "no pod answered it - MTU not testable"
        continue
    fi
    probe="${MTU_PROBE//__TARGET__/$target}"
    out=$(on_client "${CLIENTIP[$c]}" "${PREFIX[$c]}sh -c '$probe'" | tr -d '\r' | tail -1)
    printf '  %-18s -> %-15s %s\n' "$c" "$target" "$out"
    [[ "$out" == *BLACKHOLE* ]] && mtu_bad=$((mtu_bad+1))
done
if (( mtu_bad )); then
    echo
    echo "  $mtu_bad client(s) reached a pod but cannot deliver a full-MTU packet"
    echo "  to it. The pages above passed anyway, because MSS clamping pins TCP"
    echo "  to the smaller end - UDP and anything DF-set does not survive it."
    echo "  Compare the client segment against the pod:"
    echo "      oc -n udn-<tenant> rsh <web pod> ip link show ovn-udn1"
    echo "  and set vars.yaml:clab_client_mtu to match, then re-run --tags"
    echo "  clabnsclient (and clabclients, if the tenant VMs are built)."
fi

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
        expect=""; nmatch=0
        for t in ${ADDR_TENANTS[$a]}; do
            case " ${SERVES[$c]} " in *" $t "*) expect="$t"; nmatch=$((nmatch + 1)) ;; esac
        done
        # A per-tenant client can only ever serve one holder of an address, so
        # this cannot fire for them. A --host client serves every tenant, and
        # under EVPN two of them really can share one address - there is then
        # no right answer to assert, and picking one silently is how a test
        # starts reporting on the wrong thing.
        if (( nmatch > 1 )); then
            echo "  AMBIG   $c serves ${ADDR_TENANTS[$a]}, which share $a."
            echo "          A page names its tenant, but with one client and one"
            echo "          address there is nothing to compare it against. Use"
            echo "          --netns, where each tenant is asked separately."
            bad=$((bad + 1))
        elif [[ -n "$expect" ]]; then
            # The banner is "I am <tenant>", and once a second cluster joins the
            # fabric "I am <tenant> on <cluster>" - because with a stretched
            # Layer2 tenant the tenant name alone no longer says who answered.
            # Both forms are correct here. Matching the first form exactly is
            # what turned a perfect diagonal into two BROKEN lines: every cell
            # was right and the string had simply grown a suffix.
            if [[ ! "$got" =~ ^"I am $expect"( on .+)?$ ]]; then
                echo "  BROKEN  $c serves $expect at $a but got: $got"; bad=$((bad+1))
            else
                # Which cluster answered, when the page says. Collected rather
                # than checked: a client reaching a pod in ANOTHER cluster over
                # a shared L2VNI is the thing the stretched tenant exists to do,
                # so it is a result to report, not a fault to flag.
                cl="${got#I am $expect}"; cl="${cl# on }"
                [[ -n "$cl" ]] && ANSWERED_BY["$cl"]="${ANSWERED_BY[$cl]:-}${ANSWERED_BY[$cl]:+ }${c}->${expect}"
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
    if (( ${#ANSWERED_BY[@]} > 0 )); then
        echo
        echo "  Answered by cluster:"
        for cl in "${!ANSWERED_BY[@]}"; do
            printf '    %-10s %s\n' "$cl" "${ANSWERED_BY[$cl]}"
        done
        if (( ${#ANSWERED_BY[@]} > 1 )); then
            echo
            echo "  More than one cluster answered. These clients are on the fabric,"
            echo "  not in any cluster, and they reached pods in both - over one"
            echo "  L2VNI, with every address inside one subnet. That is the"
            echo "  stretched broadcast domain doing what it is for."
        fi
    fi
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
exit $(( (bad > 0 || proxy_rc > 0 || mtu_bad > 0) ? 1 : 0 ))
