#!/usr/bin/env bash
#
# lab-up.sh - one command from nothing to a metal host ready for build-lab.sh.
#
#   ./lab-up.sh                     provision and bootstrap
#   ./lab-up.sh bootstrap           re-run the Ansible bootstrap only
#   ./lab-up.sh stage-image FILE    copy the RHEL KVM qcow2 to every host
#   ./lab-up.sh ssh [N]             ssh to host N (default 1)
#   ./lab-up.sh tunnel [N]          ssh with the VNC port forwarded
#   ./lab-up.sh status              show what is provisioned
#   ./lab-up.sh destroy             tear it all down
#
# WHY THIS RUNS ANSIBLE ITSELF rather than leaving it to terraform's
# local-exec provisioner: a provisioner buffers its output until it finishes,
# and a playbook that fails taints the null_resource, so retrying means
# another `terraform apply` rather than re-running the playbook. Neither is
# what you want while watching a bootstrap. So `up` applies with
# run_bootstrap=false and then runs the playbook in the foreground, where you
# can see it and can re-run it on its own. Using terraform directly still
# works - run_bootstrap defaults to true there.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

readonly TFVARS=terraform.tfvars
readonly INVENTORY=inventory.ini
readonly PLAYBOOK=ansible/bootstrap.yml
readonly IMAGE_NAME=rhel-9.8-x86_64-kvm.qcow2

# 5900 + vnc_display, and vnc_display is 99 in vars.yaml. Not a concatenation
# of 59 and 99 - that coincidence only holds for display 99.
readonly VNC_PORT="${VNC_PORT:-5999}"

AUTO_APPROVE=""
RUN_BOOTSTRAP=yes

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { red "ERROR: $*"; exit 1; }

## ---------------------------------------------------------------------------
## Preflight
##
## Every check here is something that otherwise fails minutes in, after you
## have walked away: no credentials surfaces as an AWS API error partway
## through a plan, a missing ansible-playbook surfaces only after the
## instances are already billing.
## ---------------------------------------------------------------------------
preflight() {
    command -v terraform >/dev/null \
        || die "terraform not on PATH. https://developer.hashicorp.com/terraform/install"

    if [[ $RUN_BOOTSTRAP == yes ]]; then
        command -v ansible-playbook >/dev/null \
            || die "ansible-playbook not on PATH. Install ansible-core, or pass --no-bootstrap."
    fi

    if [[ ! -f $TFVARS ]]; then
        red "No $TFVARS."
        cat >&2 <<EOF

Start from the example and fill in the three values that have no default:

    cp terraform.tfvars.example $TFVARS
    \$EDITOR $TFVARS

    allowed_ssh_cidrs    your own address - curl -s https://checkip.amazonaws.com
    ssh_public_key       contents of ~/.ssh/id_ed25519.pub
    ssh_private_key_path path to the matching private key
EOF
        exit 1
    fi

    # Credentials: prove them if the AWS CLI is here, and otherwise just look
    # for somewhere they could come from. Terraform's own error for missing
    # credentials is legible, so this is about failing in two seconds rather
    # than after a plan.
    if command -v aws >/dev/null; then
        aws sts get-caller-identity >/dev/null 2>&1 \
            || die "AWS credentials are not working. aws sts get-caller-identity to see why."
    elif [[ -z ${AWS_ACCESS_KEY_ID:-} && -z ${AWS_PROFILE:-} && ! -f ~/.aws/credentials ]]; then
        die "No AWS credentials found (no AWS_ACCESS_KEY_ID, no AWS_PROFILE, no ~/.aws/credentials)."
    fi

    # The private key has to exist on THIS machine: terraform reads it to wait
    # for ssh, and Ansible connects with it.
    local key
    key=$(tfvar ssh_private_key_path)
    if [[ -n $key ]]; then
        key="${key/#\~/$HOME}"
        [[ -f $key ]] || die "ssh_private_key_path points at $key, which does not exist."
    fi
}

# Read a scalar out of terraform.tfvars. Enough for the handful of simple
# `name = "value"` lines this script cares about; terraform remains the thing
# that actually parses the file.
tfvar() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" \
        "$TFVARS" | head -1
}

## ---------------------------------------------------------------------------
## Reading back what was applied
## ---------------------------------------------------------------------------
have_state() {
    terraform output -json public_ips >/dev/null 2>&1
}

host_ips() {
    terraform output -json public_ips | tr -d '[]" ' | tr ',' '\n' | grep -v '^$'
}

# have_state is checked by the CALLERS, not in host_ips: die inside a $(...)
# exits the subshell and nothing else, so a guard down here would print its
# message and then let the caller carry on with an empty list.
host_ip() {
    have_state || die "Nothing provisioned yet. Run ./lab-up.sh first."
    local n="${1:-1}" ips ip
    ips=$(host_ips)
    ip=$(sed -n "${n}p" <<<"$ips")
    [[ -n $ip ]] || die "No host $n. There are $(grep -c . <<<"$ips")."
    echo "$ip"
}

ssh_key() {
    local key
    key=$(tfvar ssh_private_key_path)
    echo "${key/#\~/$HOME}"
}

