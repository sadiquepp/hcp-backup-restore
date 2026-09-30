#!/usr/bin/env bash
#
# Build the SPIFFE/SPIRE lab - one trust domain on the hub, one on the SNO,
# federated - in one command.
#
#   ./build-lab.sh                     # everything: base lab if absent, then SPIRE
#   ./build-lab.sh --workshop          # day 0 of workshop.md, then stop
#   ./build-lab.sh --from spire        # resume at a step
#   ./build-lab.sh --only verify       # one step
#   ./build-lab.sh --cluster hub       # per-cluster steps on the hub only
#   ./build-lab.sh --list              # what the steps are
#   ./build-lab.sh --dry-run           # print the commands, run nothing
#   ./build-lab.sh --only cleanup      # remove SPIRE from both clusters
#   ./build-lab.sh --no-boutique       # everything but Online Boutique
#   ./build-lab.sh -e @my-vars.yaml    # extra vars, passed to every playbook
#
# THE BASE LAB. The first two steps are the repository's own playbooks,
# unchanged: bmhost (../setup_bm_host.yaml - the helper, DNS, load balancer)
# and clusters (../setup_hub_cluster.yaml --skip-tags acm and
# ../setup_sno.yaml, in parallel). Each is SKIPPED when what it builds is
# already there, so on a lab that another use case built, a bare
# ./build-lab.sh goes straight to the SPIRE steps. The cluster playbooks are
# not idempotent - re-running one over a live cluster destroys it - so a
# cluster that looks half-built (VMs defined, no kubeconfig) stops the run
# rather than being built over.
#
# THE WORKSHOP. --workshop runs what an attendee is not there to learn: the
# base lab, the preflight, the operator install (a quarter of an hour of
# waiting on OLM and image pulls) and the SPIRE server's storage, then writes
# /root/spiffe-workshop.env. Every SPIRE CR, every registration, every
# workload and the federation are the attendee's, from workshop.md. After it,
# --only check verifies what they built, with the same asserts the full build
# uses.
#
# HOST OVERRIDES. ../vars-metal.yaml (base_image_dir, worker sizing, VNC) is
# passed to every playbook when it exists, first, so -e overrides it.
#
# RUN IT UNDER tmux if the base lab is not built yet: the cluster installs take
# over an hour, and a dropped ssh session takes the build with it.
#
# VAULT. Every invocation gets --vault-password-file: --vault-password-file
# PATH, else $ANSIBLE_VAULT_PASSWORD_FILE, else ~/.vault_pass. Never read here.
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")"   # always run from spiffe-spire/

VAULT_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$HOME/.vault_pass}"
INVENTORY="../inventory/hosts"
KUBECONFIG_HUB="${KUBECONFIG_HUB:-/var/lib/libvirt/images/hub_install/auth/kubeconfig}"
KUBECONFIG_SNO="${KUBECONFIG_SNO:-/var/lib/libvirt/images/sno_install/auth/kubeconfig}"
LOGDIR="${LOGDIR:-./build-logs}"
PB="setup_spiffe_spire.yaml"
HOST_VARS="../vars-metal.yaml"
DRY_RUN=0
WANT_LIST=0
WORKSHOP=0
ASSUME_YES=0
FROM=""
ONLY=""
CLUSTERS=(hub sno)
NO_BOUTIQUE=0
EXTRA_VARS=()

ALL_STEPS=(bmhost clusters preflight operator storage spire demo verify federation xverify boutique boutique-federate)
WORKSHOP_STEPS=(bmhost clusters preflight operator storage prep)
# Valid for --only, in no sequence.
EXTRA_STEPS=(prep check boutique-verify cleanup)

