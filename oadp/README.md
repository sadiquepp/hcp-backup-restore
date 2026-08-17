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
you run it against a real hosted cluster.

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

## Per-hub: configure OADP (credentials + DPA)

The operator is already there (installed during hub bring-up). This
step just points it at your bucket:

```bash
# hub1 (default)
ansible-playbook setup_oadp.yaml --ask-vault-pass

# hub2, after cutover
ansible-playbook setup_oadp.yaml --ask-vault-pass -e target_hub=hub2
```

Idempotent - re-running against the same hub just reconciles the
secret/DPA. Both hubs point at the same bucket/prefix, so hub2's Velero
can see backups hub1 created.

## Deploy a hello-openshift application with a PVC to Hub Cluster and backup it using OADP.
This will be helpful to verify that the backup and restore process is working before running it against a hosted cluster.

```bash
oc apply -f oadp/hello-openshift-oadp.yaml
```

Write some persistent data to the PVC.

```bash
# Use single quotes around sh -c so bash does not expand ! in "Hello, World!"
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

## Backup a hosted cluster (run against the hub that currently owns it)

```bash
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1
```

`hcp_cluster_name` must match the HostedCluster's name/namespace - it's
used to derive both the hosting namespace and the HyperShift
control-plane namespace (`<name>-<name>`). Works unchanged for
`hcp-cluster2` or any future hosted cluster.

## Full hub1 -> hub2 DR cutover

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass                      # OADP on hub1
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1                                     # backup on hub1

ansible-playbook shutdown_hub_cluster.yaml                             # power off hub1
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass   # build hub2

ansible-playbook setup_oadp.yaml --ask-vault-pass -e target_hub=hub2   # OADP on hub2
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2                  # restore on hub2
```

## Manual / one-off apply

The rendered manifests are just Jinja2 templates under `oadp/templates/`
and `roles/setup-oadp/templates/` - if you'd rather not go through the
playbooks, render and `oc apply` them yourself with `ansible-playbook
... --check --diff` or a throwaway `template` task.