## ---------------------------------------------------------------------------
## Subcommands
## ---------------------------------------------------------------------------
cmd_up() {
    preflight

    info "terraform init"
    terraform init -input=false

    # run_bootstrap=false: the playbook is run below, in the foreground. See
    # the header.
    info "terraform apply"
    if [[ -n $AUTO_APPROVE ]]; then
        terraform apply -input=false -auto-approve -var run_bootstrap=false
    else
        bold "A c5.metal is roughly \$4/hour on demand. Review the plan."
        terraform apply -input=false -var run_bootstrap=false
    fi

    if [[ $RUN_BOOTSTRAP == yes ]]; then
        cmd_bootstrap
    else
        info "Skipping the bootstrap (--no-bootstrap). Run ./lab-up.sh bootstrap when ready."
    fi

    info "Provisioned"
    terraform output -raw next_steps
}

cmd_bootstrap() {
    [[ -f $INVENTORY ]] || die "No $INVENTORY - run ./lab-up.sh first."
    command -v ansible-playbook >/dev/null || die "ansible-playbook not on PATH."

    info "Bootstrapping $(grep -c 'ansible_host=' "$INVENTORY") host(s)"
    ansible-playbook -i "$INVENTORY" "$PLAYBOOK" "$@"
}

# The one manual step the automation cannot do - it needs a Red Hat login -
# made as close to automatic as it can be from a machine that already has the
# file. ~14 GiB per host, so it says what it is about to do first.
cmd_stage_image() {
    have_state || die "Nothing provisioned yet. Run ./lab-up.sh first."
    local src="${1:-}"
    [[ -n $src ]] || die "Usage: ./lab-up.sh stage-image /path/to/$IMAGE_NAME"
    [[ -f $src ]] || die "$src does not exist."

    local dir key
    dir=$(tfvar base_image_dir); dir="${dir:-/opt/lab-images}"
    key=$(ssh_key)

    local size
    size=$(du -h "$src" | cut -f1)
    bold "Copying $src ($size) to $dir on each host."

    local ip
    for ip in $(host_ips); do
        info "$ip"
        # To /tmp then sudo mv: base_image_dir is root-owned, and scp does not
        # sudo. The move is on the same filesystem, so it is a rename.
        scp -i "$key" -o StrictHostKeyChecking=accept-new \
            "$src" "ec2-user@${ip}:/tmp/$(basename "$src")"
        ssh -i "$key" -o StrictHostKeyChecking=accept-new "ec2-user@${ip}" \
            "sudo mv /tmp/$(basename "$src") $dir/ && sudo chmod 0644 $dir/$(basename "$src") && ls -lh $dir/"
    done
}

cmd_ssh() {
    local ip; ip=$(host_ip "${1:-1}")
    exec ssh -i "$(ssh_key)" -o StrictHostKeyChecking=accept-new "ec2-user@${ip}"
}

# VNC binds to loopback on the host and its password is truncated to 8
# characters by the protocol, so the tunnel is how you reach it - not a
# workaround for the security group.
cmd_tunnel() {
    local ip; ip=$(host_ip "${1:-1}")
    bold "Forwarding localhost:${VNC_PORT} -> ${ip}:${VNC_PORT}"
    bold "Point a viewer at localhost:${VNC_PORT}. Password: sudo cat /root/.vnc-credentials"
    exec ssh -i "$(ssh_key)" -o StrictHostKeyChecking=accept-new \
        -L "${VNC_PORT}:localhost:${VNC_PORT}" "ec2-user@${ip}"
}

cmd_status() {
    have_state || { echo "Nothing provisioned."; return 0; }
    terraform output -raw next_steps
}

cmd_destroy() {
    have_state || die "Nothing to destroy."
    bold "This destroys the instances AND their root volumes - every VM disk,"
    bold "every cluster, the staged images. There is no snapshot."
    terraform destroy ${AUTO_APPROVE:+-auto-approve}
}

usage() {
    sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options (for the default command and destroy):
  -y, --yes           do not prompt before applying or destroying
      --no-bootstrap  provision only; run ./lab-up.sh bootstrap later
EOF
}

## ---------------------------------------------------------------------------
main() {
    local cmd=up args=()

    while (( $# )); do
        case "$1" in
            -y|--yes)       AUTO_APPROVE=1 ;;
            --no-bootstrap) RUN_BOOTSTRAP=no ;;
            -h|--help)      usage; exit 0 ;;
            up|bootstrap|stage-image|ssh|tunnel|status|destroy) cmd="$1" ;;
            *)              args+=("$1") ;;
        esac
        shift
    done

    case "$cmd" in
        up)          cmd_up ;;
        bootstrap)   cmd_bootstrap "${args[@]+"${args[@]}"}" ;;
        stage-image) cmd_stage_image "${args[@]+"${args[@]}"}" ;;
        ssh)         cmd_ssh "${args[@]+"${args[@]}"}" ;;
        tunnel)      cmd_tunnel "${args[@]+"${args[@]}"}" ;;
        status)      cmd_status ;;
        destroy)     cmd_destroy ;;
    esac
}

main "$@"