usage() { sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

list_steps() {
    cat <<EOF
  bmhost     ../setup_bm_host.yaml: the helper VM (DNS, load balancer). Skipped
             when the helper VM already exists
  clusters   ../setup_hub_cluster.yaml --skip-tags acm and ../setup_sno.yaml,
             IN PARALLEL. Each skipped when its kubeconfig already exists
  preflight  per cluster: is the operator in redhat-operators, which channel,
             is there a StorageClass. Changes nothing
  operator   per cluster: Namespace, OperatorGroup, Subscription; waits for
             the CSV and checks for the 1.x API
  storage    per cluster: the SPIRE server's local PV, if there is no default
             StorageClass
  spire      per cluster: ZeroTrustWorkloadIdentityManager, SpireServer,
             SpireAgent, SpiffeCSIDriver, the federation Route; waits for Ready
  demo       per cluster: spiffe-demo - ClusterSPIFFEID, echo-server, client,
             intruder
  verify     per cluster: asserts - SVIDs issued, mTLS allowed, intruder refused
  federation both: exchange bundles, a ClusterFederatedTrustDomain each side,
             refresh over each Route, re-register the demo with federatesWith
  xverify    both: hub client -> SNO echo-server, and SNO -> hub
  boutique   per cluster: Online Boutique, every service registered,
             checkoutservice -> paymentservice under mTLS (ghostunnel), then
             its asserts. After federation, so its identities federate too
  boutique-federate
             hub's checkoutservice pays through the SNO's paymentservice,
             across the trust domains; asserts on both

  Not in any sequence, with --only:

  prep       per cluster: /root/spiffe-workshop.env (--workshop runs it)
  check      per cluster: verify, for the workshop - what was built by hand
  boutique-verify
             per cluster: the Online Boutique asserts alone (workshop Part C)
  cleanup    per cluster: remove the demo, SPIRE and the operator. Asks first
EOF
    printf '\n  this run (%s): %s\n' "$( (( WORKSHOP )) && echo workshop || echo full)" "${STEPS[*]}"
    printf '  clusters for per-cluster steps: %s\n' "${CLUSTERS[*]}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-password-file) VAULT_FILE="$2"; shift 2 ;;
        --from)                FROM="$2"; shift 2 ;;
        --only)                ONLY="$2"; shift 2 ;;
        --workshop)            WORKSHOP=1; shift ;;
        --cluster)             CLUSTERS=("$2"); shift 2 ;;
        -e|--extra-vars)       EXTRA_VARS+=(-e "$2"); shift 2 ;;
        -y|--yes)              ASSUME_YES=1; shift ;;
        --no-boutique)         NO_BOUTIQUE=1; shift ;;
        --dry-run)             DRY_RUN=1; shift ;;
        --list)                WANT_LIST=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if (( WORKSHOP )); then STEPS=("${WORKSHOP_STEPS[@]}"); EXTRA_STEPS+=("${ALL_STEPS[@]}")
else STEPS=("${ALL_STEPS[@]}"); fi
# Thirteen more images and ~1.4 GiB per cluster; still reachable with --only.
if (( NO_BOUTIQUE )); then
    STEPS=("${STEPS[@]/boutique-federate}"); STEPS=("${STEPS[@]/boutique}")
    read -r -a STEPS <<< "${STEPS[*]}"
    EXTRA_STEPS+=(boutique boutique-federate)
