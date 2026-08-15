# HCP Backup & Restore with OADP

End-to-end automation for backing up and restoring Hosted Control Plane (HCP) clusters using OADP/Velero, including a full disaster-recovery cutover from one management hub to another.

The lab runs on a single bare-metal RHEL 9 node using KVM/libvirt to simulate the management hub(s) and hosted clusters.

High-Level-Arch

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  Bare Metal Host (RHEL 9 + KVM/libvirt)                      │
│                                                              │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐         │
│  │  Helper VM  │   │   Hub1 VMs  │   │   Hub2 VMs  │         │
│  │ (DNS + LB)  │   │ (OCP + ACM) │   │ (DR target) │         │
│  └─────────────┘   └──────-┬─────┘   └──────-┬─────┘         │
│                            │                 │               │
│                    ┌───────┴───────┐  ┌──────┴───────┐       │
│                    │ HCP Cluster 1 │  │ HCP Cluster 1│       │
│                    └───────────────┘  └──────────────┘       │
└──────────────────────────────────────────────────────────────┘
                             │                  │
                             ▼                  ▼
                    ┌────────────────────────────────┐
                    │  AWS S3 (shared backup bucket) │
                    └────────────────────────────────┘
```

**Hub1** is the primary management cluster running ACM, OADP, LVM-Storage, and MetalLB. **Hub2** is a replacement hub used as the restore target during a DR cutover. Both hubs share the same S3 bucket so backups created by hub1 are visible to hub2's Velero instance.

## Prerequisites

Start with a freshly installed RHEL 9.5+ bare-metal host with valid subscriptions.

```bash
subscription-manager register
yum install ansible-core -y
ansible-galaxy collection install community.libvirt
ansible-galaxy collection install community.crypto
```

Download `rhel-9.8-x86_64-kvm.qcow2` (or latest RHEL 9 KVM image) from [access.redhat.com/downloads](https://access.redhat.com/downloads) and place it in the role files directory:

```bash
git clone https://github.com/sadiquepp/hcp-backup-restore.git
cp rhel-9.8-x86_64-kvm.qcow2 hcp-backup-restore/roles/setup-bm-host/files/
```

If you have a different RHEL 9 version, update `rhel9_kvm_image` in `vars.yaml`.

## Configuration



### vars.yaml

Review and adjust lab-specific values:


| Variable             | Purpose                                          |
| -------------------- | ------------------------------------------------ |
| `oadp_aws_region`    | AWS region for the S3 backup bucket              |
| `oadp_bucket_name`   | Globally unique S3 bucket name                   |
| `oadp_backup_prefix` | Key prefix inside the bucket                     |
| `oadp_backup_ttl`    | Backup retention (e.g. `2h30m0s`)                |
| `target_hub`         | Which hub the playbooks target (`hub` or `hub2`) |




### vault.yaml (encrypted)

```bash
ansible-vault create vault.yaml
```

```yaml
org_id: XXXX
activation_key: YYYYY
pull_secret: 'ZZZZZ...'
oadp_aws_access_key_id: 'AKIA...'
oadp_aws_secret_access_key: '...'
```



## End-to-End Workflow



### Step 1 — Setup Bare Metal Host

Creates and configures the `helper` VM that provides DNS and HAProxy for the lab.

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --ask-vault-pass
```



### Step 2 — Setup Hub Cluster (hub1)

Deploys an OpenShift cluster with ACM, LVM-Storage, MetalLB, and the OADP operator.

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster.yaml --ask-vault-pass
```
### Step 3 — Prepare ACM and Inventory

- Configure CIM. Apply the AgentServiceConfig to the ACM cluster. Customize the OS images using `osImages` to the ones you want to use for the hosted clusters.

```bash
oc apply -f roles/setup-hub-acm/files/acm/05-agent-service.yaml
```
- Create Infrastructure Environment. `ACM -> Fleet Management -> Host Inventory -> Create Infrastructure Environment -> Create Environment -> Fill up the form and create the environment.`
- Download the Discovery ISO from Add Hosts
- Discover the VMs as hosts in inventory. Either create from virt-manager specifiying the correct mcaddress or use the playbook to create the hosts.

```bash
ansible-playbook -i inventory/hosts setup_hosted_cluster.yaml --ask-vault-pass
ansible-playbook -i inventory/hosts setup_hosted_cluster2.yaml --ask-vault-pass
```
- Once discovered, approve the nodes.
- Create a Hosted Cluster from the Web UI using the discovered nodes.


### Step 4 — Create S3 Bucket (one-time)

```bash
export BUCKET=adp-backup-bucket-xjt   # pick a globally unique name
export REGION=ap-southeast-1

