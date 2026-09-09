# HCP Backup & Restore on Ceph — Summary

## Goal

Prove that an OpenShift hosted control plane can be recovered onto a
**different management hub** after the original hub is gone, with its etcd
state intact and its hosted workloads running.

## Approach

Capture the hosted control plane's etcd volumes as **CSI volume snapshots**,
move those snapshots into object storage, and rehydrate them onto the DR hub.

The storage cluster the backup was taken from is **destroyed and rebuilt**
between the backup and the restore. That is deliberate: it removes any doubt
about where the recovered data came from, and it mirrors production, where the
DR site has its own storage rather than the primary's.

## Topology

**Connected**, single bare-metal RHEL 9 host running KVM/libvirt.

| Component | Role |
| --- | --- |
| hub1 | Primary management cluster — ACM/MCE, OADP, MetalLB |
| hub2 | DR management cluster, own network segment |
| Ceph cluster | 3 all-in-one nodes (mon+mgr+osd) + 1 admin node |
| Hosted cluster | Agent/bare-metal platform, 3-member etcd, worker VMs on the same host |
| AWS S3 | One bucket, shared by both hubs |

## Building blocks

| Component | Version |
| --- | --- |
| OpenShift (hubs and hosted cluster) | 4.22.10 |
| Red Hat Ceph Storage | 9 |
| OpenShift Data Foundation | External mode, consuming the Ceph cluster |
| Advanced Cluster Management | 2.17.1 |
| Multicluster Engine | 2.17.2 |
| OADP (Velero) | 1.6.1 |

## Methodology

**Storage.** Hub PVs come from Ceph through ODF external mode rather than LVM
Storage. LVM Storage ships no VolumeSnapshotClass, so CSI snapshots — and
therefore a trustworthy control-plane restore — are not possible on it.

**Backup.** A Velero backup of the hosted cluster's namespaces taken with CSI
snapshots plus Velero's built-in data mover: the storage layer takes a
point-in-time snapshot of each etcd volume, the data mover copies it to S3, and
the snapshot is released. One transfer per etcd member.

**Storage loss.** The Ceph cluster is destroyed and rebuilt. Nothing of the
original pool, images or credentials survives.

**Restore.** On the DR hub, Velero recreates the objects and provisions fresh
volumes from the rebuilt Ceph cluster, streaming each etcd volume's contents
back from S3.

**Reconnection.** The restored cluster re-registers with the DR hub's ACM, and
DNS moves the hosted cluster's API name from the primary hub's load-balancer
address to the DR hub's, which is what brings the worker nodes back.

## Result

Successful, end to end.

| | Backup | Restore |
| --- | --- | --- |
| Phase | Completed | Completed |
| Items | 374 / 374 | 379 / 379 |
| CSI operations | 3 / 3 | 3 / 3 |
| Volume transfers | 3 DataUploads, ~371 MB each | 3 DataDownloads, byte-identical |
| Wall clock | ~5 min | ~6 min |

The hosted cluster came up on the DR hub with its etcd state intact, imported
into ACM, worker nodes Ready and workloads running — on a Ceph cluster built
after the backup was taken.

## Constraints worth knowing

- **OCP 4.22+ is required.** Below it the in-kernel RBD client cannot attach to
  an RHCS 9 cluster and the PV never mounts.
- **The exporter script must match the installed ODF operator**, or the
  external StorageCluster silently never becomes usable.
- **ACM's cluster-import secret must be kept out of the backup.** It carries a
  bootstrap token minted by the primary hub; restoring it leaves the recovered
  cluster stuck importing.
- **Data-plane persistence is out of scope.** This recovers the hosted
  *control plane*. Backing up the workloads' own PVs inside the hosted cluster
  is a separate exercise.

---

Detailed walkthrough: [README.md](README.md) and
[oadp/README.md](oadp/README.md). Commands only: [steps.md](steps.md).