fi
[[ -r "$HOST_VARS" ]] && EXTRA_VARS=(-e "@$HOST_VARS" "${EXTRA_VARS[@]}")
TOTAL=${#STEPS[@]}

for c in "${CLUSTERS[@]}"; do
    [[ "$c" == hub || "$c" == sno ]] || { echo "--cluster must be hub or sno, not '$c'" >&2; exit 1; }
done

(( WANT_LIST )) && { list_steps; exit 0; }

# --from resumes THIS run's sequence, so it must name a step in it; --only
# may also name a step from outside it.
if [[ -n "$FROM" && " ${STEPS[*]} " != *" $FROM "* ]]; then
    echo "no such step in this run's sequence: $FROM" >&2; echo >&2; list_steps >&2; exit 1
fi
if [[ -n "$ONLY" && " ${STEPS[*]} ${EXTRA_STEPS[*]} " != *" $ONLY "* ]]; then
    echo "no such step: $ONLY" >&2; echo >&2; list_steps >&2; exit 1
fi
[[ -n "$FROM" && -n "$ONLY" ]] && { echo "--from and --only are mutually exclusive" >&2; exit 1; }

if (( ! DRY_RUN )); then
    command -v ansible-playbook >/dev/null || { echo "ansible-playbook not in PATH" >&2; exit 1; }
    [[ -r "$VAULT_FILE" ]] || { echo "vault password file not readable: $VAULT_FILE (--vault-password-file PATH)" >&2; exit 1; }
fi
mkdir -p "$LOGDIR"

# ---------------------------------------------------------------------------
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
skip() { printf '    (skipping %s)\n' "$*"; }

inv() { [[ -r "$INVENTORY" ]] && printf -- '-i\n%s\n' "$INVENTORY"; return 0; }

# play <playbook> [args...]
play() {
    local pb="$1"; shift
    local -a i; mapfile -t i < <(inv)
    local -a cmd=(ansible-playbook "${i[@]}" "$pb" --vault-password-file "$VAULT_FILE" "${EXTRA_VARS[@]}" "$@")
    if (( DRY_RUN )); then printf '    %s\n' "${cmd[*]}"; return 0; fi
    "${cmd[@]}"
}

# play_bg <logname> <playbook> [args...] - backgrounded, output to a log
BG_NAMES=(); BG_PIDS=()
play_bg() {
    local name="$1" pb="$2"; shift 2
    local -a i; mapfile -t i < <(inv)
    local -a cmd=(ansible-playbook "${i[@]}" "$pb" --vault-password-file "$VAULT_FILE" "${EXTRA_VARS[@]}" "$@")
    if (( DRY_RUN )); then printf '    %s   > %s/%s.log &\n' "${cmd[*]}" "$LOGDIR" "$name"; return 0; fi
    printf '    %s -> %s/%s.log\n' "$name" "$LOGDIR" "$name"
    "${cmd[@]}" >"$LOGDIR/$name.log" 2>&1 &
    BG_NAMES+=("$name"); BG_PIDS+=("$!")
}

wait_all() {
    (( DRY_RUN )) && { BG_NAMES=(); BG_PIDS=(); return 0; }
    local rc=0 i
    for i in "${!BG_PIDS[@]}"; do
        if wait "${BG_PIDS[$i]}"; then echo "    ${BG_NAMES[$i]}: ok"
        else
            rc=1
            echo "--- ${BG_NAMES[$i]} FAILED, last 25 lines of $LOGDIR/${BG_NAMES[$i]}.log ---" >&2
            tail -25 "$LOGDIR/${BG_NAMES[$i]}.log" >&2 2>/dev/null || true
        fi
    done
    BG_NAMES=(); BG_PIDS=()
    return $rc
}

pos() {
    local s="$1" i
    for i in "${!STEPS[@]}"; do
        [[ "${STEPS[$i]}" == "$s" ]] && { printf '%d/%d' "$((i + 1))" "$TOTAL"; return 0; }
    done
    printf 'only'
}

started=0
should_run() {
    local step="$1"
    if [[ -n "$ONLY" ]]; then [[ "$step" == "$ONLY" ]]; return; fi
    if [[ -n "$FROM" ]]; then [[ "$step" == "$FROM" ]] && started=1; (( started )); return; fi
    return 0
}

domain_exists() { command -v virsh >/dev/null 2>&1 && virsh dominfo "$1" >/dev/null 2>&1; }

# per_cluster <tag> - the one playbook, once per selected cluster, in order.
# Sequential: the output stays readable, and the SNO's half of nothing here
# depends on the hub's, so there is little to gain from overlapping them.
per_cluster() {
    local tag="$1" c
    for c in "${CLUSTERS[@]}"; do
        say "$(pos "$CURRENT")  $tag on $c"
        play "$PB" --tags "$tag" -e "spire_cluster=$c"
    done
}

both_clusters() {
    if [[ " ${CLUSTERS[*]} " != *" hub "* || " ${CLUSTERS[*]} " != *" sno "* ]]; then
        skip "$1 - it needs both clusters, and --cluster limited this run to ${CLUSTERS[*]}"
        return 1
    fi
    if (( ! DRY_RUN )) && [[ ! -r "$KUBECONFIG_HUB" || ! -r "$KUBECONFIG_SNO" ]]; then
        echo "    $1 needs both kubeconfigs: $KUBECONFIG_HUB, $KUBECONFIG_SNO" >&2
        return 2
    fi
}

run_step() {
    local step="$1"
    should_run "$step" || { skip "$step"; return 0; }
    case "$step" in
    bmhost)
        if (( ! DRY_RUN )) && domain_exists helper; then
            skip "bmhost - the helper VM exists; the base lab is already built"; return 0
        fi
        say "$(pos bmhost)  helper VM (DNS, LB, inventory)"
        play ../setup_bm_host.yaml ;;
    clusters)
        say "$(pos clusters)  hub and SNO"
        local -a want=()
        local c kc dom
        for c in hub sno; do
            [[ " ${CLUSTERS[*]} " == *" $c "* ]] || continue
            if [[ $c == hub ]]; then kc="$KUBECONFIG_HUB"; dom=hub_master1; else kc="$KUBECONFIG_SNO"; dom=sno; fi
            if (( ! DRY_RUN )) && [[ -r "$kc" ]]; then
                skip "$c - $kc exists"
            elif (( ! DRY_RUN )) && domain_exists "$dom"; then
                cat >&2 <<EOF