aws s3api create-bucket --bucket $BUCKET --region $REGION \
  --create-bucket-configuration LocationConstraint=$REGION
```

Create an IAM user with the required permissions (see `oadp/README.md` for the full policy document) and add the access key to `vault.yaml`.

### Step 5 — Configure OADP on hub1

Installs the cloud-credentials secret and DataProtectionApplication pointing at your S3 bucket. The OADP operator itself was already installed in Step 2.

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass
```

Verify that the BackupStorageLocation reports `Available`:

```bash
oc get backupstoragelocation -n openshift-adp
```



### Step 6 — Backup a Hosted Cluster

```bash
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1
```

The playbook renders a Velero `Backup` manifest that captures:

- The hosted cluster namespace (`hcp-cluster1`)
- The HyperShift control-plane namespace (`hcp-cluster1-hcp-cluster1`)
- The bare-metal infrastructure namespace (`bminfra`)

It then waits (polling every 15 s, up to 30 min) until the backup reaches `Completed`.

### Step 7 — DR Cutover: Restore to a New Hub

This sequence simulates a disaster-recovery scenario where hub1 is lost and the hosted cluster control plane is restored onto hub2.

```bash
# 7a. Shut down hub1 (graceful; VMs/disks preserved for inspection)
ansible-playbook shutdown_hub_cluster.yaml

# 7b. Build the replacement hub
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass

# 7c. Configure OADP on hub2 (same bucket, sees hub1's backups)
ansible-playbook setup_oadp.yaml --ask-vault-pass -e target_hub=hub2

# 7d. Restore the hosted cluster onto hub2
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2
```

The restore playbook applies a Velero `Restore` manifest referencing the backup name, re-creates the PVs, and uses `existingResourcePolicy: update` so pre-existing resources are patched rather than skipped.

## Playbook Reference


| Playbook                      | Description                                   |
| ----------------------------- | --------------------------------------------- |
| `setup_bm_host.yaml`          | Prepare bare metal, create helper VM (DNS/LB) |
| `setup_hub_cluster.yaml`      | Deploy hub1 (OCP + day-2 operators)           |
| `setup_hub_cluster2.yaml`     | Deploy hub2 (DR replacement hub)              |
| `setup_hosted_cluster.yaml`   | Provision hosted cluster 1                    |
| `setup_hosted_cluster2.yaml`  | Provision hosted cluster 2                    |
| `setup_oadp.yaml`             | Wire OADP to S3 (credentials + DPA)           |
| `backup_hosted_cluster.yaml`  | Backup a hosted cluster control plane         |
| `restore_hosted_cluster.yaml` | Restore a hosted cluster control plane        |
| `shutdown_hub_cluster.yaml`   | Gracefully stop hub1 VMs (preserves disks)    |
| `cleanup-hub.yaml`            | Destroy hub1 VMs and delete disks             |
| `cleanup.yaml`                | Destroy all VMs (hub + helper)                |




## Key Roles


| Role            | Responsibility                                                        |
| --------------- | --------------------------------------------------------------------- |
| `setup-hub-acm` | Installs ACM, LVM-Storage, MetalLB, and OADP operator subscriptions   |
| `setup-oadp`    | Creates the cloud-credentials secret and DataProtectionApplication CR |




## OADP Details

The OADP configuration uses:

- **Velero plugins**: `openshift`, `aws`, `csi`, `hypershift`
- **Uploader**: Kopia (node-agent based filesystem backup)
- **Storage**: AWS S3 with a shared bucket/prefix across hubs

Templates live in `oadp/templates/` (backup/restore manifests) and `roles/setup-oadp/templates/` (DPA and credentials).

For the full IAM policy, smoke-test manifests, and per-hub setup details, see `[oadp/README.md](oadp/README.md)`.

## Cleanup

Remove hub1 VMs and disks (does not affect hub2 or S3 backups):

```bash
ansible-playbook cleanup-hub.yaml
```

Remove everything (all VMs including helper):

```bash
ansible-playbook cleanup.yaml
```

