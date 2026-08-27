# Online Boutique — stateless 11-service fixture

[GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo)
`v0.10.6`, vendored and patched to actually run on OpenShift.

Use this when you want a **large, genuinely distributed, stateless** workload:
no PersistentVolumeClaims anywhere, 11 services across 5 languages talking gRPC,
plus a load generator that keeps traffic flowing on its own.

For a **stateful** fixture — something whose data has to survive a restore,
migration or node drain — use [`../microservices-demo`](../microservices-demo)
instead. The two are complementary; nothing is shared between them.

| | this | `../microservices-demo` |
|---|---|---|
| Services | 11 (+ load generator) | 3 |
| State | none — `redis-cart` uses `emptyDir` | 2 PVCs (or `emptyDir` via its `ephemeral` overlay) |
| Protocol | gRPC | HTTP/JSON |
| Languages | Go, C#, Node, Python, Java | Python |
| Images to mirror | 13 | 1 |
| Requests | 1.57 CPU / 1368 Mi | ~0.1 CPU / 192 Mi |
| Good for | mesh, tracing, load, scheduling, upgrades | storage, backup/restore, DR |

## Was this the right pick?

For a stateless fixture, yes — it is the most realistic well-known option, it is
actively maintained with pinned release tags, and `redis-cart` uses `emptyDir`
so nothing needs storage. It also ships OpenTelemetry instrumentation, which
matters if you go on to wire up Tempo.

Two things to know before committing to it:

**It does not deploy on OpenShift as shipped.** Upstream pins
`runAsUser: 1000`, `runAsGroup: 1000` and `fsGroup: 1000` on all 12 deployments.
Under the default `restricted-v2` SCC each namespace gets its own allocated UID
range (e.g. `1000750000/10000`), so a hardcoded `1000` is outside it and
admission rejects the pod:

```
unable to validate against any security context constraint
```

There is no upstream OpenShift kustomize component (checked against
`kustomize/components` at `v0.10.6`), so `base/kustomization.yaml` supplies that
missing piece. It strips the three fields and keeps `runAsNonRoot: true`.
Dropping `runAsGroup` matters as much as `runAsUser`: OpenShift runs containers
with GID 0 and expects images to be group-writable, so forcing GID 1000 breaks
that assumption.

**Two of the 13 images come from Docker Hub** (`redis:alpine`,
`busybox:1.38.0@sha256:…`), which means anonymous pull-rate limits in CI and two
extra registries to mirror for a disconnected cluster.

## Deploy

```bash
oc apply -k tests/online-boutique/overlays/default
```

```bash
oc get route frontend -n online-boutique -o jsonpath='{.spec.host}{"\n"}'
```

Tear down with `oc delete -k tests/online-boutique/overlays/default`.

## Layout

```
base/
  kubernetes-manifests.yaml   vendored verbatim from upstream v0.10.6
  kustomization.yaml          the OpenShift compatibility layer
  route.yaml                  replaces upstream's LoadBalancer Service
overlays/
  default/                    namespace + labels           <- start here
  no-loadgenerator/           default minus the traffic generator
```

## What the patches do, and why

- **Strips `runAsUser` / `runAsGroup` / `fsGroup`** from all 12 deployments — see
  above. Written as JSON 6902 `remove`, so if a future upstream release drops
  these fields the build **fails loudly** rather than silently no-opping and
  leaving you to discover the drift at deploy time.
- **Deletes the `frontend-external` LoadBalancer Service.** Upstream ships it for
  GKE; on a cluster with no LB provider it sits in `<pending>` forever.
  `base/route.yaml` exposes the ClusterIP `frontend` Service via an OpenShift
  Route instead, with no `host:` so the cluster's apps domain supplies one.
  If you do have MetalLB and would rather use a real LoadBalancer, delete that
  patch from `base/kustomization.yaml`.

## Load generator

`overlays/default` includes it: continuous synthetic traffic through the whole
call graph, so traces, metrics and autoscaling behaviour appear without you
scripting anything. It also burns CPU continuously and means the app is never
idle — use `overlays/no-loadgenerator` when measuring baseline usage or when you
want a quiet cluster.

## Disconnected clusters

13 images. Add them to `mirror_catalog_operator_packages`' sibling
`additionalImages` list in
`roles/setup-mirror-registry/templates/imageset-config.yaml.j2`, then repoint
them with an `images:` block in `overlays/default/kustomization.yaml` (there is a
commented stub there). Upstream also ships a `container-images-registry`
component that does the same job if you prefer.

Note this is a meaningfully bigger mirroring job than `../microservices-demo`,
which needs exactly one image.

## Refreshing to a newer upstream release

```bash
V=v0.10.7
curl -sfL "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$V/release/kubernetes-manifests.yaml" \
  -o tests/online-boutique/base/kubernetes-manifests.yaml
```

```bash
kustomize build tests/online-boutique/overlays/default > /dev/null && echo ok
```

The manifest is vendored rather than referenced by URL so that `kustomize build`
works air-gapped and the version cannot drift underneath you.
