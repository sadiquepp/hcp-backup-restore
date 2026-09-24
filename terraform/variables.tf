## ---------------------------------------------------------------------------
## Required
## ---------------------------------------------------------------------------

# No default, deliberately. This opens SSH to the internet on a host that will
# be running an OpenShift lab, and "0.0.0.0/0 because it was the default" is
# how that ends up permanently open. Put your own address here:
#
#   allowed_ssh_cidrs = ["203.0.113.4/32"]
#
# curl -s https://checkip.amazonaws.com will tell you what it is.
variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to reach port 22. Your own /32, not 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ssh_cidrs) > 0
    error_message = "Set at least one CIDR. Your own address: curl -s https://checkip.amazonaws.com"
  }
}

variable "ssh_public_key" {
  description = "Contents of the public key to install on the instances (ssh-ed25519 AAAA... or ssh-rsa AAAA...)."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the matching private key on THIS machine. Used by the Ansible bootstrap."
  type        = string
}

## ---------------------------------------------------------------------------
## Sizing and placement
## ---------------------------------------------------------------------------

# The escape hatch for the AMI lookup in main.tf. Leave it empty and the
# newest RHEL 9 PAYG image is found by name; set it and the lookup is skipped
# altogether. Worth knowing about because the lookup's failure mode is the
# opaque "Your query returned no results", and because pinning one AMI is how
# you get 20 workshop hosts that are all identical rather than all "whatever
# was newest that morning".
#
#   aws ec2 describe-images --owners 309956199498 --region us-east-2 \
#     --filters 'Name=name,Values=RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3' \
#     --query 'reverse(sort_by(Images,&CreationDate))[:5].[ImageId,Name]' \
#     --output text
#
# An AMI ID is region-specific: change region and this must change with it.
variable "ami_id" {
  description = "Pin a specific AMI. Empty looks up the newest RHEL 9 PAYG image by name."
  type        = string
  default     = ""
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "instance_count" {
  description = "How many metal hosts. One lab per host."
  type        = number
  default     = 1
}

# c5.metal is 96 vCPU / 192 GiB and has NO instance store, so every byte of
# lab storage is EBS - see root_volume_size below. Availability varies by AZ;
# if an apply fails with InsufficientInstanceCapacity, try another region or
# pin a different availability_zone.
variable "instance_type" {
  description = "Metal instance type."
  type        = string
  default     = "c5.metal"
}

# THE DEFAULT RHEL AMI ROOT VOLUME IS 10 GiB. The lab needs the base image,
# the customized image, a helper, a containerlab VM, client VMs, three hub
# masters, three hub workers and an SNO - several hundred GiB before anything
# is pulled. This is the single most likely thing to be set too small.
variable "root_volume_size" {
  description = "Root EBS volume, GiB. All lab storage lives here."
  type        = number
  default     = 1000
}

variable "root_volume_throughput" {
  description = "gp3 throughput, MiB/s. Raised from the 125 default because this volume carries every VM disk."
  type        = number
  default     = 1000
}

variable "root_volume_iops" {
  description = "gp3 IOPS."
  type        = number
  default     = 16000
}

## ---------------------------------------------------------------------------
## Naming and network
## ---------------------------------------------------------------------------

variable "project" {
  description = "Tag and name prefix."
  type        = string
  default     = "hcp-lab"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must not overlap the lab's own 192.168.122.0/24 or 192.168.140.0/24."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Public subnet CIDR."
  type        = string
  default     = "10.0.3.0/24"
}

variable "availability_zone" {
  description = "AZ for the subnet and instances. Empty picks the first in the region."
  type        = string
  default     = ""
}

## ---------------------------------------------------------------------------
## Lab bootstrap
## ---------------------------------------------------------------------------

variable "run_bootstrap" {
  description = "Run the Ansible bootstrap after the instances come up."
  type        = bool
  default     = true
}

variable "repo_url" {
  description = "Repository to clone onto each host."
  type        = string
  default     = "https://github.com/sadiquepp/hcp-backup-restore.git"
}

variable "repo_branch" {
  description = "Branch to check out."
  type        = string
  default     = "integration"
}

variable "base_image_dir" {
  description = "Where the RHEL KVM qcow2 is staged. Deliberately NOT /var/lib/libvirt/images, which does not exist until the libvirt RPM creates it."
  type        = string
  default     = "/opt/lab-images"
}

variable "worker_memory" {
  description = "MiB per hub worker."
  type        = number
  default     = 24576
}

variable "worker_cpu" {
  description = "vCPUs per hub worker."
  type        = number
  default     = 16
}

variable "vnc_enabled" {
  description = "Install and start the VNC desktop. Loopback only; reach it over an ssh tunnel."
  type        = bool
  default     = true
}
