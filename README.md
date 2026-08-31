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
  every hub; the *addresses* are not (`hub` 60-62, `hub2` 90-92, `hubd` 64-66),
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

The release image stays the canonical, digest-pinned `quay.io` pullspec -
`imageContentSources` is what redirects it to the mirror, and keeping the
canonical name is what lets the same HostedCluster be restored onto a connected
hub unchanged. Set `hosted_cluster_release_image_disconnected` to pin it at the
mirror registry by tag instead.

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

Worker and `*.apps` records are rendered only for `ip_list` keys that exist
(see `hosted_cluster_node_keys`), so a `-d` cluster gets a valid zone carrying
the `api`/`api-int` records its HostedCluster publishes before its worker VMs
are built, and picks up the rest when you add the octets.

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

Set `target_hub: hub2` in `vars.yaml` to make the cutover permanent. See
[MetalLB Address Pools for Hosted Clusters](#metallb-address-pools-for-hosted-clusters)
for how the per-hub addresses are defined.


## MetalLB Address Pools for Hosted Clusters

Each hosted cluster gets its **own single-address MetalLB pool**, so its
kube-apiserver VIP can only ever be the address DNS publishes for it on the hub
it is running on.

The **pool name is the same on every hub**; the **address it holds is not**.
The DR hub sits on its own network segment where hub1's addresses are not
routable, so each cluster carries one address per hub:

| Hosted cluster | Pool                    | hub (primary)    | hub2 (DR)        | hubd (disconnected) |
| -------------- | ----------------------- | ---------------- | ---------------- | ------------------- |
| `hcp-cluster1` | `hcp-cluster1-api-pool` | `192.168.122.60` | `192.168.122.90` | `192.168.122.64`    |
| `hcp-cluster2` | `hcp-cluster2-api-pool` | `192.168.122.61` | `192.168.122.91` | `192.168.122.65`    |
| `hcp-cluster3` | `hcp-cluster3-api-pool` | `192.168.122.62` | `192.168.122.92` | `192.168.122.66`    |

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
      hubd: 64
  hcp-cluster2:
    pool: hcp-cluster2-api-pool
    ip: {hub: 61, hub2: 91, hubd: 65}
  hcp-cluster3:
    pool: hcp-cluster3-api-pool
    ip: {hub: 62, hub2: 92, hubd: 66}
```

Two variables select the hub:

- **`metallb_hub`** - which hub `setup-hub-acm` is configuring. Set by
  `setup_hub_cluster.yaml` (`hub`), `setup_hub_cluster2.yaml` (`hub2`) and the
  disconnected hub's example block (`hubd`).
- **`target_hub`** - which hub is currently authoritative. Already used to pick
  the kubeconfig for the OADP playbooks; it now also selects the address
  `setup-dns` publishes as `api`/`api-int`. Defaults to `hub`.

Three things are generated from the map:

1. `roles/setup-hub-acm` renders one `IPAddressPool` per cluster holding
   `metallb_hub`'s address for it (a single address, e.g.
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

The DR hub's pools are created when you build it
(`setup_hub_cluster2.yaml` passes `metallb_hub: hub2`), so after restoring the
hosted clusters onto hub2 the only remaining step is to move DNS:

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
  range. `.63`, `.67` and `.93` are now free. `roles/setup-hub-acm` deletes the
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
| `setup-hub-acm` | Installs ACM, LVM-Storage, MetalLB, and OADP operator subscriptions, and creates one single-address MetalLB `IPAddressPool` + `L2Advertisement` per hosted cluster |
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

