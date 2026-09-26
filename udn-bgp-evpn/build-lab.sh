#!/usr/bin/env bash
#
# Build the whole UDN-over-EVPN lab, two clusters, in one command.
#
#   ./build-lab.sh                       # everything, from scratch (EVPN)
#   ./build-lab.sh --vrflite             # the VRF-Lite lab instead
#   ./build-lab.sh --shared              # the shared-VRF lab (phase 2)
#   ./build-lab.sh --from fabric         # resume at a step
#   ./build-lab.sh --only tenants        # one step
#   ./build-lab.sh --list                # what the steps are
#   ./build-lab.sh --dry-run             # print the commands, run nothing
#   ./build-lab.sh --rebuild-clusters    # cleanup.yaml first, then all of it
#   ./build-lab.sh --rebuild-clusters -y # ... without the 10s abort window
#
# TWO LABS, ONE SCRIPT. --evpn (the default) builds the stretched-Layer2
# EVPN lab; --vrflite builds the VRF-Lite one. They share every step but
# the containerlab topology, the tag the cluster phase runs, and - for the
# shared phase only - which steps make sense at all.
#
# --shared is the odd one. It leaks every UDN into the ONE default VRF, so
# there are no per-tenant VRFs for a client VLAN to enter and no two tenants
# behind one address for an ingress to separate. It therefore has no nsproxy
# step, and its verify curls every pod from ONE client (--host) instead of
# asking an ingress by hostname. The namespace client VM is still built: its
# ROOT namespace carries the phase-2 routes, so one VM serves all three labs.
#
# The cross-cluster test runs in all three, asking a different question in
# each. Under EVPN: does a tenant reach ITSELF in the other cluster over one
# stretched Layer2 domain. Under VRF-Lite there is no stretched Layer2 and no
# tenant is in both clusters, so it asks whether the openings in
# udn_vrf_leaks are real pod to pod and - the part worth having - whether the
# pairs left out are shut. The script detects which of those two it is
# looking at; --shared has to be passed.
#
# Under --shared the answer is that NO cell crosses the boundary, and that is
# the phase behaving correctly rather than a defect. Phase 2 advertises pod
# subnets outward so fabric clients can reach pods; it does not give pods a
# path out to the fabric - the tenant's gateway router holds its own /16 and
# a default pointing at the MANAGEMENT gateway. Giving the tenant VRF its own
# fabric path is what VRF-Lite adds, which is why the same test lights up
# under --vrflite. So here the test is checking the same-cluster ACL still
# holds AND that nothing has unexpectedly opened a pod path to the fabric.
#
# The mode still decides the topology, so --list and the N/N counters stay
# derived from it. The step formerly called 'evpn' is now 'tenants'; --from
# evpn and --only vrflite still work and name the same step.
#
# RUN IT UNDER tmux (or screen). A full build installs two OpenShift
# clusters and takes hours; if the ssh session drops, the shell gets
# SIGHUP and takes the build with it, usually mid-install, leaving VMs
# half-provisioned that --from cannot resume cleanly.
#
#   tmux new -s lab      then  ./build-lab.sh
#   ctrl-b d             detach;  tmux attach -t lab  to come back
#
# A bare ./build-lab.sh runs every step of the mode and therefore BUILDS THE
# CLUSTERS. That is only right on a bare lab host: the cluster playbooks
# are not idempotent, so it refuses if a hub kubeconfig or the libvirt
# domains are already there. With clusters already up, start at --from
# fabric; to really rebuild them, pass --rebuild-clusters, which runs
# cleanup.yaml first - destroying every VM of this lab on the host, the helper
# and the containerlab VM included - and then builds the lot. It warns and
# waits 10s before doing so; -y skips the wait.
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
MODE="evpn"                             # --evpn | --vrflite
TOPOLOGY="evpn"                         # derived from MODE, see below
KUBECONFIG_HUB="${KUBECONFIG_HUB:-/var/lib/libvirt/images/hub_install/auth/kubeconfig}"
KUBECONFIG_SNO="${KUBECONFIG_SNO:-/var/lib/libvirt/images/sno_install/auth/kubeconfig}"
LOGDIR="${LOGDIR:-./build-logs}"
PARALLEL_TENANTS=0
REBUILD_CLUSTERS=0
ASSUME_YES=0
CLEANED=0
DRY_RUN=0
WANT_LIST=0
FROM=""
ONLY=""

