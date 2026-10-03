# SPIFFE/SPIRE workload identity on the hub and the SNO

Each of the lab's two clusters becomes its own SPIFFE trust domain -
`hub.mylab.com` and `sno.mylab.com` - using Red Hat's operator packaging of
SPIRE. A demo workload gets an X.509-SVID over the Workload API (through the
SPIFFE CSI driver) and uses it to authenticate to a peer over mTLS; a
workload with no registration entry gets no SVID and is refused. Then the
two trust domains are federated, and a hub workload authenticates to a SNO
workload across the boundary. Optionally, the same identities secure a hop
inside a real application - [Online Boutique](#online-boutique-spiffe-on-a-real-application) -
including a payment that crosses from one trust domain to the other. Or the
same application on [OpenShift Service Mesh](#online-boutique-on-service-mesh-spire-as-the-meshs-ca),
with SPIRE issuing every sidecar's certificate in place of istiod.

- **Build it:** [Quick start](#quick-start), or `./build-lab.sh --help`
- **Learn it:** [workshop.md](workshop.md) - day 0 automated, then every
  SPIRE object typed by hand
- **Variables:** [vars.yaml](vars.yaml) - every one prefixed `spire_`

> **Status.** The playbook, templates and demo app have been rendered,
> syntax-checked, linted, and run phase by phase against a simulated `oc`
> on ansible-core 2.14 and 2.19; the mTLS app was tested against real
> SPIFFE-shaped certificates; both Online Boutique overlays were built with
> kustomize against the real source, and the `Istio`/`IstioCNI` CRs checked
> against the Sail operator's CRD schema. **None of it has yet run against a live
> cluster.** The operator's API was read from its source (release-1.0.0 and
> release-1.1), not from a running catalog.

---

## Contents

- [What it builds](#what-it-builds)
- [Quick start](#quick-start)
- [Layout](#layout)
- [Design decisions](#design-decisions)
  - [Red Hat's operator, found in the catalog, not assumed](#red-hats-operator-found-in-the-catalog-not-assumed)
  - [Storage: LVM Storage from the base build](#storage-lvm-storage-from-the-base-build)
  - [Why this lab's own federation Route](#why-this-labs-own-federation-route)
  - [Federation: ClusterFederatedTrustDomain, with the bootstrap bundle in it](#federation-clusterfederatedtrustdomain-with-the-bootstrap-bundle-in-it)
  - [`className` on every ClusterSPIFFEID](#classname-on-every-clusterspiffeid)
  - [The demo](#the-demo)
- [Online Boutique: SPIFFE on a real application](#online-boutique-spiffe-on-a-real-application)
- [Online Boutique on Service Mesh: SPIRE as the mesh's CA](#online-boutique-on-service-mesh-spire-as-the-meshs-ca)
  - [Support status](#support-status)
- [Memory budget](#memory-budget)
- [Verifying](#verifying)
- [When something is wrong](#when-something-is-wrong)

---

## What it builds

```
 lab host ── helper .21: DNS for *.mylab.com, haproxy for the hub's *.apps

 hub: trust domain hub.mylab.com            SNO: trust domain sno.mylab.com
 ns zero-trust-workload-identity-manager    ns zero-trust-workload-identity-manager
   spire-server-0 (+ controller manager)      spire-server-0 (+ controller manager)
     PVC on lvms-vg1 (a worker's disk)          PVC on lvms-vg1 (its 2nd disk)
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
| PVC `spire-data-spire-server-0` | on `lvms-vg1`, the default StorageClass the base build's LVM Storage provides | [storage](#storage-lvm-storage-from-the-base-build); a `spire-local` StorageClass + local PV only as a fallback on a cluster with no default class |
| `spiffe-demo` | ClusterSPIFFEID, `echo-server`, `client`, `intruder`, passthrough Route | [demo](#the-demo) |
| `ClusterFederatedTrustDomain` | one, naming the other cluster | carries the bootstrap bundle |
| `online-boutique` (`--tags boutique`) | Online Boutique, one hop under ghostunnel mTLS | [Online Boutique](#online-boutique-spiffe-on-a-real-application) |
| `boutique-mesh` (`--tags mesh`) | Online Boutique on Service Mesh 3, every Envoy's certificate from SPIRE; plus the Service Mesh operator, `istio-system`, `istio-cni` | [on Service Mesh](#online-boutique-on-service-mesh-spire-as-the-meshs-ca) |

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
| `lvm` | per cluster: LVM Storage from the base playbooks (`../setup_hub_cluster.yaml --tags lvm`, `../setup_sno.yaml --tags snostorage`) - a no-op on clusters the `clusters` step just built | 1-10 min |
| `preflight` | per cluster: operator in the catalog? which channel? StorageClass? Changes nothing | 1 min |
| `operator` | per cluster: Subscription, CSV, CRDs, API check | 5 min |
| `storage` | per cluster: nothing when `lvms-vg1` is there; a local PV as a fallback when there is no default StorageClass | 1 min |
| `spire` | per cluster: the four CRs and the federation Route, wait Ready, every agent attested | 5 min |
| `demo` | per cluster: `spiffe-demo`, wait for SVIDs | 3 min |
| `verify` | per cluster: asserts - entries, mTLS allowed, intruder refused | 1 min |
| `federation` | both: bundles, `ClusterFederatedTrustDomain`s, refresh over each Route, `federatesWith` | 3 min |
| `xverify` | both: hub client → SNO echo-server, and back | 1 min |
| `boutique` | per cluster: [Online Boutique](#online-boutique-spiffe-on-a-real-application), every service registered, `checkoutservice → paymentservice` over mTLS, then its asserts | 10 min |
| `boutique-federate` | the hub's checkoutservice pays through the SNO's paymentservice, across the trust domains | 3 min |
| `mesh` | with `--mesh`, **in place of** the two above: per cluster, [Online Boutique on Service Mesh](#online-boutique-on-service-mesh-spire-as-the-meshs-ca) with SPIRE as the mesh's CA, then its asserts | 15 min |

`--from <step>` resumes, `--only <step>` runs one, `--cluster hub` limits the
per-cluster steps to one cluster (federation then skips), `--dry-run` prints
the commands. `--only cleanup` removes SPIRE from both clusters.
`--no-boutique` leaves out the last two steps (13 more images, ~1.4 GiB per
cluster); they stay reachable with `--only`. `--mesh` builds the Service
Mesh version instead; `--only mesh` adds it to a lab that already has the
ghostunnel one (they use different namespaces and can run side by side), and
`--only mesh-cleanup` takes it away again, mesh and all.

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
    tasks/                 one file per phase; catalog.yml, storage-decide.yml and boutique-source.yml are shared
    templates/             every manifest, one .j2 each
    templates/boutique/    the Online Boutique overlay: ghostunnel patches, NetworkPolicy, Route, ClusterSPIFFEID
    templates/mesh/        the Service Mesh overlay: gateway, PeerAuthentication, AuthorizationPolicy, ClusterSPIFFEID
    templates/mesh-*.j2    the Service Mesh operator Subscription; IstioCNI and Istio with the SPIRE templates
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

### Storage: LVM Storage from the base build

`SpireServer` requires a PVC - the sqlite datastore and the CA keys live on
it - and the operator names a StorageClass in it.

The class comes from the base lab, not from this one. With
`use_lvm_storage: true` (the base default) LVM Storage is part of the
cluster builds themselves (`roles/setup-lvm-storage`): the hub's, on the
500G `storage_worker<N>.qcow2` disk every worker is built with - outside
`--tags acm`, so `--skip-tags acm` keeps it - and the SNO's, on a second
disk `setup_sno.yaml` hot-plugs after the install. Either way the cluster
comes up with `lvms-vg1` as its default StorageClass, and
`spire_storage_class: auto` uses it: a thin LV on whichever node the SPIRE
server is scheduled to, `Delete` reclaim, so `--tags cleanup` deleting the
PVC also deletes the CA keys - a rebuild is a genuinely new trust domain root.

On a lab whose clusters were built before LVM Storage moved into the build,
the `lvm` step (`./build-lab.sh --only lvm`) runs the base playbooks with just
their storage tags - `../setup_hub_cluster.yaml --tags lvm` and
`../setup_sno.yaml --tags snostorage` - and touches nothing else.

**Fallback, a local PV.** A cluster with no default class at all (the SNO on
the Ceph path, `use_lvm_storage: false`) gets this lab's own `spire-local`
StorageClass (no-provisioner, `WaitForFirstConsumer`) and one local PV on the
first worker's `/var/lib/spire-server-data`, reserved for the SPIRE server's
PVC by `claimRef`, reclaim policy `Retain` - which pins the SPIRE server to
that node. `--tags cleanup` removes the PV, the class and the directory.

**`persistence` is immutable.** An existing `SpireServer` keeps the class it
was created with - the lab reads it back and renders the same one - so a
lab that has been running on `spire-local` stays there after LVM Storage
arrives. Moving it is `--tags cleanup` and building SPIRE again (a new CA,
and the peer must re-federate).

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

## Online Boutique: SPIFFE on a real application

The three-pod demo shows each SPIFFE decision in isolation. Online Boutique
(from [sadiquepp/openshift `test-workloads/online-boutique`](https://github.com/sadiquepp/openshift/tree/main/test-workloads/online-boutique),
Google's microservices demo with the OpenShift SCC fixes) shows it inside an
application that was never written for it: eleven services talking plaintext
gRPC, none of which presents or checks a certificate.

**What the lab does with it** (`--tags boutique`, per cluster):

| | |
| --- | --- |
| Source | cloned from `spire_boutique_repo` at a **pinned commit** (`spire_boutique_ref`) into `/root/spiffe-spire-src/openshift`, and never edited |
| Overlay | rendered into `/root/spiffe-spire-manifests/<cluster>/boutique/` on top of the repo's own `overlays/default`; `oc kustomize` writes `40-boutique.yaml`, which is applied |
| Registration | one ClusterSPIFFEID for the namespace with no pod selector: **every** pod gets `spiffe://<td>/ns/online-boutique/sa/<service>`. Only two of them use it - registration and use are separate things |
| The hop | `checkoutservice → paymentservice`, under mTLS with [ghostunnel](https://github.com/ghostunnel/ghostunnel) sidecars that fetch SVIDs straight from the Workload API socket (no spiffe-helper, no files) |
| paymentservice | the app moves to `localhost:50052`; a ghostunnel **server** on `:8443` takes the Service's traffic, requires a client SVID, and admits only `--allow-uri spiffe://<td>/ns/online-boutique/sa/checkoutservice` (and the peer cluster's checkoutservice, inert until federation) |
| checkoutservice | `PAYMENT_SERVICE_ADDR=localhost:50051`, a ghostunnel **client** that dials paymentservice with the pod's SVID and refuses any server that is not `--verify-uri spiffe://<td>/ns/online-boutique/sa/paymentservice` |
| NetworkPolicy | only the ghostunnel ports reach the paymentservice pod. Without it the mTLS would be decoration: the app still listens on every interface, and anything that can reach the pod IP could dial `:50052` around ghostunnel |
| Route | `payment-online-boutique.apps.<cluster>`, passthrough - the other cluster's way in |

The load generator places orders continuously, so payments cross the tunnel
without anyone clicking.

**What `boutique-verify` asserts:**

1. every running pod in the namespace has a registration entry;
2. checkoutservice's ghostunnel reports `backend_ok` on `/_status` (read
   through the API server's pod proxy) - in client mode that is a full mTLS
   handshake to the paymentservice with its SPIFFE ID checked - and orders
   are opening connections through it;
3. spiffe-demo's `client` - a registered workload with a perfectly valid SVID
   from the same trust domain, but not checkoutservice - is refused by
   paymentservice's ghostunnel during the handshake;
4. a direct connection to the paymentservice pod's `:50052` is dropped, while
   `:8443` on the same IP connects - so it is the policy doing it.

**Across the federation** (`boutique-federate`): the hub's checkoutservice
is re-pointed at `payment-online-boutique.apps.sno.mylab.com:443` and told to
expect `spiffe://sno.mylab.com/ns/online-boutique/sa/paymentservice`; the SNO's
paymentservice already admits `spiffe://hub.mylab.com/.../checkoutservice`.
Both namespaces' ClusterSPIFFEIDs carry `federatesWith` once the trust domains
are federated, which is why `boutique` runs after `federation`. The hub's
orders are then paid in the other trust domain. The switch is
`spire_boutique_remote_payments`; a plain `--tags boutique -e spire_cluster=hub`
puts payments back on the hub.

What it deliberately does not do: put every hop under mTLS. `frontend` alone
calls seven services, and a sidecar pair per hop is exactly the plumbing a
service mesh exists to remove - which is the next section.

## Online Boutique on Service Mesh: SPIRE as the mesh's CA

The same application, from the same pinned commit, on OpenShift Service Mesh
3 - with the mesh's certificates issued by SPIRE rather than istiod. Every
hop is mTLS, the application is not modified at all, and the authorisation
rule that ghostunnel's `--allow-uri` expressed becomes an
`AuthorizationPolicy` on a SPIFFE ID.

**What the lab does with it** (`--tags mesh`, per cluster):

| | |
| --- | --- |
| Operator | `servicemeshoperator3` from `redhat-operators`, a Subscription in `openshift-operators` (the cluster's global OperatorGroup), channel from the catalog. If the cluster already has one, it is used as it is |
| Control plane | `IstioCNI` in `istio-cni`; `Istio` in `istio-system` with `meshConfig.trustDomain` = the SPIRE trust domain, `WORKLOAD_IDENTITY_SOCKET_FILE: spire-agent.sock`, and two injection templates, `spire` and `spireGateway`, that mount the SPIRE agent's socket through `csi.spiffe.io` - as in Red Hat's documented procedure. istiod requests are cut from 500m / 2 GiB to 50m / 256 MiB, each Envoy's to 10m / 48 MiB. Refuses to touch an `Istio` it did not create |
| Namespace | `boutique-mesh`, labelled `istio-injection=enabled`; the repo's `overlays/default` moved there by kustomize. Separate from `online-boutique`, so the two versions never share an object |
| Workloads | every Deployment annotated `inject.istio.io/templates: sidecar,spire`; nothing else about them changes |
| Registration | a ClusterSPIFFEID for the namespace, applied **before** the pods: an Envoy with no entry gets no certificate and its pod never goes Ready. `federatesWith` the peer when the trust domains are federated, so the peer's CA is in every sidecar's `ROOTCA` too |
| Policy | `PeerAuthentication` STRICT for the namespace; `AuthorizationPolicy` on paymentservice: ALLOW `<td>/ns/boutique-mesh/sa/checkoutservice` only |
| Ingress | an ingress gateway (`gateway,spireGateway` templates - it holds a SPIRE certificate too) with a `Gateway` and `VirtualService` to frontend. The repo's Route `frontend` is repointed at it: the router is not in the mesh, and STRICT mTLS would otherwise lock it out |
| Manifests | `50-mesh-operator.yaml`, `51-mesh-istio.yaml`, `52-mesh-clusterspiffeid.yaml`, `53-boutique-mesh.yaml` (the `oc kustomize` output of `boutique-mesh/`) |

How a certificate gets into Envoy: the `spire` template adds the CSI volume
to `istio-proxy`; pilot-agent finds `spire-agent.sock` in it and points Envoy's
SDS straight at the SPIRE agent instead of serving certificates from istiod.
The operator configures the agent's SDS for this (`default` is the pod's
SVID, `ROOTCA` is every bundle the agent holds, federated ones included).
istiod keeps its own CA only for its own serving certificate.

**What `mesh-verify` asserts:**

1. every running pod has a registration entry;
2. every pod's Envoy (`pilot-agent request GET certs`) holds a certificate
   whose SPIFFE ID is that pod's service account and whose lifetime is a
   SPIRE SVID's (1h), not an istiod certificate's (24h);
3. paymentservice's Envoy has accepted requests over `mutual_tls` whose
   `source_principal` is `spiffe://<td>/ns/boutique-mesh/sa/checkoutservice`
   (its `istio_requests_total`) - the load generator's orders, paid;
4. the load generator - inside the mesh, with its own valid SPIRE
   certificate, but not checkoutservice - gets `403 RBAC: access denied`
   from paymentservice;
5. if spiffe-demo is deployed: its `client`, outside the mesh, is cut off
   when it talks plaintext to `frontend`, and gets the shop's `200` through
   the Route and the ingress gateway.

**Not built: across the clusters.** Red Hat documents a multi-cluster mesh on
SPIRE federation, but it needs more than this lab has: east-west gateways on
LoadBalancer Services (the base clusters have no load balancer provider),
remote secrets so each istiod can read the other cluster's API, a shared
`meshID` and network names. The SPIRE half is here - with `federatesWith`,
each sidecar already trusts the peer's CA.

**Ambient mode does not work with SPIRE.** Ambient's node proxy, ztunnel,
gets workload certificates only from a CA over Istio's certificate-signing
API (`CA_ADDRESS`, istiod by default); it has no SDS/Workload API client, so
it cannot use the SPIRE agent's socket. That was confirmed in the ztunnel
source (`src/identity/caclient.rs` at upstream `main`, 28 September 2026), and
Red Hat's procedures cover sidecar mode only. Ambient on OpenShift Service
Mesh works on its own, but then istiod is the CA and SPIRE is not involved.

### Support status

Checked against the product documentation source (`openshift/openshift-docs`,
`security/zero_trust_workload_identity_manager/`, as of 2026-09-30):

- **Supported, not Technology Preview.** Zero Trust Workload Identity Manager
  **1.1.0** (30 June 2026) added "single-cluster integration with Red Hat
  OpenShift Service Mesh" and "multi-cluster integration through SPIRE
  federation". Neither page carries a Technology Preview notice. 1.1.1
  (26 August 2026) is a bug-fix release.
- **Shape of it:** Service Mesh 3, sidecar mode, the `spire` and
  `spireGateway` injection templates, `trustDomain` set to SPIRE's - what
  `--tags mesh` builds. The documented procedure also sets
  `jwksResolverExtraRootCA` from the OIDC discovery provider; that is for
  JWT-SVID request authentication, and this lab deploys no OIDC discovery
  provider, so it is left out.
- **Multi-cluster** adds east-west gateways, remote secrets, Istio **1.29.2
  or later**, `istioctl` and `helm`.
- Related, from the same 1.1.0 release: a **supported SPIFFE Helper image**,
  `registry.redhat.io/zero-trust-workload-identity-manager/spiffe-helper-rhel9`.
  The lab still defaults to upstream `ghcr.io/spiffe/spiffe-helper:0.11.0`,
  because the docs give no tag and none could be listed from here; set
  `spire_demo_helper_image` to the Red Hat image once you have picked a tag
  (`skopeo list-tags docker://registry.redhat.io/zero-trust-workload-identity-manager/spiffe-helper-rhel9`).

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
| **total, SPIRE and demo** | | **~1.0 GiB / ~3.3 GiB** | | **~0.8 GiB / ~2.3 GiB** |
| Online Boutique, upstream (12 Deployments incl. load generator) | 12 | 1368 Mi / 2542 Mi | 12 | 1368 Mi / 2542 Mi |
| its two ghostunnel sidecars (32/128 Mi) | 2 | 64 Mi / 256 Mi | 2 | 64 Mi / 256 Mi |
| **total with `boutique`** | | **~2.4 GiB / ~6.0 GiB** | | **~2.2 GiB / ~5.0 GiB** |
| *instead, `mesh`:* Service Mesh operator (Sail chart default, 64 Mi / 1 Gi) | 1 | 64 Mi / 1 Gi | 1 | 64 Mi / 1 Gi |
| istiod (`spire_mesh_istiod_resources`) | 1 | 256 Mi / 1 Gi | 1 | 256 Mi / 1 Gi |
| istio-cni-node (chart default 100 Mi, no limit; every node) | 6 (3 on masters) | 600 Mi / - | 1 | 100 Mi / - |
| Online Boutique, upstream | 12 | 1368 Mi / 2542 Mi | 12 | 1368 Mi / 2542 Mi |
| an Envoy per pod, gateway included (`spire_mesh_proxy_resources`, 48/256 Mi) | 13 | 624 Mi / 3328 Mi | 13 | 624 Mi / 3328 Mi |
| **total with `mesh`** | | **~3.8 GiB / ~11 GiB** | | **~3.2 GiB / ~10 GiB** |

LVM Storage's own pods (operator, `vg-manager`, TopoLVM) are part of the base
build now, not of this lab, and are not counted here.

Against the smallest supported sizing (3 × 24 GiB hub workers, a 32 GiB
SNO): about 1.4% of the hub workers' memory requested, ~4.6% at the limits;
about 2.5% of the SNO requested, ~7% at the limits. The limits are ceilings,
not expected use: SPIRE at this scale is tens of MiB per process. These are
configured values, not measurements - measure with
`oc adm top pods -n zero-trust-workload-identity-manager` once it runs. The
SNO is the tighter of the two, because it already carries a whole control
plane in 32 GiB; neither needs its VM resized.

With Online Boutique on both clusters: ~3.4% of the hub workers requested
(~8.4% at the limits) and ~6.8% of the SNO (~16% at the limits), plus 1.57
CPU of requests per cluster, most of it the load generator keeping traffic
flowing. Still no VM change; `--no-boutique` if the SNO is already busy.

With the mesh version instead: ~4.9% of the hub workers requested and ~10%
of the SNO. The limits look large (~31% of the SNO) because every Envoy may
grow to 256 MiB; idle Envoys in an application this size sit far below that.
Both versions at once add the ghostunnel row's ~1.4 GiB again: ~4.6 GiB
requested on the SNO, still without a resize, but it is the point where
`oc adm top node` is worth watching.

---

## Verifying

`verify` (per cluster) and `xverify` (both) assert outcomes, not objects, so
they check the automated build and a workshop attendee's hand-built one the
same way:

```bash
./build-lab.sh --only verify            # or: --workshop --only check
./build-lab.sh --only xverify
./build-lab.sh --only boutique-verify   # the ghostunnel version
./build-lab.sh --only mesh-verify       # the Service Mesh version
```

By hand, on either cluster:

```bash
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig
S="oc -n zero-trust-workload-identity-manager exec spire-server-0 -c spire-server -- /proc/1/exe"
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
| `SpireServer` never Ready, PVC `Pending` | `oc -n zero-trust-workload-identity-manager get pvc,pv` and `oc get sc` - no `lvms-vg1`? `./build-lab.sh --only lvm`; `oc -n openshift-storage get lvmcluster -o yaml` says why LVM Storage is not Ready |
| agents fewer than workers | `oc -n zero-trust-workload-identity-manager logs ds/spire-agent`; node attestation errors name the cause |
| ClusterSPIFFEID `.status` empty | missing or wrong `spec.className` |
| `executable file ... spire-server not found` | the server image keeps the binary neither on `$PATH` nor at upstream's `/opt/spire/bin`; it is the container's entrypoint, so call it as `/proc/1/exe` (`spire_server_cli`; the workshop's `spire` helper does) |
| pod has no `/svid/svid.pem` | `oc -n spiffe-demo logs deploy/<pod> -c spiffe-helper` - `no identity issued` means no entry matches the pod |
| `federation refresh` fails | the message names DNS (`no such host`), the Route (connection refused / 503) or the endpoint's SVID (`x509`) |
| cross-cluster call `SERVER NOT TRUSTED` | the pod's bundle lacks the peer CA: `federatesWith` on the ClusterSPIFFEID, then wait for spiffe-helper to rewrite it |
| cross-cluster call `HTTP 403` | the peer's client is not in `echo-allowed-ids` |
| boutique: checkoutservice or paymentservice ghostunnel restarting | `oc -n online-boutique logs deploy/<svc> -c ghostunnel` - it exits if no SVID arrives within `--use-workload-api-timeout` (10m): is the ClusterSPIFFEID `online-boutique` there, with its className? |
| boutique: `backend_ok: false` | `backend_error` in the same JSON; `unauthorized` on the paymentservice side means the caller's SPIFFE ID is not in `--allow-uri` |
| boutique-federate: handshake fails | both ClusterSPIFFEIDs need `federatesWith`: re-run `--tags boutique` on both clusters after `--tags federation` |
| mesh: pods stuck `Init`/not Ready, `istio-proxy` logs waiting for the socket or a certificate | `oc get clusterspiffeid boutique-mesh -o yaml` - is it there, with `className`, entries > 0? `oc -n boutique-mesh get pod <pod> -o yaml \| grep -e templates -e csi.spiffe` - the `spire` template and the CSI volume must both be on the pod |
| mesh-verify: a certificate valid 24h | it came from istiod: the pod lacks `inject.istio.io/templates: sidecar,spire`, or was created before the `Istio` CR had the templates - `oc -n boutique-mesh rollout restart deploy/<name>` |
| mesh: shop Route answers 503 | the gateway pod: `oc -n boutique-mesh logs deploy/boutique-gateway`; is it Ready (it needs its own SPIRE entry), does the `VirtualService` name the `Gateway` |
| mesh-verify: load generator gets 200 from paymentservice | the `AuthorizationPolicy` `paymentservice` is missing, or its principal's trust domain differs from `meshConfig.trustDomain` |
| mesh: `Istio` not Ready | `oc get istio default -o yaml` - the conditions name the cause; `oc -n openshift-operators logs deploy/servicemesh-operator3` |

Non-trivial debugging on a live cluster goes in [troubleshooting.md](troubleshooting.md)
(case 1: where `spire-server` lives in Red Hat's image), in the format of [`udn-bgp-evpn/troubleshooting.md`](../udn-bgp-evpn/troubleshooting.md).
