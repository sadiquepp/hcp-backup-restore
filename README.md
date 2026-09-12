# HCP Backup & Restore with OADP

End-to-end automation for backing up and restoring Hosted Control Plane (HCP) clusters using OADP/Velero, including a full disaster-recovery cutover from one management hub to another.

The lab runs on a single bare-metal RHEL 9 node using KVM/libvirt to simulate the management hub(s) and hosted clusters.

High-Level-Arch

What this lab proves, in one page: [summary.md](summary.md).
In a hurry? [steps.md](steps.md) is the same end-to-end run as commands only.

## Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
  - [Setup Bare Metal Host](#setup-bare-metal-host)
  - [Configure OADP Pre-requisites](#configure-oadp-pre-requisites)
  - [vars.yaml](#varsyaml)
  - [vault.yaml (encrypted)](#vaultyaml-encrypted)
- [End-to-End Workflow](#end-to-end-workflow)
  - [Setup Bare Metal Host](#setup-bare-metal-host-1)
  - [Setup Mirror Registry (If using a disconnected deployment)](#setup-mirror-registry-if-using-a-disconnected-deployment)
  - [Choose the Hub's PV Storage](#choose-the-hubs-pv-storage)
  - [Setup Hub Cluster (hub1 - Connected Deployment)](#setup-hub-cluster-hub1---connected-deployment)
  - [Setup Hub Cluster (hub1 - Disconnected Deployment)](#setup-hub-cluster-hub1---disconnected-deployment)
  - [Prepare ACM (Disconnected Deployment)](#prepare-acm-disconnected-deployment)
  - [Prepare ACM and Inventory](#prepare-acm-and-inventory)
  - [Create a Hosted Cluster (Disconnected Deployment)](#create-a-hosted-cluster-disconnected-deployment)
  - [Deploy a Sample hello-openshift application to the hosted cluster](#deploy-a-sample-hello-openshift-application-to-the-hosted-cluster)
- [Choose how the control-plane volumes are captured](#choose-how-the-control-plane-volumes-are-captured)
- [Primary Hub](#primary-hub)
  - [Configure OADP (credentials + DPA)](#configure-oadp-credentials--dpa)
  - [Deploy a hello-openshift application to Hub](#deploy-a-hello-openshift-application-to-hub)
  - [Exclude ACM's import secret from the backup](#exclude-acms-import-secret-from-the-backup)
  - [Backup a hosted cluster using OADP](#backup-a-hosted-cluster-using-oadp)
  - [Shutdown Primary Hub](#shutdown-primary-hub)
  - [Destroy the Ceph cluster (Ceph/CSI DR demo)](#destroy-the-ceph-cluster-cephcsi-dr-demo)
- [DR Hub](#dr-hub)
  - [Rebuild Ceph for the DR hub (Ceph/CSI DR demo)](#rebuild-ceph-for-the-dr-hub-cephcsi-dr-demo)
  - [Build DR Hub](#build-dr-hub)
  - [Configure OADP on DR Hub](#configure-oadp-on-dr-hub)
  - [Restore hello-openshift application with a PVC to DR Hub](#restore-hello-openshift-application-with-a-pvc-to-dr-hub)
  - [Restore the hosted cluster to the DR Hub using OADP](#restore-the-hosted-cluster-to-the-dr-hub-using-oadp)
  - [Point DNS at the DR hub](#point-dns-at-the-dr-hub)
- [Disconnected Hosted Cluster](#disconnected-hosted-cluster)
  - [How the workers are cut off](#how-the-workers-are-cut-off)
  - [Image signature policy on the discovery host](#image-signature-policy-on-the-discovery-host)
  - [Building it](#building-it)
- [MetalLB Address Pools for Hosted Clusters](#metallb-address-pools-for-hosted-clusters)
  - [DR cutover](#dr-cutover)
  - [What actually pins the address](#what-actually-pins-the-address)
  - [Notes and constraints](#notes-and-constraints)
  - [Verifying](#verifying)
- [Ceph 9 Storage for Hub PVs (ODF External Mode)](#ceph-9-storage-for-hub-pvs-odf-external-mode)
  - [What gets built](#what-gets-built)
  - [Requirements](#requirements)
  - [Switching the hub off LVM Storage](#switching-the-hub-off-lvm-storage)
  - [Build the Ceph cluster](#build-the-ceph-cluster)
  - [Attach it to OpenShift](#attach-it-to-openshift)
  - [Verifying](#verifying-1)
  - [Notes and constraints](#notes-and-constraints-1)
- [UDN over BGP, VRF-Lite and EVPN (containerlab fabric)](#udn-over-bgp-vrf-lite-and-evpn-containerlab-fabric)
  - [Can this be simulated on this lab? Yes - here is the honest shape of it](#can-this-be-simulated-on-this-lab-yes---here-is-the-honest-shape-of-it)
  - [The one idea to drop first: you do not move a UDN's default gateway](#the-one-idea-to-drop-first-you-do-not-move-a-udns-default-gateway)
  - [Topology](#topology)
  - [Containerlab in a VM, or on the bare-metal host?](#containerlab-in-a-vm-or-on-the-bare-metal-host)
  - [What it costs the existing lab](#what-it-costs-the-existing-lab)
  - [Constraints worth knowing before you start](#constraints-worth-knowing-before-you-start)
  - [Building it](#building-it-1)
  - [Verifying each phase](#verifying-each-phase)
  - [EVPN, two ways](#evpn-two-ways)
  - [Troubleshooting](#troubleshooting)
- [Playbook Reference](#playbook-reference)
- [Key Roles](#key-roles)
- [OADP Details](#oadp-details)
- [Cleanup](#cleanup)

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

A hub's PVs come from LVM-Storage by default. They can instead come from a standalone Ceph 9 cluster running on the same bare-metal host, consumed through ODF external mode - see [Ceph 9 Storage for Hub PVs (ODF External Mode)](#ceph-9-storage-for-hub-pvs-odf-external-mode).

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
 - `ceph_dashboard_password` is only needed if you run the Ceph flow
   (`setup_ceph.yaml`) - it is the initial password `cephadm bootstrap` sets for
   the Ceph dashboard's admin user (`ceph_dashboard_user` in `vars.yaml`).
   `setup_ceph.yaml` asserts it is present before it creates anything.

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
ceph_dashboard_password: '...'   # only for the Ceph flow
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

### Choose the Hub's PV Storage

The hub needs a PV provider before anything with a PVC (the hosted clusters'
etcd, the hello-openshift sample used in the backup/restore walkthrough) will
schedule.
There are two options, and the choice has to be made **before** the hub is
built, because `setup-hub-acm` acts on it during bring-up:

- **LVM Storage** (default) - `use_lvm_storage: true` in `vars.yaml`. Nothing
  else to do; the sections below install it as part of the hub. Good enough to
  stand up hosted clusters and run workloads on them.
- **Ceph 9 via ODF external mode** - set `use_lvm_storage: false`, then build
  the Ceph cluster and attach it with the two `setup_ceph*.yaml` playbooks,
  before the AgentServiceConfig step - that step's PVCs need a default
  StorageClass to exist already. See
  [Ceph 9 Storage for Hub PVs (ODF External Mode)](#ceph-9-storage-for-hub-pvs-odf-external-mode)
  for the whole flow, its OCP 4.22 requirement, and why the two should not both
  run on the same hub.

> **For backup and restore, pick Ceph.** Restoring a hosted control plane
> needs a CSI VolumeSnapshot of its etcd volume, and LVM Storage provides no
> VolumeSnapshotClass - so `oadp_backup_method=csi` is not available on it at
> all. The `fs` method will still produce a `Completed` backup there, but a
> file-by-file copy of a live etcd volume is not a point-in-time image of it,
> which is the property a control-plane restore depends on. Treat LVM Storage
> as the option for demonstrating hosted clusters, and Ceph as the one for
> demonstrating backup and restore.

### Setup Hub Cluster (hub1 - Connected Deployment)

Deploys an OpenShift cluster with ACM, LVM-Storage, MetalLB, and the OADP
operator. LVM-Storage is skipped when `use_lvm_storage: false`.

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster.yaml --ask-vault-pass
```

### Setup Hub Cluster (hub1 - Disconnected Deployment)

Deploys an OpenShift cluster with ACM, LVM-Storage, MetalLB, and the OADP operator in a disconnected deployment.

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster_disconnected.yaml --ask-vault-pass -e disconnected_install=true
```

### Prepare ACM (Disconnected Deployment)

`setup-hub-acm` renders differently when it is run disconnected. It hangs off
the same `disconnected_install` flag as the rest of the disconnected flow - set
it in `vars.yaml` or pass `-e disconnected_install=true`. Connected runs are
unaffected.

`setup_hub_cluster_disconnected.yaml` chains into the role once the cluster is
up, the same way `setup_hub_cluster.yaml` does for hub1, so the command in the
section above already covers it. To re-run just the ACM part against an
existing disconnected hub:

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster_disconnected.yaml --ask-vault-pass -e disconnected_install=true --tags acm
```

What the disconnected run does on top of the connected one:

- Points every operator `Subscription` (ACM, LVM Storage, MetalLB, OADP) at the
  CatalogSource oc-mirror generated instead of the built-in `redhat-operators`,
  which a disconnected hub has disabled. The name is derived from
  `mirror_catalog_index` (`...redhat-operator-index:v4.21` →
  `cs-redhat-operator-index-v4-21`); override `acm_catalog_source` in
  `vars.yaml` if oc-mirror named it something else. The role checks the
  CatalogSource exists before subscribing, since a Subscription naming a
  missing catalog just sits in `ResolutionFailed`.
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
- The hub also needs a **default StorageClass** by this point. The
  AgentServiceConfig provisions three PVCs (`databaseStorage` 10Gi,
  `filesystemStorage` 100Gi, `imageStorage` 50Gi) and none of them names a
  `storageClassName`, so they bind against the default class - without one
  they stay `Pending` and assisted-service never starts. On the LVM path
  that class is `lvms-vg1` and hub bring-up created it. On the Ceph path
  (`use_lvm_storage: false`) run `setup_ceph.yaml` and `setup_ceph_odf.yaml`
  **before** this step, so `ocs-external-storagecluster-ceph-rbd` exists and
  is the default (`ceph_odf_rbd_default_sc`). Confirm with `oc get sc`.

```bash
oc apply -f roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc get pvc -n multicluster-engine    # the three should reach Bound
```

- Create Infrastructure Environment. 

  - **Option1**: `ACM -> Fleet Management -> Host Inventory -> Create Infrastructure Environment -> Create Environment -> Fill up the form and create the environment.` 
  
  - **Option2**: Invoke the setup-bminfra role to render the yaml files.

```bash
ansible-playbook -i inventory/hosts setup_bminfra.yaml --ask-vault-pass
# disconnected hub:
ansible-playbook -i inventory/hosts setup_bminfra.yaml --ask-vault-pass -e disconnected_install=true
```

  With `disconnected_install=true` the rendered pull-secret carries only the
  mirror registry's credentials (read from `mirror_registry_authfile`, the
  authfile `setup_mirror_registry.yaml` logs podman into), not vault.yaml's
  `pull_secret`. The discovery agent resolves its image through the mirror
  mappings in the ConfigMap `roles/setup-hub-acm` publishes, so the pull is
  against the mirror registry and is authenticated against that host - with the
  Red Hat pull secret instead it fails `unauthorized` on the mirror and then
  `no route to host` on `registry.redhat.io`. Same reduction the disconnected
  hub's own `install-config.yaml` does, and for the same reason: nothing in a
  disconnected lab should hold a working credential back to the real registries.

  A note on the pull-secret, if you hit this on a connected hub:

```
The Secret "pullsecret-bminfra" is invalid: data[.dockerconfigjson]: Invalid value:
"<secret contents redacted>": invalid character '\'' looking for beginning of object key string
```

  Those are Python's quotes, from `str(dict)` - and vault.yaml is not the
  problem. Ansible converts a template's result back into an object when the
  whole thing looks like one, so a properly quoted JSON *string* in vault.yaml
  came back out of the role's `bminfra_pull_secret: "{{ pull_secret }}"` hop as a
  dict, which `b64encode` then encoded as its repr. The default now ends in a
  `string`/`to_json` filter (`STRING_TYPE_FILTERS`, which suppresses that
  conversion), so either spelling of `pull_secret` - quoted string or YAML
  mapping - renders as JSON, and the role asserts the document has an `auths`
  object before rendering. Nothing to change in vault.yaml. Roles that use
  `pull_secret` directly never hit this; it takes the extra variable hop.

- The role applies those four itself, in order (namespace, pull-secret,
  InfraEnv, capi-provider RBAC). It refuses to run if this hub has no
  AgentServiceConfig, since an InfraEnv without assisted-service never
  produces a discovery ISO - apply
  `.rendered-05-agentserviceconfig.yaml` first, as in the step above.
  The rendered files are left in place for inspection:

```bash
ls roles/setup-bminfra/templates/.rendered-*.yaml
oc get infraenv -n bminfra
```

- The discovery ISO is downloaded in the same run, after the apply, so there
  is no longer a race against the timeout. If it does expire, download the ISO
  from `Add Hosts` in the ACM Web UI, or let the playbook that creates the
  hosted cluster VMs fetch it as its first step.

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

  - List the hosted clusters you want in `hosted_clusters` in `vars.yaml`, then render them all by invoking the create-hosted-cluster role. One template covers every connected cluster (a second one covers disconnected clusters - see below); an entry is a bare name, or a dict with `name` plus any per-cluster override. Concurrent hosted clusters on the same hub can share `cluster_cidr`/`service_cidr` - each is its own OVN-Kubernetes cluster and those CIDRs never leave its data plane.
  ```yaml
  hosted_clusters:
    - hcp-cluster1
    - hcp-cluster2
    - name: hcp-cluster3
      nodepool_replicas: 3
  ```
  Every name listed must also have an entry in `hosted_cluster_metallb_pools`
  - that is what gives the cluster its own single-address MetalLB pool and
  keeps its kube-apiserver VIP on the address `api`/`api-int` resolve to. See
  [MetalLB Address Pools for Hosted Clusters](#metallb-address-pools-for-hosted-clusters).
  ```bash
  ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass
  ```
  - Add `-e hcp_cluster_name=hcp-cluster2` to render just one of them.
  - Add `-e disconnected_install=true` to render the **disconnected** hosted
    clusters (`hosted_clusters_disconnected`) instead - see
    [Disconnected Hosted Cluster](#disconnected-hosted-cluster).
  - Review and apply the rendered yaml files (one `.rendered-<cluster>.yaml` per entry) to the ACM cluster.
  ```bash
  oc apply -f roles/create-hosted-cluster/templates/.rendered-hcp-cluster1.yaml
  ```
### Create a Hosted Cluster (Disconnected Deployment)

`create-hosted-cluster` renders differently when it is run disconnected, the
same way `setup-hub-acm` does. It hangs off the same `disconnected_install`
flag - set it in `vars.yaml` or pass `-e disconnected_install=true`. Connected
runs render byte-for-byte what they always did.

```bash
ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass -e disconnected_install=true
```

Requires `setup_mirror_registry.yaml` to have run against this lab first - that
is what leaves the registry's CA at
`/etc/pki/ca-trust/source/anchors/mirror-registry-rootCA.pem` and logs the
bare-metal host's podman into the registry, which are the two inputs the
disconnected rendering reads.

What the disconnected run adds to each bundle:

- A `<cluster>-user-ca-bundle` ConfigMap in the hosted cluster's own namespace,
  holding the mirror registry CA under `ca-bundle.crt`. The HostedCluster
  references it twice: `spec.configuration.proxy.trustedCA`, which puts the CA
  in the hosted cluster's cluster-wide proxy trust bundle, and
  `spec.additionalTrustBundle`, which HyperShift carries into the nodes' own
  trust store through the ignition it generates. Both fields look for
  `ca-bundle.crt`, so one ConfigMap serves both. The mirror registry is
  self-signed, so without this every pull from it fails on an unknown
  authority.
- `spec.imageContentSources` on the HostedCluster, from
  `hosted_cluster_image_content_sources`. A hosted cluster is its own cluster
  with its own `registries.conf` - the hub's `ImageDigestMirrorSet` /
  `ImageTagMirrorSet` only redirect pulls made *by the hub*, so without this
  list the hosted cluster resolves every pullspec to its public registry.
  `registry.redhat.io/multicluster-engine` is the mapping that matters most on
  Agent platform: the agent and assisted-installer images the nodes run come
  from there, so omitting it gives you a control plane that comes up while the
  NodePool never finishes joining. The role asserts it is present
  (`hosted_cluster_required_image_content_sources`) rather than letting that
  fail silently hours later.
- A pull secret reduced to the mirror registry's own credentials, read from
  `mirror_registry_authfile`. Same reasoning as
  `roles/setup-hub-cluster-disconnected`: vault's `pull_secret` also carries
  live quay.io / registry.redhat.io credentials, and shipping those would give
  the nodes a working route back to the real registries, so a pull the mirror
  is missing could still succeed and the cluster would be disconnected only by
  accident. Set `hosted_cluster_disconnected_pull_secret: false` to render
  vault's secret unchanged while debugging.
- `spec.configuration.operatorhub.disableAllDefaultSources: true`, since the
  default catalogs resolve against `registry.redhat.io` and otherwise only show
  up as failing CatalogSource pods. Set
  `hosted_cluster_disable_default_catalog_sources: false` if you are mirroring
  them.
- An APIServer `loadBalancer.hostname` that has to resolve to this cluster's
  MetalLB address **on the hub it is running on**. Pool *names* are identical on
  every hub; the *addresses* are not (connected clusters: `hub` 60-62, `hub2`
  90-92; `-d` clusters: `hub2` 93-95, `hubd` 67-69),
  so a cluster rendered disconnected publishes a name that must resolve to its
  `hubd` address, not its `hub` one. The role resolves the hub per cluster
  (`hosted_cluster_metallb_hub`, defaulting to `target_hub`, but `hubd` for any
  cluster rendered disconnected), fails if that cluster's
  `hosted_cluster_metallb_pools[...].ip` has no entry for that hub, and prints
  the name/address pairing plus the `dig` command to check it. Re-render DNS for
  the same hub or the two drift apart:
  `setup_bm_host.yaml --tags dns -e target_hub=hubd`. For a disconnected cluster
  that is the zone `roles/setup-dns` renders with `-e target_hub=hubd`, not
  hub1's. The default (`api.<cluster-name>.<base_domain>`) is correct by
  construction under the repo convention that a hosted cluster's DNS zone is
  named after the cluster - a cluster named `hcp-cluster1-d` gets
  `api.hcp-cluster1-d.mylab.com`. If you render a cluster disconnected under a
  name whose zone points at another hub - e.g. plain `hcp-cluster1` with
  `-e disconnected_install=true` - set `api_hostname` on its `hosted_clusters`
  entry, or `hosted_cluster_api_hostname` in `vars.yaml`.

The connected and disconnected renderings are **two separate templates**
(`templates/hosted-cluster.yaml.j2` and
`templates/hosted-cluster-disconnected.yaml.j2`), the same way `setup-hub-acm`
keeps its disconnected `AgentServiceConfig` separate. `tasks/main.yml` picks
between them per cluster. They share the NodePool / ManagedCluster /
KlusterletAddonConfig tail, so a change to one usually belongs in both.

The release payload is addressed **by version**, not by a hard-coded digest:
`hosted_cluster_release_version` defaults to `<ocp_major_version>.<ocp_minor_version>`,
so the hosted clusters run the same release the rest of the lab is built from
and there is one number to bump. Both `HostedCluster.spec.release.image` and
`NodePool.spec.release.image` come from it.

Connected renders `quay.io/openshift-release-dev/ocp-release:<version>-x86_64`.
Disconnected renders the **mirror registry's own copy** at the same version,
`<registry>:<port>/<mirror_release_repository>:<version>-x86_64` - the same
pullspec `setup-hub-cluster-disconnected` already extracts `openshift-install`
from, so it is known to exist there.

That is a preference, not a requirement. The release image is resolved **on the
hub** - HyperShift pulls it there to extract the payload and pin every component
image by digest - and the hub carries oc-mirror's `ImageTagMirrorSet`, which
redirects `quay.io/openshift-release-dev/ocp-release` by tag
(`acm_disconnected_registry_mirrors` lists it with `digest_only: false`, and
`setup-hub-cluster-disconnected` applies ITMS as a day-2 resource). So the
canonical quay.io tag resolves through the mirror perfectly well.

`spec.imageContentSources` is a different layer: it is the hosted cluster's own
`registries.conf`, carries `ImageDigestMirrorSet` (mirror-by-digest-only)
semantics, and covers the component images - which are pulled by digest anyway,
so digest-only is exactly right there.

Naming the mirror directly buys one thing: the payload pull stops depending on
the hub's ITMS being present and correct. It costs portability, since the
pullspec names this lab's registry, so a HostedCluster restored onto a connected
hub needs its release image swapped. Set
`hosted_cluster_release_image_disconnected: "{{ hosted_cluster_release_image }}"`
to keep the canonical name and lean on the hub's ITMS instead.

Connected and disconnected clusters are **two separate lists of separate
clusters**, which is what lets a connected and a disconnected hosted cluster be
up on this lab at the same time:

```yaml
## connected - these names are reserved for connected runs
hosted_clusters:
  - hcp-cluster1
  - hcp-cluster2
  - hcp-cluster3

## disconnected - rendered instead of the above when disconnected_install=true
hosted_clusters_disconnected:
  - hcp-cluster1-d
  - hcp-cluster2-d
  - hcp-cluster3-d
```

A `-d` cluster is a cluster in its own right: its own namespace, its own
MetalLB pool (`hubd` .67-.69), its own DNS zone and its own worker VMs. It is
not `hcp-cluster1` rendered differently, and the role refuses to run if a name
appears in both lists, since the two would collide on all three. Note the
connected clusters carry **no `hubd` address** - they never run on the
disconnected hub, and a stray entry would make `setup-hub-acm` create pools
there for clusters that will never ask for them.

Run a disconnected render against the disconnected hub's kubeconfig:

```bash
ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass \
  -e disconnected_install=true -e target_hub=hubd
```

`setup_bm_host.yaml` renders the helper for **both** kinds in one
unconditional pass - there is no `disconnected_install` switch anywhere in
`setup-bm-host` / `setup-dns` / `setup-lb` / `setup-tftp`, so the helper never
needs rebuilding to move between connected and disconnected. That pass now
covers the `-d` clusters:

- a forward zone per hosted cluster, connected and disconnected, derived from
  the two cluster lists (`<cluster-name>.<base_domain>`) instead of the old
  `hosted_domain`/`2`/`3` variables. One shared template replaces the three
  copy-pasted ones, which is why adding the `-d` clusters needed no new
  template.
- a matching `zone` stanza in `named.conf` and PTRs in the reverse zone, driven
  from the same lists so a zone file and its stanza can never disagree.
- a `<forwarder>` in the libvirt `default` network per zone, so those names
  resolve from the VMs on `virbr0` and not just from the helper.

Which hub each zone's `api`/`api-int` points at is resolved **per cluster**:
connected clusters follow `target_hub`, disconnected ones use `hubd`, and both
move to `hub2` under `-e target_hub=hub2` for a DR cutover. `-e target_hub=hubd`
leaves the connected clusters on their `hub` addresses rather than failing,
since they do not run there.

`*.apps` is wired for the `-d` clusters too. `setup-lb` binds one ingress VIP
per hosted cluster as a secondary address on the helper and renders an haproxy
frontend/backend pair per cluster on :80 and :443, all derived from
`hosted_cluster_node_keys` rather than hand-listed - the `-d` clusters had no
ingress path before simply because that list was maintained by hand:

| cluster | `*.apps` VIP | worker backends |
|---|---|---|
| hcp-cluster1 / 2 / 3 | .49 / .59 / .58 | .41-.43 / .51-.53 / .54-.56 |
| hcp-cluster1-d | .48 | .44-.46 |
| hcp-cluster2-d | .38 | .28, .29, .37 |
| hcp-cluster3-d | .99 | .96-.98 |

Worker, PTR, DHCP and `*.apps` records are all rendered only for `ip_list` keys
that exist, so a cluster whose VMs have not been built yet still gets a valid
zone carrying the `api`/`api-int` records its HostedCluster publishes, and an
haproxy section appears only once it has both a VIP and at least one worker -
never a frontend with no backend.

Review and apply the rendered bundles exactly as in the connected flow -
`roles/create-hosted-cluster/templates/.rendered-<cluster>.yaml`. Keep
`hosted_cluster_image_content_sources` in step with
`acm_disconnected_registry_mirrors` (setup-hub-acm) and with what oc-mirror
actually published; after the hub is up,
`oc get imagedigestmirrorset,imagetagmirrorset -o yaml` is the source of truth.

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

Or Online Boutique, if you want a workload with a UI worth showing after the
cutover. The `no-loadgenerator` overlay drops the Locust traffic generator,
strips the `runAsUser`/`runAsGroup`/`fsGroup` values `restricted-v2` rejects,
swaps upstream's LoadBalancer Service for a Route, and creates its own
namespace:

```bash
oc apply -k https://github.com/sadiquepp/openshift/test-workloads/online-boutique/overlays/no-loadgenerator
oc get route frontend -n online-boutique -o jsonpath='{.spec.host}{"\n"}'
```

It is ~1270m CPU / ~1112Mi of requests across 11 services, which fits two
workers at 4 vCPU / 8Gi. Stateless apart from `redis-cart` on an `emptyDir`,
so what a restore brings back is the workload definitions - the same claim
hello-openshift makes, with a better demo.

Verify that the application is accessible.

```bash
oc get route hello-openshift -n hello-openshift
```


# Backup and Restore

## Choose how the control-plane volumes are captured

The hosted control plane's state is etcd, on a PVC in the HyperShift
control-plane namespace. `oadp_backup_method` in `vars.yaml` decides how
Velero captures it, and every command below takes it as an override:

- **`fs`** (default) - Kopia file-system backup
  (`defaultVolumesToFsBackup: true`). Velero's node-agent mounts the
  volume and streams the files to S3. Runs on any StorageClass, LVM
  Storage included - but see the note under
  [Choose the Hub's PV Storage](#choose-the-hubs-pv-storage): completing is
  not the same as being restorable for a control plane.
- **`csi`** - CSI VolumeSnapshot plus Velero's data mover
  (`snapshotVolumes` + `snapshotMoveData` + `datamover: velero`). The
  storage layer takes a point-in-time snapshot and the data mover copies
  it to the same S3 bucket. Needs a CSI driver with snapshot support -
  which on this lab means the hub is on Ceph/ODF rather than LVM
  Storage, and is the reason
  [the Ceph cluster](#ceph-9-storage-for-hub-pvs-odf-external-mode)
  exists.

Each method has its own Backup/Restore templates in `oadp/templates/`
and its own object names (`<cluster>-backup` vs `<cluster>-backup-csi`),
so both can be demonstrated against one bucket. The bucket, the
credentials and the DataProtectionApplication are shared - switching
methods changes nothing else. `oadp/README.md` has the full comparison
and the prerequisites.

## Primary Hub
### Configure OADP (credentials + DPA)
The operator is already there (installed during hub bring-up). This
step just points it at your bucket:

```bash
ansible-playbook -i inventory/hosts setup_oadp.yaml --ask-vault-pass
```

For the CSI method, pass it here too - the role then labels the
VolumeSnapshotClass (`velero.io/csi-volumesnapshot-class=true`) that
Velero selects snapshot classes by. Without that label Velero skips the
volume and still reports the backup `Completed`:

```bash
ansible-playbook -i inventory/hosts setup_oadp.yaml --ask-vault-pass -e oadp_backup_method=csi
```

Idempotent - re-running against the same hub just reconciles the
secret/DPA. Both hubs point at the same bucket/prefix, so hub2's Velero
can see backups hub1 created. Run it on the DR hub with the same method,
so the snapshot class is labelled there before the restore.

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
oc get backup.velero.io -n openshift-adp hello-openshift-oadp-backup -o yaml
```
### Exclude ACM's import secret from the backup

Do this **before** the backup, on the hub being backed up.

```bash
oc label secret hcp-cluster1-import -n hcp-cluster1 \
  velero.io/exclude-from-backup=true --overwrite
oc get secret hcp-cluster1-import -n hcp-cluster1 --show-labels
```

`hcp-cluster1` is the HostedCluster's namespace and *also* ACM's
ManagedCluster namespace, so `hcp-cluster1-import` - which carries a
bootstrap ServiceAccount token minted by this hub - is inside the
backup's scope. Restoring it hands the DR hub a token signed by the wrong
cluster's key, and the restored cluster hangs in `Importing` with the
klusterlet logging `Unauthorized` until the secret is deleted by hand. It
is also a 360-day credential that has no business sitting in S3.

`velero.io/exclude-from-backup` is a **label**, not an annotation -
`oc annotate` applies cleanly and does nothing. Velero reads it while
collecting items, so it only has to be set at backup time; nothing is
needed on the DR hub.

MCE owns this secret and reconciles it, so check `--show-labels` before
each backup rather than assuming the label stuck - a backup that quietly
re-includes it looks healthy right up until the restore fails.

Full write-up:
[Restored cluster stuck in `Importing`](oadp/README.md#restored-cluster-stuck-in-importing).

### Backup a hosted cluster using OADP.

```bash
ansible-playbook -i inventory/hosts backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1
```

`hcp_cluster_name` must match the HostedCluster's name/namespace - it's
used to derive both the hosting namespace and the HyperShift
control-plane namespace (`<name>-<name>`). Works unchanged for
`hcp-cluster2` or any future hosted cluster.

For a CSI snapshot backup (Backup named `hcp-cluster1-backup-csi`):

```bash
ansible-playbook -i inventory/hosts backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e oadp_backup_method=csi
```

The playbook refuses to start if no VolumeSnapshotClass is labelled for
Velero. The volume data then moves in `DataUpload` objects rather than
inside the Backup's own progress counters, so a csi backup sits in
`WaitingForPluginOperations` for a while - watch it with:

```bash
oc get datauploads.velero.io -n openshift-adp -w
```

- Get the status of the backup and wait till it finishes before proceeding to the next step.
```bash
oc get backup.velero.io -n openshift-adp hcp-cluster1-backup -o yaml
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
ansible-playbook -i inventory/hosts shutdown_hub_cluster.yaml --ask-vault-pass
```

### Destroy the Ceph cluster (Ceph/CSI DR demo)

Only for the Ceph path, and only worth doing deliberately: **this
destroys the storage the backup was taken from.**

With `oadp_backup_method=csi` the etcd data is no longer on Ceph. The CSI
snapshot was transient - taken, copied to S3 by the data mover, then
released - so the bucket holds everything the restore needs. Leaving the
original Ceph cluster running makes that impossible to demonstrate: an
observer cannot tell whether the hosted cluster came back from object
storage or from storage that never went away, and in a real disaster it
would not have.

In production the DR site has its own storage cluster of the same type,
never the primary's. Rebuilding gets the same evidence on one bare-metal
host without a second 80G Ceph cluster: after this, every RBD image the
hosted cluster's etcd ever lived on is gone.

Take the backup first, and confirm the `DataUpload`s completed, before
running this - after it there is no going back to hub1's storage.

```bash
ansible-playbook -i inventory/hosts cleanup-ceph.yaml
```

Verify it actually removed everything - a partial teardown leaves stale
OSD disks that the rebuilt cluster cannot claim, and you get a Ceph
cluster with no OSDs:

```bash
virsh list --all | grep -E 'ceph[123]|cephadmin'          # expect no rows
ls /var/lib/libvirt/images/ | grep -E '^ceph|^cephadmin'  # expect nothing
```

If anything is left, remove it by hand before rebuilding.

## DR Hub
### Rebuild Ceph for the DR hub (Ceph/CSI DR demo)

A brand-new cluster on the same four VMs - no pool, no image, no CSI user
survives from hub1's cluster:

```bash
ansible-playbook -i inventory/hosts setup_ceph.yaml --ask-vault-pass
```

Wait for `HEALTH_OK` with 3 mons and 9 OSDs before continuing
(`ssh root@192.168.122.27 ceph -s`) - the export step will produce a JSON
blob against a degraded cluster and you will find out later.

The StorageClass name is derived from `ceph_odf_storagecluster_name`, so
the rebuilt cluster presents `ocs-external-storagecluster-ceph-rbd`
again. That matters: Velero restores each PVC with its original
`spec.storageClassName`, and a DR hub without a class of that exact name
leaves the restored PVCs `Pending` for ever with nothing in the Restore's
status to explain it.

### Build DR Hub
Once the primary hub is shutdown, you can build the DR hub.
```bash
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass
```

On the Ceph path, build hub2 with `use_lvm_storage: false` and attach it to
the rebuilt Ceph cluster **now**, before the AgentServiceConfig below:

```bash
ansible-playbook -i inventory/hosts setup_ceph_odf.yaml --ask-vault-pass -e target_hub=hub2
```

The AgentServiceConfig provisions three PVCs - `databaseStorage` (10Gi),
`filesystemStorage` (100Gi) and `imageStorage` (50Gi) - and none of them
names a `storageClassName`, so they bind against whatever StorageClass the
cluster marks **default**. Until that exists they sit `Pending` and
assisted-service never starts. On the LVM path `lvms-vg1` is the default;
on the Ceph path it is `ocs-external-storagecluster-ceph-rbd`, which is
why `ceph_odf_rbd_default_sc` defaults to true. Check before continuing:

```bash
oc get sc      # exactly one class marked (default)
```

Note that AgentServiceConfigs are not restored by OADP. You need to apply the rendered manifests manually before proceeding to the next step. Watch the ansible debug output for the location of the rendered manifests to apply.
```bash
oc apply -f /home/images/hcp-backup-restore/roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc get pvc -n multicluster-engine    # the three should reach Bound
```
There is no need to create InfraEnv, HostedCluster and discover nodes. OADP will do that automatically.

### Configure OADP on DR Hub

```bash
ansible-playbook -i inventory/hosts setup_oadp.yaml --ask-vault-pass -e target_hub=hub2
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
ansible-playbook -i inventory/hosts restore_hosted_cluster.yaml --ask-vault-pass -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2
```
Check the status of the restore.
```bash
oc get restore.velero.io -n openshift-adp hcp-cluster1-restore -o yaml
```

Restore with the same method the backup used - it selects both the
Restore template and the name of the Backup to restore from, and the
playbook stops with a clear message if that Backup is not visible on
this hub yet:

```bash
ansible-playbook -i inventory/hosts restore_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2 -e oadp_backup_method=csi
oc get restore.velero.io -n openshift-adp hcp-cluster1-restore-csi -o yaml
oc get datadownloads.velero.io -n openshift-adp -w
```

### Point DNS at the DR hub

The DR hub is on its own network segment, so the restored hosted clusters come
up on its MetalLB addresses (`.90`/`.91`/`.92`) rather than hub1's - the pool
names are the same, the addresses are not. Re-render the zone files so
`api`/`api-int` follow them:

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns \
  --ask-vault-pass -e target_hub=hub2
```

Verify DNS and the restored kube-apiserver Service agree:

```bash
dig +short api.hcp-cluster1.mylab.com @192.168.122.21
oc get svc kube-apiserver -n hcp-cluster1-hcp-cluster1 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

**Then check a worker node, not just the helper.** The VMs do not query the
helper directly - they get `192.168.122.1` from DHCP, which is libvirt's
dnsmasq, which forwards the lab zones to the helper **and caches the answers**.
A correct zone on the helper and a stale answer on the nodes is the normal
state for a few minutes after a cutover, and the symptom is both hosted-cluster
workers going `NotReady` while `oc get co` falls apart - the kubelets are still
dialling the hub that just went away.

```bash
ssh core@192.168.122.41 'getent hosts api.hcp-cluster1.mylab.com'   # want the DR address
```

If it still shows the old address, flush dnsmasq's cache on the bare-metal
host - this clears cached records without touching DHCP leases or disturbing
any VM:

```bash
sudo kill -HUP $(cat /var/run/libvirt/network/default.pid 2>/dev/null \
                 || cat /var/run/libvirt/dnsmasq/default.pid)
```

Kubelets re-resolve and rejoin on their own within a minute or two;
`systemctl restart kubelet` on each worker forces it.

The hosted-cluster zones are served with `$TTL 60` and this dnsmasq is capped
at `max-cache-ttl=60` (`roles/setup-bm-host/templates/default-network.xml.j2`),
so a cutover propagates in about a minute. Both are recent - a lab whose
`default` network was defined before that change still caches at the zone's
old 1-day TTL until `setup_bm_host.yaml --tags virtnet` redefines the network,
which drops `virbr0` and briefly interrupts every VM. The flush above is the
zero-downtime alternative.

Set `target_hub: hub2` in `vars.yaml` to make the cutover permanent. See
[MetalLB Address Pools for Hosted Clusters](#metallb-address-pools-for-hosted-clusters)
for how the per-hub addresses are defined.


## Disconnected Hosted Cluster

A hosted cluster whose worker VMs have **no route off the lab network**, so it
can only ever pull from the local mirror registry. It runs on the disconnected
hub (`setup_hub_cluster_disconnected.yaml`) and is deliberately built to sit
*alongside* `hcp-cluster1` rather than replace it - both can be up at once.

Everything hangs off the same `disconnected_install` flag as the rest of the
disconnected flow (`vars.yaml`, or `-e disconnected_install=true`). Connected
runs are completely unaffected: the same playbooks, the same role and the same
`hosted-cluster.yaml.j2` template are used for both.

What is distinct about it:

| | Connected (`hcp-cluster1`) | Disconnected (`hcp-cluster1-d`) |
| --- | --- | --- |
| Worker VMs | `c1_worker1..3` | `c1-d-worker1..3` |
| Worker IPs | `.41` `.42` `.43` | `.44` `.45` `.46` |
| Internet access from workers | yes | **cut** (no NAT, egress rejected) |
| DNS zone | `hcp-cluster1.mylab.com` | `hcp-cluster1-d.mylab.com` |
| `api` / `api-int` | MetalLB `hcp-cluster1-api-pool` | MetalLB `hcp-cluster1-d-api-pool` |
| `*.apps` VIP (haproxy) | `.49` (`c1lb`) | `.48` (`c1dlb`) |
| VM folder | `/var/lib/libvirt/images/hosted_cluster` | `/var/lib/libvirt/images/hosted_cluster_disconnected` |

The `api`/`api-int` split is what makes the two clusters independent: each
hosted cluster's kube-apiserver VIP comes from its own single-address MetalLB
pool, and each has its own zone publishing that address, so nothing collides.
`*.apps` for the disconnected cluster is served by its own haproxy frontends on
`c1dlb`, whose backends are the three `c1dworker*` addresses.

### How the workers are cut off

Before any VM is created, the three worker IPs get the same two rules the
disconnected hub's nodes get (see
`roles/setup-hub-cluster-disconnected/tasks/block-node-nat.yml`, which both
share):

1. `RETURN` at the top of libvirt's `LIBVIRT_PRT` chain (**nat** table), so
   their traffic is never MASQUERADEd out to the real internet.
2. `REJECT` at the top of `LIBVIRT_FWO` (**filter** table), so the un-NATed
   packets do not leave the hypervisor either and the node fails fast instead
   of timing out.

Both matches are "from this worker, NOT to `192.168.122.0/24`", so the mirror
registry, MinIO, the helper's DNS/DHCP/TFTP, the load balancer and the workers
themselves all stay fully reachable - only egress past the lab is cut. The
rules live in the running ruleset only; libvirt rebuilds those chains when
libvirtd restarts or a network is stopped/started, so re-run the playbook (or
just `--tags disconnected-nat`) if that happens. Set
`hosted_cluster_disconnected_block_node_nat: false` to leave the workers
connected while still installing from the mirror - useful when checking whether
a failure is genuinely caused by the disconnection.

### Image signature policy on the discovery host

RHCOS ships `/etc/containers/policy.json` with a `signedBy` entry for
`registry.redhat.io` and `registry.access.redhat.com`. The mirror mappings in
`roles/setup-hub-acm`'s `mirror-config` ConfigMap redirect the *pull* to the
mirror registry, but podman still looks for the detached signature under the
image's original `registry.redhat.io` name - in Red Hat's sigstore, which a node
whose NAT has been cut cannot reach and which mirror-registry does not serve.
So a disconnected worker boots the discovery ISO and dies on:

```
podman[3161]: Trying to pull registry.redhat.io/multicluster-engine/assisted-installer-agent-rhel9@sha256:12fdad03...
podman[3161]: Error: copying system image from manifest list: Source image rejected: A signature was required, but no signature exists
```

`agent.service` never starts, so the host never registers and **no Agent ever
appears in the InfraEnv** - which looks exactly like the VMs failing to boot.

Shipping the GPG key with the ISO does not help: the keys are already on the
host (that is what `keyPaths` points at) - it is the per-image signature that is
missing, not the key to verify it with.

The fix is the InfraEnv's `spec.ignitionConfigOverride`, which writes a
`policy.json` that accepts those two registries unsigned - the same edit that
works by hand after sshing into the node, applied declaratively so the run does
not need one.
`setup_hosted_cluster_vm.yaml` puts it on the live InfraEnv (patching an
InfraEnv that predates it), waits for assisted-service to rebuild the ISO, and
forces the cached copy in `download_dir` to be replaced before booting the VMs -
so nothing boots the old ISO. `setup_bminfra.yaml` renders the same override
into `.rendered-03-infraenv.yaml` for a fresh InfraEnv.

Only the disconnected path does any of this; a connected InfraEnv is rendered
exactly as before. Tunable in `vars.yaml`:

| Variable | Default | |
|---|---|---|
| `bminfra_disconnected_relax_image_policy` | `true` | set `false` to keep signature checking - only useful if you have mirrored Red Hat's sigstore |
| `bminfra_discovery_image_policy` | both Red Hat registries unsigned | the `policy.json` document itself; narrow it to one registry if you prefer |
| `bminfra_ignition_extra_files` | `[]` | extra ignition `storage.files` entries, e.g. an `/etc/containers/registries.d/` drop-in pointing `sigstore` at a mirrored signature store |
| `bminfra_ignition_version` | `3.2.0` | ignition spec version of the override |

To re-apply just this step against an existing InfraEnv:

```bash
ansible-playbook -i inventory/hosts setup_hosted_cluster_vm.yaml --ask-vault-pass \
  -e disconnected_install=true --tags discovery-ignition
```

### Building it

Same order as a connected hosted cluster, with `-e disconnected_install=true`
on each step so the disconnected hub's kubeconfig and the disconnected cluster
list are used (`disconnected_install` wins over `target_hub`):

```bash
# 1. worker VMs (.44-.46): NAT cut first, the hubd InfraEnv's ignition override
#    ensured (see above), then the VMs booted off that InfraEnv's ISO
ansible-playbook -i inventory/hosts setup_hosted_cluster_vm.yaml --ask-vault-pass \
  -e disconnected_install=true

# 2. approve the discovered agents in the ACM/MCE Web UI, then render the bundle
ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass \
  -e disconnected_install=true

# 3. review and apply it
oc apply -f roles/create-hosted-cluster/templates/.rendered-hcp-cluster1-d.yaml
```

DNS for the zone is rendered by `setup-dns` like every other zone (no flag
needed - the zone is always present). Point its `api`/`api-int` at the
disconnected hub with the usual `target_hub` override:

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns --ask-vault-pass \
  -e target_hub=hubd
```

Verify:

```bash
dig +short api.hcp-cluster1-d.mylab.com @192.168.122.21     # -> 192.168.122.67 on hubd
dig +short console-openshift-console.apps.hcp-cluster1-d.mylab.com @192.168.122.21  # -> 192.168.122.48
sudo iptables -t nat -nL LIBVIRT_PRT --line-numbers | grep hcp-cluster1-d
```

Adding a second disconnected hosted cluster is the same three edits as a
connected one: a name in `hosted_clusters_disconnected`, an entry in
`hosted_cluster_metallb_pools`, and its workers in
`hosted_cluster_disconnected_workers` (plus their `ip_list` octets, a zone and
haproxy frontends if it needs its own ingress VIP).


## MetalLB Address Pools for Hosted Clusters

Each hosted cluster gets its **own single-address MetalLB pool**, so its
kube-apiserver VIP can only ever be the address DNS publishes for it on the hub
it is running on.

The **pool name is the same on every hub**; the **address it holds is not**.
The DR hub sits on its own network segment where hub1's addresses are not
routable, so each cluster carries one address per hub:

| Hosted cluster   | Pool                      | hub (primary)    | hub2 (DR)        | hubd (disconnected) |
| ---------------- | ------------------------- | ---------------- | ---------------- | ------------------- |
| `hcp-cluster1`   | `hcp-cluster1-api-pool`   | `192.168.122.60` | `192.168.122.90` | -                   |
| `hcp-cluster2`   | `hcp-cluster2-api-pool`   | `192.168.122.61` | `192.168.122.91` | -                   |
| `hcp-cluster3`   | `hcp-cluster3-api-pool`   | `192.168.122.62` | `192.168.122.92` | -                   |
| `hcp-cluster1-d` | `hcp-cluster1-d-api-pool` | -                | `192.168.122.93` | `192.168.122.67`    |
| `hcp-cluster2-d` | `hcp-cluster2-d-api-pool` | -                | `192.168.122.94` | `192.168.122.68`    |
| `hcp-cluster3-d` | `hcp-cluster3-d-api-pool` | -                | `192.168.122.95` | `192.168.122.69`    |

A `-` is a deliberate reservation, not an omission. The connected three never
run on the disconnected hub and the `-d` clusters never run on hub1, so those
addresses do not exist and nothing renders a pool for them. hub2 is the one hub
in both columns: it is the DR restore target for both sets, because the
disconnected bundle pins the canonical quay.io release digest and a `-d`
cluster therefore restores onto a connected hub unchanged.

Keeping the pool names identical across hubs is what lets a HostedCluster's
`metallb.io/address-pool` annotation survive an OADP restore onto the DR hub
unchanged - the cluster still belongs to the same pool, that pool just holds a
different, locally routable address there.

All of it comes from one map in `vars.yaml`, so the pool, the DNS record and
the HostedCluster annotation cannot drift apart:

```yaml
hosted_cluster_metallb_pools:
  hcp-cluster1:
    pool: hcp-cluster1-api-pool
    ip:
      hub: 60
      hub2: 90
  hcp-cluster2:
    pool: hcp-cluster2-api-pool
    ip: {hub: 61, hub2: 91}
  hcp-cluster3:
    pool: hcp-cluster3-api-pool
    ip: {hub: 62, hub2: 92}

  hcp-cluster1-d:
    pool: hcp-cluster1-d-api-pool
    ip: {hub2: 93, hubd: 67}
  hcp-cluster2-d:
    pool: hcp-cluster2-d-api-pool
    ip: {hub2: 94, hubd: 68}
  hcp-cluster3-d:
    pool: hcp-cluster3-d-api-pool
    ip: {hub2: 95, hubd: 69}
```

Three variables select what a hub gets:

- **`metallb_hub`** - which hub `setup-hub-acm` is configuring. Set by
  `setup_hub_cluster.yaml` (`hub`), `setup_hub_cluster2.yaml` (`hub2`) and the
  disconnected hub's example block (`hubd`).
- **`target_hub`** - which hub is currently authoritative. Already used to pick
  the kubeconfig for the OADP playbooks; it now also selects the address
  `setup-dns` publishes as `api`/`api-int`. Defaults to `hub`.
- **`disconnected_install`** - which *set* of hosted clusters the run is about:
  `hosted_clusters_disconnected` when true, `hosted_clusters` when false. The
  same switch `roles/create-hosted-cluster` already renders from, so a hub gets
  pools for exactly the clusters that hub run would create there.

Carrying the hub's address is necessary but not sufficient - the cluster must
also be in the run's install mode. This only ever changes hub2, the one hub
holding addresses for both sets:

| Run                                            | Pools rendered                            |
| ---------------------------------------------- | ----------------------------------------- |
| `setup_hub_cluster.yaml`                        | `hcp-cluster1/2/3-api-pool` (.60-.62)     |
| `setup_hub_cluster2.yaml`                       | `hcp-cluster1/2/3-api-pool` (.90-.92)     |
| `setup_hub_cluster2.yaml -e disconnected_install=true` | `hcp-cluster{1,2,3}-d-api-pool` (.93-.95) |
| `setup_hub_cluster_disconnected.yaml`           | `hcp-cluster{1,2,3}-d-api-pool` (.67-.69) |

So `oc get IPAddressPool -n metallb-system` on a connected hub2 shows **three**
pools, not six. The `-d` clusters' hub2 addresses stay reserved in the map; the
pools for them are created by re-running just the `acm` tag in disconnected
mode, which is the step before restoring a `-d` cluster onto hub2:

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass --tags acm \
  -e disconnected_install=true
```

`roles/setup-hub-acm` prints the split it resolved (`renders pools for: ... |
not rendered here: ...`) on every run, so you can see which set a hub got
without reading the map.

Switching modes also cleans up after itself, since `oc apply` does not prune: a
hub2 built when both sets were rendered would otherwise keep all six pools
forever. The role deletes the other mode's `IPAddressPool`/`L2Advertisement`
pairs - only ones named in `hosted_cluster_metallb_pools` that carry an address
for this hub, never anything else on the cluster - and **skips any pool whose
address a Service currently holds**, so a connected re-run cannot strip the VIP
from a `-d` cluster restored onto the same hub. It reports what it did
(`deleted:` / `in use ..., kept:` / `absent:`) per pool. Set
`metallb_prune_other_mode_pools: false` to leave both modes' pools in place.

Three things are generated from the map:

1. `roles/setup-hub-acm` renders one `IPAddressPool` per cluster of this run's
   install mode that holds a `metallb_hub` address (a single address, e.g.
   `192.168.122.60-192.168.122.60`) and one `L2Advertisement` per pool, so each
   address is advertised independently.
2. `roles/setup-dns` points that cluster's `api` and `api-int` A records at
   `target_hub`'s address for it.
3. `roles/create-hosted-cluster` annotates the HostedCluster with
   `metallb.io/address-pool: <pool>`.

If a hub is genuinely on a different subnet rather than a different block of
the same `/24`, give it its own prefix and the addresses and DNS records both
follow:

```yaml
hosted_cluster_metallb_network_prefixes:
  hub2: "192.168.150"
```

### DR cutover

The DR hub's pools for the connected clusters are created when you build it
(`setup_hub_cluster2.yaml` passes `metallb_hub: hub2`), so after restoring the
hosted clusters onto hub2 the only remaining step is to move DNS. (Restoring a
`-d` cluster there needs its pool created first - see the
`disconnected_install` note above.)

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns \
  --ask-vault-pass -e target_hub=hub2
```

`api`/`api-int` for every hosted cluster now resolve to the hub2 addresses
(`.90`/`.91`/`.92`), which is where their restored kube-apiservers actually
came up. Set `target_hub: hub2` in `vars.yaml` to make the cutover permanent.

### What actually pins the address

Each pool carries a `serviceAllocation` constraint naming that hosted
cluster's control-plane namespace:

```yaml
  serviceAllocation:
    priority: 10
    namespaces:
      - hcp-cluster1-hcp-cluster1   # <hostedcluster-namespace>-<hostedcluster-name>
```

That constraint is what enforces the mapping. **The
`metallb.io/address-pool` annotation on the HostedCluster does not, on its
own** - MetalLB reads that annotation from the LoadBalancer *Service*, and
HyperShift does not copy HostedCluster annotations onto the `kube-apiserver`
Service it generates. Keep the annotation for what it is: the record, on the
HostedCluster itself, of which pool that cluster belongs to, and the value to
pass if you ever need to force a reallocation by hand:

```bash
oc -n hcp-cluster1-hcp-cluster1 annotate svc/kube-apiserver \
  metallb.io/address-pool=hcp-cluster1-api-pool --overwrite
```

### Notes and constraints

- This replaces the old shared `hcp-ip-pool` (hub `60-63`, hubd `64-67`,
  hub2 `90-93`), which let any hosted cluster take any free address in the
  range. `.63` is now free; `.67` and `.93` were taken back by the `-d`
  clusters' own pools. `roles/setup-hub-acm` deletes the
  old pool and its `l2advertisement` before applying the new ones, since
  MetalLB rejects overlapping pools - set
  `metallb_remove_legacy_shared_pool: false` to skip that.
- All three hubs can carry the pools at once, since MetalLB only ARPs for an
  address once a Service is assigned it. Just don't run the same hosted
  cluster on two hubs at the same time.
- Every pool is namespace-constrained and there is no longer a catch-all pool
  on the hub, so a LoadBalancer Service outside these control-plane
  namespaces will sit at `<pending>` until you give it a pool of its own.
- Adding a fourth hosted cluster means adding it to **both**
  `hosted_cluster_metallb_pools` (with an address for every hub) and
  `hosted_clusters`, then re-running `setup-hub-acm` (pools) and `setup-dns`
  (records). Both roles fail fast on a missing entry.

### Verifying

```bash
oc get ipaddresspool,l2advertisement -n metallb-system
oc get svc kube-apiserver -n hcp-cluster1-hcp-cluster1 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
dig +short api.hcp-cluster1.mylab.com @192.168.122.21
```

The last two must agree - that is the whole point of this layout.


## Ceph 9 Storage for Hub PVs (ODF External Mode)

The hub's PVs come from **LVM Storage** by default - one `LVMCluster` over the
hub nodes' own spare disks, installed by `roles/setup-hub-acm` as part of hub
bring-up. The alternative documented here builds a **standalone Red Hat Ceph
Storage 9 cluster** on the same bare-metal host and hands it to the hub through
**OpenShift Data Foundation (ODF) in external mode**: ODF is installed on the
hub, but no Ceph daemon runs there - ceph-csi simply talks to the external
cluster's mons and provisions RBD (and CephFS) PVs out of it.

It is a drop-in replacement for LVM Storage as the hub's PV provider - the
backup/restore flow works either way - but it is what makes one thing possible
that LVM Storage cannot do: **CSI snapshot backups of the hosted control
plane's etcd volume**. LVM Storage ships no VolumeSnapshotClass, so on it OADP
can only walk the filesystem with Kopia. On the Ceph/ODF StorageClass, Velero
can take a point-in-time CSI snapshot and move it to S3 - see
[Choose how the control-plane volumes are captured](#choose-how-the-control-plane-volumes-are-captured).
It also brings RWX volumes and storage that survives rebuilding the hub.

### What gets built

`setup_ceph.yaml` creates four VMs on the same libvirt network as the rest of
the lab, addressed from `ip_list` in `vars.yaml`:

| VM          | Address          | Role                                                          |
| ----------- | ---------------- | ------------------------------------------------------------- |
| `ceph1`     | `192.168.122.24` | mon + mgr + osd ("all-in-one"); `cephadm bootstrap` runs here |
| `ceph2`     | `192.168.122.25` | mon + mgr + osd                                               |
| `ceph3`     | `192.168.122.26` | mon + mgr + osd                                               |
| `cephadmin` | `192.168.122.27` | `_admin` label only - `ceph.conf` + admin keyring, no daemons |

Each storage node gets `ceph_osd_disks_per_node` raw disks (3 x 100G by
default, sparse qcow2) on top of a 60G OS disk, so a default run is 9 OSDs and
roughly 1.1T of thin-provisioned image files. It is also 80G of RAM
(`ceph_storage_memory` x 3 + `ceph_admin_memory`) and 52 vCPUs - size the
bare-metal host accordingly, or trim those vars first.

`cephadmin` is where `ceph` / `cephadm shell` commands run, and where the ODF
exporter script runs later. It holds the admin keyring but never runs a daemon,
so day-2 work never has to happen on a node that is also serving I/O.

There is no Satellite anywhere in this flow. The nodes register directly with
`subscription-manager` using the same `org_id` / `activation_key` every other VM
in this lab uses, and cephadm pulls
`registry.redhat.io/rhceph/rhceph-9-rhel9:latest` authenticated with the same
`pull_secret`, which `setup-ceph-prereqs` installs as each node's podman
authfile - no separate registry credentials. Without RHCS entitlements, point
`ceph_container_registry` / `ceph_container_image` at the public upstream image
instead; `vars.yaml` carries the values commented in place.

### Requirements

**OCP 4.22 or later on the cluster consuming the storage.** Below 4.22 the
in-kernel RBD client cannot attach to an RHCS 9 (Tentacle) cluster: `rbd map`
fails with `failed to add secret to kernel` and the CSI attach ends in error
524, so the PV binds but never mounts. This is a client-side kernel gap - the
cluster health, the CSI user's caps and the image features all check out, and
the same image maps by hand from a RHEL 9 node. OCP 4.22 ships the kernel that
fixes it. `ocp_major_version` in `vars.yaml` (currently `"4.21"`) drives both
the hub's OCP version and the ODF channel the consumer role subscribes to
(`stable-{{ ocp_major_version }}`), so moving to 4.22 moves both together.

If you are pinned below 4.22, take krbd out of the path and mount through
rbd-nbd in userspace instead, by giving the RBD StorageClass
`parameters.mounter: rbd-nbd`. StorageClass parameters are immutable, so this
means exporting the generated class, renaming it, adding the parameter and
applying that as a second class - not patching the one ODF created:

```bash
oc get sc ocs-external-storagecluster-ceph-rbd -o yaml > rbd-nbd-sc.yaml
# edit: metadata.name -> ocs-external-storagecluster-ceph-rbd-nbd,
#       drop metadata.uid/resourceVersion/creationTimestamp,
#       add   parameters.mounter: rbd-nbd
oc apply -f rbd-nbd-sc.yaml
```

Not needed on 4.22+, and not something this repo renders for you.

**vault.yaml** reuses what the lab already requires - `org_id`,
`activation_key` and `pull_secret` - and adds one new value,
`ceph_dashboard_password`. `setup_ceph.yaml` asserts all of them up front
rather than failing halfway through a bootstrap.

**inventory/hosts** needs the `ceph`, `ceph_admin` and `ceph_nodes` groups that
`setup_ceph.yaml`'s second play targets. They are rendered from
`inventory/hosts.j2` by `setup_bm_host.yaml`, so an inventory generated before
the Ceph groups existed has to be re-rendered:

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --ask-vault-pass
```

### Switching the hub off LVM Storage

`use_lvm_storage` in `vars.yaml` gates both the LVM Storage operator
Subscription and the `LVMCluster` CR in `roles/setup-hub-acm`:

```yaml
use_lvm_storage: false
```

Set it before building the hub. Flipping it on an existing hub does not
uninstall anything - the role only skips those two steps on the next run, so an
already-installed LVM Storage has to be removed by hand.

That matters because **LVM Storage and ODF both want the `openshift-storage`
namespace**. LVM Storage's operator, its `LVMCluster`, ODF's operator and the
external `StorageCluster` all land there, and this repo has not tested them
sharing it. Run one or the other on a given hub:

- switch the hub to Ceph from the start (`use_lvm_storage: false`), or
- remove LVM Storage from the hub before running `setup_ceph_odf.yaml`, or
- leave the hub on LVM Storage and point the ODF plays at a different cluster
  entirely: `-e ceph_odf_target_kubeconfig=/path/to/other/kubeconfig`.

If the two do end up coexisting, at least keep the default StorageClass
unambiguous by setting `ceph_odf_rbd_default_sc: false`.

### Build the Ceph cluster

```bash
ansible-playbook -i inventory/hosts setup_ceph.yaml --ask-vault-pass
```

Three ordered plays, tagged so each can be re-run on its own
(`--tags ceph-vm`, `rhsm`, `ceph-prereqs`, `ceph-cluster`):

1. **`setup-ceph-vm`** creates the four VMs from `rhel9_kvm_image`, expands the
   OS partition into a 60G disk, and attaches the raw OSD disks to ceph1-3.
2. **`setup-rhsm` + `setup-ceph-prereqs`** register each node directly with
   `subscription-manager`, enable `rhceph_tools_repo`, install `cephadm` and
   `ceph-common`, and drop `pull_secret` as the node's podman authfile.
3. **`setup-ceph-cluster`** (delegated to ceph1) runs `cephadm bootstrap`,
   distributes the cluster's SSH key, adds ceph2/ceph3 as `mon,mgr,osd` hosts
   and `cephadmin` as `_admin`, places mon/mgr by label, and deploys OSDs on
   every available device.

The third play is a one-shot cluster **creation** role, not a day-2 reconciler:
everything after the bootstrap check is gated on `/etc/ceph/ceph.conf` not
already existing. Re-running against a live cluster re-checks the prereqs and
leaves the cluster alone. The bootstrap output - including the dashboard URL -
is printed on the first run only.

```bash
ssh root@192.168.122.27 ceph -s
ssh root@192.168.122.27 ceph orch host ls
ssh root@192.168.122.27 ceph osd tree
```

Expect `HEALTH_OK` with 3 mons, 3 mgrs (1 active, 2 standby) and 9 OSDs before
moving on - the export step will happily produce a JSON blob against a degraded
cluster, and you will find out later.

### Attach it to OpenShift

```bash
ansible-playbook -i inventory/hosts setup_ceph_odf.yaml --ask-vault-pass
```

Targets the same hub as every other playbook here (`target_hub`, defaulting to
`hub`); pass `-e target_hub=hub2` for the DR hub, or
`-e ceph_odf_target_kubeconfig=...` for something else entirely. Three ordered
plays, because ODF has to be installed *before* the export can run:

1. **`setup-ceph-odf-consumer`, stage `install`** (`--tags ceph-odf-install`) -
   creates `openshift-storage`, subscribes to the ODF operator on channel
   `stable-{{ ocp_major_version }}`, waits for the `StorageCluster` CRD, enables
   the `odf-console` plugin, and extracts the exporter script **from the
   installed operator** - the ConfigMap `rook-ceph-external-cluster-script-config`
   (`.data.script`) on ODF 4.19+, falling back to the
   `external.features.ocs.openshift.io/export-script` CSV annotation on 4.18 and
   below.
2. **`setup-ceph-odf-export`** (`--tags ceph-odf-export`, delegated to
   `cephadmin`) - creates the RBD pool `ceph_odf_rbd_pool` and, if
   `ceph_odf_enable_cephfs`, the CephFS `ceph_odf_cephfs_name` plus an MDS to
   serve it. The exporter creates *users*, not pools, so these have to exist
   first. It then runs the version-matched script with `--v2-port-enable` and
   fetches the resulting JSON - fsid, mon endpoints, scoped CSI credentials - to
   `ceph_odf_export_dir` on the controller.
3. **`setup-ceph-odf-consumer`, stage `create`** (`--tags ceph-odf-create`) -
   loads that JSON into the `rook-ceph-external-cluster-details` secret and
   applies the external `StorageCluster` named `ceph_odf_storagecluster_name`.

The exported JSON holds live cluster credentials. `ceph-odf/` is in
`.gitignore`; keep it that way.

### Verifying

```bash
oc get storagecluster -n openshift-storage
oc get pods -n openshift-storage
oc get sc
```

A healthy external `StorageCluster` reaches `Ready`, and `oc get sc` shows
`ocs-external-storagecluster-ceph-rbd` (marked `(default)` when
`ceph_odf_rbd_default_sc` is true) alongside
`ocs-external-storagecluster-cephfs`. Then prove it end to end - binding is not
mounting, and the 4.22 issue above only shows up on the mount:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-rbd-smoke
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: ocs-external-storagecluster-ceph-rbd
---
apiVersion: v1
kind: Pod
metadata:
  name: ceph-rbd-smoke
spec:
  containers:
    - name: smoke
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sleep", "3600"]
      volumeMounts:
        - name: vol
          mountPath: /data
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: ceph-rbd-smoke
EOF

oc get pvc ceph-rbd-smoke
oc wait --for=condition=Ready pod/ceph-rbd-smoke --timeout=180s
oc exec ceph-rbd-smoke -- sh -c 'echo ok > /data/f && cat /data/f'
```

A PVC that goes `Bound` while the pod stays `ContainerCreating` with
`rbd: map failed ... failed to add secret to kernel` is the 4.22 issue above,
not a Ceph or credentials problem.

### Notes and constraints

- **The exporter script must match the installed operator.** Do not substitute
  a copy from a GitHub branch. An older upstream script emits the CSI secrets
  as `adminID`/`adminKey`, while a current ODF operator reads `userID`/`userKey`
  - the operator finds no usable credential, falls back to DNS SRV mon
  discovery, and the `StorageCluster` sits in `Progressing` with
  `unable to get monitor info from DNS SRV` / `RADOS object not found`. Nothing
  says "wrong key names". This is why `setup_ceph_odf.yaml` installs ODF first
  and pulls the script out of the operator, and why `ceph_odf_exporter_local_path`
  points at a file the playbook writes rather than one you supply.
- **Do not add `reconcileStrategy: ignore` to the StorageCluster's
  `managedResources.cephBlockPools`.** It reads like the right thing in external
  mode - the operator is not managing the pools - but what it actually suppresses
  is the *StorageClass* creation the operator is responsible for, so no
  StorageClass ever appears and nothing can provision. The template deliberately
  sets only `defaultStorageClass` (from `ceph_odf_rbd_default_sc`), which is what
  the ODF console generates.
- **The mons have to be answering msgr2.** The exporter runs with
  `--v2-port-enable`, so the endpoints it hands ODF are the v2 port 3300; if the
  mons are only bound to the v1 port 6789 those endpoints are dead and CSI
  cannot reach the cluster. A Ceph 9 cluster bootstrapped by cephadm has msgr2
  on already - confirm with `ceph mon dump` (each mon should show a `v2:` entry)
  and, in the unlikely case it does not, `ceph mon enable-msgr2` turns it on.
- The Ceph cluster is entirely independent of the HCP flow - no other playbook
  in this repo imports `setup_ceph.yaml`, and skipping it changes nothing else.
- `setup_ceph_odf.yaml` can be pointed at hub2 as well, but the export step
  re-runs the exporter against the same Ceph cluster, so both hubs end up
  consuming the same pool. That is fine for a lab; it is not isolation.

## UDN over BGP, VRF-Lite and EVPN (containerlab fabric)

Built by `setup_udn_bgp_lab.yaml` (roles `setup-clab-fabric` and
`setup-udn-bgp`). Entirely additive: nothing in the hub, hosted-cluster, OADP
or Ceph flows reads any of it, and none of those flows change whether or not
you ever run it.

**[bgp-evpn.md](bgp-evpn.md)** takes `setup-udn-bgp` apart into the `oc`
commands it runs, phase by phase, with every manifest shown filled in rather
than as a template. Read that to understand the mechanism, to debug a phase
that failed, or to reproduce this on a cluster the repo does not manage - each
section names the `--tags` that automate it.

### Can this be simulated on this lab? Yes - here is the honest shape of it

Yes, on the bare-metal host, using containerlab as the provider network. The
OpenShift nodes are already KVM guests on a libvirt bridge, and containerlab
attaches container interfaces to an existing Linux bridge as a first-class
feature (its `bridge` kind). Put both on the same bridge and an FRR container
is layer-2 adjacent to an OpenShift node. From there it is ordinary BGP -
there is nothing to fake.

What is and is not testable on this lab, stated up front:

| Phase | Testable here | Needs |
| --- | --- | --- |
| BGP, default pod network | Yes | 4.19+ |
| BGP + primary UDN, shared VRF | Yes | 4.19+ |
| BGP + UDN with **VRF-Lite** | Yes | 4.19+, **local gateway mode** |
| **EVPN**, cluster nodes as VTEPs | Yes | **4.22**, local gateway mode |
| **EVPN** fabric with VRF-Lite handoff at the border leaf | Yes | works on 4.21 too |

EVPN for primary cluster user-defined networks is GA in OpenShift 4.22, and
`vars.yaml` sets `ocp_major_version: "4.22"` so the full path - nodes as
VTEPs, VXLAN between them, type-5 routes carrying a per-tenant VNI - is
available. The border-leaf handoff variant is still described
[below](#evpn-two-ways) because it is a legitimate production design and the
only option on 4.21.

### The one idea to drop first: you do not move a UDN's default gateway

The natural mental model - "point each UDN's default gateway at the
containerlab router" - is worth discarding early, because there is no setting
that does it and designing around it leads somewhere unpleasant.

A pod on a primary UDN always has the OVN gateway router **on its own node**
as its default gateway. That is structural: OVN-Kubernetes owns the pod's
first hop, and it is how the UDN's isolation, its per-node subnet allocation
and its east/west path all work. Nothing external can take that over.

What BGP actually changes is one layer further out - the **node's** routing
table and the **absence of SNAT**:

- The cluster advertises pod and UDN subnets to the fabric
  (`RouteAdvertisements`), so the fabric has a route back to real pod
  addresses.
- The fabric advertises its prefixes to the cluster, and FRR-K8s installs
  them in the node's kernel routing table, so the node knows to send that
  traffic out the fabric NIC.
- Because the fabric can now route back to the pod, pod egress to those
  prefixes **stops being SNATed to the node IP**. Packets arrive at the
  router with the real pod IP as the source. That is the single most
  legible proof the whole thing is working.

The pod's gateway never moves. Which is exactly why this is safe to run
against a cluster that is already doing other work: no node's default route
changes, and the only prefixes that go out the fabric are ones a BGP peer
explicitly advertised.

### Topology

```
  virbr0  192.168.122.0/24  NAT       <-- the existing lab, untouched
    helper .21   hub masters .31-.33   hub workers .34-.36
    hosted-cluster workers, MetalLB VIPs, mirror registry, MinIO, Ceph ...
    clab VM .40  (management/ssh only)

  virbr1  no address on the host, MTU 9000, no NAT, no DHCP, no DNS
    |                                    <-- NEW. Pure L2, the "provider network"
    +-- hub_worker1 second NIC   192.168.140.34   (+ VLAN 110 .141.34, VLAN 120 .142.34)
    +-- hub_worker2 second NIC   192.168.140.35   (+ VLANs)
    +-- hub_worker3 second NIC   192.168.140.36   (+ VLANs)
    +-- clab VM second NIC -> in-guest bridge br-fabric
          |
          +-- containerlab: leaf1 (FRR)  192.168.140.1
                            + VRF blue on VLAN 110  192.168.141.1
                            + VRF red  on VLAN 120  192.168.142.1
                            blue-ext 10.210.10.10   red-ext 10.211.10.10
```

Every fabric address ends in the octet the node already owns on virbr0 -
worker1 is `.34` on `192.168.140`, `192.168.141` and `192.168.142` alike - so
there is one number per node to remember and no new collision surface.

The VLANs are how VRF-Lite is done: one L3 link per VRF between the node and
the provider edge. A plain Linux bridge (`vlan_filtering=0`, which is the
default) forwards 802.1Q frames untouched, so virbr1 carries the tagged
traffic without OVS or any special configuration.

### Containerlab in a VM, or on the bare-metal host?

Both work and `setup_udn_bgp_lab.yaml` builds either. `clab_deploy_mode`
defaults to `vm`.

**`vm` (default).** A dedicated RHEL9 guest with two NICs; its fabric NIC is
enslaved to an in-guest bridge that containerlab attaches FRR nodes to. The
reason to prefer this is narrow and real: **containerlab needs Docker, and
Docker rewrites the host's iptables** - it sets the `FORWARD` policy to
`DROP`, adds its own chains, and loads `br_netfilter`, which makes bridged
frames traverse `FORWARD` too. On a hypervisor that is also running your
entire HCP lab behind libvirt NAT, that is a real risk to take on for a side
project. In a VM it is somebody else's problem.

**`host`.** Containerlab runs on the bare-metal host and attaches directly to
virbr1. One less hop, and `tcpdump`/`ip netns`/`containerlab inspect` all
live where you already run Ansible - noticeably easier to debug. Containerlab
inserts `FORWARD ACCEPT` rules for any bridge its topology references, which
handles the specific Docker problem above, and the role inserts an explicit
intra-bridge ACCEPT of its own and then prints whatever rules end up
referencing the bridge, so you can see the situation rather than assume it.

(`<forward mode='open'/>` would have libvirt add no rules at all, but libvirt
refuses to define an open network without an IP address, and giving the
fabric an address starts a dnsmasq on a bridge three OpenShift nodes are
plugged into - the worse trade. Hence an isolated network with no address.)

Pick `host` if you want the easiest debugging and are comfortable with Docker
on the hypervisor. Stay on `vm` otherwise.

### What it costs the existing lab

- Each node VM in `clab_fabric_nodes` gains **one extra NIC**. Hot-plugged on
  a running VM, no reboot, no rebuild.
- A new libvirt network (`virbr1`): isolated, with no `<ip>` at all - so no
  NAT, no DHCP, no DNS, no address on the host, and no dnsmasq started for
  it. It cannot route anywhere and cannot perturb virbr0.
- One extra VM (`clab`, `.40`) in `vm` mode: 4 vCPU / 8G. It is registered
  with subscription-manager from the same `org_id` / `activation_key` in
  `vault.yaml` the helper uses - it is a bare RHEL9 image and cannot install
  Docker or containerlab until it is entitled. In `host` mode this does not
  apply, since containerlab runs on the already-registered hypervisor.
- On the cluster: the **Kubernetes NMState Operator** is installed if absent
  (namespace `openshift-nmstate`, plus its `NMState` instance) - every phase
  from `default` on applies `NodeNetworkConfigurationPolicy` objects, which
  come from it. On a disconnected hub, point `udn_bgp_catalog_source` at the
  mirrored catalog; it follows `acm_catalog_source` when vars.yaml sets one.
- On the cluster: `Network.operator.openshift.io/cluster` is patched to
  enable FRR and route advertisements, which **restarts every ovnkube-node
  pod**. That is a few minutes of rolling pod-egress disruption on this lab's
  three workers. The API, the hosted clusters' control planes and MetalLB are
  unaffected. Enabling local gateway mode is a second such rollout.

What does *not* change: every address on virbr0, DNS, the DHCP reservations,
MetalLB's L2 pools, and every node's default route. The leaf's BGP policy
explicitly refuses to advertise or accept `192.168.122.0/24` in either
direction, so no BGP-learned route can shadow the lab's management network.

### Constraints worth knowing before you start

**The lab is now 4.22.** `ocp_major_version` is `"4.22"` (with
`ocp_minor_version: 8` / `coreos_minor_version: 8`) because BGP EVPN for
primary cluster user-defined networks is GA there and does not exist on 4.21.
That variable drives the hub install, the RHCOS images, the mirror registry
payload, the hosted clusters' release image and the operator channels, so it
is not a UDN-only change - a hub built before the bump is still 4.21 and must
be rebuilt or upgraded for the EVPN phase. Everything except `--tags evpn`
works on either version; to go back, set those three values to `"4.21"` / 15
/ 0.

**Do this on hub1, not on a hosted cluster.** Every phase patches
`Network.operator.openshift.io/cluster` and applies `NodeNetworkConfiguration`
policies. hub1 is a plain standalone cluster where that is straightforward.
A HyperShift hosted cluster's OVN-Kubernetes is configured through its
`HostedCluster`/`NodePool` and reconciled from the management cluster, so
patching the guest's Network CR directly is at best fragile. Prove the
mechanism on hub1 first; extending it to a hosted cluster afterwards is a
separate piece of work, not a variable change. `clab_fabric_nodes` therefore
defaults to hub1's three workers.

**VRF-Lite and EVPN require local gateway mode** (`routingViaHost: true`).
This is an OVN-Kubernetes restriction, not a lab one - VRF-Lite is not
implemented in shared gateway mode, and the CRs are accepted and quietly do
nothing. `udn_bgp_set_local_gateway` (default `true`) makes the switch; it is
a separate patch from the enablement one precisely because it is a second
full rollout and changes how all pod egress leaves the node.

**MetalLB is already on this cluster** for the hosted clusters' API VIPs, in
**L2 mode**, so it is not competing for BGP sessions. MetalLB also ships an
FRR-K8s; the Cluster Network Operator deploys its own into
`openshift-frr-k8s`, and that is the one this lab uses. If you later move a
MetalLB pool to BGP mode, point it at the CNO's instance rather than letting
the MetalLB operator stand up a second one. The pre-flight phase lists every
FRR-K8s daemonset it finds so you can see the situation before enabling
anything.

**`FRRConfiguration` goes in `openshift-frr-k8s`, not `metallb-system`.**
Upstream OVN-Kubernetes examples use `metallb-system` because upstream
installs FRR-K8s via MetalLB. On OpenShift the CNO owns it. An
`FRRConfiguration` in the wrong namespace is accepted and silently never
read, which is a tedious hour to lose.

**Overlapping UDN subnets only work with VRF-Lite, and nothing stops you
getting it wrong.** With `targetVRF` unset both tenants' routes land in the
default VRF, where the same prefix cannot mean two things - but the
`RouteAdvertisements` is still Accepted. OVN-Kubernetes does not validate
this; its route advertisements controller carries a literal
`// TODO check overlaps?` where that check would go. What you get is one
winner and one tenant quietly unreachable, not an error.

The tenant definitions carry two subnets for this reason:
`udn_subnet_shared` (unique across all tenants, used by the `shared` phase)
and `udn_subnet` (**deliberately identical between blue and red**, used by
`vrflite` and `evpn`). The role asserts the shared-phase subnets are distinct,
because the cluster will not. Proving two UDNs can carry the same addresses in
isolation is most of the point of VRF-Lite.

**The third tenant, `orange`, is the control.** It overlaps with nothing in
any phase, and it exists to make the isolation result unambiguous. "blue
cannot reach red's external network" has two possible explanations - the VRF,
or the fact that they share a subnet so the routing is ambiguous rather than
isolated. "blue cannot reach *orange's*" has only one. Read blue-vs-orange as
the isolation result and blue-vs-red as the overlap result. Orange's prefix is
also the only tenant prefix that means exactly one thing wherever it appears,
which makes it the one to look for when reading a routing table on the leaf or
on a node.

**MTU.** The fabric is 9000 end to end - bridge, taps, node NICs, VLAN
subinterfaces and FRR containers. At 1500 the BGP sessions come up fine and
then large flows black-hole, because the fabric is carrying Geneve or VXLAN
wrapped around pod traffic that is already encapsulated.

### Building it

Phases are cumulative and are meant to be run in order. Each one removes an
entire class of explanation for a failure in the next - that ordering is the
main thing this playbook is for.

```bash
# 0. The fabric. No cluster changes at all.
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags fabric

# Report what the cluster can do. Changes nothing.
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags preflight

# 1. Advertise the cluster DEFAULT pod network. No UDN involved -
#    if this does not work, UDN is not the reason.
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags default

# 2. Primary UDNs advertised into the default VRF (targetVRF unset).
#    Adds UDN. Still no VLANs, no VRFs, no NMState.
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags shared

# 3. VRF-Lite: per-tenant VRFs and VLANs (targetVRF: auto).
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags vrflite

# 4. EVPN. Rebuild the fabric as leaf/spine/leaf first, then the cluster side.
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags fabric -e clab_topology=evpn
ansible-playbook -i inventory/hosts setup_udn_bgp_lab.yaml --ask-vault-pass --tags evpn
```

`--tags fabric -e clab_topology=evpn` redeploys the containerlab topology in
place (`containerlab deploy --reconfigure`); it does not disturb the node
NICs, `virbr1`, or anything on the cluster.

Run containerlab on the bare-metal host instead: `-e clab_deploy_mode=host`.

Every manifest is rendered to `udn-bgp/` before it is applied, so you can
read and diff exactly what was sent, and re-apply by hand with `oc apply -f`.

The VRF-Lite phase does something worth understanding rather than trusting.
OVN-Kubernetes creates a Linux VRF per UDN on each node and enslaves its own
management port (`ovn-k8s-mpN`) to it. VRF-Lite needs a VLAN subinterface
added to *that same VRF*. But NMState treats a VRF's port list as
declarative - a policy declaring the VRF with only the VLAN in `port:` would
**remove `ovn-k8s-mpN` and take the tenant's pods off the network**. So the
role reads the live VRF layout off each node first (`vrflite-discover.yml`),
and templates the policy with the discovered port list and route-table id
restated in full. Never hand-write one of these from the example; render it.

The VRF's *name* is not guessed either: it comes from the CUDN's own
`status.vrfName`, which OVN-Kubernetes publishes precisely so that NMState
policies and `FRRConfiguration` authors read it rather than deriving it from
the CUDN name (a Linux interface name caps at 15 characters, so a longer CUDN
name necessarily has a VRF called something else).

The discovery still needs the VRF to *exist*, and OVN-Kubernetes only creates
it on a node that has something on that network - which is why the test
workload is a DaemonSet, and why the CUDNs and workloads are applied before
the discovery runs.

### Verifying each phase

The playbook prints control-plane state and then the data-plane commands to
run by hand (they need a pod name). The ones that matter:

```bash
# Accepted? A RouteAdvertisements is accepted long before it works.
oc get routeadvertisements -o wide
oc get routeadvertisements <name> -o jsonpath='{.status.conditions}' | jq

# The objects OVN-Kubernetes GENERATED from it carry the actual prefixes.
# If these are absent, nothing took effect regardless of the status above.
oc get frrconfiguration -n openshift-frr-k8s

# The leaf's view.
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp summary' -c 'show bgp ipv4 unicast'
docker exec clab-udnbgp-leaf1 vtysh -c 'show bgp vrf blue ipv4 unicast'

# Pod address comes from the UDN, not the cluster network.
oc -n udn-blue exec <pod> -- ip -br addr show eth0

# Egress is NOT SNATed - the leaf sees the real pod IP. This is the proof.
docker exec clab-udnbgp-leaf1 tcpdump -ni any icmp
oc -n udn-blue exec <pod> -- ping -c3 10.210.10.10

# Tenant isolation. This one MUST FAIL (VRF-Lite phase):
oc -n udn-blue exec <pod> -- ping -c3 -W2 10.211.10.10
# blue and red carry the SAME pod subnet and their external networks are one
# hop away on the same physical link. If this succeeds, the VRFs are leaking.

# Routes learned over BGP, not statically pointed anywhere:
oc debug node/worker1 -- chroot /host ip route show proto bgp
oc debug node/worker1 -- chroot /host ip route show vrf blue

# And the thing this lab is careful NOT to have changed:
oc debug node/worker1 -- chroot /host ip route show default
# expect: default via 192.168.122.1
```

### EVPN, two ways

`-e clab_topology=evpn` builds a three-node fabric - `leaf1` (border),
`spine` (EVPN route reflector), `leaf2` (far end) - with VXLAN between the
VTEPs and the tenant external endpoints moved behind `leaf2`, so traffic
genuinely crosses the overlay instead of being configured and never used.

**Nodes as VTEPs (4.22, what this lab does).** Each OCP node is a tunnel
endpoint. The `VTEP` CR discovers the node's address, the CUDN carries
`network.transport: EVPN` with an `ipVRF` VNI and route target, and the node
peers `l2vpn evpn` with `leaf1` over the fabric link it already uses - a
second address family on an existing session, not a new adjacency. VXLAN
then flows node to `leaf2` directly; `leaf1` only provides underlay
reachability and EVPN transit, and holds no tenant VRFs.

Note this phase does **not** use the VRF-Lite VLAN plumbing, and removes it
if phase 3 left it behind. Under EVPN the tenant routes travel as type-5
routes over VXLAN; keeping the VLAN handoff as well would give every tenant
two paths to the same destinations with nothing choosing between them.

**Border-leaf handoff (works on 4.21).** Use `clab_topology=evpn` with
`--tags vrflite` instead of `--tags evpn`. The cluster keeps peering
per-tenant VLANs with `leaf1` exactly as in phase 3, and `leaf1` maps each
VRF into an EVPN VNI itself. Plenty of real clusters hand off to an EVPN
fabric at a border leaf rather than running VTEPs on nodes, and it exercises
the same VNI and route-target mapping. What it does not exercise is
node-level VTEPs.

**VTEP addressing is deliberately `Unmanaged`.** The `VTEP` CR supports
`Managed` (OVN-Kubernetes allocates a VTEP IP per node) and `Unmanaged` (it
discovers an address something else put there). This lab uses `Unmanaged`
and assigns `100.64.0.<the node's usual octet>` via NMState, because the
fabric is three FRR containers with no IGP: something has to give `leaf1` a
route to each VTEP, and with `Managed` you do not know which node holds
which address until after allocation. Assigning them means `leaf1` carries
static `/32`s written at render time. On a real fabric with an IGP, `Managed`
is the right answer. Exactly one address per node may fall inside the CR's
CIDRs - two is a failed status, not a choice.

**Layer 2 / MAC-VRF is not wired up.** Both tenants here are `Layer3` with
an `ipVRF`, which is the direct continuation of the VRF-Lite phase. The API
also supports `Layer2` primary CUDNs with a `macVRF` VNI, which is what you
want for stretching an L2 segment off-cluster and preserving a VM's MAC and
IP across migration. That needs a MAC-VRF on the fabric side too - an L2VNI
bridge and SVI on `leaf2` - which this topology does not build. The tenant
definitions already carry an unused `evpn_mac_vni` for that extension. The
API shape is:

```yaml
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets: ["10.200.0.0/16"]
      # for a VM keeping its off-cluster gateway and address:
      # defaultGatewayIPs / infrastructureSubnets / reservedSubnets
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF: { vni: 100, routeTarget: "65000:100" }
      ipVRF:  { vni: 101, routeTarget: "65000:101" }   # optional on Layer2
```

`macVRF` is required for `Layer2` and forbidden for `Layer3`; `ipVRF` is
required for `Layer3`.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| BGP session never establishes | Fabric NIC not addressed (check `oc get nncp`), or MTU mismatch, or the node has no fabric NIC at all |
| `Configuration file[/etc/frr/frr.conf] processing failure: N` from vtysh | Cosmetic, and misleading. vtysh had no `vtysh.conf`, so it read `frr.conf` as its own config and failed the lines that are daemon config. It says nothing about whether the daemons are healthy - read `show bgp summary` for that. The role ships a `vtysh.conf` to stop it |
| leaf1 peers `Idle` with `Last write never`, and `show bfd peers brief` says `down` | BFD configured on one end only. It is a two-ended protocol - FRR-K8s needs a `bfdProfile` to match - and a permanently-down BFD session holds the BGP peer administratively down. The lab does not use BFD for this reason |
| leaf1 peers all `Idle`, `MsgSent 0`, while nodes sit in `Active` | bgpd is running but was never given its configuration - `frrinit.sh` applies the config as its last step, so a kill part-way through leaves a running bgpd with zero peers, refusing every SYN. `show bgp summary` showing `Peers 0` is the tell. Redeploy |
| `Failed to execute command "/usr/lib/frr/frrinit.sh restart" rc=137` | FRR is the container's PID 1. Stopping it stops the container, Docker restarts it, and the restart wipes every containerlab veth. Use `vtysh -b` to apply the config instead - never restart FRR from an `exec:` block |
| A clab node has only `lo` and `eth0`; its other interfaces vanished | The container was restarted. containerlab builds every link but the management one as a veth into the container's netns, and a restart destroys it - the node comes back running and healthy-looking with no fabric connection, and the `exec:` block that addressed those links does not re-run. Redeploy (`--tags clabdeploy`), never `docker start` |
| BGP `Active`, never `Established`, and the node has its fabric address | The same underlay failure as the row below - the session cannot open a TCP connection to a neighbour it cannot ARP. Run `--tags clabverify` to check leaf1's address and the fabric bridge's ports before looking at any FRR configuration |
| Pod ping returns `Destination Host Unreachable` from the node subnet's `.2` | That address is `ovn-k8s-mp0` - the host, not OVN. The packet reached the node's kernel and it could not ARP the next hop. Underlay problem: check the fabric NIC's address on the node, then `virbr1` on the lab host, then the bridge inside the clab VM. The BGP session will be down too, for the same reason |
| `tcpdump: executable file not found` inside a clab node | The FRR image does not ship tcpdump. Capture on `virbr1` on the lab host (or `br-fabric` in the clab VM) instead - all fabric traffic crosses it |
| Session up, `RouteAdvertisements` Accepted, no `route-advertisements-*` FRRConfiguration | `frrConfigurationSelector` matched zero or more than one FRRConfiguration |
| `RouteAdvertisements` not Accepted: "has no VRF matching the target VRF" | `targetVRF` was set to the string `default`. Unset means the default VRF; a value is matched literally against the routers' `vrf` field, and a default-VRF router has none. Only `auto` or unset are meaningful |
| `RouteAdvertisements` not Accepted, other reasons | Overlapping UDN subnets leaked into the default VRF, or two CRs selecting the same network |
| Session up, prefixes exchanged, pod ping still fails - and `tcpdump` shows the reply arriving on the fabric NIC but never on `ovn-k8s-mp0` | IP forwarding is off on the fabric NIC. OVN-Kubernetes enables it per interface (`br-ex`, `ovn-k8s-mpN`) and leaves `conf.all.forwarding` at 0, so a NIC it does not manage inherits 0. `ip route get <pod ip> from <leaf ip> iif <nic>` answering "No route to host" is the tell - that is EHOSTUNREACH, which the kernel returns only when forwarding is off, never for a missing route. The role sets `net.ipv4.ip_forward=1` on the workers with a Tuned profile - nmstate 2.2.60 rejects the per-device `ipv4.forwarding` field and rolls the whole policy back when it does |
| `authentication`/`console` Degraded with `lookup ... on 172.30.0.10:53: server misbehaving` after phase 1 | Advertising the cluster default pod network removed OVN's SNAT for **all** its egress, not just towards the fabric, so CoreDNS now queries the lab resolver from a pod IP nothing can route back to. Expected, not a fault. `oc delete ra default-podnetwork` restores it, `--tags shared` does it for you, or add return routes on the lab host - see `udn_bgp_advertise_default` |
| Everything green, pods still SNATed | The advertisement did not reach the node - check the generated FRRConfiguration, not the CR |
| VRF-Lite configured, no isolation | Cluster is in shared gateway mode. VRF-Lite needs `routingViaHost: true` |
| Tenant pods lose the network after an NNCP | A VRF policy was applied without the discovered `ovn-k8s-mpN` port restated. Re-render, do not hand-write |
| Small pings work, real traffic does not | MTU. Check the bridge, the taps, the node NIC, the VLAN subinterface and the FRR containers are all 9000 |
| Fabric dies as soon as Docker is installed | `br_netfilter` + Docker's `FORWARD DROP`. `iptables -I FORWARD 1 -i virbr1 -o virbr1 -j ACCEPT` |
| `FRRConfiguration` applied and ignored | Wrong namespace. It belongs in `openshift-frr-k8s` on OpenShift |
| VRF-Lite discovery fails with "missing a tenant VRF" | Either no tenant pod is running on that node yet (the VRF is created on demand), or OVN-Kubernetes names the VRF something other than the CUDN name in your release - the task above the failure lists what is actually there |

## Playbook Reference

Every playbook here is run with `-i inventory/hosts`. Most plays target
`localhost`, but they reach the lab VMs through `delegate_to` - the helper, the
mirror registry, minio, `ceph1`, `cephadmin` - and a delegated host that is not
in the inventory gets no `ansible_ssh_private_key_file` or
`StrictHostKeyChecking=no`, so the SSH fails or hangs on a host-key prompt.
`setup_ceph.yaml` goes further and has a play against the `ceph_nodes` group,
which does not exist at all without `-i`. Passing it everywhere keeps one habit
instead of a rule about which playbook needs it.

`inventory/hosts` is generated from `inventory/hosts.j2` and `vars.yaml`
(`lab_network_prefix` + `ip_list`) by `setup_bm_host.yaml`, which re-reads it in
the same run so its own delegated tasks use what it just wrote. The copy in git
is the render of the defaults; if you change `lab_network_prefix` or `ip_list`,
re-run that playbook (its first task is enough) before running anything that
delegates.

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
| `setup_hosted_cluster_vm.yaml` | Create a hosted cluster's worker VMs; `-e disconnected_install=true` builds the disconnected set |
| `create_hosted_cluster.yaml`  | Render the HostedCluster/NodePool bundle; `-e disconnected_install=true` renders the disconnected clusters |
| `setup_ceph.yaml`             | Build the standalone Ceph 9 cluster (ceph1-3 + cephadmin) |
| `setup_ceph_odf.yaml`         | Install ODF and attach that Ceph cluster to a hub in external mode |
| `cleanup-ceph.yaml`           | Destroy the Ceph VMs and their OSD disks - also the DR demo's deliberate storage-loss step |
| `setup_udn_bgp_lab.yaml`      | Build the containerlab BGP/EVPN provider fabric and wire a cluster into it. Phase-tagged: `--tags fabric\|preflight\|default\|shared\|vrflite\|evpn` |




## Key Roles


| Role            | Responsibility                                                        |
| --------------- | --------------------------------------------------------------------- |
| `setup-hub-acm` | Installs ACM, LVM-Storage, MetalLB, and OADP operator subscriptions, and creates one single-address MetalLB `IPAddressPool` + `L2Advertisement` per hosted cluster. LVM-Storage (operator + `LVMCluster`) is skipped when `use_lvm_storage: false` |
| `setup-oadp`    | Creates the cloud-credentials secret and DataProtectionApplication CR; with `oadp_backup_method=csi` also labels the VolumeSnapshotClass Velero selects CSI snapshot classes by |
| `setup-ceph-vm` | Creates the ceph1-3 + cephadmin VMs and attaches the raw OSD disks |
| `setup-ceph-prereqs` | Registers the Ceph nodes with subscription-manager (no Satellite), enables the RHCS 9 tools repo, installs cephadm, and installs `pull_secret` as each node's podman authfile |
| `setup-ceph-cluster` | Runs `cephadm bootstrap` on ceph1, expands the cluster onto ceph2/ceph3 + cephadmin, places mon/mgr/osd daemons, and enables msgr2 |
| `setup-ceph-odf-export` | Creates the RBD pool (+ optional CephFS) and runs the version-matched exporter on cephadmin to produce the connection JSON |
| `setup-ceph-odf-consumer` | Installs the ODF operator and extracts its exporter script (stage `install`), then creates the external-cluster secret and `StorageCluster` (stage `create`) |
| `setup-clab-fabric` | Creates the isolated fabric bridge (virbr1), adds a second NIC to each OCP node VM, optionally builds the containerlab VM, and deploys the FRR topology (single border leaf, or leaf/spine/leaf for EVPN) |
| `setup-udn-bgp` | The cluster half: enables FRR + route advertisements, addresses the fabric NICs via NMState, creates the tenant CUDNs and workloads, and applies the phase's `FRRConfiguration`/`RouteAdvertisements`. Discovers each node's live UDN VRF before writing any VRF-Lite policy |




## OADP Details

The OADP configuration uses:

- **Velero plugins**: `openshift`, `aws`, `csi`, `hypershift`
- **Uploader**: Kopia (node-agent), used both for filesystem backup and as the
  data mover behind CSI snapshots
- **Storage**: AWS S3 with a shared bucket/prefix across hubs
- **Volume method**: `oadp_backup_method` - `fs` (default) or `csi`

Templates live in `oadp/templates/` (backup/restore manifests) and `roles/setup-oadp/templates/` (DPA and credentials). There is one Backup/Restore pair per volume method, selected by `oadp_backup_method`:

| Method | Backup template | Restore template | Objects |
| ------ | --------------- | ---------------- | ------- |
| `fs`   | `backup-hcp-cluster.yaml.j2` | `restore-hcp-cluster.yaml.j2` | `<cluster>-backup` / `<cluster>-restore` |
| `csi`  | `backup-hcp-cluster-csi.yaml.j2` | `restore-hcp-cluster-csi.yaml.j2` | `<cluster>-backup-csi` / `<cluster>-restore-csi` |

There is no CSI copy of the hello-openshift smoke test. The hypershift plugin
the DPA loads runs against every item of every backup and errors on any
namespace that is not a hosted control plane, which aborts Velero's action
chain before the CSI snapshot action runs - fs backup survives that, CSI cannot.
Validate the `csi` method on a real hosted cluster instead; `oadp/README.md`
explains the mechanism.

For the full IAM policy, smoke-test manifests, and per-hub setup details, see `[oadp/README.md](oadp/README.md)`.

## Cleanup

Remove hub1 VMs and disks (does not affect hub2 or S3 backups):

```bash
ansible-playbook -i inventory/hosts cleanup-hub.yaml
```

Remove everything (all VMs including helper):

```bash
ansible-playbook -i inventory/hosts cleanup.yaml
```

Remove the Ceph cluster (VMs + OSD disks; leaves the hubs alone). ODF on the
hub is not touched - delete the `StorageCluster` there first if you are tearing
the whole thing down:

```bash
ansible-playbook -i inventory/hosts cleanup-ceph.yaml
```

