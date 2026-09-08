# HCP Backup & Restore - Steps

Connected lab, Ceph 9 / ODF external storage, CSI snapshot backup, DR cutover
to hub2. Commands only. Explanations: [README.md](README.md) and
[oadp/README.md](oadp/README.md).

## 0. Prepare

```bash
subscription-manager register
yum install ansible-core -y
ansible-galaxy collection install community.libvirt
ansible-galaxy collection install community.crypto

git clone https://github.com/sadiquepp/hcp-backup-restore.git
cd hcp-backup-restore
cp rhel-9.8-x86_64-kvm.qcow2 roles/setup-bm-host/files/
```

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
oadp_bucket_name: <your globally unique bucket>
oadp_aws_region: <your region>
```

S3 bucket + IAM user: [oadp/README.md](oadp/README.md#one-time-aws-setup-per-bucket-not-per-hub).

## 1. Bare metal host

```bash
ansible-playbook -i inventory/hosts setup_bm_host.yaml --ask-vault-pass
```

## 2. Ceph cluster

```bash
ansible-playbook -i inventory/hosts setup_ceph.yaml --ask-vault-pass
ssh root@192.168.122.27 ceph -s          # HEALTH_OK, 3 mons, 9 OSDs
```

## 3. Hub1

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster.yaml --ask-vault-pass
```

## 4. Attach Ceph to hub1

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
ansible-playbook setup_ceph_odf.yaml --ask-vault-pass
oc get storagecluster -n openshift-storage
oc get sc                                 # ocs-external-storagecluster-ceph-rbd (default)
```

## 5. ACM inventory

```bash
oc apply -f roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc get pvc -n multicluster-engine         # three Bound
ansible-playbook -i inventory/hosts setup_bminfra.yaml --ask-vault-pass
```

## 6. Hosted cluster

```bash
ansible-playbook -i inventory/hosts setup_hosted_cluster_vm.yaml --ask-vault-pass
# approve the discovered agents in the ACM/MCE web UI
ansible-playbook -i inventory/hosts create_hosted_cluster.yaml --ask-vault-pass
oc get hostedcluster,nodepool -n hcp-cluster1
```

## 7. Workload

```bash
export KUBECONFIG=<hosted cluster kubeconfig>
oc apply -f hello-openshift.yaml
```

## 8. OADP on hub1

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
ansible-playbook setup_oadp.yaml --ask-vault-pass -e oadp_backup_method=csi
oc get volumesnapshotclass -L velero.io/csi-volumesnapshot-class
```

## 9. Backup

```bash
ansible-playbook backup_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e oadp_backup_method=csi

oc get backup.velero.io hcp-cluster1-backup-csi -n openshift-adp -o yaml
oc get datauploads.velero.io -n openshift-adp
```

Do not continue until every `DataUpload` is `Completed`.

## 10. Shut down hub1

```bash
ansible-playbook shutdown_hub_cluster.yaml --ask-vault-pass
```

## 11. Destroy Ceph

```bash
ansible-playbook cleanup-ceph.yaml
virsh list --all | grep -E 'ceph[123]|cephadmin'
ls /var/lib/libvirt/images/ | grep -E '^ceph|^cephadmin'
```

Both must return nothing.

## 12. Rebuild Ceph

```bash
ansible-playbook -i inventory/hosts setup_ceph.yaml --ask-vault-pass
ssh root@192.168.122.27 ceph -s
```

## 13. Hub2

```bash
ansible-playbook -i inventory/hosts setup_hub_cluster2.yaml --ask-vault-pass
```

## 14. Attach Ceph to hub2

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub2_install/auth/kubeconfig
ansible-playbook setup_ceph_odf.yaml --ask-vault-pass -e target_hub=hub2
oc get sc                                 # ocs-external-storagecluster-ceph-rbd (default)
```

## 15. ACM on hub2

```bash
oc apply -f roles/setup-hub-acm/files/.rendered-05-agentserviceconfig.yaml
oc get pvc -n multicluster-engine         # three Bound
```

## 16. OADP on hub2

```bash
ansible-playbook setup_oadp.yaml --ask-vault-pass \
  -e target_hub=hub2 -e oadp_backup_method=csi
oc get backup.velero.io -n openshift-adp  # hcp-cluster1-backup-csi appears
```

## 17. Restore

```bash
ansible-playbook restore_hosted_cluster.yaml --ask-vault-pass \
  -e hcp_cluster_name=hcp-cluster1 -e target_hub=hub2 -e oadp_backup_method=csi

oc get restore.velero.io hcp-cluster1-restore-csi -n openshift-adp -o yaml
oc get datadownloads.velero.io -n openshift-adp
```

## 18. DNS cutover

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

## 19. Verify

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
