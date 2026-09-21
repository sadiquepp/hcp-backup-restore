#!/usr/bin/env bash
#
# Build the whole UDN-over-EVPN lab, two clusters, in one command.
#
#   ./build-lab.sh                       # everything, from scratch
#   ./build-lab.sh --from fabric         # resume at a step
#   ./build-lab.sh --only evpn           # one step
#   ./build-lab.sh --list                # what the steps are
#   ./build-lab.sh --dry-run             # print the commands, run nothing
#
# RUN IT UNDER tmux (or screen). A full build installs two OpenShift
# clusters and takes hours; if the ssh session drops, the shell gets
# SIGHUP and takes the build with it, usually mid-install, leaving VMs
# half-provisioned that --from cannot resume cleanly.
#
#   tmux new -s lab      then  ./build-lab.sh
#   ctrl-b d             detach;  tmux attach -t lab  to come back
#
# A bare ./build-lab.sh runs all ten steps and therefore BUILDS THE
# CLUSTERS. That is only right on a bare lab host: the cluster playbooks
# are not idempotent, so it refuses if a hub kubeconfig or the libvirt
# domains are already there. With clusters already up, start at --from
# fabric; to really rebuild them, pass --rebuild-clusters.
#
# WHY A SCRIPT AND NOT A PLAYBOOK. This orchestrates eight ansible-playbook
# INVOCATIONS plus two test scripts, not ten plays, and four things make that
# un-foldable:
#
#   1. Every phase in setup_udn_bgp_lab.yaml is `tags: [<phase>, never]`.
#      `never` means the task runs only when its tag is named on the command
#      line. import_playbook cannot request tags, and putting tags: on the
#      import adds them to every task instead - the play-tag trap this lab
#      already hit once.
#   2. playbook_dir follows the playbook. ../setup_bm_host.yaml uses
#      {{ playbook_dir }}/inventory/hosts.j2, so it has to stay a separate
#      invocation; an import_playbook would repoint it here and break it.
#   3. Ansible plays are sequential. The hub and the SNO install in parallel
#      here, which is impossible inside one playbook when both are localhost.
#   4. The lab playbook runs twice with different -e udn_bgp_cluster.
#      import_playbook is static - no loop, no repeat.
#
# VAULT. Every invocation is passed --vault-password-file. Point at it with
# --vault-password-file, or $ANSIBLE_VAULT_PASSWORD_FILE, or leave it and the
# default below is used. The file is never read by this script, only passed on.
# -E (errtrace) matters: without it the ERR trap below does NOT fire for a
# failure inside a function, which is where every step actually runs. The
# script would still exit non-zero, silently, with no resume hint.
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")"   # always run from udn-bgp-evpn/

VAULT_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$HOME/.vault_pass}"
INVENTORY="../inventory/hosts"
TOPOLOGY="evpn"
KUBECONFIG_HUB="${KUBECONFIG_HUB:-/var/lib/libvirt/images/hub_install/auth/kubeconfig}"
KUBECONFIG_SNO="${KUBECONFIG_SNO:-/var/lib/libvirt/images/sno_install/auth/kubeconfig}"
LOGDIR="${LOGDIR:-./build-logs}"
PARALLEL_EVPN=0
REBUILD_CLUSTERS=0
DRY_RUN=0
FROM=""
ONLY=""

STEPS=(bmhost clusters fabric preflight evpn web nsclient nsproxy verify xcluster)

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

