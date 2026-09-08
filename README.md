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
  else to do; the sections below install it as part of the hub.
- **Ceph 9 via ODF external mode** - set `use_lvm_storage: false`, then build
  the Ceph cluster and attach it with the two `setup_ceph*.yaml` playbooks,
  before the AgentServiceConfig step - that step's PVCs need a default
  StorageClass to exist already. See
  [Ceph 9 Storage for Hub PVs (ODF External Mode)](#ceph-9-storage-for-hub-pvs-odf-external-mode)
  for the whole flow, its OCP 4.22 requirement, and why the two should not both
  run on the same hub.

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
  volume and streams the files to S3. Works on any StorageClass,
  including LVM Storage.
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
ansible-playbook setup_oadp.yaml --ask-vault-pass
```

For the CSI method, pass it here too - the role then labels the
VolumeSnapshotClass (`velero.io/csi-volumesnapshot-class=true`) that
Velero selects snapshot classes by. Without that label Velero skips the
volume and still reports the backup `Completed`:

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass -e oadp_backup_method=csi
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
### Backup a hosted cluster using OADP.

```bash
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1
```

`hcp_cluster_name` must match the HostedCluster's name/namespace - it's
used to derive both the hosting namespace and the HyperShift
control-plane namespace (`<name>-<name>`). Works unchanged for
`hcp-cluster2` or any future hosted cluster.

For a CSI snapshot backup (Backup named `hcp-cluster1-backup-csi`):

```bash
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
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
ansible-playbook shutdown_hub_cluster.yaml --ask-vault-pass
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
ansible-playbook cleanup-ceph.yaml
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
ansible-playbook setup_ceph_odf.yaml --ask-vault-pass -e target_hub=hub2
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

Restore with the same method the backup used - it selects both the
Restore template and the name of the Backup to restore from, and the
playbook stops with a clear message if that Backup is not visible on
this hub yet:

```bash
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass \
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

| Hosted cluster | Pool                    | hub (primary)    | hub2 (DR)        | hubd (disconnected) |
| -------------- | ----------------------- | ---------------- | ---------------- | ------------------- |
| `hcp-cluster1` | `hcp-cluster1-api-pool` | `192.168.122.60` | `192.168.122.90` | `192.168.122.64`    |
| `hcp-cluster2` | `hcp-cluster2-api-pool` | `192.168.122.61` | `192.168.122.91` | `192.168.122.65`    |
| `hcp-cluster3` | `hcp-cluster3-api-pool` | `192.168.122.62` | `192.168.122.92` | `192.168.122.66`    |
| `hcp-cluster1-d` | `hcp-cluster1-d-api-pool` | `192.168.122.63` | `192.168.122.93` | `192.168.122.67` |

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
ansible-playbook setup_ceph_odf.yaml --ask-vault-pass
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
| `setup_hosted_cluster_vm.yaml` | Create a hosted cluster's worker VMs; `-e disconnected_install=true` builds the disconnected set |
| `create_hosted_cluster.yaml`  | Render the HostedCluster/NodePool bundle; `-e disconnected_install=true` renders the disconnected clusters |
| `setup_ceph.yaml`             | Build the standalone Ceph 9 cluster (ceph1-3 + cephadmin) |
| `setup_ceph_odf.yaml`         | Install ODF and attach that Ceph cluster to a hub in external mode |
| `cleanup-ceph.yaml`           | Destroy the Ceph VMs and their OSD disks - also the DR demo's deliberate storage-loss step |




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
ansible-playbook cleanup-hub.yaml
```

Remove everything (all VMs including helper):

```bash
ansible-playbook cleanup.yaml
```

Remove the Ceph cluster (VMs + OSD disks; leaves the hubs alone). ODF on the
hub is not touched - delete the `StorageCluster` there first if you are tearing
the whole thing down:

```bash
ansible-playbook cleanup-ceph.yaml
```

