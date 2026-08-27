# microservices-demo

A small, reusable distributed application for OpenShift. Three services, real
HTTP calls between them, real persistent state — intended as a drop-in fixture
for whatever you actually want to exercise: storage, ingress, backup/restore,
service mesh, tracing, upgrades, node drains, DR.

It is deliberately **not** tied to any one of those. The app lives in `base/`;
each use case is an overlay.

```
                Route (edge TLS, generated host)
                        │
                 ┌──────▼──────┐
                 │  storefront │   frontend · stateless · 2 replicas
                 └──┬───────┬──┘
                    │       │      cluster DNS, plain HTTP
           ┌────────▼─┐   ┌─▼────────┐
           │ catalog  │   │  orders  │   backend · 1 replica each
           │   PVC    │   │   PVC    │
           └──────────┘   └──────────┘
```

| Service | Component | State | Role |
|---|---|---|---|
| `storefront` | frontend | none | Only service with a Route. Fans out to both backends and aggregates. |
| `catalog` | backend | PVC | Seeds itself on first start. Read-mostly. |
| `orders` | backend | PVC | Append-only. Starts empty — **the thing to assert on** when testing that state survives something. |

## Why it is built this way

**One image, no build step.** All three services run from
`quay.io/sclorg/python-312-c9s` with their code supplied as ConfigMaps. There is
no Dockerfile, no registry to push to, and exactly one image to mirror.

**Standard library only.** No `pip install` at runtime, so it behaves identically
on an air-gapped cluster as on a connected one.

**Multi-arch.** The base image publishes amd64, arm64 and ppc64le, so the same
manifests work on x86 clusters, ARM clusters, and CRC on Apple silicon.

**Restricted SCC clean.** `runAsNonRoot`, all capabilities dropped,
`seccompProfile: RuntimeDefault`, no fixed UID — runs under the default
`restricted-v2` SCC with no SCC grants or service-account changes.

**Portable by construction.** No hardcoded namespace, no `storageClassName`, no
Route `host`, no image tag in `base/`. Every one of those is an overlay
decision.

## Layout

```
base/                     the app. not deployable alone — no namespace, no image tag
  src/*.py                service code as real, runnable Python files
  catalog|orders|storefront.yaml
overlays/
  default/                namespace + PVCs + pinned image     <- start here
  ephemeral/              emptyDir instead of PVCs
  network-policy/         default-deny + the three flows the app needs
  oadp/                   Velero Backup/Restore  (specific to this repo)
```

## Deploy

```bash
oc apply -k tests/microservices-demo/overlays/default
```

```bash
oc get route storefront -n microservices-demo -o jsonpath='{.spec.host}{"\n"}'
```

To tear down: `oc delete -k tests/microservices-demo/overlays/default`.

## Reusing it in another project

Copy `overlays/default` as your starting point and edit the four things that
matter — or reference this base remotely and never copy the app at all:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: my-project

resources:
  - github.com/<org>/hcp-backup-restore//tests/microservices-demo/base?ref=main

images:
  - name: quay.io/sclorg/python-312-c9s
    newName: registry.internal:8443/sclorg/python-312-c9s   # your mirror
    newTag: "20260820"
