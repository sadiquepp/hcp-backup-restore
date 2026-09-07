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
you run it against a real hosted cluster. The `*-csi-*` copies of those
do the same thing through CSI snapshots (see below).

Control-plane volumes can be captured two ways, selected by
`oadp_backup_method` - see [Backup methods: fs vs csi](#backup-methods-fs-vs-csi).

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
| Works on | any StorageClass, CSI or not - including LVM Storage (`lvms-vg1`) | only a CSI StorageClass with a VolumeSnapshotClass - here, Ceph via ODF external mode |
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
ansible-playbook setup_oadp.yaml --ask-vault-pass
```

For CSI snapshot backups, add the method so the role also labels the
VolumeSnapshotClass Velero needs (it fails with a clear message if ODF
has not created one yet):

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass -e oadp_backup_method=csi
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
oc get Backup -n hello-openshift-oadp-backup -o yaml
```

### The same smoke test through CSI snapshots

`hello-openshift-oadp-csi*.yaml` are the CSI copies of the three files
above: same app, its own namespace, and a PVC on
`ocs-external-storagecluster-ceph-rbd` instead of `lvms-vg1`. Run this
before an HCP backup with `oadp_backup_method=csi` - it exercises the
same code path in about a minute instead of an hour.

**First make sure the hub is prepared for CSI backups**, or Velero will
skip the volume and produce no `DataUpload` at all:

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass -e oadp_backup_method=csi
oc get volumesnapshotclass -L velero.io/csi-volumesnapshot-class
```

Exactly one class for your CSI driver must show `true` in that column.
Applying the manifests below without this step is the most common way to
get a backup that reports `Completed` (or `PartiallyFailed`) while
having snapshotted nothing.

```bash
oc apply -f oadp/hello-openshift-oadp-csi.yaml
POD=`oc get pod -n hello-openshift-oadp-csi -o jsonpath='{.items[0].metadata.name}'`
oc exec -it $POD -n hello-openshift-oadp-csi -- sh -c 'echo "Hello, CSI!" > /var/data/hello.txt'

oc apply -f oadp/hello-openshift-oadp-csi-backup.yaml
```

Unlike the fs backup, the transfer is visible as a `DataUpload`, and
the Backup sits in `WaitingForPluginOperations` until it finishes:

```bash
oc get datauploads -n openshift-adp -w
oc get backup hello-openshift-oadp-csi-backup -n openshift-adp -o jsonpath='{.status.phase}{"\n"}'
```

Re-running it needs the old backup gone first - Velero acts on a Backup
once, so re-applying the same manifest over an existing object does
nothing. Delete it **through Velero**, not with `oc delete`:

```bash
alias velero='oc -n openshift-adp exec deployment/velero -c velero -it -- ./velero'
velero backup delete hello-openshift-oadp-csi-backup --confirm
oc apply -f oadp/hello-openshift-oadp-csi-backup.yaml
```

`oc delete backup` removes only the Kubernetes object; the backup's data
stays in the bucket, and the next run of the same name fails with
`backup already exists in object storage`. `velero backup delete` files
a `DeleteBackupRequest` that removes both. See
[Recovering from `backup already exists in object storage`](#recovering-from-backup-already-exists-in-object-storage)
if you already hit this.

#### If no `DataUpload` is created at all

`oc get datauploads -n openshift-adp` returning nothing means Velero
never attempted the volume - the backup did not fail at snapshotting, it
declined to snapshot. Work down this list:

```bash
# 1. Is a snapshot class labelled for Velero? (the usual answer)
oc get volumesnapshotclass -L velero.io/csi-volumesnapshot-class

# 2. Did the PVC actually bind, and to a CSI driver?
oc get pvc -n hello-openshift-oadp-csi
oc get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,DRIVER:.spec.csi.driver \
  | grep -i ceph

# 3. What did Velero decide about the PVC?
velero backup logs hello-openshift-oadp-csi-backup -n openshift-adp \
  | grep -iE 'persistentvolumeclaim|volumesnapshot|snapshotclass|skip'

# 4. Were any VolumeSnapshots created?
oc get volumesnapshot -A

# 5. Is the csi plugin actually loaded, and the node-agent running?
oc get dpa dpa-instance -n openshift-adp -o jsonpath='{.spec.configuration.velero.defaultPlugins}{"\n"}'
oc get pods -n openshift-adp -l name=node-agent
```

Most often it is (1): no class carries
`velero.io/csi-volumesnapshot-class=true`, Velero finds no snapshot class
for the PVC's driver, and silently moves on. Fix it and re-run:

```bash
oc label volumesnapshotclass ocs-external-storagecluster-rbdplugin-snapclass \
  velero.io/csi-volumesnapshot-class=true --overwrite
velero backup delete hello-openshift-oadp-csi-backup --confirm
oc apply -f oadp/hello-openshift-oadp-csi-backup.yaml
```

If (2) shows the PVC `Pending`, or bound to `lvms-vg1` rather than the
Ceph class, there is nothing snapshottable in the namespace - check the
`storageClassName` in `hello-openshift-oadp-csi.yaml` matches a class
`oc get sc` actually lists on this hub.

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
oc get backup -n openshift-adp | grep hello-openshift-oadp-csi   # wait for it to reappear
velero backup delete hello-openshift-oadp-csi-backup --confirm
oc get deletebackuprequests -n openshift-adp                     # processed, then gone
```

Delete the failed Backup object too (it is a separate object from the
synced one) before re-applying the manifest.

If it will not come back, remove that one backup's directory from S3
by hand - `oadp_bucket_name` and `oadp_backup_prefix` in `vars.yaml` give
the path:

```bash
aws s3 ls s3://<oadp_bucket_name>/<oadp_backup_prefix>/backups/
aws s3 rm s3://<oadp_bucket_name>/<oadp_backup_prefix>/backups/hello-openshift-oadp-csi-backup/ --recursive
```

Delete only that one directory. Do not clear the prefix or reorganise
the bucket: `backuprepositories.velero.io` indexes what is under it, and
rearranging the folder structure means recreating the DPA, backups and
restores.

#### `no HostedControlPlane found` errors, and why they stop CSI working

Errors like

```
error executing custom action (groupResource=persistentvolumes, ...):
  rpc error: code = Unknown desc = error getting HCP namespace: no HostedControlPlane found
```

on a backup of an ordinary namespace come from the hypershift OADP
plugin, and they are not the harmless noise they look like.

The plugin's `AppliesTo()` is an **empty ResourceSelector**, which in
Velero means it runs on every item of every backup. Its only guard is
`pkg/common.ShouldEndPluginExecution`, which skips the plugin unless the
Backup looks like an HCP backup - and the test for that is the Backup's
`includedResources`:

```go
for _, resource := range backup.Spec.IncludedResources {
    if resource == "*" ||
        strings.Contains(resource, "hostedcluster") ||
        strings.Contains(resource, "hostedcontrolplane") ||
        strings.Contains(resource, "nodepool") {
        return false, nil   // not skipped: run on every item
    }
}
return true, nil            // skipped
```

So `includedResources: ["*"]` on a backup of a namespace that is not a
hosted control plane makes the plugin claim the backup and then fail on
every item.

**Why that breaks CSI snapshots.** Velero's `executeActions`
(`pkg/backup/item_backupper.go`) returns on the first action error:

```go
updatedItem, ..., err := action.Execute(obj, ib.backupRequest.Backup)
if err != nil {
    return nil, itemFiles, errors.Wrapf(err, "error executing custom action (...)")
}
```

The CSI snapshot is just another action in that same loop, keyed on
PVCs. When the hypershift action fails on the PVC first, Velero bails out
and the CSI action never runs - so there is **no VolumeSnapshot and no
DataUpload at all**, and no `csiSnapshot` entry in the skipped-PV summary
either, because that entry is only written inside the branch it never
reached. It looks exactly like a broken storage setup, and is not.

The fix is an explicit `includedResources` list naming none of those
keywords, which is what the manifests here now use. The HCP templates in
`templates/` deliberately do name `hostedcluster`, `hostedcontrolplane`
and `nodepool` - there the plugin is the whole point, the namespace
really is a hosted control plane, and it resolves cleanly.

#### If the backup reports thousands of items

A one-pod namespace backing up 4000+ items is backing up the whole
cluster - `includeClusterResources: true` does not mean "the
cluster-scoped objects this namespace needs", it means **every**
cluster-scoped object there is. On an ACM hub that is thousands of
`AppliedManifestWork`s. Leave the field unset (as these manifests do) and
Velero includes only what is associated with the namespace's own
objects - above all the PV behind the PVC.

A good run is a `Completed` phase with a `DataUpload` in phase
`Completed`:

```bash
oc get datauploads -n openshift-adp -l velero.io/backup-name=hello-openshift-oadp-csi-backup
```

To restore it (on the DR hub, or after deleting the namespace here):

```bash
oc apply -f oadp/hello-openshift-oadp-csi-restore.yaml
oc get datadownloads -n openshift-adp -w
POD=`oc get pod -n hello-openshift-oadp-csi -o jsonpath='{.items[0].metadata.name}'`
oc exec -it $POD -n hello-openshift-oadp-csi -- sh -c 'cat /var/data/hello.txt'
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

To take the same backup through CSI snapshots instead (Backup named
`hcp-cluster1-backup-csi`):

```bash
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e oadp_backup_method=csi
```

The playbook checks a labelled VolumeSnapshotClass exists before it
applies anything, then reports the `DataUpload` objects alongside the
final phase. Watch the volume transfer while it runs:

```bash
oc get datauploads -n openshift-adp -w
```

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

### Restore the hosted cluster to the DR Hub using OADP. This will restore the hosted cluster to the DR Hub using OADP.

```bash
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2
```

Pass the same `oadp_backup_method` the backup was taken with - it picks
both the Restore template and the name of the Backup to restore from,
and the playbook stops with a clear message if that Backup is not
visible on this hub yet:

```bash
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2 -e oadp_backup_method=csi
```

On a csi restore the volume data comes back through `DataDownload`
objects, which is where to look if the Restore seems to stall:

```bash
oc get datadownloads -n openshift-adp -w
```
