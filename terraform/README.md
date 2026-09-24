# terraform — a c5.metal host for the lab, on AWS

Makes a VPC with one public subnet and *N* `c5.metal` instances in it, then
hands them to Ansible to install the tools, clone this repository and write a
sizing override file. It stops where a human is needed: the RHEL KVM image
and `vault.yaml`.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit it
terraform init
terraform apply
```

`terraform apply` prints the addresses and exactly what to do next.

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
fetch it.

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
free. `terraform destroy` when you are done — and note that destroying the
instance destroys the lab on it, including any golden images you have not
copied off.
