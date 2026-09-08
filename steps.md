# HCP Backup & Restore - Steps

Connected lab, Ceph 9 / ODF external storage, CSI snapshot backup, DR cutover
to hub2. Commands only. Explanations: [README.md](README.md) and
[oadp/README.md](oadp/README.md).

## 1. Prepare

```bash
subscription-manager register
yum install ansible-core -y
ansible-galaxy collection install community.libvirt
ansible-galaxy collection install community.crypto

git clone https://github.com/sadiquepp/hcp-backup-restore.git
cd hcp-backup-restore
cp rhel-9.8-x86_64-kvm.qcow2 roles/setup-bm-host/files/
```

## 2. S3 bucket and IAM user (once per lab, not per hub)

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

## 3. Credentials and lab variables

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
ceph_dashboard_password: '...'
```

In `vars.yaml`:

```yaml
use_lvm_storage: false
oadp_backup_method: csi
oadp_bucket_name: <$BUCKET from step 2>
oadp_aws_region: <$REGION from step 2>
```

## 4. Bare metal host

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --ask-vault-pass
```

## 5. Ceph cluster

```bash
ansible-playbook -i inventory/hosts setup_ceph.yaml --ask-vault-pass
ssh root@192.168.122.27 ceph -s          # HEALTH_OK, 3 mons, 9 OSDs
```

## 6. Hub1

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster.yaml --ask-vault-pass
```

## 7. Attach Ceph to hub1

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
ansible-playbook setup_ceph_odf.yaml --ask-vault-pass
oc get storagecluster -n openshift-storage
oc get sc                                 # ocs-external-storagecluster-ceph-rbd (default)
```

## 8. ACM inventory

```bash
oc apply -f roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc get pvc -n multicluster-engine         # three Bound
ansible-playbook -i inventory/hosts setup_bminfra.yaml --ask-vault-pass
```

## 9. Hosted cluster

```bash
ansible-playbook -i inventory/hosts setup_hosted_cluster_vm.yaml --ask-vault-pass
# approve the discovered agents in the ACM/MCE web UI
ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass
oc get hostedcluster,nodepool -n hcp-cluster1
```

## 10. Workload

```bash
export KUBECONFIG=<hosted cluster kubeconfig>
oc apply -f hello-openshift.yaml
```

## 11. OADP on hub1

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
ansible-playbook setup_oadp.yaml --ask-vault-pass -e oadp_backup_method=csi
oc get volumesnapshotclass -L velero.io/csi-volumesnapshot-class
```

## 12. Backup

```bash
oc label secret hcp-cluster1-import -n hcp-cluster1 \
  velero.io/exclude-from-backup=true --overwrite
oc get secret hcp-cluster1-import -n hcp-cluster1 --show-labels

ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e oadp_backup_method=csi

oc get backup.velero.io hcp-cluster1-backup-csi -n openshift-adp -o yaml
oc get datauploads.velero.io -n openshift-adp
```

Do not continue until every `DataUpload` is `Completed`.

## 13. Shut down hub1

```bash
ansible-playbook shutdown_hub_cluster.yaml --ask-vault-pass
```

## 14. Destroy Ceph

```bash
ansible-playbook cleanup-ceph.yaml
virsh list --all | grep -E 'ceph[123]|cephadmin'
ls /var/lib/libvirt/images/ | grep -E '^ceph|^cephadmin'
```

Both must return nothing.

## 15. Rebuild Ceph

```bash
ansible-playbook -i inventory/hosts setup_ceph.yaml --ask-vault-pass
ssh root@192.168.122.27 ceph -s
```

## 16. Hub2

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass
```

## 17. Attach Ceph to hub2

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub2_install/auth/kubeconfig
ansible-playbook setup_ceph_odf.yaml --ask-vault-pass -e target_hub=hub2
oc get sc                                 # ocs-external-storagecluster-ceph-rbd (default)
```

## 18. ACM on hub2

```bash
oc apply -f roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc get pvc -n multicluster-engine         # three Bound
```

## 19. OADP on hub2

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass \
  -e target_hub=hub2 -e oadp_backup_method=csi
oc get backup.velero.io -n openshift-adp  # hcp-cluster1-backup-csi appears
```

## 20. Restore

```bash
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2 -e oadp_backup_method=csi

oc get restore.velero.io hcp-cluster1-restore-csi -n openshift-adp -o yaml
oc get datadownloads.velero.io -n openshift-adp
```

## 21. DNS cutover

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns \
  --ask-vault-pass -e target_hub=hub2

dig +short api.hcp-cluster1.mylab.com @192.168.122.21
oc get svc kube-apiserver -n hcp-cluster1-hcp-cluster1 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'

ssh core@192.168.122.41 'getent hosts api.hcp-cluster1.mylab.com'
```

If the worker still returns the old address:

```bash
sudo kill -HUP $(cat /var/run/libvirt/network/default.pid 2>/dev/null \
                 || cat /var/run/libvirt/dnsmasq/default.pid)
```

Make it permanent: `target_hub: hub2` in `vars.yaml`.

## 22. Verify

```bash
oc get managedcluster                                   # hub2
oc get hostedcluster,nodepool -n hcp-cluster1

export KUBECONFIG=<hosted cluster kubeconfig>
oc get nodes                                            # Ready
oc get co | grep -v 'True.*False.*False'
oc get pods -A | grep -vE 'Running|Completed'
oc get route -n hello-openshift
```

## Cleanup

```bash
ansible-playbook cleanup-hub.yaml
ansible-playbook cleanup-ceph.yaml
ansible-playbook cleanup.yaml
```

---

Full explanations, the fs-vs-csi choice, troubleshooting and known-good
output: **[README.md](README.md)** and **[oadp/README.md](oadp/README.md)**.
Common failures: [no DataUpload](oadp/README.md#if-no-dataupload-is-created-at-all),
[stuck in Importing](oadp/README.md#restored-cluster-stuck-in-importing),
[backup already exists in object storage](oadp/README.md#recovering-from-backup-already-exists-in-object-storage).
