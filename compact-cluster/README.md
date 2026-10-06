# Three-node compact cluster

A three-node compact OpenShift cluster (three schedulable masters, no
workers), installed from a single agent ISO, with every node's address on a
bond over two NICs.

| File | What it is |
| --- | --- |
| [compact-cluster.md](compact-cluster.md) | Lab, connected: three VMs on the hypervisor, active-backup (mode 1) bonds. Manual steps and the automated path. |
| [compact-cluster-disconnected.md](compact-cluster-disconnected.md) | Lab, disconnected (`compactd`): installed only from the lab's mirror registry, with the nodes' internet egress blocked. |
| [compact-cluster-baremetal.md](compact-cluster-baremetal.md) | Physical servers, connected, with LACP (802.3ad) bonds. Manual steps only. |
| [compact-cluster-baremetal-disconnected.md](compact-cluster-baremetal-disconnected.md) | Physical servers, from your own mirror registry, with LACP bonds. Self-contained manual steps. |
| [setup_compact_cluster.yaml](setup_compact_cluster.yaml) | Automates the connected lab cluster. |
| [setup_compact_cluster_disconnected.yaml](setup_compact_cluster_disconnected.yaml) | Automates the disconnected lab cluster: mirror registry, cluster, day 2. |

Both lab clusters get LVM Storage (`lvms-vg1`, the default StorageClass) on
an empty 500G disk per node.

## Running the playbooks

The playbooks share the repository's `vars.yaml`, `vault.yaml`,
`inventory/hosts` and `roles/`, and run from **inside this directory**:
Ansible reads `ansible.cfg` from the working directory, and the one here
adds `../roles` to `roles_path`.

```bash
# DNS for both clusters, from the repository root
ansible-playbook -i inventory/hosts setup_bm_host.yaml --tags dns --ask-vault-pass

cd compact-cluster

# connected
ansible-playbook -i ../inventory/hosts setup_compact_cluster.yaml --ask-vault-pass

# disconnected (builds the mirror registry first)
ansible-playbook -i ../inventory/hosts setup_compact_cluster_disconnected.yaml \
  -e disconnected_install=true --ask-vault-pass
```

To remove a cluster, run `cleanup.yaml --tags compact` or `--tags compactd`
from the repository root.

The roles stay in the shared `../roles/`: `setup-compact-cluster` (reused by
both playbooks, and sharing the disconnected hub's egress-block tasks) and
`setup-lvm-storage`.
