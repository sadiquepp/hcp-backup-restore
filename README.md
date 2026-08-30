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
### Setup Bare Metal Host

- Start with a freshly installed RHEL 9.5+ bare-metal host with valid subscriptions.

```bash
subscription-manager register
yum install ansible-core -y
ansible-galaxy collection install community.libvirt
ansible-galaxy collection install community.crypto
```

- Download `rhel-9.8-x86_64-kvm.qcow2` (or latest RHEL 9 KVM image) from [access.redhat.com/downloads](https://access.redhat.com/downloads) and place it in the role files directory:

```bash
git clone https://github.com/sadiquepp/hcp-backup-restore.git
cp rhel-9.8-x86_64-kvm.qcow2 hcp-backup-restore/roles/setup-bm-host/files/
```

If using a different RHEL 9 KVM image, update `rhel9_kvm_image` in `vars.yaml`.

- Set up OADP s3 Bucket. An example with AWS is shown here. Refer the respective documentation for other cloud providers.

### Configure OADP Pre-requisites
- Configure variables in the terminal.

```bash
export BUCKET=adp-backup-bucket-xjtvvs   # must be globally unique - pick your own
export REGION=ap-south-1
```
- Create the S3 bucket.
```bash
aws s3api create-bucket --bucket $BUCKET --region $REGION \
  --create-bucket-configuration LocationConstraint=$REGION
```
- Create the IAM policy.
```bash
cat > adp-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": ["arn:aws:s3:::${BUCKET}/*"]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": ["arn:aws:s3:::${BUCKET}"]
        }
    ]
}
EOF
```

- Create the IAM user and retrieve the access key.
```bash 
aws iam create-user --user-name adp-user
aws iam put-user-policy --user-name adp-user --policy-name adp-policy --policy-document file://adp-policy.json
aws iam create-access-key --user-name adp-user
```

Set `oadp_bucket_name` and `oadp_aws_region` in `vars.yaml` to match, and
add the access key from the last command to `vault.yaml` as below.

### vars.yaml

Review and adjust lab-specific values:

- Review the variables in `vars.yaml` and adjust them to your needs. Each section has a description of the variables and their purpose.

### vault.yaml (encrypted)
- Configure the vault.yaml file. All the values are mandatory
 - Get org_id from [console.redhat.com](https://console.redhat.com)
 - Get activation_key from [console.redhat.com](https://console.redhat.com/insights/connector/activation-keys)
 - Get pull_secret from [console.redhat.com](hhttps://console.redhat.com/openshift/install/pull-secret)
 - Use your own ssh public key for ssh_key.
 - Get oadp_aws_access_key_id and oadp_aws_secret_access_key from the previous steps

```bash
ansible-vault create vault.yaml
```

```yaml
org_id: XXXX
activation_key: YYYYY
pull_secret: 'ZZZZZ...'
ssh_key: 
oadp_aws_access_key_id: 'AKIA...'
oadp_aws_secret_access_key: '...'
```

## End-to-End Workflow


### Setup Bare Metal Host

Creates and configures the `helper` VM that provides DNS and HAProxy for the lab.

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --ask-vault-pass
```

### Setup Mirror Registry (If using a disconnected deployment)
If you are using a disconnected deployment, you need to setup a mirror registry to pull the images from the internet.
```bash
ansible-playbook -i inventory/hosts setup_mirror_registry.yaml --ask-vault-pass -e disconnected_install=true
```

### Setup Hub Cluster (hub1 - Connected Deployment)

Deploys an OpenShift cluster with ACM, LVM-Storage, MetalLB, and the OADP operator.

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster.yaml --ask-vault-pass
```

### Setup Hub Cluster (hub1 - Disconnected Deployment)

Deploys an OpenShift cluster with ACM, LVM-Storage, MetalLB, and the OADP operator in a disconnected deployment.

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster_disconnected.yaml --ask-vault-pass -e disconnected_install=true
```

### Prepare ACM (Disconnected Deployment)

`setup-hub-acm` renders differently when it is run disconnected - it does so
whenever `disconnected_install: true` is set in `vars.yaml` or `-e disconnected=true`
is passed. Connected runs are unaffected.

`setup_hub_cluster_disconnected.yaml` chains into the role once the cluster is
up, the same way `setup_hub_cluster.yaml` does for hub1, so the command in the
section above already covers it. To re-run just the ACM part against an
existing disconnected hub:

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster_disconnected.yaml --ask-vault-pass -e disconnected_install=true --tags acm
```

What the disconnected run does on top of the connected one:

- Publishes the mirror registry CA as the `registry-config` ConfigMap in
  `openshift-config`, keyed `<registry-host>..<port>`, and sets it as
  `spec.additionalTrustedCA` on `image.config.openshift.io/cluster` so every
  node's CRI-O trusts the mirror. This is a MachineConfig change - the role
  waits for the pools to roll it out.
- Creates the `mirror-config` ConfigMap in `multicluster-engine` (mirror
  registry CA + `registries.conf`) and renders
  `AgentServiceConfig.spec.mirrorRegistryRef` pointing at it, so
  assisted-service and the discovery ISOs it builds pull through the mirror.
  The mappings come from `acm_disconnected_registry_mirrors`; the role warns
  about any source the hub's own IDMS/ITMS redirects that is missing from it.
- Downloads each `agent_service_os_images` RHCOS live ISO to the bare-metal
  host and pushes it to the helper's web server
  (`/var/www/html/bootp`, served on port 8080), then rewrites the `osImages`
  urls to point there - the `mirror.openshift.com` urls are unreachable from a
  disconnected hub. Set `agent_service_os_images_disconnected` in `vars.yaml`
  to skip this and use urls you staged yourself.
- Creates one `ClusterImageSet` per osImage version
  (`openshift-4-21-0`, ...) pointing at the mirror registry's copy of the
  release payload, since ACM/HyperShift will not offer a version that has no
  ClusterImageSet and cannot resolve the quay.io pullspec anyway.

The ISOs are ~1.3G each and the helper is built from the 10G RHEL9 base image,
so `roles/setup-bm-host` now expands that base image into a `helper_disk_size`
(100G, sparse) disk with `virt-resize`. An **existing** helper is not resized -
if the role stops with "the helper has only N G free", either delete
`/var/lib/libvirt/images/helper_disk.qcow2` and re-run `setup_bm_host.yaml`, or
grow the disk in place:

```bash
virsh shutdown helper
qemu-img resize /var/lib/libvirt/images/helper_disk.qcow2 100G
virsh start helper
# on the helper
growpart /dev/vda 4 && xfs_growfs /
```

The rendered files are left in `roles/setup-hub-acm/files/` for review:
`.rendered-05-agentserviceconfig.yaml` (the disconnected rendering, applied
manually as below), plus `.rendered-06-registry-ca-configmap.yaml`,
`.rendered-07-mirror-config-configmap.yaml` and
`.rendered-08-clusterimagesets.yaml`, which the role applies itself.

### Prepare ACM and Inventory

- Configure CIM. Apply the AgentServiceConfig to the ACM cluster. Customize the OS images using `osImages` to the ones you want to use for the hosted clusters. Review the rendendered yaml file at `roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml` and apply it to the ACM cluster.
- Make sure that ACM and `MultClusterHub` is fully operational before proceeding to apply the `AgentServiceConfig` in the next step.

```bash
oc apply -f roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
```

- Create Infrastructure Environment. 

  - **Option1**: `ACM -> Fleet Management -> Host Inventory -> Create Infrastructure Environment -> Create Environment -> Fill up the form and create the environment.` 
  
  - **Option2**: Invoke the setup-bminfra role to render the yaml files.

```bash
ansible-playbook -i inventory/hosts setup_bminfra.yaml --ask-vault-pass
```
- Then apply the rendered yaml files to the ACM cluster.

```bash
oc apply -f roles/setup-bminfra/templates/.rendered-01-namespace.yaml
oc apply -f roles/setup-bminfra/templates/.rendered-02-pullsecret.yaml
oc apply -f roles/setup-bminfra/templates/.rendered-03-infraenv.yaml
oc apply -f roles/setup-bminfra/templates/.rendered-04-capi-role.yaml
```
- Discovery ISO will be automatically downlaoded by this role if yaml files are applied before the configured timeout is expired. If the timeout is expired, you can download the ISO from `Add Hosts` in the ACM Web UI or the playbook to create the hosted cluster vms will download the ISO as the first step.

- Download the Discovery ISO from `Add Hosts` in the ACM Web UI if needed. Only required if you are not using the playbook to automate the discovery process.
Note: The ISO is automatically downloaded to the bare-metal host in the download dir specified in `vars.yaml`  when you automate the discovery process by running the playbook `setup_hosted_cluster_vm.yaml` or `setup_hosted_cluster2_vm.yaml` in the next step. If vms for hosted cluster is manually created, you can download the ISO from `Add Hosts` and place it in the download dir.

- Discover the VMs as hosts in inventory. 
  - **Option1**: Manually create from virt-manager specifiying the correct mcaddress.

  - **Option2**: Invoke the setup-hosted-cluster-vm role which automatically downloads the discovery ISO and creates the hosts in inventory.

  ```bash
  ansible-playbook -i inventory/hosts setup_hosted_cluster_vm.yaml --ask-vault-pass
  ```
- Once discovered, approve the nodes from ACM/MCE Web UI.

- Create a Hosted Cluster from the Web UI using the discovered nodes.

  - List the hosted clusters you want in `hosted_clusters` in `vars.yaml`, then render them all by invoking the create-hosted-cluster role. One generic template covers every cluster; an entry is a bare name, or a dict with `name` plus any per-cluster override. Concurrent hosted clusters on the same hub can share `cluster_cidr`/`service_cidr` - each is its own OVN-Kubernetes cluster and those CIDRs never leave its data plane.
  ```yaml
  hosted_clusters:
    - hcp-cluster1
    - hcp-cluster2
    - name: hcp-cluster3
      nodepool_replicas: 3
  ```
  ```bash
  ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass
  ```
  - Add `-e hcp_cluster_name=hcp-cluster2` to render just one of them.
  - Review and apply the rendered yaml files (one `.rendered-<cluster>.yaml` per entry) to the ACM cluster.
  ```bash
  oc apply -f roles/create-hosted-cluster/templates/.rendered-hcp-cluster1.yaml
  ```
- Note that the hosted cluster worker nodes will go to shutoff mode while joining the nodes to the NodePool. Make sure that the vms are started from virt-manager or via virsh to complete the NodePool join process.
```bash
virsh start c1_worker1
virsh start c1_worker2
```
### Deploy a Sample hello-openshift application to the hosted cluster.

We will evaluate that the application is accessible while hub cluster is down and during and after the restore process.

Get the kubeconfig for the hosted cluster.
```bash
oc get secret hcp-cluster1-admin-kubeconfig -n hcp-cluster1 -o jsonpath='{.data.kubeconfig}' | base64 -d > kubeconfig-hcp-cluster1.yaml
export KUBECONFIG=kubeconfig-hcp-cluster1.yaml
```

Apply the hello-openshift application.
```bash
oc apply -f hello-openshift.yaml
```

Verify that the application is accessible.

```bash
oc get route hello-openshift -n hello-openshift
```


# Backup and Restore

## Primary Hub
### Configure OADP (credentials + DPA)
The operator is already there (installed during hub bring-up). This
step just points it at your bucket:

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass
```

Idempotent - re-running against the same hub just reconciles the
secret/DPA. Both hubs point at the same bucket/prefix, so hub2's Velero
can see backups hub1 created.

### Deploy a hello-openshift application to Hub. 
Deply a hello-openshift application with a PVC to Hub Cluster and backup it using OADP. This will be helpful to verify that the backup and restore process of a sample application is working before running it against a hosted cluster.

```bash
oc apply -f oadp/hello-openshift-oadp.yaml
```

Write some persistent data to the PVC.

```bash
POD=`oc get pod -n hello-openshift-oadp -o jsonpath='{.items[0].metadata.name}'`
oc exec -it $POD -n hello-openshift-oadp -- sh -c 'echo "Hello, World!" > /var/data/hello.txt'
```

Verify that the data is written to the PVC.

```bash
oc exec -it $POD -n hello-openshift-oadp -- sh -c 'cat /var/data/hello.txt'
```

Backup the hello-openshift application with a PVC using OADP.
```bash
oc apply -f oadp/hello-openshift-oadp-backup.yaml
```
- Check the backup status periodically until it shows as completed.
```bash
oc get Backup -n openshift-adp hello-openshift-oadp-backup -o yaml
```
### Backup a hosted cluster using OADP.

```bash
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1
```

`hcp_cluster_name` must match the HostedCluster's name/namespace - it's
used to derive both the hosting namespace and the HyperShift
control-plane namespace (`<name>-<name>`). Works unchanged for
`hcp-cluster2` or any future hosted cluster.

- Get the status of the backup and wait till it finishes before proceeding to the next step.
```bash
oc get Backup -n openshift-adp hcp-cluster1-backup -o yaml
```
It should show the backup as completed. Example output: `phase: Completed`. `itemsBackedUp:` should be equal to `totalItems`.
```yaml
status:
  expiration: "2026-09-28T04:52:01Z"
  formatVersion: 1.1.0
  phase: Completed
  progress:
    itemsBackedUp: 363
    totalItems: 363
  startTimestamp: "2026-08-17T13:52:01Z"
  version: 1
```
### Shutdown Primary Hub

```bash
ansible-playbook shutdown_hub_cluster.yaml --ask-vault-pass
```
## DR Hub
### Build DR Hub
Once the primary hub is shutdown, you can build the DR hub.
```bash
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass
```
Note that AgentServiceConfigs are not restored by OADP. You need to apply the rendered manifests manually before proceeding to the next step. Watch the ansible debug output for the location of the rendered manifests to apply.
```bash
oc apply -f /home/images/hcp-backup-restore/roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
```
There is no need to create InfraEnv, HostedCluster and discover nodes. OADP will do that automatically.
### Configure OADP on DR Hub

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass -e target_hub=hub2
```
### Restore hello-openshift application with a PVC to DR Hub.
This will validate that the restore is working before restoring the hosted cluster.

```bash
oc apply -f oadp/hello-openshift-oadp-restore.yaml
```
Verify that the data persisted in the PVC is visible in the DR hub pod after restore.

```bash
POD=`oc get pod -n hello-openshift-oadp -o jsonpath='{.items[0].metadata.name}'`
oc exec -it $POD -n hello-openshift-oadp -- sh -c 'cat /var/data/hello.txt'
```

### Restore the hosted cluster to the DR Hub using OADP. 
This will restore the hosted cluster to the DR Hub using OADP.

```bash
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2
```
Check the status of the restore.
```bash
oc get restore.velero.io -n openshift-adp hcp-cluster1-restore -o yaml
```


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

