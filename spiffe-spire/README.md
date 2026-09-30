# SPIFFE/SPIRE workload identity on the hub and the SNO

Each of the lab's two clusters becomes its own SPIFFE trust domain -
`hub.mylab.com` and `sno.mylab.com` - using Red Hat's operator packaging of
SPIRE. A demo workload gets an X.509-SVID over the Workload API (through the
SPIFFE CSI driver) and uses it to authenticate to a peer over mTLS; a
workload with no registration entry gets no SVID and is refused. Then the
two trust domains are federated, and a hub workload authenticates to a SNO
workload across the boundary.

- **Build it:** [Quick start](#quick-start), or `./build-lab.sh --help`
- **Learn it:** [workshop.md](workshop.md) - day 0 automated, then every
  SPIRE object typed by hand
- **Variables:** [vars.yaml](vars.yaml) - every one prefixed `spire_`

> **Status.** The playbook, templates and demo app have been rendered,
> syntax-checked, linted, and run phase by phase against a simulated `oc`
> on ansible-core 2.14 and 2.19; the mTLS app was tested against real
> SPIFFE-shaped certificates. **None of it has yet run against a live
> cluster.** The operator's API was read from its source (release-1.0.0 and
> release-1.1), not from a running catalog.

---

## What it builds

```
 lab host ── helper .21: DNS for *.mylab.com, haproxy for the hub's *.apps

 hub: trust domain hub.mylab.com            SNO: trust domain sno.mylab.com
 ns zero-trust-workload-identity-manager    ns zero-trust-workload-identity-manager
   spire-server-0 (+ controller manager)      spire-server-0 (+ controller manager)
     PV on worker1                              PV on the node
   spire-agent, CSI driver: 3 workers         spire-agent, CSI driver: 1 node
   Route spire-federation.apps.hub  <─ bundle refresh ─>  Route spire-federation.apps.sno

 ns spiffe-demo                             ns spiffe-demo
   echo-server   mTLS :8443                   echo-server   <─ Route echo-spiffe-demo.apps.sno
   client  ─────────────── mTLS, across the trust domains ─────────────^
   intruder      (no registration)            client, intruder
```