list_steps() {
    cat <<EOF
  bmhost     the helper VM: DNS, load balancer, the generated inventory
  clusters   hub (--skip-tags acm) and the SNO, IN PARALLEL
  fabric     containerlab leaf1/spine/leaf2, virbr1, the node NICs
  preflight  report what the clusters can do; changes nothing
  evpn       the cluster half, hub then sno (--parallel-evpn to overlap)
  web        one web pod per tenant, hub then sno
  nsclient   the namespace client VM - one netns per tenant
  nsproxy    the tenant ingress, on that VM. Needs nsclient and web
  verify     scripts/udn-web-demo.sh --proxy - the ingress, from outside
  xcluster   scripts/udn-xcluster-curl.sh - pod to pod ACROSS the two
             clusters. Needs both kubeconfigs and web on both
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-password-file) VAULT_FILE="$2"; shift 2 ;;
        --from)                FROM="$2"; shift 2 ;;
        --only)                ONLY="$2"; shift 2 ;;
        --parallel-evpn)       PARALLEL_EVPN=1; shift ;;
        --rebuild-clusters)    REBUILD_CLUSTERS=1; shift ;;
        --dry-run)             DRY_RUN=1; shift ;;
        --list)                list_steps; exit 0 ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# Arguments first, environment second. A typo in --from is the user's mistake
# and should say so; reporting a missing ansible-playbook for it sends them
# after the wrong thing.
for want in "$FROM" "$ONLY"; do
    [[ -z "$want" ]] && continue
    [[ " ${STEPS[*]} " == *" $want "* ]] || {
        echo "no such step: $want" >&2; echo >&2; list_steps >&2; exit 1; }
done
[[ -n "$FROM" && -n "$ONLY" ]] && { echo "--from and --only are mutually exclusive" >&2; exit 1; }

# --dry-run prints commands and touches nothing, so it needs neither ansible
# nor the vault file - it has to stay usable on a machine that has no lab.
if (( ! DRY_RUN )); then
    command -v ansible-playbook >/dev/null || { echo "ansible-playbook not in PATH" >&2; exit 1; }
    if [[ ! -r "$VAULT_FILE" ]]; then
        echo "vault password file not readable: $VAULT_FILE" >&2
        echo "  pass --vault-password-file PATH, or set ANSIBLE_VAULT_PASSWORD_FILE," >&2
        echo "  or put vault_password_file in ansible.cfg and pass the path here." >&2
        exit 1
    fi
fi
mkdir -p "$LOGDIR"

# ---------------------------------------------------------------------------
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
skip() { printf '    (skipping %s)\n' "$*"; }

# play <playbook> [args...]  - one ansible-playbook invocation, in the foreground
play() {
    local pb="$1"; shift
    local -a cmd=(ansible-playbook -i "$INVENTORY" "$pb" --vault-password-file "$VAULT_FILE" "$@")
    if (( DRY_RUN )); then printf '    %s\n' "${cmd[*]}"; return 0; fi
    "${cmd[@]}"
}

# play_bg <logname> <playbook> [args...] - same, backgrounded, output to a log
#
# Parallel runs go to separate logs on purpose. Two ansible-playbook runs
# writing to one terminal interleave line by line and the result is unreadable
# exactly when you need to read it.
BG_NAMES=(); BG_PIDS=()
play_bg() {
    local name="$1" pb="$2"; shift 2
    local -a cmd=(ansible-playbook -i "$INVENTORY" "$pb" --vault-password-file "$VAULT_FILE" "$@")
    if (( DRY_RUN )); then printf '    %s   > %s/%s.log &\n' "${cmd[*]}" "$LOGDIR" "$name"; return 0; fi
    printf '    %s -> %s/%s.log\n' "$name" "$LOGDIR" "$name"
    "${cmd[@]}" >"$LOGDIR/$name.log" 2>&1 &
    BG_NAMES+=("$name"); BG_PIDS+=("$!")
}

# wait_all - wait on the jobs play_bg started, and say which one failed.
#
# Tracks its own PIDs rather than reading `jobs -p`, so it can name the step
# that failed instead of reporting an anonymous exit code. `wait` is called on
# every PID before returning, so one failure does not orphan the other run.
wait_all() {
    (( DRY_RUN )) && { BG_NAMES=(); BG_PIDS=(); return 0; }
    local rc=0 i
    local -a failed=()
    for i in "${!BG_PIDS[@]}"; do
        if wait "${BG_PIDS[$i]}"; then
            echo "    ${BG_NAMES[$i]}: ok"
        else
            failed+=("${BG_NAMES[$i]}"); rc=1
        fi
    done
    if (( rc )); then
        echo
        for i in "${failed[@]}"; do
            echo "--- $i FAILED, last 25 lines of $LOGDIR/$i.log ---" >&2
            tail -25 "$LOGDIR/$i.log" >&2 2>/dev/null || true
        done
    fi
    BG_NAMES=(); BG_PIDS=()
    return $rc
}

