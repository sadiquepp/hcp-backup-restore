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

Re-running it needs the old Backup object gone first - Velero acts on a
Backup once, so re-applying the same manifest over an existing object
does nothing:

```bash
oc delete backup hello-openshift-oadp-csi-backup -n openshift-adp
oc apply -f oadp/hello-openshift-oadp-csi-backup.yaml
```

#### If the backup ends `PartiallyFailed` with thousands of errors

Check what the errors actually are before assuming the snapshot failed:

```bash
velero backup logs hello-openshift-oadp-csi-backup -n openshift-adp | grep -i error | head
oc get datauploads -n openshift-adp -l velero.io/backup-name=hello-openshift-oadp-csi-backup
```

Errors reading `error executing custom action (groupResource=appliedmanifestworks...)`
/ `no HostedControlPlane found` are not about your volume. They come from
`includeClusterResources: true` on the Backup, which does not mean "the
cluster-scoped objects this namespace needs" - it means **every**
cluster-scoped object in the cluster. On an ACM hub that is thousands of
`AppliedManifestWork` objects, and the hypershift plugin's custom action
errors on each one that is not a hosted control plane. The item count
gives it away: a one-pod namespace backing up 4000+ items is backing up
the whole cluster.

The manifests here leave the field unset, which is what you want - Velero
then includes only the cluster-scoped resources associated with the
namespace's own objects, above all the PV behind the PVC. If you hit this
on a Backup of your own, drop the field and re-run. A `Completed` phase
and a `DataUpload` in phase `Completed` are what a good run looks like.

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
