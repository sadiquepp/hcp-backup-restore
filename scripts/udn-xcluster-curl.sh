#!/usr/bin/env bash
# Pod-to-pod HTTP across two clusters on one stretched UDN.
#
#   scripts/udn-xcluster-curl.sh <kubeconfig> <kubeconfig> [...]
#   UDN_KUBECONFIGS="/a/kubeconfig /b/kubeconfig" scripts/udn-xcluster-curl.sh
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
# nothing else answers at all. That is one broadcast domain spanning two
# clusters, with tenant isolation intact across it.
set -uo pipefail

PORT="${UDN_WEB_PORT:-8080}"
TIMEOUT="${UDN_CURL_TIMEOUT:-5}"

kubeconfigs=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 1 ;;
        *)  kubeconfigs+=("$arg") ;;
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
# Verdict. Same tenant answers in EITHER cluster; nothing else answers at all.
# ---------------------------------------------------------------------------
echo
bad=0; crossed=0
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
            fi
        elif [[ "$got" != "(no answer)" ]]; then
            echo "  LEAK    $src -> $a  serves none of [${TARGETS[$a]}] but got: $got"
            bad=$((bad+1))
        fi
    done
done

if (( bad )); then
    echo
    echo "FAIL - $bad cell(s) wrong."
    exit 1
fi

echo "  clean: every tenant reached its own pods in BOTH clusters,"
echo "         and nothing reached a tenant it does not belong to."
echo
echo "  ${crossed} of those answers crossed a cluster boundary. Those packets left"
echo "  one cluster's VTEP, crossed the fabric as VXLAN on the tenant's VNI, and"
echo "  were delivered inside the other cluster - with no gateway, no route and"
echo "  no address translation anywhere in the path."
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