# Filled in from MODE once the arguments are parsed - xcluster is EVPN-only.
STEPS=()

# --from/--only still accept the phase names. 'evpn' named this step before
# there was a second mode, and 'vrflite' is what the equivalent run is called
# by hand, so both resolve to it rather than erroring as unknown steps.
declare -A STEP_ALIAS=([evpn]=tenants [vrflite]=tenants [shared]=tenants)

# Steps that are valid for --only but are in no mode's sequence, so a full
# run never performs them. 'image' rewrites a file in base_image_dir that
# other labs on this host may share and needs credentials the rest of a
# --from fabric run does not, so it is opt-in and explicit - see
# build-lab-image.yaml.
EXTRA_STEPS=(image image-publish image-fetch)

usage() { sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

list_steps() {
    cat <<EOF
  bmhost     the helper VM: DNS, load balancer, the generated inventory
  clusters   hub (--skip-tags acm) and the SNO, IN PARALLEL
  fabric     containerlab leaf1/spine/leaf2, virbr1, the node NICs
  preflight  report what the clusters can do; changes nothing
  tenants    the cluster half, hub then sno (--parallel-tenants to overlap).
             --tags evpn under --evpn, --tags vrflite under --vrflite
  web        one web pod per tenant, hub then sno
  nsclient   the namespace client VM - one netns per tenant
  nsproxy    the tenant ingress, on that VM. Needs nsclient and web.
             NOT in --shared: nothing to separate behind one address
  verify     scripts/udn-web-demo.sh - the ingress by hostname (--proxy), or
             under --shared every pod from one client (--host)
  xcluster   scripts/udn-xcluster-curl.sh - pod to pod ACROSS the two
             clusters. Needs both kubeconfigs and web on both. Under EVPN,
             same tenant over the stretched L2; under VRF-Lite, the
             udn_vrf_leaks matrix with the shut pairs asserted shut

  Not in any mode's sequence, run each on its own with --only:

  image      build-lab-image.yaml - copy the base image, prepare the COPY
             (root password, lab ssh key, cloud-init removed), register it,
             install every package the lab's guests need, then unregister
             and clean. Build it once and every guest is created from it
             with no registration and no dnf; skip it and nothing changes.
             Its PRESENCE is the switch. No ordering dependency on bmhost -
             it prepares its own copy and works from a pristine base

  image-publish
             upload that image plus a .sha256 to S3, from the ONE host that
             built it
  image-fetch
             pull it down on a lab host instead of building one here. The
             workshop path: build once, publish, fetch on each of N hosts.
             Verified against the published checksum before it is moved
             into place, so a truncated download never becomes the image
EOF
    printf '\n  this run (--%s): %s\n' "$MODE" "${STEPS[*]}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-password-file) VAULT_FILE="$2"; shift 2 ;;
        --from)                FROM="$2"; shift 2 ;;
        --only)                ONLY="$2"; shift 2 ;;
        --evpn)                MODE="evpn"; shift ;;
        --vrflite)             MODE="vrflite"; shift ;;
        --shared)              MODE="shared"; shift ;;
        --parallel-tenants|--parallel-evpn)
                               PARALLEL_TENANTS=1; shift ;;
        --rebuild-clusters)    REBUILD_CLUSTERS=1; shift ;;
        -y|--yes)              ASSUME_YES=1; shift ;;
        --dry-run)             DRY_RUN=1; shift ;;
        --list)                WANT_LIST=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# The mode decides the fabric topology and the step list. Only clab_topology