# should_run <step> - honours --from and --only
started=0
should_run() {
    local step="$1"
    if [[ -n "$ONLY" ]]; then [[ "$step" == "$ONLY" ]] && return 0 || return 1; fi
    if [[ -n "$FROM" ]]; then
        [[ "$step" == "$FROM" ]] && started=1
        (( started )) && return 0 || return 1
    fi
    return 0
}

# setup_hub_cluster.yaml and setup_sno.yaml are NOT idempotent. Their VM
# creation is unguarded shell: `qemu-img create` OVERWRITES an existing disk
# and `virt-install` fails on a domain that already exists. Run them against a
# built cluster and you do not get a no-op, you get a destroyed one.
#
# So a bare ./build-lab.sh is only safe on a bare lab host. With the clusters
# already up, the entry point is --from fabric.
guard_clusters() {
    (( REBUILD_CLUSTERS )) && return 0
    (( DRY_RUN )) && return 0
    local -a found=()
    [[ -r "$KUBECONFIG_HUB" ]] && found+=("a hub kubeconfig at $KUBECONFIG_HUB")
    if command -v virsh >/dev/null 2>&1; then
        local d
        for d in hub_master1 sno; do
            virsh dominfo "$d" >/dev/null 2>&1 && found+=("libvirt domain '$d'")
        done
    fi
    (( ${#found[@]} == 0 )) && return 0
    cat >&2 <<EOF

REFUSING to rebuild the clusters - this lab looks already built:
$(printf '  - %s\n' "${found[@]}")

setup_hub_cluster.yaml and setup_sno.yaml are not idempotent. qemu-img create
overwrites an existing disk and virt-install fails on an existing domain, so
re-running them against a live cluster destroys it rather than skipping.

  ./build-lab.sh --from fabric        build the UDN lab on the clusters you have
  ./build-lab.sh --rebuild-clusters   really rebuild them, from scratch

EOF
    # exit, not return: the ERR trap would otherwise append
    # "resume with: --from bmhost", which is the very thing just refused.
    exit 1
}

run_step() {
    local step="$1"
    should_run "$step" || { skip "$step"; return 0; }
    case "$step" in
    bmhost)
        guard_clusters
        say "1/10  helper VM (DNS, LB, inventory)"
        play ../setup_bm_host.yaml ;;
    clusters)
        guard_clusters
        say "2/10  hub and SNO, in parallel"
        play_bg hub ../setup_hub_cluster.yaml --skip-tags acm
        play_bg sno ../setup_sno.yaml
        wait_all ;;
    fabric)
        say "3/10  containerlab fabric (leaf1 / spine / leaf2)"
        play setup_udn_bgp_lab.yaml --tags fabric -e "clab_topology=$TOPOLOGY" ;;
    preflight)
        say "4/10  pre-flight - changes nothing"
        play setup_udn_bgp_lab.yaml --tags preflight ;;
    evpn)
        if (( PARALLEL_EVPN )); then
            say "5/10  EVPN on both clusters, in parallel"
            play_bg evpn-hub setup_udn_bgp_lab.yaml --tags evpn -e udn_bgp_cluster=hub
            play_bg evpn-sno setup_udn_bgp_lab.yaml --tags evpn -e udn_bgp_cluster=sno
            wait_all
        else
            # Sequential by default. Both runs patch cluster-scoped state, and
            # the SNO's session depends on leaf1 already holding the hub's, so
            # serialising removes a variable. --parallel-evpn to overlap them.
            say "5/10  EVPN on the hub"
            play setup_udn_bgp_lab.yaml --tags evpn -e udn_bgp_cluster=hub
            say "5/10  EVPN on the SNO"
            play setup_udn_bgp_lab.yaml --tags evpn -e udn_bgp_cluster=sno
        fi ;;
    web)
        say "6/10  web pods, hub"
        play setup_udn_bgp_lab.yaml --tags web -e udn_bgp_cluster=hub
        say "6/10  web pods, SNO"
        play setup_udn_bgp_lab.yaml --tags web -e udn_bgp_cluster=sno ;;
    nsclient)
        say "7/10  namespace client VM"
        play setup_udn_bgp_lab.yaml --tags clabnsclient -e "clab_topology=$TOPOLOGY" ;;
    nsproxy)
        say "8/10  tenant ingress"
        play setup_udn_bgp_lab.yaml --tags clabnsproxy -e "clab_topology=$TOPOLOGY" ;;
    verify)
        say "9/10  the tenant ingress, from outside"
        if (( DRY_RUN )); then
            printf '    KUBECONFIG=%s scripts/udn-web-demo.sh --proxy\n' "$KUBECONFIG_HUB"
        else
            KUBECONFIG="$KUBECONFIG_HUB" scripts/udn-web-demo.sh --proxy
        fi ;;
    # The only test in the build that crosses a cluster boundary from INSIDE.
    # Step 9 asks from the fabric client, which reaches a pod the same way any
    # external host would; this one has a pod in one cluster curl a pod in the
    # other over the tenant's L2VNI, with nothing in the path belonging to
    # either cluster's host networking. It is therefore the step that actually
    # fails when the stretched Layer2 domain is only half built - the case
    # where each cluster's tenants answer locally and neither can see the
    # other's, which every earlier step passes.
    #
    # It needs BOTH kubeconfigs, so it is guarded rather than assumed: a lab
    # built with the SNO skipped should say so and move on, not fail nine
    # steps of good work on a missing file.
    xcluster)
        say "10/10  pod to pod, across both clusters"
        if [[ ! -r "$KUBECONFIG_SNO" ]]; then
            echo "    no SNO kubeconfig at $KUBECONFIG_SNO - skipping." >&2
            echo "    This test needs two clusters. Set KUBECONFIG_SNO if it" >&2
            echo "    lives elsewhere, or run the SNO half first." >&2
            return 0
        fi
        if (( DRY_RUN )); then
            printf '    scripts/udn-xcluster-curl.sh %s %s\n' \
                   "$KUBECONFIG_HUB" "$KUBECONFIG_SNO"
        else
            scripts/udn-xcluster-curl.sh "$KUBECONFIG_HUB" "$KUBECONFIG_SNO"
        fi ;;
    esac
}

trap 'echo; echo "FAILED at step: ${CURRENT:-?}" >&2;
      echo "  resume with: $0 --from ${CURRENT:-?}" >&2' ERR

# Warn, do not block: someone may be running this under nohup, or from a
# console, or re-running a single quick step where it does not matter.
if (( ! DRY_RUN )) && [[ -z "${TMUX:-}" && "${TERM:-}" != screen* && -z "$ONLY" ]]; then
    cat >&2 <<'EOF'

NOT running under tmux or screen.

A full build installs two OpenShift clusters and takes hours. If this ssh
session drops, the shell is sent SIGHUP and the build dies with it - usually
mid-install, leaving VMs that --from cannot cleanly resume.

  tmux new -s lab     then re-run this
  ctrl-b d            detach;  tmux attach -t lab  to come back

Continuing in 10s - ctrl-c to stop.
EOF
    sleep 10
fi

for step in "${STEPS[@]}"; do
    CURRENT="$step"
    run_step "$step"
done

if [[ -n "$ONLY" ]]; then
    say "done - step '$ONLY' only. The lab as a whole was not built or checked."
elif [[ -n "$FROM" ]]; then
    say "done - resumed from '$FROM' through the end."
else
    say "done - the lab is up"
fi