| Object | Per cluster | Notes |
| --- | --- | --- |
| Operator | Zero Trust Workload Identity Manager from `redhat-operators`, namespace `zero-trust-workload-identity-manager` | package name (matched on `zero-trust-workload-identity-manager`) and channel looked up in the catalog at run time |
| `ZeroTrustWorkloadIdentityManager` | trust domain, cluster name | both immutable |
| `SpireServer` | StatefulSet of one, sqlite on a PV, CA 24h, X.509-SVID 1h | federation bundle endpoint, `https_spiffe` |
| `SpireAgent` | DaemonSet: 3 hub workers, the one SNO node | `k8s_psat` node attestation, `k8s` workload attestation |
| `SpiffeCSIDriver` | DaemonSet | mounts the Workload API socket into pods; `restricted` CSI profile |
| Route `spire-federation` | `spire-federation.apps.<cluster>.mylab.com`, passthrough | the bundle endpoint, see [below](#why-this-labs-own-federation-route) |
| StorageClass `spire-local` + PV | only when the cluster has no default StorageClass | the base build has none |
| `spiffe-demo` | ClusterSPIFFEID, `echo-server`, `client`, `intruder`, passthrough Route | [demo](#the-demo) |
| `ClusterFederatedTrustDomain` | one, naming the other cluster | carries the bootstrap bundle |

What it does **not** touch: no base role is run or changed, no VM is added,
no DNS record is added, nothing on the helper. Every name it needs is under a
cluster's `*.apps` wildcard, which the helper already serves. `--tags cleanup`
removes everything above.

---

## Quick start

The base lab - helper, hub, SNO - built as the repository's root README and
[`udn-bgp-evpn/workshop.md`](../udn-bgp-evpn/workshop.md) A1-A2 describe
(`vault.yaml`, `~/.vault_pass`, `vars-metal.yaml`). If it is not built yet,
`build-lab.sh` builds it first; if it is, it skips straight to SPIRE.

```bash
cd /root/hcp-backup-restore/spiffe-spire
./build-lab.sh --list          # the steps
./build-lab.sh                 # base lab if absent, then SPIRE on both, federated, verified
```

| Step | What | About |
| --- | --- | --- |
| `bmhost` | `../setup_bm_host.yaml` - skipped if the helper VM exists | 15 min |
| `clusters` | `../setup_hub_cluster.yaml --skip-tags acm` and `../setup_sno.yaml` in parallel - each skipped if its kubeconfig exists | 75 min |
| `preflight` | per cluster: operator in the catalog? which channel? StorageClass? Changes nothing | 1 min |
| `operator` | per cluster: Subscription, CSV, CRDs, API check | 5 min |
| `storage` | per cluster: local PV when there is no default StorageClass | 1 min |
| `spire` | per cluster: the four CRs and the federation Route, wait Ready, every agent attested | 5 min |
| `demo` | per cluster: `spiffe-demo`, wait for SVIDs | 3 min |
| `verify` | per cluster: asserts - entries, mTLS allowed, intruder refused | 1 min |
| `federation` | both: bundles, `ClusterFederatedTrustDomain`s, refresh over each Route, `federatesWith` | 3 min |
| `xverify` | both: hub client → SNO echo-server, and back | 1 min |

`--from <step>` resumes, `--only <step>` runs one, `--cluster hub` limits the
per-cluster steps to one cluster (federation then skips), `--dry-run` prints
the commands. `--only cleanup` removes SPIRE from both clusters.

By hand, the same thing is one playbook with one tag per phase:

```bash
cd spiffe-spire
PB="ansible-playbook setup_spiffe_spire.yaml --vault-password-file ~/.vault_pass -e @../vars-metal.yaml"
$PB --tags preflight -e spire_cluster=hub
$PB --tags operator,storage,spire,demo,verify -e spire_cluster=hub
$PB --tags operator,storage,spire,demo,verify -e spire_cluster=sno
$PB --tags federation
$PB --tags xverify
```

Every phase is `tags: [<phase>, never]`, so a bare run does nothing. Every
manifest is rendered to `/root/spiffe-spire-manifests/<cluster>/` and then
applied with `oc apply -f`, so what was applied can be read afterwards.

---

## Layout

```
spiffe-spire/
  ansible.cfg              mirrored from the root: ansible reads it from the working directory
  vars.yaml                every spire_* variable; loaded after ../vars.yaml, before ../vault.yaml
  build-lab.sh             the steps above
  setup_spiffe_spire.yaml  one play per cluster (phases by tag) + four federation/xverify plays
  workshop.md              the hands-on version
  roles/setup-spiffe-spire/
    tasks/                 one file per phase; catalog.yml and storage-decide.yml are shared
    templates/             every manifest, one .j2 each
    files/                 echo_server.py, spiffe_client.py - the demo app, stdlib Python
```

Load order in every play, as for every use case being split out of the root
`vars.yaml`:

```yaml
vars_files:
  - ../vars.yaml          # base (and, for now, everyone else's)
  - vars.yaml             # this use case - may refer to base variables freely
  - ../vault.yaml
```

plus `-e @../vars-metal.yaml` when it exists (build-lab.sh passes it).

---

## Design decisions

### Red Hat's operator, found in the catalog, not assumed

Red Hat ships SPIRE as the **Zero Trust Workload Identity Manager** (GA 1.0
from OpenShift 4.19). The `preflight` and `operator` phases list the packages
in `redhat-operators` and pick the one matching
`spire_operator_package_match`; if there is none, the run stops and says so.
There is no fallback to the upstream Helm charts: the operator handles the
SCCs, the CSI driver's `restricted` ephemeral-volume profile and the
controller manager's webhook, all of which the charts would need by hand on
OpenShift. The channel is the package's `defaultChannel` unless
`spire_operator_channel` names one, and an installed operator keeps its
channel on a re-run.

The operator phase then reads the CRDs and fails in words if the installed
operator predates the 1.x API (0.x put the trust domain on `SpireServer`
and had no federation), rather than letting `oc apply` fail on unknown fields.

### Storage: a local PV, because the base has no StorageClass

`SpireServer` requires a PVC - the sqlite datastore and the CA keys live on
it. The base clusters have no StorageClass (LVM Storage comes from
`setup-hub-acm`, which the base build skips with `--skip-tags acm`). With
`spire_storage_class: auto` the lab uses the default class when there is one
and otherwise creates its own `spire-local` StorageClass (no-provisioner,
`WaitForFirstConsumer`) and one local PV per cluster: on the first worker's
`/var/lib/spire-server-data`, reserved for the SPIRE server's PVC by
`claimRef`, reclaim policy `Retain`. The SPIRE server is thereby pinned to
that node. Nothing cluster-wide changes - no default class is set - and
`--tags cleanup` removes the PV, the class and the directory (the directory
holds the CA keys, so a rebuild is a genuinely new trust domain root).

### Why this lab's own federation Route

The operator can create the federation Route itself (`managedRoute: "true"`),
but names it `federation.<trust domain>` - `federation.hub.mylab.com`. That is
outside the `*.apps.hub.mylab.com` wildcard and the helper has no record for
it, so it would need a base DNS change (a generic `dns_extra_records` hook in
`setup-dns`). Instead `managedRoute: "false"` and the lab creates
`spire-federation.apps.<cluster>.mylab.com`, which resolves today. The
hostname is only routing: under the `https_spiffe` profile the peer
authenticates the endpoint by its SPIFFE ID, `spiffe://<td>/spire/server`,
against the bundle it already holds, never by name. Passthrough, because a
router terminating TLS would present its own certificate and fail that check.

This is the one place the lab could have needed a base change, and the
reason it does not.

### Federation: ClusterFederatedTrustDomain, with the bootstrap bundle in it

`https_spiffe` has a bootstrapping problem: to authenticate the peer's
endpoint the first time, a server needs the peer's CA - which it would
otherwise learn only from that endpoint. The `federation` plays copy each
server's bundle (`spire-server bundle show -format spiffe`) into the other
cluster's `ClusterFederatedTrustDomain.spec.trustDomainBundle`; from then on
each server refreshes the other's bundle over the Route, so CA rotation on
either side propagates by itself. spire-controller-manager uses that field
only when it creates the relationship, so the stale copy in the CR never
overwrites a newer bundle.

Relationships are declared only by these CRs, not by `federatesWith` on the
`SpireServer`: spire-controller-manager deletes any relationship no CR
declares, and two sources would fight.

The plays then force `spire-server federation refresh` in each direction.
That one command proves the Route, the helper's DNS, the router passthrough
and the `https_spiffe` authentication together, and names the failing stage
if one does.

### `className` on every ClusterSPIFFEID

The operator runs spire-controller-manager with `watchClassless: false` and
class `zero-trust-workload-identity-manager-spire`. A `ClusterSPIFFEID` (or
`ClusterFederatedTrustDomain`) without that `className` is accepted by the API
and then silently ignored - no entries, no SVIDs, and an empty `.status`. It
is `spire_class_name` in vars.yaml and is in every template.

### The demo

`spiffe-demo` holds three Deployments, identical except for the one label
the `ClusterSPIFFEID` selects (`spiffe.mylab.com/identity: "true"`):

| Pod | Registered | Gets an SVID | Calling echo-server |
| --- | --- | --- | --- |
| `echo-server` | yes | `spiffe://<td>/ns/spiffe-demo/sa/echo-server` | - (it is the server) |
| `client` | yes | `spiffe://<td>/ns/spiffe-demo/sa/client` | `HTTP 200: hello spiffe://.../sa/client, this is spiffe://.../sa/echo-server` |
| `intruder` | **no** | none - `no identity issued` | no SVID (exit 4); forced without a certificate, `REFUSED: TLSV13_ALERT_CERTIFICATE_REQUIRED` |

Each pod runs [spiffe-helper](https://github.com/spiffe/spiffe-helper) as a
sidecar - it fetches the SVID and bundle over the Workload API socket the CSI
driver mounts, writes them to an in-memory `emptyDir`, and rewrites them on
rotation - next to a UBI Python container. The app
([echo_server.py](roles/setup-spiffe-spire/files/echo_server.py),
[spiffe_client.py](roles/setup-spiffe-spire/files/spiffe_client.py)) is
standard-library Python: the server requires a client certificate chaining to
its bundle (authentication) and then checks the client's SPIFFE ID against an
allowlist ConfigMap (authorisation); the client checks the server's SPIFFE ID,
never a hostname. The client's exit status separates the outcomes: 0 allowed,
2 refused by the server, 3 server not trusted or not who it should be, 4 no
SVID, 5 unreachable.

**No OIDC discovery provider, on purpose.** A `SpireOIDCDiscoveryProvider`
CR makes the operator also create `zero-trust-workload-identity-manager-spire-default`,
a *fallback* ClusterSPIFFEID that gives every pod outside the operator's
namespace an identity - the intruder would get
`spiffe://<td>/ns/spiffe-demo/sa/intruder`. It is only needed for JWT-SVID
validation by outside parties, which this lab does not do. `verify` fails,
naming it, if a fallback ClusterSPIFFEID exists.

The allowlist lists the peer cluster's client from the start. Before
federation that entry is inert - the peer's certificate does not even chain -
and after it, it is the line that lets the peer in.

---

## Memory budget

No VM is added, so the configured total in the sizing table of
[`vars-metal.yaml.example`](../vars-metal.yaml.example) is unchanged: 170 GiB
at `worker_memory: 24576` on a 192 GiB host. What SPIRE adds lives inside the
existing hub workers and the SNO. Requests and limits are set explicitly
(`spire_*_resources` in vars.yaml; the operator's own Deployment requests
256 MiB in its CSV and sets no limit):

| Pods | Hub: count | Hub: request / limit | SNO: count | SNO: request / limit |
| --- | --- | --- | --- | --- |
| operator | 1 | 256 Mi / - | 1 | 256 Mi / - |
| spire-server (server + controller manager, 128/512 Mi each) | 1 | 256 Mi / 1 Gi | 1 | 256 Mi / 1 Gi |
| spire-agent (64/256 Mi) | 3 | 192 Mi / 768 Mi | 1 | 64 Mi / 256 Mi |
| CSI driver (2 containers, 32/128 Mi each) | 3 | 192 Mi / 768 Mi | 1 | 64 Mi / 256 Mi |
| demo (3 pods: helper 16/64 + app 32/128 Mi) | 3 | 144 Mi / 576 Mi | 3 | 144 Mi / 576 Mi |
| **total** | | **~1.0 GiB / ~3.3 GiB** | | **~0.8 GiB / ~2.3 GiB** |

Against the smallest supported sizing (3 × 24 GiB hub workers, a 32 GiB
SNO): about 1.4% of the hub workers' memory requested, ~4.6% at the limits;
about 2.5% of the SNO requested, ~7% at the limits. The limits are ceilings,
not expected use: SPIRE at this scale is tens of MiB per process. These are
configured values, not measurements - measure with
`oc adm top pods -n zero-trust-workload-identity-manager` once it runs. The
SNO is the tighter of the two, because it already carries a whole control
plane in 32 GiB; neither needs its VM resized.

---

## Verifying

`verify` (per cluster) and `xverify` (both) assert outcomes, not objects, so
they check the automated build and a workshop attendee's hand-built one the
same way:

```bash
./build-lab.sh --only verify            # or: --workshop --only check
./build-lab.sh --only xverify
```

By hand, on either cluster:

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
S="oc -n zero-trust-workload-identity-manager exec spire-server-0 -c spire-server -- spire-server"
$S agent list                                    # one per worker, k8s_psat
$S entry show                                    # echo-server and client; no intruder
$S federation show -trustDomain sno.mylab.com
$S federation refresh -id sno.mylab.com          # "Bundle refreshed"
oc -n spiffe-demo exec deploy/client -c app -- python3 /app/spiffe_client.py \
   https://echo-spiffe-demo.apps.sno.mylab.com/ spiffe://sno.mylab.com/ns/spiffe-demo/sa/echo-server
```

## When something is wrong

| Symptom | First look |
| --- | --- |
| preflight: no package matching | `oc -n openshift-marketplace get catalogsource,pods` - is `redhat-operators` healthy |
| `SpireServer` never Ready, PVC `Pending` | `oc -n zero-trust-workload-identity-manager get pvc,pv`; no default class and no `--tags storage`? |
| agents fewer than workers | `oc -n zero-trust-workload-identity-manager logs ds/spire-agent`; node attestation errors name the cause |
| ClusterSPIFFEID `.status` empty | missing or wrong `spec.className` |
| pod has no `/svid/svid.pem` | `oc -n spiffe-demo logs deploy/<pod> -c spiffe-helper` - `no identity issued` means no entry matches the pod |
| `federation refresh` fails | the message names DNS (`no such host`), the Route (connection refused / 503) or the endpoint's SVID (`x509`) |
| cross-cluster call `SERVER NOT TRUSTED` | the pod's bundle lacks the peer CA: `federatesWith` on the ClusterSPIFFEID, then wait for spiffe-helper to rewrite it |
| cross-cluster call `HTTP 403` | the peer's client is not in `echo-allowed-ids` |

Non-trivial debugging on a live cluster goes in a `troubleshooting.md` case
file here, in the format of [`udn-bgp-evpn/troubleshooting.md`](../udn-bgp-evpn/troubleshooting.md).
