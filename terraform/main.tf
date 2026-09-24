## ---------------------------------------------------------------------------
## A VPC with one public subnet, and N c5.metal hosts in it.
##
## One lab per host. The lab builds its own libvirt networks inside the
## instance (192.168.122.0/24 management, 192.168.140.0/24 fabric), which is
## why vpc_cidr must not overlap those - nothing here routes between them,
## but an overlapping VPC CIDR makes the host's own routing ambiguous.
## ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]
}

# Red Hat's own account. Filtering on the owner rather than a name pattern
# alone matters: anyone can publish an AMI called RHEL-9-something.
data "aws_ami" "rhel9" {
  most_recent = true
  owners      = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP2"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

## ---------------------------------------------------------------------------
## Security
##
## INBOUND IS SSH ONLY, from allowed_ssh_cidrs. Nothing else is opened, and
## nothing else needs to be: the cluster APIs, the consoles, the tenant
## ingress and VNC are all reached by forwarding a port over that one ssh
## connection. VNC in particular binds to loopback on the host and has an
## 8-character password the protocol truncates - exposing it would be a bad
## trade at any password length.
##
##   ssh -L 5999:localhost:5999 \
##       -L 6443:api.hub.mylab.com:6443 ec2-user@<ip>
## ---------------------------------------------------------------------------
resource "aws_security_group" "lab" {
  name        = "${var.project}-sg"
  description = "SSH in from named CIDRs; everything else is tunnelled"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "All outbound - RHSM, quay.io, the release payload, git"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-sg" }
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.project}-key"
  public_key = var.ssh_public_key
  tags       = { Name = "${var.project}-key" }
}

resource "aws_instance" "metal" {
  count = var.instance_count

  ami                    = data.aws_ami.rhel9.id
  instance_type          = var.instance_type
  availability_zone      = local.az
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.lab.id]
  key_name               = aws_key_pair.lab.key_name

  # Public IP is required: the host has to reach RHSM, quay.io and the release
  # payload, and you have to reach it.
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    throughput            = var.root_volume_throughput
    iops                  = var.root_volume_iops
    delete_on_termination = true
    encrypted             = true
    tags                  = { Name = "${var.project}-${count.index + 1}-root" }
  }

  # The RHEL AMI's root filesystem is sized to the AMI, not to the volume, so
  # a 1000 GiB volume still shows 10 GiB until it is grown. cloud-init's
  # growpart does this on first boot; naming it explicitly means it is not
  # left to whatever the AMI happens to default to.
  user_data = <<-CLOUDCFG
    #cloud-config
    growpart:
      mode: auto
      devices: ['/']
    resize_rootfs: true
    write_files:
      - path: /etc/profile.d/lab.sh
        content: |
          # Set by terraform. The lab is built from here.
          export LAB_REPO_DIR=/root/hcp-backup-restore
    CLOUDCFG

  tags = { Name = "${var.project}-${count.index + 1}" }
}