```

Common overrides:

| Want to change | How |
|---|---|
| Namespace | `namespace:` in the overlay |
| Image / registry / tag | `images:` in the overlay |
| Replica counts | `replicas:` in the overlay |
| StorageClass, PVC size | patch the PVCs |
| Downstream URLs, timeout | `storefront-config` ConfigMap (`CATALOG_URL`, `ORDERS_URL`, `UPSTREAM_TIMEOUT`) |
| Deploy into an existing namespace | drop `namespace.yaml` from `resources:` — then no cluster-scoped permission is needed at all |

Each service also honours `PORT` (default 8080), which is what lets you run all
three on one laptop:

```bash
cd tests/microservices-demo/base/src
PORT=8081 DATA_DIR=/tmp/c python3 catalog.py &
PORT=8082 DATA_DIR=/tmp/o python3 orders.py &
PORT=8083 CATALOG_URL=http://127.0.0.1:8081 ORDERS_URL=http://127.0.0.1:8082 python3 storefront.py &
curl -s localhost:8083/api/summary
```

### If you add a `namePrefix`

Kustomize rewrites Service names but **not** environment variable values, so a
prefix would leave `storefront` calling a `catalog` that no longer exists. Update
`CATALOG_URL`/`ORDERS_URL` in the `storefront-config` generator to match.

## API

| Service | Endpoint | |
|---|---|---|
| all | `GET /healthz` | liveness/readiness |
| catalog | `GET /items`, `POST /items` | |
| orders | `GET /orders`, `POST /orders` | `GET` returns `{count, orders}` |
| storefront | `GET /` | HTML page |
| storefront | `GET /api/summary` | aggregates both backends; **503 + `"degraded"`** if either is unreachable |
| storefront | `POST /api/orders` | forwards to orders |

`/api/summary` returning `degraded` is the app's main diagnostic: it means the
pods are up but the wiring between them is not, which is exactly the failure a
restore, a NetworkPolicy mistake, or a bad mesh config produces.

## Design notes

Things that look odd but are load-bearing:

- **`strategy: Recreate`** on `catalog` and `orders` — their PVCs are RWO, so a
  rolling update deadlocks waiting for the outgoing pod to release the volume.
- **Readiness probes `/healthz`, not `/api/summary`** — otherwise a brief
  backend outage evicts every storefront pod from its Service endpoints and
  turns a partial failure into a total one.
- **`topologySpreadConstraints` with `ScheduleAnyway`**, not `DoNotSchedule` —
  on a single-node cluster a hard constraint leaves the second replica `Pending`
  forever.
- **`labels:` with `includeSelectors: false`** — the older `commonLabels` also
  writes into `spec.selector`, which is immutable on a Deployment; changing a
  label later would then require deleting every workload.
- **ConfigMaps generated from `src/*.py`** — the generated name carries a content
  hash, so editing a service rolls its Deployment automatically instead of
  leaving old pods running against new config.
- **`overlays/ephemeral` uses a JSON 6902 patch, not a strategic merge** — a
  strategic merge (even with `$retainKeys`) leaves *both* `persistentVolumeClaim`
  and `emptyDir` set on the volume; kustomize builds it happily and the API
  server then rejects it. JSON 6902 `remove` fails at build time instead.
- **NetworkPolicy is an overlay, not base** — enforcement depends on the CNI, and
  the router rule uses an OpenShift-specific namespace label. In base it would
  silently break the app on some clusters.

## Backup/restore (this repo's use case)

```bash
oc apply -k tests/microservices-demo/overlays/oadp
```

1. Seed some orders and record the count:

```bash
oc rsh -n microservices-demo deploy/storefront curl -s -XPOST -H 'Content-Type: application/json' -d '{"item":"RHEL9"}' http://orders:8080/orders
```

```bash
oc rsh -n microservices-demo deploy/storefront curl -s http://orders:8080/orders
```

2. Back up and wait for `Completed`:

```bash
oc get backup microservices-demo-backup -n openshift-adp -o jsonpath='{.status.phase}{"\n"}'
```

3. **Actually destroy it** — restoring over a live namespace leaves the existing
   PVC contents in place, so the test would pass without proving anything:

```bash
oc delete ns microservices-demo
```

4. Restore, then re-check the count against step 1:

```bash
oc apply -f tests/microservices-demo/overlays/oadp/restore.yaml
```

The Backup uses Kopia file-level backup rather than CSI snapshots, so it works
across this lab's storage backends without a `VolumeSnapshotClass` per backend.
OADP runs on the hub, so this deploys to a hub cluster; using it inside a hosted
cluster needs OADP installed there too.

## Disconnected clusters

One image to mirror. It is already listed under `additionalImages` in
`roles/setup-mirror-registry/templates/imageset-config.yaml.j2`; point the
overlay's `images:` entry at your mirror.
