# terraform — a c5.metal host for the lab, on AWS

Makes a VPC with one public subnet and *N* `c5.metal` instances in it, then
hands them to Ansible to install the tools, clone this repository and write a
sizing override file. It stops where a human is needed: the RHEL KVM image
and `vault.yaml`.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit it
./lab-up.sh
```

That is init, apply and the Ansible bootstrap in one command, ending with the
addresses and exactly what to do next.

## `lab-up.sh`

| | |
| --- | --- |
| `./lab-up.sh` | provision and bootstrap |
| `./lab-up.sh bootstrap` | re-run the bootstrap playbook only |
| `./lab-up.sh stage-image FILE` | copy the RHEL KVM qcow2 to every host |
| `./lab-up.sh ssh [N]` | ssh to host *N* (default 1) |
| `./lab-up.sh tunnel [N]` | ssh with the VNC port forwarded |
| `./lab-up.sh status` | what is provisioned, and the next steps again |
| `./lab-up.sh destroy` | tear it all down |

`-y` skips the confirmation on apply and destroy; `--no-bootstrap` provisions
only. Arguments it does not recognise are passed through to
`ansible-playbook`, so `./lab-up.sh bootstrap --limit hcp-lab-2 -vv` works.

It preflights before spending anything — `terraform` and `ansible-playbook`
on `PATH`, AWS credentials that actually resolve, `terraform.tfvars` present,
and the private key existing where `ssh_private_key_path` says it does. Each
of those otherwise fails minutes in, after you have walked away, and one of
them fails with the instances already billing.

### Why the script runs Ansible instead of Terraform running it

`terraform apply` on its own does run the bootstrap, through a `local-exec`
provisioner. But a provisioner buffers its output until it finishes, and a
playbook that fails taints the `null_resource` — so retrying means another
`terraform apply` rather than just re-running the playbook. `lab-up.sh`
therefore applies with `run_bootstrap=false` and runs the playbook itself, in
the foreground. Using `terraform` directly still works exactly as before.

## What it creates

| | |
| --- | --- |
| VPC + public subnet + IGW | `vpc_cidr` **must not overlap** the lab's own `192.168.122.0/24` / `192.168.140.0/24` |
| Security group | **SSH only**, from `allowed_ssh_cidrs`. Nothing else is opened |
| `c5.metal` × `instance_count` | 96 vCPU, 192 GiB, public IP. No instance store — all storage is EBS |
| Root volume | `root_volume_size`, default **1000 GiB** gp3 |
| Key pair | from `ssh_public_key` |

### `allowed_ssh_cidrs` has no default, on purpose

It opens a port to the internet. `0.0.0.0/0` "because it was the default" is
how a lab host ends up permanently open, so Terraform will not plan until you
name a CIDR.

```bash
curl -s https://checkip.amazonaws.com
```

### Everything except SSH is tunnelled

The security group opens port 22 and nothing else, and that is sufficient —
VNC, the cluster API, the consoles and the tenant ingress are all reached by
forwarding a port over the same connection:

```bash
./lab-up.sh tunnel                  # or, by hand:
ssh -i ~/.ssh/id_ed25519 -L 5999:localhost:5999 ec2-user@<ip>
```

This matters most for VNC: the protocol truncates its password to 8
characters and does not encrypt the session, so exposing it would be a poor
trade at any password length. It binds to loopback and the tunnel supplies
the encryption and authentication VNC lacks.

### The root volume is the thing to get right

A RHEL AMI's root volume defaults to **10 GiB**. This lab stores the base
image, the customized image, a helper, a containerlab VM, client VMs, three
hub masters, three hub workers and an SNO on it. 1000 GiB is the default
here; `resize_rootfs` in the instance's cloud-config grows the filesystem to
match on first boot.

## What the bootstrap does

`ansible/bootstrap.yml`, run automatically unless `run_bootstrap = false`:

- installs `ansible-core`, `tmux`, `git`, `python3-libvirt`, `python3-lxml`
- installs the `community.libvirt` and `community.crypto` collections
- clones this repository to `/root/hcp-backup-restore`
- creates `base_image_dir` (default `/opt/lab-images`) — **not**
  `/var/lib/libvirt/images`, which does not exist until the libvirt RPM
  creates it
- writes `vars-metal.yaml` with `worker_memory`, `worker_cpu`,
  `base_image_dir` and the VNC settings
- reports what is still missing

It is an ordinary playbook and can be re-run on its own:

```bash
ansible-playbook -i inventory.ini ansible/bootstrap.yml
```

## The two things you still do by hand

**1. The RHEL KVM image.** It needs your Red Hat login, so nothing here can
fetch it. Once it is on your own machine, `stage-image` copies it to every
host and puts it in `base_image_dir`:

```bash
./lab-up.sh stage-image ~/Downloads/rhel-9.8-x86_64-kvm.qcow2
```

By hand, if you prefer:

```bash
scp -i ~/.ssh/id_ed25519 rhel-9.8-x86_64-kvm.qcow2 ec2-user@<ip>:/tmp/
ssh -i ~/.ssh/id_ed25519 ec2-user@<ip> 'sudo mv /tmp/rhel-9.8-x86_64-kvm.qcow2 /opt/lab-images/'
```

**2. `vault.yaml`.**

```bash
sudo -i && cd /root/hcp-backup-restore
ansible-vault create vault.yaml     # pull_secret, org_id, activation_key,
                                    # ssh_key, dns_forwarders
echo '<vault password>' > ~/.vault_pass && chmod 600 ~/.vault_pass
```

## Then build

```bash
tmux new -s lab
cd /root/hcp-backup-restore/udn-bgp-evpn
./build-lab.sh --evpn        # or --vrflite / --shared
```

Under `tmux`: a full build installs two OpenShift clusters and takes hours,
and an ssh drop otherwise takes the build with it.

The sizing in `vars-metal.yaml` is applied with `-e @vars-metal.yaml`, or
merge it into `vars.yaml`. `worker_memory: 24576` and `worker_cpu: 16` suit
192 GiB of host RAM; see the memory note in that file before changing them.

## Cost

`c5.metal` is a large on-demand instance and a 1000 GiB gp3 volume is not
free. `./lab-up.sh destroy` when you are done — and note that destroying the
instance destroys the lab on it, including any golden images you have not
copied off.
