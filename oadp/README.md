# OADP: HCP control-plane backup/restore, including restore-to-new-hub

This directory used to hold static, hub1-only manifests. It's now driven
by `roles/setup-oadp/` plus three top-level playbooks, so the same flow
works for any hosted cluster (`hcp-cluster1`, `hcp-cluster2`, ...) and for
restoring onto a replacement hub (`hub2`) after a DR cutover
(`shutdown_hub_cluster.yaml` / `setup_hub_cluster2.yaml`).

The OADP operator itself is installed as part of hub bring-up, by
`roles/setup-hub-acm` (right alongside ACM/LVM-Storage/MetalLB) - see
`roles/setup-hub-acm/files/oadp/`. So it's already present on both hub1
and hub2 by the time you get here; `roles/setup-oadp/` only wires up the
cloud-credentials secret and the DataProtectionApplication, which need
AWS credentials/a bucket that don't exist at first hub bring-up.

`hello-openshift*.yaml` are left as-is - a small, self-contained
smoke-test app + Backup/Restore pair to sanity-check OADP itself before
you run it against a real hosted cluster. They use the `fs` method; there
is no CSI equivalent, for a reason worth reading before debugging a CSI
backup - see [Why there is no CSI smoke test](#why-there-is-no-csi-smoke-test).

Control-plane volumes can be captured two ways, selected by
`oadp_backup_method` - see [Backup methods: fs vs csi](#backup-methods-fs-vs-csi).

Commands only, end to end: [steps.md](../steps.md).

## Contents

- [One-time AWS setup (per bucket, not per hub)](#one-time-aws-setup-per-bucket-not-per-hub)
- [Backup methods: fs vs csi](#backup-methods-fs-vs-csi)
  - [What `csi` needs](#what-csi-needs)
- [Primary Hub](#primary-hub)
  - [Configure OADP (credentials + DPA)](#configure-oadp-credentials--dpa)
  - [Deploy a hello-openshift application with a PVC to Hub Cluster and backup it using OADP](#deploy-a-hello-openshift-application-with-a-pvc-to-hub-cluster-and-backup-it-using-oadp)
  - [Why there is no CSI smoke test](#why-there-is-no-csi-smoke-test)
  - [Backup a hosted cluster using OADP](#backup-a-hosted-cluster-using-oadp)
  - [Shutdown Primary Hub](#shutdown-primary-hub)
  - [Destroy the Ceph cluster (Ceph/CSI DR demo)](#destroy-the-ceph-cluster-cephcsi-dr-demo)
- [DR Hub](#dr-hub)
  - [Rebuild Ceph for the DR hub (Ceph/CSI DR demo)](#rebuild-ceph-for-the-dr-hub-cephcsi-dr-demo)
  - [Build DR Hub](#build-dr-hub)
  - [Configure OADP on DR Hub](#configure-oadp-on-dr-hub)
  - [Restore hello-openshift application with a PVC to DR Hub](#restore-hello-openshift-application-with-a-pvc-to-dr-hub)
  - [Restore the hosted cluster to the DR Hub using OADP. This will restore the hosted cluster to the DR Hub using OADP](#restore-the-hosted-cluster-to-the-dr-hub-using-oadp-this-will-restore-the-hosted-cluster-to-the-dr-hub-using-oadp)
  - [Point DNS at the DR hub](#point-dns-at-the-dr-hub)
  - [Verify the hosted cluster came back](#verify-the-hosted-cluster-came-back)

## One-time AWS setup (per bucket, not per hub)

```bash
export BUCKET=adp-backup-bucket-xjtvvs   # must be globally unique - pick your own
export REGION=ap-south-1

aws s3api create-bucket --bucket $BUCKET --region $REGION \
  --create-bucket-configuration LocationConstraint=$REGION

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

aws iam create-user --user-name adp-user
aws iam put-user-policy --user-name adp-user --policy-name adp-policy --policy-document file://adp-policy.json
aws iam create-access-key --user-name adp-user
```

Set `oadp_bucket_name` and `oadp_aws_region` in `vars.yaml` to match, and
add the access key from the last command to `vault.yaml`:

```bash
ansible-vault edit vault.yaml
```
```yaml
oadp_aws_access_key_id: 'AKIA...'
oadp_aws_secret_access_key: '...'
```

This bucket and IAM user are reused by both hub1 and hub2 - you only do
this section once per lab, not once per hub.

## Backup methods: fs vs csi

The hosted control plane's state lives in etcd, on a PVC in the
HyperShift control-plane namespace. How Velero captures that PVC is the
one real choice in this flow, and `oadp_backup_method` in `vars.yaml`
makes it:

| | `fs` (default) | `csi` |
| --- | --- | --- |
| Velero fields | `defaultVolumesToFsBackup: true` | `snapshotVolumes: true`, `snapshotMoveData: true`, `datamover: velero` |
| How the data moves | node-agent mounts the volume and streams the files to S3 with Kopia | CSI driver snapshots the volume; the data mover copies the snapshot to S3 |
| Consistency | file-by-file while etcd keeps writing | point-in-time, taken atomically by the storage layer |
| Runs on | any StorageClass, CSI or not - including LVM Storage (`lvms-vg1`) | only a CSI StorageClass with a VolumeSnapshotClass - here, Ceph via ODF external mode |
| Use for a control-plane restore | no - a file-level copy of a live etcd volume is not point-in-time | yes - this is the method the DR walkthrough uses |
| Templates | `templates/backup-hcp-cluster.yaml.j2`, `templates/restore-hcp-cluster.yaml.j2` | `templates/backup-hcp-cluster-csi.yaml.j2`, `templates/restore-hcp-cluster-csi.yaml.j2` |
| Object names | `<cluster>-backup` / `<cluster>-restore` | `<cluster>-backup-csi` / `<cluster>-restore-csi` |

Both write to the same bucket, prefix and `DataProtectionApplication`;
the two methods differ only in the Backup/Restore CRs. The names differ
so both can be demonstrated against one bucket without colliding, and
the `fs` names are unchanged from before this option existed.

Demonstrating `csi` is the reason the Ceph cluster exists in this lab:
LVM Storage ships no VolumeSnapshotClass, so it can only ever do `fs`.
See [Ceph 9 Storage for Hub PVs](../README.md#ceph-9-storage-for-hub-pvs-odf-external-mode)
for building the cluster and attaching it with `setup_ceph_odf.yaml`.

### What `csi` needs

- The hub's PVs come from a CSI driver with snapshot support. On this
  lab that means `use_lvm_storage: false` plus `setup_ceph.yaml` and
  `setup_ceph_odf.yaml`, which leave the hub with
  `ocs-external-storagecluster-ceph-rbd` as the default StorageClass.
- A `VolumeSnapshotClass` for that driver labelled
  `velero.io/csi-volumesnapshot-class=true`. Velero has no field for
  naming one - it looks the class up by that label, per driver, and if
  no class carries it **the volume is skipped and the Backup still
  reports `Completed`**. `setup_oadp.yaml` applies the label when run
  with `-e oadp_backup_method=csi`; `backup_hosted_cluster.yaml`
  refuses to run a csi backup if nothing carries it.
- The `csi` plugin and the node-agent in the DPA. Both are already
  there (`roles/setup-oadp/templates/dpa.yaml.j2`) - the data mover
  reuses the same node-agent the `fs` method uses, so no DPA change is
  needed to switch methods.

Everything else - the bucket, the credentials, the resource list, the
DR cutover - is identical.

## Primary Hub
### Configure OADP (credentials + DPA)
The operator is already there (installed during hub bring-up). This
step just points it at your bucket:

```bash
ansible-playbook -i inventory/hosts setup_oadp.yaml --ask-vault-pass
```

For CSI snapshot backups, add the method so the role also labels the
VolumeSnapshotClass Velero needs (it fails with a clear message if ODF
has not created one yet):

```bash
ansible-playbook -i inventory/hosts setup_oadp.yaml --ask-vault-pass -e oadp_backup_method=csi
```

Idempotent - re-running against the same hub just reconciles the
secret/DPA. Both hubs point at the same bucket/prefix, so hub2's Velero
can see backups hub1 created. Run it on the DR hub with the same
`oadp_backup_method` you backed up with, so the snapshot class is
labelled there too before the restore.

### Deploy a hello-openshift application with a PVC to Hub Cluster and backup it using OADP.
This will be helpful to verify that the backup and restore process is working before running it against a hosted cluster.

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

### Why there is no CSI smoke test

There is deliberately no CSI equivalent of the hello-openshift smoke test
above. On any hub this repo builds it cannot work, and the reason is
worth knowing before you debug a CSI backup of your own.

The DPA loads the `hypershift` plugin on every hub. That plugin's
`AppliesTo()` is an **empty ResourceSelector**, which in Velero means its
BackupItemAction runs against every item of every backup - PVs,
ServiceAccounts, Events, everything. Whenever the item's namespace is not
a hosted control plane it fails:

```
error executing custom action (groupResource=persistentvolumes, ...):
  rpc error: code = Unknown desc = error getting HCP namespace: no HostedControlPlane found
```

Upstream's `pkg/common.ShouldEndPluginExecution` is supposed to skip the
plugin for backups that do not look like HCP backups (it tests whether
`includedResources` contains `*`, `hostedcluster`, `hostedcontrolplane`
or `nodepool`), but the plugin build shipped with OADP 1.5 here errors
regardless - an explicit resource list naming none of those keywords
makes no difference.

**Why that kills CSI specifically.** In
`pkg/backup/item_backupper.go`, Velero collects pod volumes for
file-system backup *before* calling `executeActions`, but the CSI
snapshot is an action *inside* it - and `executeActions` returns on the
first action error:

```go
updatedItem, ..., err := action.Execute(obj, ib.backupRequest.Backup)
if err != nil {
    return nil, itemFiles, errors.Wrapf(err, "error executing custom action (...)")
}
```

So on a non-HCP namespace:

| | outcome |
| --- | --- |
| `fs` | works - the PodVolumeBackup was already set up before the failing action, so data is backed up and the Backup merely reports `PartiallyFailed` |
| `csi` | never runs - the hypershift action fails on the PVC first, so no VolumeSnapshot and no DataUpload are ever created |

That is why the fs smoke test above is useful despite its error count,
and why a CSI one would only ever look like broken storage.

**Validate the CSI method on the real thing instead.** In a hosted
control plane's namespace the plugin resolves the HCP, returns success,
and the CSI action runs normally:

```bash
ansible-playbook -i inventory/hosts backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e oadp_backup_method=csi
oc get datauploads.velero.io -n openshift-adp -w
```

A `DataUpload` reaching phase `Completed` is the proof that CSI snapshot
plus data mover works; the Backup's own phase is the weaker signal.

#### If no `DataUpload` is created at all

`oc get datauploads.velero.io -n openshift-adp` returning nothing means Velero
never attempted the volume. Check, in this order:

```bash
# 1. a snapshot class labelled for Velero, for this PVC's driver?
oc get volumesnapshotclass -L velero.io/csi-volumesnapshot-class

# 2. did the PVC bind to a CSI driver?
oc get pvc -n <namespace>
oc get pv <pv-name> -o jsonpath='{.spec.storageClassName}{"  driver="}{.spec.csi.driver}{"\n"}'

# 3. is CSI enabled in this Velero?
oc get deployment velero -n openshift-adp \
  -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'   # expect --features=EnableCSI

# 4. did an item action fail before the CSI one got to run?
velero backup logs <backup-name> -n openshift-adp | grep 'level=error' | head -3
```

(1)-(3) are the prerequisites. (4) is the case described above: a
`no HostedControlPlane found` error on the PVC means the CSI action was
never reached, and the storage configuration is not at fault.

#### `oc get backup` shows nothing, `oc get backup.velero.io` does

Always qualify the group. More than one installed operator defines a
`Backup` kind, so the short name is ambiguous and kubectl resolves it to
one of the others - `oc get backup` then lists an empty, unrelated
resource and gives no hint that it looked in the wrong place.

On this lab the competing CRD arrives with ODF itself: NooBaa pulls in
CloudNativePG, which defines `backups.postgresql.cnpg.noobaa.io`. So the
collision appears exactly when you take the Ceph path. Ask the cluster
what it has rather than assuming:

```bash
oc api-resources | grep -i backup           # every group defining Backup
oc get backup -n openshift-adp              # whichever one won, likely empty
oc get backup.velero.io -n openshift-adp    # what you meant
```

The same care applies to `restore.velero.io`, `datauploads.velero.io` and
`datadownloads.velero.io`. Everything in this repo qualifies them.

#### Recovering from `backup already exists in object storage`

A Backup that fails immediately with

```yaml
  failureReason: backup already exists in object storage
  phase: Failed
```

means the name is still taken in the bucket. It happens after
`oc delete backup`, which deletes the Kubernetes object and leaves the
data behind - Velero refuses to overwrite an existing backup directory.

Velero re-syncs backups from the bucket about once a minute, so the
object comes back on its own; then delete it properly:

```bash
alias velero='oc -n openshift-adp exec deployment/velero -c velero -it -- ./velero'
oc get backup.velero.io -n openshift-adp | grep <backup-name>   # wait for it to reappear
velero backup delete <backup-name> --confirm
oc get deletebackuprequests -n openshift-adp          # processed, then gone
```

If it will not come back, remove that one backup's directory from S3 by
hand - `oadp_bucket_name` and `oadp_backup_prefix` in `vars.yaml` give
the path:

```bash
aws s3 ls s3://<oadp_bucket_name>/<oadp_backup_prefix>/backups/
aws s3 rm s3://<oadp_bucket_name>/<oadp_backup_prefix>/backups/<backup-name>/ --recursive
```

Delete only that one directory. Do not clear the prefix or reorganise the
bucket: `backuprepositories.velero.io` indexes what is under it, and
rearranging the folder structure means recreating the DPA, backups and
restores.

#### If a backup reports thousands of items

A one-namespace backup collecting 4000+ items is backing up the whole
cluster: `includeClusterResources: true` does not mean "the
cluster-scoped objects this namespace needs", it means **every**
cluster-scoped object there is. On an ACM hub that is thousands of
`AppliedManifestWork`s, each one erroring through the hypershift plugin.
Leave the field unset and Velero includes only what is associated with
the namespace's own objects - above all the PV behind the PVC.


### Backup a hosted cluster using OADP.

```bash
ansible-playbook -i inventory/hosts backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1
```

`hcp_cluster_name` must match the HostedCluster's name/namespace - it's
used to derive both the hosting namespace and the HyperShift
control-plane namespace (`<name>-<name>`). Works unchanged for
`hcp-cluster2` or any future hosted cluster.

To take the same backup through CSI snapshots instead (Backup named
`hcp-cluster1-backup-csi`):

```bash
ansible-playbook -i inventory/hosts backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e oadp_backup_method=csi
```

The playbook checks a labelled VolumeSnapshotClass exists before it
applies anything, then reports the `DataUpload` objects alongside the
final phase. Watch the volume transfer while it runs:

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

#### What a good `csi` run looks like

A known-good run of `hcp-cluster1` on this lab, for comparison when
something looks off:

```yaml
status:
  backupItemOperationsAttempted: 3
  backupItemOperationsCompleted: 3
  completionTimestamp: "2026-09-08T03:47:54Z"
  formatVersion: 1.1.0
  phase: Completed
  progress:
    itemsBackedUp: 374
    totalItems: 374
  startTimestamp: "2026-09-08T03:42:30Z"
  version: 1
```

```
$ oc get datauploads.velero.io -n openshift-adp
NAME                            STATUS      STARTED   BYTES DONE   TOTAL BYTES   STORAGE LOCATION   AGE     NODE
hcp-cluster1-backup-csi-nnb2t   Completed   8m42s     371423568    371423568     default            9m12s   worker1
hcp-cluster1-backup-csi-x76zq   Completed   8m35s     370738865    370738865     default            9m7s    worker3
hcp-cluster1-backup-csi-xdctc   Completed   8m31s     370678113    370678113     default            9m2s    worker2
```

What to check, in order of how much it tells you:

- **One `DataUpload` per etcd member**, three for a standard hosted
  control plane, each on a different worker. Their sizes should be close
  to each other - the members hold the same data - and `BYTES DONE` must
  equal `TOTAL BYTES`.
- **`backupItemOperationsCompleted` equal to `...Attempted`**, and equal
  to the number of volumes. These are the asynchronous CSI operations;
  this is the field that says the data actually moved, where
  `itemsBackedUp` only counts objects written to the archive.
- **`phase: Completed`** last. It is the weakest of the three signals:
  a backup can reach `Completed` having snapshotted nothing (if Velero
  skipped the volumes), and can read `PartiallyFailed` while the volume
  data is perfectly fine (if an unrelated item action errored).

Roughly five minutes wall clock for ~1.1G of etcd across three members,
against the Ceph cluster on the same bare-metal host.

No `DataUpload` rows at all is the failure worth recognising - see
[If no `DataUpload` is created at all](#if-no-dataupload-is-created-at-all).

### Shutdown Primary Hub

```bash
ansible-playbook -i inventory/hosts shutdown_hub_cluster.yaml --ask-vault-pass
```

### Destroy the Ceph cluster (Ceph/CSI DR demo)

Only on the Ceph path, and only deliberately: **this destroys the storage
the backup was taken from.** Take the backup and confirm its `DataUpload`s
completed first; there is no going back to hub1's storage afterwards.

With `oadp_backup_method=csi` the etcd data is no longer on Ceph - the
snapshot was taken, copied to S3 by the data mover, and released. So the
bucket already holds everything the restore needs, and leaving the
original cluster running makes that impossible to show: an observer
cannot tell whether the hosted cluster came back from object storage or
from storage that never went away.

Production puts the DR site on its own storage cluster of the same type.
Rebuilding gets the same evidence on one bare-metal host without standing
up a second 80G Ceph cluster.

```bash
ansible-playbook -i inventory/hosts cleanup-ceph.yaml

# a partial teardown leaves stale OSD disks the rebuilt cluster cannot
# claim - you get a cluster with no OSDs. Check before rebuilding:
virsh list --all | grep -E 'ceph[123]|cephadmin'          # expect no rows
ls /var/lib/libvirt/images/ | grep -E '^ceph|^cephadmin'  # expect nothing
```

## DR Hub
### Rebuild Ceph for the DR hub (Ceph/CSI DR demo)

A brand-new cluster on the same four VMs - no pool, no image and no CSI
user survives from hub1's:

```bash
ansible-playbook -i inventory/hosts setup_ceph.yaml --ask-vault-pass
ssh root@192.168.122.27 ceph -s     # HEALTH_OK, 3 mons, 9 OSDs
```

The StorageClass name comes from `ceph_odf_storagecluster_name`, so the
rebuilt cluster presents `ocs-external-storagecluster-ceph-rbd` again.
That matters: Velero restores each PVC with its original
`spec.storageClassName`, and a DR hub with no class of that exact name
leaves the restored PVCs `Pending` indefinitely, with nothing in the
Restore status to explain why.

### Build DR Hub
Once the primary hub is shutdown, you can build the DR hub.
```bash
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass
```

On the Ceph path, build hub2 with `use_lvm_storage: false` and attach it to
the rebuilt Ceph cluster **now**, before the AgentServiceConfig below - this
creates hub2's own ODF external StorageCluster and its own CSI credentials:

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

### Restore the hosted cluster to the DR Hub using OADP. This will restore the hosted cluster to the DR Hub using OADP.

```bash
ansible-playbook -i inventory/hosts restore_hosted_cluster.yaml --ask-vault-pass -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2
```

Pass the same `oadp_backup_method` the backup was taken with - it picks
both the Restore template and the name of the Backup to restore from,
and the playbook stops with a clear message if that Backup is not
visible on this hub yet:

```bash
ansible-playbook -i inventory/hosts restore_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2 -e oadp_backup_method=csi
```

On a csi restore the volume data comes back through `DataDownload`
objects, which is where to look if the Restore seems to stall:

```bash
oc get datadownloads.velero.io -n openshift-adp -w
```

#### What a good `csi` restore looks like

The counterpart to
[What a good `csi` run looks like](#what-a-good-csi-run-looks-like) - a
verified restore of `hcp-cluster1` onto the DR hub, from the backup
recorded there:

```yaml
status:
  phase: Completed
  progress:
    itemsRestored: 379
    totalItems: 379
  restoreItemOperationsAttempted: 3
  restoreItemOperationsCompleted: 3
  startTimestamp: "2026-09-08T08:12:30Z"
  completionTimestamp: "2026-09-08T08:18:11Z"
  warnings: 1
```

```
$ oc get datadownloads.velero.io -n openshift-adp
NAME                             STATUS      STARTED   BYTES DONE   TOTAL BYTES   STORAGE LOCATION   AGE     NODE
hcp-cluster1-restore-csi-76kvd   Completed   5m18s     371423568    371423568     default            5m23s   worker2
hcp-cluster1-restore-csi-l82hx   Completed   5m18s     370678113    370678113     default            5m23s   worker1
hcp-cluster1-restore-csi-qxxlj   Completed   5m18s     370738865    370738865     default            5m23s   worker3
```

The strongest single check is that **the byte counts match the backup's
`DataUpload`s exactly** - 371423568, 370738865 and 370678113 in both
tables. Same three etcd volumes, round-tripped through S3. Which worker
each lands on differs from the backup and does not matter; the data mover
provisions a fresh PVC wherever the pod is scheduled.

Also worth noting what this proves: the Ceph cluster the backup was taken
from had been destroyed and rebuilt in between (see
[Destroy the Ceph cluster](../README.md#destroy-the-ceph-cluster-cephcsi-dr-demo)),
so none of these bytes could have come from the original storage.

A non-zero `warnings` count is normal - `itemsRestored == totalItems` and
three completed operations are what matter. Read them rather than guessing:

```bash
alias velero='oc -n openshift-adp exec deployment/velero -c velero -it -- ./velero'
velero restore describe hcp-cluster1-restore-csi --details
velero restore logs hcp-cluster1-restore-csi | grep -i 'level=warning'
```

Two appear on every run here, both benign:

- `No annotations found for <ns>/<secret>, using restore spec setting: false`
  - Velero deciding whether to restore the object's `status` subresource.
  An object with no annotations at all logs this at warn, one with any
  annotation logs the same decision at debug. Secrets have no `status`,
  and it is never counted in `status.warnings`.
- `item not found when patching managed fields .../token-nodepool-...`
  - Velero created the Secret, then found it gone when patching
  `managedFields` back. HyperShift's NodePool controller rotates those
  token secrets and had already collected the stale one. This is the
  warning the count refers to.

#### Restored cluster stuck in `Importing`

If the restored HostedCluster reaches `Completed` but its ManagedCluster
sits at `Available=Unknown` / `ManagedClusterLeaseUpdateStopped`, and the
klusterlet registration agent logs

```
failed to list *v1.ManagedCluster: Unauthorized
failed to list *v1.CertificateSigningRequest: Unauthorized
```

then the agent is presenting a ServiceAccount token minted by the
**original** hub. `Unauthorized` is a 401 - the credential itself was
rejected - so this is not a missing Role or ClusterRole, which would be a
403 `Forbidden`.

The path in: this repo's Backup includes `secrets` from the
`<cluster>` namespace, and for an ACM-imported hosted cluster that is
*also* the ManagedCluster's namespace, so `<cluster>-import` - carrying
the bootstrap SA token - is inside backup scope. Restoring it hands the
DR hub a token signed by the old hub's key, referencing an SA uid the DR
hub regenerated.

Confirm by decoding the token and comparing with the live ServiceAccount:

```bash
oc get secret bootstrap-hub-kubeconfig -n klusterlet-<cluster> -o jsonpath='{.data.kubeconfig}' \
  | base64 -d | grep 'token:' | awk '{print $2}' | cut -d. -f2 \
  | tr '_-' '/+' | base64 -d | python3 -m json.tool
oc get sa <cluster>-bootstrap-sa -n <cluster> -o jsonpath='{.metadata.uid}{"\n"}'
```

An `iat` predating the restore, or a uid that differs from the live SA,
is the confirmation. Fix by deleting the transplanted import secret so
MCE regenerates it against this hub:

```bash
oc delete secret <cluster>-import -n <cluster>
```

MCE mints a new token, rebuilds the `<cluster>-hosted-klusterlet`
ManifestWork from it, and the work agent re-applies
`bootstrap-hub-kubeconfig`; the agent then files a CSR which auto-approves
if `hubAcceptsClient` is already true.

Deleting `bootstrap-hub-kubeconfig` directly does **not** help - it is
owned by that ManifestWork and gets re-applied with the same stale
content. Refresh the import secret and let MCE rebuild the chain.

To stop this recurring, exclude the import secret from the backup using
Velero's object-level opt-out, so the artifact never carries another
hub's credentials (it is a 360-day token otherwise sitting in S3):

```bash
oc label secret <cluster>-import -n <cluster> velero.io/exclude-from-backup=true
```

This is not a deviation from the upstream guide's resource list - keep
`sa` and `secrets` as documented. The collision exists only because the
HostedCluster's namespace shares its name with the ManagedCluster;
upstream's example puts the HostedCluster in `clusters`, so ACM's
namespace falls outside the backup.


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

**Then check a worker node, not just the helper.** The VMs get
`192.168.122.1` from DHCP - libvirt's dnsmasq - which forwards the lab
zones to the helper and caches the answers. A correct zone on the helper
with a stale answer on the nodes is the normal state after a cutover, and
the symptom is both hosted-cluster workers going `NotReady` while
`oc get co` falls apart: the kubelets are still dialling the hub that
just went away.

```bash
ssh core@192.168.122.41 'getent hosts api.hcp-cluster1.mylab.com'   # want the DR address
```

If it still shows the old address, flush dnsmasq's cache on the
bare-metal host - this clears cached records without touching DHCP leases
or disturbing any VM:

```bash
sudo kill -HUP $(cat /var/run/libvirt/network/default.pid 2>/dev/null \
                 || cat /var/run/libvirt/dnsmasq/default.pid)
```

Kubelets re-resolve and rejoin within a minute or two;
`systemctl restart kubelet` on each worker forces it.

Set `target_hub: hub2` in `vars.yaml` to make the cutover permanent. See
[MetalLB Address Pools for Hosted Clusters](../README.md#metallb-address-pools-for-hosted-clusters)
for how the per-hub addresses are defined.

### Verify the hosted cluster came back

```bash
export KUBECONFIG=<hosted cluster kubeconfig>
oc get nodes                     # both workers Ready
oc get co | grep -v 'True.*False.*False'
oc get pods -A | grep -vE 'Running|Completed'
```

Nodes stay `NotReady` until DNS points at the DR hub and the kubelets
reconnect, so do the step above first. `metrics.k8s.io` errors and
Pending/Terminating pods are downstream of that and clear on their own.