# 'bgp' puts the per-tenant <vrf_prefix>.1 addresses on leaf1 that VRF-Lite
# peers with; the 'evpn' topology keeps tenant VRFs on leaf2 and would leave
# the vrflite phase with nothing to peer to.
case "$MODE" in
    evpn)    TOPOLOGY="evpn"
             STEPS=(bmhost clusters fabric preflight tenants web nsclient nsproxy verify xcluster) ;;
    vrflite) TOPOLOGY="bgp"
             STEPS=(bmhost clusters fabric preflight tenants web nsclient nsproxy verify xcluster) ;;
    shared)  TOPOLOGY="bgp"
             STEPS=(bmhost clusters fabric preflight tenants web nsclient verify xcluster) ;;
esac

# What the last two steps ask, which is the other thing the mode decides.
case "$MODE" in
    shared) DEMO_FLAG="--host";  XCLUSTER_FLAG="--shared" ;;
    *)      DEMO_FLAG="--proxy"; XCLUSTER_FLAG="" ;;
esac
TOTAL=${#STEPS[@]}

(( WANT_LIST )) && { list_steps; exit 0; }

# Resolve the phase-name aliases before validating, so --from evpn and
# --only vrflite name the step they obviously mean.
if [[ -n "$FROM" ]]; then FROM="${STEP_ALIAS[$FROM]:-$FROM}"; fi
if [[ -n "$ONLY" ]]; then ONLY="${STEP_ALIAS[$ONLY]:-$ONLY}"; fi

# Arguments first, environment second. A typo in --from is the user's mistake
# and should say so; reporting a missing ansible-playbook for it sends them
# after the wrong thing.
for want in "$FROM" "$ONLY"; do
    [[ -z "$want" ]] && continue
    [[ " ${STEPS[*]} ${EXTRA_STEPS[*]} " == *" $want "* ]] || {
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

# pos <step> - "3/9", from the step's place in the mode's list. Hand-written
# counters went wrong the last time a step was added: every message still read
# N/9 after the tenth step appeared. Deriving them removes the class.
pos() {
    local s="$1" i
    for i in "${!STEPS[@]}"; do
        [[ "${STEPS[$i]}" == "$s" ]] && { printf '%d/%d' "$((i + 1))" "$TOTAL"; return 0; }
    done
    printf '?/%d' "$TOTAL"
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
# --rebuild-clusters used to mean only "skip the guard", which walked straight
# into the failure the guard describes: qemu-img create overwrites the disks -
# destroying the clusters - and then virt-install fails on the domain that is
# still defined, leaving a lab that is neither the old one nor a new one and
# has to be cleaned up by hand anyway.
#
# So do the cleanup first and properly. cleanup.yaml destroys and undefines
# every domain before removing its storage, in that order, because `virsh
# undefine` on a running domain quietly converts it to a transient one instead
# of stopping it.
#
# It takes out more than the clusters - the helper, the containerlab VM and
# the tenant client VMs included - which is correct here: --rebuild-clusters
# starts at step 1, and step 1 is what rebuilds the helper.
wipe_lab() {
    (( CLEANED )) && return 0      # guard_clusters is called by two steps
    CLEANED=1
    if (( ! DRY_RUN )) && (( ! ASSUME_YES )); then
        cat >&2 <<EOF

--rebuild-clusters: running cleanup.yaml first. This DESTROYS, on this host:

  - the hub cluster (masters, workers, bootstrap) and its install folder
  - the SNO and its install folder
  - the helper VM, and the containerlab VM with the fabric inside it
  - the tenant client VMs
  - hub2, the mirror registry, minio and the Ceph VMs, if you have them

There is no undo and no snapshot. If anything on this host matters and is not
part of this lab, stop now and check cleanup.yaml.

Continuing in 10s - ctrl-c to stop.  (-y skips this wait)
EOF
        sleep 10
    fi
    say "0/$TOTAL  cleanup.yaml - destroying the existing lab"
    play ../cleanup.yaml
}

guard_clusters() {
    (( REBUILD_CLUSTERS )) && { wipe_lab; return 0; }
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
  ./build-lab.sh --rebuild-clusters   run cleanup.yaml, then build from scratch

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
        say "$(pos bmhost)  helper VM (DNS, LB, inventory)"
        # clab_topology because the helper's DNS zone carries the tenant
        # ingress hostnames, and which tenants each cluster builds - so which
        # names exist - differs by phase (udn_proxy_phase in vars.yaml). Left
        # unset it defaulted to the VRF-Lite list, so an --evpn build got a
        # zone naming violet-sno but not green-sno, purple-sno or the hub's
        # violet. The demo sends an explicit Host header and never noticed;
        # anything resolving the names did.
        play ../setup_bm_host.yaml -e "clab_topology=$TOPOLOGY" ;;
    clusters)
        guard_clusters
        say "$(pos clusters)  hub and SNO, in parallel"
        play_bg hub ../setup_hub_cluster.yaml --skip-tags acm
        play_bg sno ../setup_sno.yaml
        wait_all ;;
    image-publish)
        say "publish the lab image to S3, for other hosts to pull"
        play publish-lab-image.yaml ;;
    image-fetch)
        say "pull the published lab image onto this host"
        play fetch-lab-image.yaml ;;
    image)
        # The image build prepares its own copy - root password, ssh key,
        # cloud-init removed - so it has no ordering dependency on
        # setup-bm-host's in-place preparation of the base image and works
        # from a pristine one. What it does need from the host is
        # virt-customize and the lab keypair, which is all --tags labprereq
        # is: basic_packages and the key, and NOT the in-place edit. On a
        # host that has already been set up it is a no-op.
        say "prebuilt lab image (1/2)  host prerequisites (virt-customize, lab ssh key)"
        play ../setup_bm_host.yaml --tags labprereq
        say "prebuilt lab image (2/2)  copy, prepare, register once, install, unregister"
        play build-lab-image.yaml ;;
    fabric)
        say "$(pos fabric)  containerlab fabric (leaf1 / spine / leaf2), topology $TOPOLOGY"
        play setup_udn_bgp_lab.yaml --tags fabric -e "clab_topology=$TOPOLOGY" ;;
    preflight)
        say "$(pos preflight)  pre-flight - changes nothing"
        play setup_udn_bgp_lab.yaml --tags preflight ;;
    # The one step the mode actually changes: --tags evpn or --tags vrflite.
    # Everything downstream is identical, which is why this is one script.
    tenants)
        if (( PARALLEL_TENANTS )); then
            say "$(pos tenants)  $MODE on both clusters, in parallel"
            play_bg "$MODE-hub" setup_udn_bgp_lab.yaml --tags "$MODE" -e udn_bgp_cluster=hub
            play_bg "$MODE-sno" setup_udn_bgp_lab.yaml --tags "$MODE" -e udn_bgp_cluster=sno
            wait_all
        else
            # Sequential by default. Both runs patch cluster-scoped state, and
            # the SNO's session depends on leaf1 already holding the hub's, so
            # serialising removes a variable. --parallel-tenants to overlap.
            say "$(pos tenants)  $MODE on the hub"
            play setup_udn_bgp_lab.yaml --tags "$MODE" -e udn_bgp_cluster=hub
            say "$(pos tenants)  $MODE on the SNO"
            play setup_udn_bgp_lab.yaml --tags "$MODE" -e udn_bgp_cluster=sno
        fi ;;
    # Each cluster deploys the tenants it actually has in this phase - the SNO
    # under --vrflite has violet and not green or purple - and webload.yml
    # deploys what exists rather than failing on the first absent namespace.
    web)
        say "$(pos web)  web pods, hub"
        play setup_udn_bgp_lab.yaml --tags web -e udn_bgp_cluster=hub
        say "$(pos web)  web pods, SNO"
        play setup_udn_bgp_lab.yaml --tags web -e udn_bgp_cluster=sno ;;
    nsclient)
        say "$(pos nsclient)  namespace client VM"
        play setup_udn_bgp_lab.yaml --tags clabnsclient -e "clab_topology=$TOPOLOGY" ;;
    nsproxy)
        say "$(pos nsproxy)  tenant ingress"
        play setup_udn_bgp_lab.yaml --tags clabnsproxy -e "clab_topology=$TOPOLOGY" ;;
    verify)
        if [[ "$DEMO_FLAG" == "--host" ]]; then
            say "$(pos verify)  every web pod, from one client"
        else
            say "$(pos verify)  the tenant ingress, from outside"
        fi
        # --host is meant to reach EVERY tenant, and under --shared the SNO
        # holds one of its own. The demo is single-cluster by default, so it
        # has to be told about the second or the run is green having never
        # asked about violet.
        demo_extra=""
        [[ "$DEMO_FLAG" == "--host" && -r "$KUBECONFIG_SNO" ]] && demo_extra="$KUBECONFIG_SNO"
        if (( DRY_RUN )); then
            printf '    KUBECONFIG=%s %sscripts/udn-web-demo.sh %s\n' "$KUBECONFIG_HUB" \
                   "${demo_extra:+UDN_EXTRA_KUBECONFIGS=$demo_extra }" "$DEMO_FLAG"
        else
            KUBECONFIG="$KUBECONFIG_HUB" UDN_EXTRA_KUBECONFIGS="$demo_extra" \
                scripts/udn-web-demo.sh "$DEMO_FLAG"
        fi ;;
    # The only test in the build with a POD at both ends, which is what makes
    # it worth its runtime in either mode. Step 9 asks from the fabric client,
    # whose address is not an advertised UDN subnet and therefore never meets
    # the advertised-network-subnets ACL at all.
    #
    # Under EVPN it is the step that fails when the stretched Layer2 domain is
    # only half built - each cluster's tenants answer locally and neither sees
    # the other's, which every earlier step passes.
    #
    # Under VRF-Lite it is the only check on the udn_vrf_leaks matrix from
    # inside a pod: the openings must work across the cluster boundary, the
    # pairs left out must stay silent, and two tenants of the SAME cluster
    # must stay silent whatever the leaks say, because the ACL is the backstop
    # there. The script reads the pairs from vars.yaml and detects the mode.
    #
    # Under --shared every cross-cluster cell is expected SILENT: phase 2
    # gives a tenant no path to the fabric, so pod egress toward the other
    # cluster leaves by the management NIC and dies. The step is still worth
    # running - it is what would catch the same-cluster ACL failing open, and
    # it would catch a pod path to the fabric appearing where this phase does
    # not configure one.
    #
    # It needs BOTH kubeconfigs, so it is guarded rather than assumed: a lab
    # built with the SNO skipped should say so and move on, not fail nine
    # steps of good work on a missing file.
    xcluster)
        say "$(pos xcluster)  pod to pod, across both clusters"
        if [[ ! -r "$KUBECONFIG_SNO" ]]; then
            echo "    no SNO kubeconfig at $KUBECONFIG_SNO - skipping." >&2
            echo "    This test needs two clusters. Set KUBECONFIG_SNO if it" >&2
            echo "    lives elsewhere, or run the SNO half first." >&2
            return 0
        fi
        if (( DRY_RUN )); then
            printf '    scripts/udn-xcluster-curl.sh %s%s %s\n' \
                   "${XCLUSTER_FLAG:+$XCLUSTER_FLAG }" "$KUBECONFIG_HUB" "$KUBECONFIG_SNO"
        else
            scripts/udn-xcluster-curl.sh ${XCLUSTER_FLAG:+"$XCLUSTER_FLAG"} \
                "$KUBECONFIG_HUB" "$KUBECONFIG_SNO"
        fi ;;
    esac
}

# The mode goes into the hint: it defaults to --evpn, so a --vrflite or
# --shared build resumed with a bare --from would carry on in the wrong one.
trap 'echo; echo "FAILED at step: ${CURRENT:-?}" >&2;
      echo "  resume with: $0 --$MODE --from ${CURRENT:-?}" >&2' ERR

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

# An out-of-band step replaces the sequence rather than being filtered from
# it - it is in no mode's STEPS, so the loop below would never reach it.
if [[ " ${EXTRA_STEPS[*]} " == *" $ONLY "* ]]; then STEPS=("$ONLY"); fi

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