REFUSING to install the $c: libvirt domain '$dom' exists but there is no
kubeconfig at $kc. That is a half-built cluster, and the install playbook is
not idempotent - it would overwrite the disks. Clean it up first (see
../cleanup.yaml) or point KUBECONFIG_${c^^} at the right file.
EOF
                exit 1
            else
                want+=("$c")
            fi
        done
        for c in "${want[@]}"; do
            if [[ $c == hub ]]; then play_bg hub ../setup_hub_cluster.yaml --skip-tags acm
            else play_bg sno ../setup_sno.yaml; fi
        done
        wait_all ;;
    preflight|operator|storage|spire|demo|verify|prep)
        per_cluster "$step" ;;
    check)
        per_cluster verify ;;
    boutique)
        per_cluster boutique,boutique-verify ;;
    boutique-verify)
        per_cluster boutique-verify ;;
    boutique-federate)
        both_clusters boutique-federate || { [[ $? == 1 ]] && return 0; return 1; }
        say "$(pos boutique-federate)  hub checkoutservice -> SNO paymentservice"
        play "$PB" --tags boutique,boutique-verify -e spire_cluster=hub -e spire_boutique_remote_payments=true
        play "$PB" --tags boutique-verify -e spire_cluster=sno ;;
    cleanup)
        if (( ! DRY_RUN )) && (( ! ASSUME_YES )); then
            cat >&2 <<EOF

cleanup removes from ${CLUSTERS[*]}: the spiffe-demo namespace, every SPIRE
operand, the operator, the SPIRE server's PV and its data directory - the
trust domain's CA keys. Nothing of the base lab. Continuing in 10s - ctrl-c
to stop (-y skips this wait).
EOF
            sleep 10
        fi
        per_cluster cleanup ;;
    federation)
        both_clusters federation || { [[ $? == 1 ]] && return 0; return 1; }
        say "$(pos federation)  federate ${CLUSTERS[*]}"
        play "$PB" --tags federation ;;
    xverify)
        both_clusters xverify || { [[ $? == 1 ]] && return 0; return 1; }
        say "$(pos xverify)  mTLS across the two trust domains"
        play "$PB" --tags xverify ;;
    esac
}

trap 'echo; echo "FAILED at step: ${CURRENT:-?}" >&2;
      echo "  resume with: $0$( (( WORKSHOP )) && echo " --workshop") --from ${CURRENT:-?}" >&2' ERR

# An out-of-band step replaces the sequence rather than being filtered from it.
if [[ -n "$ONLY" && " ${STEPS[*]} " != *" $ONLY "* ]]; then STEPS=("$ONLY"); TOTAL=1; fi

for step in "${STEPS[@]}"; do
    CURRENT="$step"
    run_step "$step"
done

if [[ -n "$ONLY" ]]; then
    say "done - step '$ONLY' only."
elif (( WORKSHOP )); then
    say "day 0 done - source /root/spiffe-workshop.env and start Lab 1 in workshop.md"
else
    say "done - SPIRE on ${CLUSTERS[*]}$( [[ ${#CLUSTERS[@]} == 2 ]] && echo ', federated')"
fi
