# SPIFFE/SPIRE workload identity on OpenShift - Workshop

You give two OpenShift clusters a cryptographic identity for every workload,
without a single password, token or certificate in a Secret. Each cluster
becomes a SPIFFE trust domain with its own SPIRE server; pods receive short-
lived X.509 certificates that say *which workload they are*, and use them to
authenticate to each other over mutual TLS. A pod nobody registered gets
nothing and is turned away. Then you federate the two trust domains, and a
workload on the hub proves who it is to a workload on the SNO.

**What is automated and what you type.** The plumbing - the host, the helper
VM, both cluster installs, the operator install and a volume for the SPIRE
server - is one command. Everything that *is* SPIFFE or SPIRE - the trust
domain, the server, the agents, the CSI driver, the registration, the
workloads, the federation - you create yourself from the blocks below. Each
block writes a manifest to a file and then applies that file, so you can read
exactly what your shell produced before it reaches the cluster.

---

## Contents

- [The lab you are building](#the-lab-you-are-building)
- [Part A - Day 0: build the lab](#part-a---day-0-build-the-lab)
  - [A1. The host](#a1-the-host)
  - [A2. One command](#a2-one-command)
  - [A3. While it runs: the six ideas](#a3-while-it-runs-the-six-ideas)
  - [A4. When it finishes](#a4-when-it-finishes)
- [Part B - Hands-on](#part-b---hands-on)
  - [Lab 1. A trust domain per cluster](#lab-1-a-trust-domain-per-cluster)
  - [Lab 2. The SPIRE server](#lab-2-the-spire-server)
  - [Lab 3. Agents and the CSI driver](#lab-3-agents-and-the-csi-driver)
  - [Lab 4. Workloads with no identity](#lab-4-workloads-with-no-identity)
  - [Lab 5. Register them](#lab-5-register-them)
  - [Lab 6. Mutual TLS, and who gets refused](#lab-6-mutual-tls-and-who-gets-refused)
  - [Lab 7. Federate the two trust domains](#lab-7-federate-the-two-trust-domains)
- [Explore - Optional](#explore---optional)
- [Part C - Optional: SPIFFE in a real application](#part-c---optional-spiffe-in-a-real-application)
  - [C1. The application, as shipped](#c1-the-application-as-shipped)
  - [C2. Register every service](#c2-register-every-service)
  - [C3. Put the payment hop under mTLS](#c3-put-the-payment-hop-under-mtls)
  - [C4. Who gets through now](#c4-who-gets-through-now)
  - [C5. Pay in the other trust domain](#c5-pay-in-the-other-trust-domain)
- [Part D - Optional: the same application on Service Mesh](#part-d---optional-the-same-application-on-service-mesh)
  - [D1. The operator](#d1-the-operator)
  - [D2. A mesh whose CA is SPIRE](#d2-a-mesh-whose-ca-is-spire)
  - [D3. The application, in the mesh - and not yet registered](#d3-the-application-in-the-mesh---and-not-yet-registered)
  - [D4. Register them, and look at what Envoy holds](#d4-register-them-and-look-at-what-envoy-holds)
  - [D5. Lock it down](#d5-lock-it-down)
  - [D6. Who gets through now](#d6-who-gets-through-now)
- [Catching up, checking, and when something is wrong](#catching-up-checking-and-when-something-is-wrong)
- [Tearing it down](#tearing-it-down)

---

## The lab you are building

```
 lab host ── helper VM 192.168.122.21: DNS for *.mylab.com, the hub's load balancer

 hub  (3 masters, 3 workers)                SNO  (one node)
 trust domain hub.mylab.com                 trust domain sno.mylab.com
 ┌─────────────────────────────────┐        ┌─────────────────────────────────┐
 │ SPIRE server   (signs SVIDs)    │        │ SPIRE server                    │
 │ SPIRE agent    x3 (one/worker)  │        │ SPIRE agent    x1               │
 │ SPIFFE CSI driver x3            │        │ SPIFFE CSI driver x1            │
 │ bundle endpoint  ◄──────────────┼─ Lab 7 ┼──────────────►  bundle endpoint │
 │                                 │        │                                 │
 │ spiffe-demo                     │        │ spiffe-demo                     │
 │   echo-server  mTLS :8443       │        │   echo-server  mTLS :8443       │
 │   client ───────────────────────┼─ Lab 7 ┼─────────────►                   │
 │   intruder  (never registered)  │        │   client, intruder              │
 └─────────────────────────────────┘        └─────────────────────────────────┘
```

| SPIFFE ID | Who |
| --- | --- |
| `spiffe://hub.mylab.com/spire/server` | the hub's SPIRE server |
| `spiffe://hub.mylab.com/spire/agent/k8s_psat/hub/<node uid>` | a SPIRE agent, one per hub worker |
| `spiffe://hub.mylab.com/ns/spiffe-demo/sa/echo-server` | the demo server on the hub |
| `spiffe://hub.mylab.com/ns/spiffe-demo/sa/client` | the demo client on the hub |
| `spiffe://sno.mylab.com/...` | the same, on the SNO |

The workload IDs are `ns/<namespace>/sa/<service account>`, which is a
choice you make in Lab 5, not a rule.

---

## Part A - Day 0: build the lab

About an hour and a half on a bare host, nearly all of it the two cluster
installs; five minutes on a host where the base lab is already up.

### A1. The host

The same host as the UDN workshop: RHEL 9, root, nested virtualisation, at
least 192 GiB of RAM, about 1 TB of disk, outbound internet, and the
repository at `/root/hcp-backup-restore` with `vault.yaml`,
`~/.vault_pass` and `vars-metal.yaml` in place. Follow
[`udn-bgp-evpn/workshop.md` A1 and A2](../udn-bgp-evpn/workshop.md#a1-a-metal-host-on-aws)
up to, not including, its A3 - that is the part that builds the UDN lab.

SPIRE adds no VM. Its pods fit inside the hub's workers and the SNO at the
sizes that page sets; the budget is in [README.md](README.md#memory-budget).

### A2. One command

```bash
cd /root/hcp-backup-restore/spiffe-spire
tmux new -s lab          # the cluster installs take over an hour
./build-lab.sh --workshop
```

| Step | What it builds | About |
| --- | --- | --- |
| `bmhost` | the helper VM - DNS for `mylab.com`, the load balancer. Skipped if it exists | 15 min |
| `clusters` | the hub and the SNO, **in parallel**, logging to `build-logs/`, each with LVM Storage as part of its build. Each skipped if already installed | 75 min |
| `lvm` | per cluster: LVM Storage from the base playbooks - a no-op on a cluster `clusters` just built; on an older one it adds `lvms-vg1`, the default StorageClass | 1-10 min |
| `preflight` | per cluster: is Red Hat's SPIRE operator in `redhat-operators`, which channel, is there a StorageClass | 1 min |
| `operator` | per cluster: the Zero Trust Workload Identity Manager - Namespace, OperatorGroup, Subscription - and a wait for it | 5 min |
| `storage` | per cluster: nothing when `lvms-vg1` is there; a local PersistentVolume for the SPIRE server only on a cluster with no default StorageClass | 1 min |
| `prep` | `/root/spiffe-workshop.env`, and one file per cluster that `lab` loads | - |

What it deliberately leaves **undone**: every SPIRE custom resource. The
operator is running and its APIs exist, but `oc get spireserver` finds
nothing - there is no trust domain yet.

**If a step fails**, the script names it and prints the command that resumes
from it, e.g. `./build-lab.sh --workshop --from operator`.

### A3. While it runs: the six ideas

1. **A SPIFFE ID names a workload, not a machine.** It is a URI,
   `spiffe://<trust domain>/<path>`. The trust domain is the authority - here,
   one per cluster - and the path is whatever that authority decides to mean
   something. Nothing about it is an IP address or a DNS name, which is why a
   pod keeps its identity when it moves, and why two different pods on one
   node do not share one.

2. **An SVID is the document that proves it.** An X.509-SVID is an ordinary
   X.509 certificate with the SPIFFE ID as its only URI SAN, signed by the
   trust domain's CA, and short-lived: one hour here. Anything that speaks TLS
   can use it. The **trust bundle** is the set of CA certificates that verify
   SVIDs from a trust domain - what a relying party must hold to check one.

3. **The SPIRE server is the CA; agents are where workloads meet it.** The
   server signs; an agent runs on every node, and workloads ask their local
   agent - never the server - over a Unix socket called the **Workload API**.
   There are no credentials in that request. The agent works out who is
   asking from the kernel (the calling process's PID) and the kubelet (which
   pod that PID belongs to). That is **workload attestation**.

4. **Agents prove where they are, too.** Before an agent can hand out
   anything, it proves to the server which node it runs on with a projected
   service account token the server checks against the Kubernetes API
   (`k8s_psat`). That is **node attestation**, and it is why an agent's own
   SPIFFE ID ends in the node's UID.

5. **Nothing gets an identity unless it is registered.** The server issues an
   SVID only against a **registration entry**: "a workload matching these
   selectors, under this agent, is this SPIFFE ID". On Kubernetes you do not
   write entries by hand; a `ClusterSPIFFEID` says which pods get which ID,
   and spire-controller-manager writes one entry per matching pod. A pod with
   no entry asks the agent and is told `no identity issued`.

6. **Federation is exchanging trust bundles.** Two trust domains stay two
   authorities. Each server publishes its bundle at an HTTPS **bundle
   endpoint**; each fetches the other's and keeps it fresh; workloads whose
   registration says `federatesWith` are handed the foreign bundle too, and
   can then verify the other side's SVIDs. Nothing is merged, and neither CA
   signs for the other.

The operator you are about to drive packages all of this: five CRs, each a
singleton named `cluster`, and it turns them into the server StatefulSet, the
agent and CSI driver DaemonSets, their SCCs, RBAC and webhooks.

### A4. When it finishes

**Once:** point the lab host's DNS at the helper, so the routes you create
resolve from the host as well as from inside the clusters:

```bash
CON=$(nmcli -g GENERAL.CONNECTION device show "$(ip route show default | awk '{print $5; exit}')")
nmcli con mod "$CON" ipv4.dns 192.168.122.21 ipv4.dns-options timeout:1
nmcli con up "$CON"
```

**Every new shell:**

```bash
source /root/spiffe-workshop.env
lab hub          # oc -> the hub, and $TD, $PEER_TD, $APPS, $SPIRE_SC, $M to match
```

| Helper / variable | Is | Same as |
| --- | --- | --- |
| `lab hub` / `lab sno` | switch `oc` and the variables below to that cluster | `export KUBECONFIG=... TD=hub.mylab.com ...` from `/root/spiffe-workshop.d/hub.env` |
| `$TD`, `$PEER_TD` | this cluster's trust domain, and the other's | `hub.mylab.com`, `sno.mylab.com` |
| `$APPS`, `$PEER_APPS` | the two clusters' `*.apps` domains | `apps.hub.mylab.com`, ... |
| `$SPIRE_SC` | the StorageClass the SPIRE server's volume uses | `lvms-vg1`, from the base build's LVM Storage |
| `$ZT_NS` | the operator's namespace, where SPIRE runs | `zero-trust-workload-identity-manager` |
| `$DEMO_NS` | the demo namespace | `spiffe-demo` |
| `$CLASS` | the class every ClusterSPIFFEID must name | `zero-trust-workload-identity-manager-spire` |
| `$LABEL` | the pod label the registration will select | `spiffe.mylab.com/identity` |
| `spire <args>` | the `spire-server` CLI, inside the SPIRE server pod | `oc -n $ZT_NS exec spire-server-0 -c spire-server -- /proc/1/exe <args>` |
| `inpod <deploy> <cmd>` | a command in a demo pod's `app` container | `oc -n $DEMO_NS exec deploy/<deploy> -c app -- <cmd>` |
| `call <from> <url> <id> [--no-cert]` | the demo client, run in pod `<from>` | `inpod <from> python3 /app/spiffe_client.py <url> <id>` |
| `svid <deploy>` | the SPIFFE ID, issuer and validity of that pod's SVID | a two-line Python decode, see `type svid` |

**Every manifest is a file.** Each block writes into `$M` -
`/root/spiffe-workshop-manifests/hub` or `.../sno`, set by `lab` - then
applies it. Between the two you can look, and ask the API for its verdict
without changing anything - for Lab 1's, say:

```text
cat "$M/lab01-trust-domain.yaml"
oc apply --dry-run=server -f "$M/lab01-trust-domain.yaml"
```

**Look before you touch anything:**

```bash
oc -n $ZT_NS get csv                          # zero-trust-workload-identity-manager.v1.x  Succeeded
oc get crd | grep -e spiffe -e spire          # the eight APIs you will use
oc get zerotrustworkloadidentitymanager,spireserver,spireagent,spiffecsidriver
                                              # No resources found - no trust domain yet
oc get sc                                     # lvms-vg1 (default) - where the SPIRE server's PVC will go
oc get pv                                     # spire-server-data-hub  Available - only if $SPIRE_SC is spire-local
```

---

## Part B - Hands-on

**Every `oc` command goes to whichever cluster you last named with `lab`.**
Each lab starts with a **Where:** line. Labs 1-6 are done on the hub and then
repeated on the SNO - the blocks use only variables, so the same paste works
on both - and Lab 7 needs both. Each lab ends with a **Check**.

### Lab 1. A trust domain per cluster

> **Where:** the hub, then the SNO.

```bash
lab hub
```

```bash
cat > "$M/lab01-trust-domain.yaml" <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster                  # a singleton: the API rejects any other name
spec:
  trustDomain: $TD               # the authority in every SPIFFE ID - IMMUTABLE
  clusterName: $CLUSTER_NAME     # this cluster within it - IMMUTABLE
  bundleConfigMap: spire-bundle  # where the operator publishes the trust bundle
EOF
oc apply -f "$M/lab01-trust-domain.yaml"
```

- **`trustDomain`** can never change: every SVID, every registration entry
  and every federation partner refers to it. The API enforces that - try
  `oc patch zerotrustworkloadidentitymanager cluster --type=merge -p
  '{"spec":{"trustDomain":"other.example"}}'` and read the refusal.
- **`clusterName`** is in every agent's SPIFFE ID; it is what would let two
  clusters share one trust domain without their agents colliding. Here each
  cluster has its own trust domain, so it is simply `hub` or `sno`.

**Check**

```bash
oc get zerotrustworkloadidentitymanager cluster \
   -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

`Ready=False` with a reason about operands not yet created is right: this CR
is the frame, and the operands inside it come next.

**Now the SNO:** `lab sno`, then paste the block and the check again.

### Lab 2. The SPIRE server

> **Where:** the hub, then the SNO.

```bash
lab hub
```

```bash
cat > "$M/lab02-spire-server.yaml" <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  logLevel: info
  logFormat: text
  jwtIssuer: https://oidc-discovery.$APPS   # required by the API; used only for JWT-SVIDs
  caValidity: 24h                  # the server's own signing CA
  defaultX509Validity: 1h          # every X.509-SVID, unless an entry says shorter
  defaultJWTValidity: 5m
  caKeyType: rsa-2048
  caSubject:
    country: US
    organization: mylab
    commonName: SPIRE Server CA
  persistence:                     # required and IMMUTABLE
    size: 1Gi
    accessMode: ReadWriteOnce
    storageClass: "$SPIRE_SC"
  datastore:
    databaseType: sqlite3
    connectionString: /run/spire/data/datastore.sqlite3
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 512Mi}
EOF
oc apply -f "$M/lab02-spire-server.yaml"
oc wait spireserver/cluster --for=condition=Ready --timeout=10m
```

- **`persistence`** holds the server's datastore - every registration entry,
  every attested agent - and, because the disk key manager is the default,
  the CA's private keys. Lose it and the trust domain starts over with a new
  root. It is immutable; get `$SPIRE_SC` wrong and the fix is to delete the
  SpireServer and its PVC and start again.
- **`caValidity: 24h`, `defaultX509Validity: 1h`.** SVIDs are short-lived
  because SPIFFE has no revocation: an SVID stops being trusted when it
  expires, so expiry is the revocation. Agents renew them at half-life; no
  one ever does it by hand.
- **`jwtIssuer`** is the `iss` claim the server writes into JWT-SVIDs, and
  the API requires it even if you never issue one. It is only a name here:
  nothing serves `https://oidc-discovery.$APPS`, and you will find no Route
  for it. That Route belongs to the OIDC discovery provider (a
  `SpireOIDCDiscoveryProvider` CR, whose `managedRoute` makes one with this
  host), which publishes the JWT signing keys for outside verifiers - and
  which this lab leaves out on purpose (README, "The demo").

**Check**

```bash
oc -n $ZT_NS get statefulset,pod,pvc
spire healthcheck                 # Server is healthy.
spire bundle show                 # the trust bundle: the CA certificate(s) that verify this trust domain
oc -n $ZT_NS get cm spire-bundle -o jsonpath='{.data}' | head -c 300; echo
```

`spire-bundle` is how the agents will learn the bundle to trust the server
with: the operator keeps it in step with the server.

The pod has two containers: `spire-server`, and `spire-controller-manager`,
which turns the Kubernetes objects of Lab 5 and Lab 7 into entries and
federation relationships through the server's local API socket.

**Now the SNO:** `lab sno`, then paste the block and the check again.

### Lab 3. Agents and the CSI driver

> **Where:** the hub, then the SNO.

```bash
lab hub
```

```bash
cat > "$M/lab03-agents.yaml" <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  logLevel: info
  logFormat: text
  socketPath: /run/spire/agent-sockets        # on the node: where the Workload API socket lives
  nodeAttestor:
    k8sPSATEnabled: "true"                    # prove the node with a projected SA token
  workloadAttestors:
    k8sEnabled: "true"                        # identify callers by asking the kubelet
    workloadAttestorsVerification:
      type: auto                              # verify the kubelet's certificate, the OpenShift way
  resources:
    requests: {cpu: 20m, memory: 64Mi}
    limits: {memory: 256Mi}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec:
  agentSocketPath: /run/spire/agent-sockets   # the same directory, from the driver's side
  pluginName: csi.spiffe.io                   # what a pod names in its volume
  resources:
    requests: {cpu: 10m, memory: 32Mi}
    limits: {memory: 128Mi}
EOF
oc apply -f "$M/lab03-agents.yaml"
oc wait spireagent/cluster spiffecsidriver/cluster --for=condition=Ready --timeout=10m
```

- **The agent** is a DaemonSet. No tolerations, so on the hub it runs on the
  three workers - which is where workloads run - and not the masters.
- **The CSI driver** exists so that a workload can reach the agent's socket
  *without* a `hostPath` volume, which would need a privileged SCC. The pod
  asks for an inline CSI volume; the driver bind-mounts the socket directory
  into it. The operator registers the driver with the `restricted`
  ephemeral-volume profile, so an ordinary restricted pod may use it.

**Check**

```bash
oc -n $ZT_NS get ds
spire agent list                  # Found 3 attested agents (1 on the SNO)
oc get nodes -o custom-columns=NAME:.metadata.name,UID:.metadata.uid
oc get csidriver csi.spiffe.io -o jsonpath='{.metadata.labels}{"\n"}'
```

Each agent's SPIFFE ID is
`spiffe://$TD/spire/agent/k8s_psat/$CLUSTER_NAME/<uid>` - match the UIDs to
the node list. That is node attestation, finished: the server now knows, for
each agent, which node it speaks for.

**Now the SNO:** `lab sno`, then paste the block and the check again.

### Lab 4. Workloads with no identity

> **Where:** the hub, then the SNO.

Three workloads, before any registration exists. They can all reach the
Workload API - and it has nothing for any of them yet.

```bash
lab hub
```

The namespace, one service account per workload (the SPIFFE ID will name
it), and the configuration:

```bash
cat > "$M/lab04-namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $DEMO_NS
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: echo-server, namespace: $DEMO_NS}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: client, namespace: $DEMO_NS}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: intruder, namespace: $DEMO_NS}
---
# spiffe-helper: fetch the SVID over the Workload API socket, write it to
# /svid, and rewrite it on every rotation.
apiVersion: v1
kind: ConfigMap
metadata: {name: spiffe-helper, namespace: $DEMO_NS}
data:
  helper.conf: |
    agent_address = "/spiffe-workload-api/spire-agent.sock"
    cert_dir = "/svid"
    svid_file_name = "svid.pem"
    svid_key_file_name = "svid_key.pem"
    svid_bundle_file_name = "svid_bundle.pem"
    include_federated_domains = true
    daemon_mode = true
---
# Authorisation, as data: the SPIFFE IDs the echo server lets in.
apiVersion: v1
kind: ConfigMap
metadata: {name: echo-allowed-ids, namespace: $DEMO_NS}
data:
  allowed-ids: |
    spiffe://$TD/ns/$DEMO_NS/sa/client
EOF
oc create configmap spiffe-demo-app -n $DEMO_NS \
   --from-file=$APP_DIR/echo_server.py --from-file=$APP_DIR/spiffe_client.py \
   --dry-run=client -o yaml > "$M/lab04-app.yaml"
oc apply -f "$M/lab04-namespace.yaml" -f "$M/lab04-app.yaml"
```

The app is two short standard-library Python programs; read them -
[echo_server.py](roles/setup-spiffe-spire/files/echo_server.py) and
[spiffe_client.py](roles/setup-spiffe-spire/files/spiffe_client.py). The
server demands a client certificate that chains to its trust bundle, then
checks the client's SPIFFE ID against `allowed-ids`. The client checks the
server's SPIFFE ID and never a hostname.

The echo server - a Service, a passthrough Route (TLS goes end to end, the
router only reads the SNI), and the Deployment:

```bash
cat > "$M/lab04-echo-server.yaml" <<EOF
apiVersion: v1
kind: Service
metadata: {name: echo-server, namespace: $DEMO_NS}
spec:
  selector: {app: echo-server}
  ports:
    - {name: https, port: 8443, targetPort: 8443}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: echo-server, namespace: $DEMO_NS}
spec:
  host: echo-$DEMO_NS.$APPS
  to: {kind: Service, name: echo-server, weight: 100}
  port: {targetPort: https}
  tls: {termination: passthrough, insecureEdgeTerminationPolicy: None}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo-server, namespace: $DEMO_NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: echo-server}}
  template:
    metadata:
      labels:
        app: echo-server
        $LABEL: "true"                 # what Lab 5's registration will select
    spec:
      serviceAccountName: echo-server
      containers:
        - name: spiffe-helper
          image: $HELPER_IMAGE
          args: ["-config", "/etc/spiffe-helper/helper.conf"]
          securityContext: &restricted
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
          volumeMounts:
            - {name: spiffe-workload-api, mountPath: /spiffe-workload-api, readOnly: true}
            - {name: svid, mountPath: /svid}
            - {name: helper-config, mountPath: /etc/spiffe-helper, readOnly: true}
        - name: app
          image: $PY_IMAGE
          command: ["python3", "/app/echo_server.py"]
          env: [{name: SVID_DIR, value: /svid}, {name: PYTHONUNBUFFERED, value: "1"}]
          securityContext: *restricted
          ports: [{name: https, containerPort: 8443}]
          readinessProbe: {tcpSocket: {port: 8443}, periodSeconds: 5}   # it listens only once it has an SVID
          volumeMounts:
            - {name: svid, mountPath: /svid, readOnly: true}
            - {name: app, mountPath: /app, readOnly: true}
            - {name: allowed, mountPath: /config, readOnly: true}
      volumes:
        - name: spiffe-workload-api    # the agent's socket, through the CSI driver
          csi: {driver: csi.spiffe.io, readOnly: true}
        - {name: svid, emptyDir: {medium: Memory}}          # the key never touches a disk
        - {name: helper-config, configMap: {name: spiffe-helper}}
        - {name: app, configMap: {name: spiffe-demo-app}}
        - {name: allowed, configMap: {name: echo-allowed-ids}}
EOF
oc apply -f "$M/lab04-echo-server.yaml"
```

`&restricted` / `*restricted` is a YAML anchor: the same security context
for both containers, written once.

The client and the intruder are the same pod with a shell and no server in
it. The **only** difference is the label. A function writes each one:

```bash
demo_pod() {   # demo_pod <name> [registered]
    local name=$1 label=""
    [ "${2:-}" = registered ] && label="$LABEL: \"true\""
    cat > "$M/lab04-$name.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $name, namespace: $DEMO_NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: $name}}
  template:
    metadata:
      labels:
        app: $name
        $label
    spec:
      serviceAccountName: $name
      containers:
        - name: spiffe-helper
          image: $HELPER_IMAGE
          args: ["-config", "/etc/spiffe-helper/helper.conf"]
          securityContext: &restricted
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
          volumeMounts:
            - {name: spiffe-workload-api, mountPath: /spiffe-workload-api, readOnly: true}
            - {name: svid, mountPath: /svid}
            - {name: helper-config, mountPath: /etc/spiffe-helper, readOnly: true}
        - name: app
          image: $PY_IMAGE
          command: ["sleep", "infinity"]
          env: [{name: SVID_DIR, value: /svid}]
          securityContext: *restricted
          volumeMounts:
            - {name: svid, mountPath: /svid, readOnly: true}
            - {name: app, mountPath: /app, readOnly: true}
      volumes:
        - name: spiffe-workload-api
          csi: {driver: csi.spiffe.io, readOnly: true}
        - {name: svid, emptyDir: {medium: Memory}}
        - {name: helper-config, configMap: {name: spiffe-helper}}
        - {name: app, configMap: {name: spiffe-demo-app}}
EOF
    oc apply -f "$M/lab04-$name.yaml"
}
demo_pod client registered
demo_pod intruder
```

**Check**

```bash
oc -n $DEMO_NS get pods
```

All three Running - and `echo-server` at `1/2`, not Ready: its readiness
probe waits for it to listen, and it will not listen without an SVID. Ask
why:

```bash
oc -n $DEMO_NS logs deploy/client -c spiffe-helper --tail=3     # ... no identity issued
oc -n $DEMO_NS logs deploy/echo-server -c app --tail=2          # waiting for an SVID
inpod client ls -la /svid                                       # empty
```

`no identity issued` is the agent answering. The pod reached the Workload
API through the CSI volume, the agent attested it (it knows exactly which
pod asked), and found no registration entry for it. Identity is not handed to
whatever can reach the socket.

**Now the SNO:** `lab sno`, then paste the blocks again, including the
`demo_pod` function and its two calls.

### Lab 5. Register them

> **Where:** the hub, then the SNO.

```bash
lab hub
```

First, the mistake everyone makes once. A `ClusterSPIFFEID` without its
class:

```bash
cat > "$M/lab05-clusterspiffeid.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: $DEMO_NS
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: $DEMO_NS
  podSelector:
    matchLabels:
      $LABEL: "true"
EOF
oc apply -f "$M/lab05-clusterspiffeid.yaml"
sleep 20
oc get clusterspiffeid $DEMO_NS -o jsonpath='{.status}{"\n"}'   # empty
spire entry show                                                 # Found 0 entries
```

Accepted by the API, ignored by the controller: the operator runs
spire-controller-manager with `watchClassless: false`, and this object has no
class. Nothing says so. Add it:

```bash
sed -i "s|^spec:|spec:\n  className: $CLASS|" "$M/lab05-clusterspiffeid.yaml"
cat "$M/lab05-clusterspiffeid.yaml"
oc apply -f "$M/lab05-clusterspiffeid.yaml"
```

- **`spiffeIDTemplate`** is rendered per pod by spire-controller-manager (the
  `{{ }}` are its Go templates, not your shell's). Service account is a good
  identity: it is what a workload *is*, it is shared by its replicas, and
  changing it takes an RBAC-level decision.
- **`namespaceSelector` and `podSelector`** decide who is registered.
  `intruder` does not carry the label.
- One entry is created **per pod**, parented to the agent on that pod's node,
  with the pod's UID among its selectors - so only that pod, through that
  agent, can ever be issued it.

**Check**

```bash
oc get clusterspiffeid $DEMO_NS -o jsonpath='{.status.stats}{"\n"}'    # podsSelected 2, entriesToSet 2
spire entry show -spiffeID spiffe://$TD/ns/$DEMO_NS/sa/client          # Parent ID: an agent; selectors k8s:pod-uid ...
spire entry show -spiffeID spiffe://$TD/ns/$DEMO_NS/sa/intruder        # Found 0 entries
oc -n $DEMO_NS get pods                                               # echo-server 2/2 now, within a minute
svid client                                                            # URI:spiffe://hub.mylab.com/ns/spiffe-demo/sa/client, 1h
```

Match the entry's `Parent ID` to `spire agent list`, and its `k8s:pod-uid`
selector to `oc -n $DEMO_NS get pod -l app=client -o jsonpath='{.items[0].metadata.uid}'`.
The intruder's helper keeps retrying, and keeps being told `no identity issued`.

**Now the SNO:** `lab sno`, then paste the corrected ClusterSPIFFEID (the
`sed` line included) and the check.

### Lab 6. Mutual TLS, and who gets refused

> **Where:** the hub. Repeat on the SNO if you like; Lab 7 only needs the
> workloads, which both clusters have.

```bash
lab hub
call client https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server
```

```text
server is spiffe://hub.mylab.com/ns/spiffe-demo/sa/echo-server - verified against the trust bundle
HTTP 200: hello spiffe://hub.mylab.com/ns/spiffe-demo/sa/client, this is spiffe://hub.mylab.com/ns/spiffe-demo/sa/echo-server
```

Both directions were checked: the client verified the server's SVID against
its bundle and matched its SPIFFE ID; the server verified the client's and
found it on its allowlist. No password, no Secret, no certificate anyone
issued by hand - and both certificates will have been replaced within the
hour without anyone noticing.

**The intruder has nothing to present:**

```bash
call intruder https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server
# NO SVID: nothing in /svid ...                                                     (exit 4)
call intruder https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server --no-cert
# REFUSED: TLSV13_ALERT_CERTIFICATE_REQUIRED                                        (exit 2)
oc -n $DEMO_NS logs deploy/echo-server -c app --tail=3
# REFUSED 10.x.x.x: TLS handshake failed: ... peer did not return a certificate
```

It is the same image, in the same namespace, on the same network, reaching
the same Service. The one thing it lacks is a registration, and that is
enough.

**Authenticated is not authorised.** Take the client off the allowlist:

```bash
cat > "$M/lab06-allowed-none.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: echo-allowed-ids, namespace: $DEMO_NS}
data:
  allowed-ids: |
    # nobody
EOF
oc apply -f "$M/lab06-allowed-none.yaml"
until call client https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server | grep -q 403; do sleep 10; done
call client https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server
# HTTP 403: forbidden: spiffe://hub.mylab.com/ns/spiffe-demo/sa/client is not allowed by ...
oc apply -f "$M/lab04-namespace.yaml"          # the allowlist as it was
```

(The `until` loop is the kubelet refreshing the mounted ConfigMap, a minute
or so.) The handshake succeeded - the server knows exactly who is calling -
and said no. SPIFFE answers *who*; what that identity may do is still yours
to decide.

**The client refuses too.** Tell it to expect a different server:

```bash
call client https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/someone-else
# WRONG SERVER: expected spiffe://.../sa/someone-else, it presented [...echo-server]. Not sending anything.
```

**Hostnames do not matter.** The same call through the Route - via the
helper's DNS and the router, as anything outside the cluster would - works
unchanged, because nothing checks the name:

```bash
call client https://echo-$DEMO_NS.$APPS/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server
```

**Check**

```bash
call client https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server; echo "exit $?"   # HTTP 200, exit 0
```

### Lab 7. Federate the two trust domains

> **Where:** both, in the order given. Every block says which.

**Before: the hub cannot trust the SNO.**

```bash
lab hub
call client https://echo-$DEMO_NS.$PEER_APPS/ spiffe://$PEER_TD/ns/$DEMO_NS/sa/echo-server
# SERVER NOT TRUSTED: ... Its CA is not in /svid/svid_bundle.pem   (exit 3)
```

The network path is fine - the call reached the SNO's router and its echo
server. The hub's client refused the SNO's certificate, because nothing in
its bundle signs for `sno.mylab.com`.

**7a. Publish a bundle endpoint, on each cluster.** A patch to the
SpireServer, and a passthrough Route to it under `*.apps`:

```bash
lab hub
```

```bash
cat > "$M/lab07-server-federation.yaml" <<EOF
spec:
  federation:
    bundleEndpoint:
      profile: https_spiffe      # authenticate the endpoint by SPIFFE ID
      refreshHint: 300           # peers re-fetch every 5 minutes
    managedRoute: "false"        # the operator's own would be federation.$TD - not in DNS
EOF
oc patch spireserver cluster --type=merge --patch-file="$M/lab07-server-federation.yaml"

cat > "$M/lab07-federation-route.yaml" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: spire-federation, namespace: $ZT_NS}
spec:
  host: spire-federation.$APPS
  to: {kind: Service, name: spire-server, weight: 100}
  port: {targetPort: federation}
  tls: {termination: passthrough, insecureEdgeTerminationPolicy: None}
EOF
oc apply -f "$M/lab07-federation-route.yaml"
oc -n $ZT_NS rollout status statefulset/spire-server --timeout=5m
oc get spireserver cluster -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
curl -sk https://spire-federation.$APPS/ | head -c 200; echo
```

Do not `oc wait` for `Ready` here: from now on it stays **False** on a
healthy server. With `managedRoute: "false"` the operator records
`RouteAvailable=False FederationRouteDisabled`, and its `Ready` roll-up
counts any False condition as a failure. Every *other* condition in that
list should be True; those two False lines are expected. (The lab's own
checks read the conditions the same way.)

The last line is the bundle, as JSON, fetched from the lab host through the
helper and the router: the bundle is public, only the endpoint's *identity*
matters.

- **`https_spiffe`**: the endpoint serves TLS with the SPIRE server's own
  SVID, `spiffe://$TD/spire/server`. A peer checks that SPIFFE ID and that the
  certificate chains to the bundle it already holds for `$TD`. The hostname
  is only for the router's SNI - which is why a Route under `*.apps` does as
  well as any.
- **Passthrough**, because a router that terminated TLS would present its own
  certificate and fail exactly that check.

Then the same on the SNO: `lab sno`, and paste the block again.

**7b. Exchange the bootstrap bundles.** To authenticate the hub's endpoint
the first time, the SNO needs the hub's CA - which it would otherwise only
learn *from* that endpoint. So it is copied once, out of band:

```bash
lab hub; spire bundle show -format spiffe > $WS_MANIFESTS/hub.bundle.json
lab sno; spire bundle show -format spiffe > $WS_MANIFESTS/sno.bundle.json
head -c 300 $WS_MANIFESTS/hub.bundle.json; echo
```

The SPIFFE bundle format is a JWKS: the X.509 CAs (`"use": "x509-svid"`) and
the JWT signing keys (`"use": "jwt-svid"`), plus a sequence number and a
refresh hint.

**7c. Declare the federation, on each cluster.** Paste this once after
`lab hub` and once after `lab sno` - `$PEER` and `$PEER_TD` follow `lab`:

```bash
cat > "$M/lab07-federate-$PEER_TD.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: $PEER_TD
spec:
  className: $CLASS
  trustDomain: $PEER_TD
  bundleEndpointURL: https://spire-federation.$PEER_APPS
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://$PEER_TD/spire/server
  trustDomainBundle: |
$(sed 's/^/    /' "$WS_MANIFESTS/$PEER.bundle.json")
EOF
oc apply -f "$M/lab07-federate-$PEER_TD.yaml"
```

```bash
lab hub        # then paste the block above
lab sno        # then paste it again
```

- **`trustDomainBundle`** is used once, when the relationship is created.
  From then on the server refreshes the peer's bundle from
  `bundleEndpointURL` - so when the peer's CA rotates, the new one arrives on
  its own, and this stale copy never overwrites it.
- **`className`** again: without it, nothing happens, silently.

**Check, on each cluster**

```bash
spire federation show -trustDomain $PEER_TD
spire bundle list -id spiffe://$PEER_TD                  # the peer's CA, held here
spire federation refresh -id $PEER_TD                    # Bundle refreshed
```

`federation refresh` makes the server fetch the peer's bundle *now*, over the
Route. It succeeding proves the helper's DNS, the peer's router, the
passthrough and the `https_spiffe` authentication together. If it fails, the
message names which.

**7d. Give the workloads the peer's CA, on each cluster.** A server holding
a foreign bundle is not enough: a workload is only handed it if its
registration federates with that trust domain.

```bash
cp "$M/lab05-clusterspiffeid.yaml" "$M/lab07-clusterspiffeid.yaml"
cat >> "$M/lab07-clusterspiffeid.yaml" <<EOF
  federatesWith:
    - $PEER_TD
EOF
oc apply -f "$M/lab07-clusterspiffeid.yaml"
until [ "$(inpod client grep -c 'BEGIN CERTIFICATE' /svid/svid_bundle.pem)" -ge 2 ]; do sleep 10; done
inpod client grep -c 'BEGIN CERTIFICATE' /svid/svid_bundle.pem    # 2: our CA and the peer's
```

**7e. Let the peer's client in, on each cluster.** Authorisation is still
the echo server's own decision:

```bash
cat > "$M/lab07-allowed.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: echo-allowed-ids, namespace: $DEMO_NS}
data:
  allowed-ids: |
    spiffe://$TD/ns/$DEMO_NS/sa/client
    spiffe://$PEER_TD/ns/$DEMO_NS/sa/client
EOF
oc apply -f "$M/lab07-allowed.yaml"
```

Do 7d and 7e after `lab hub`, then again after `lab sno`.

**Check: across the boundary, both ways**

```bash
lab hub
call client https://echo-$DEMO_NS.$PEER_APPS/ spiffe://$PEER_TD/ns/$DEMO_NS/sa/echo-server
# HTTP 200: hello spiffe://hub.mylab.com/ns/spiffe-demo/sa/client, this is spiffe://sno.mylab.com/ns/spiffe-demo/sa/echo-server
lab sno
call client https://echo-$DEMO_NS.$PEER_APPS/ spiffe://$PEER_TD/ns/$DEMO_NS/sa/echo-server
# HTTP 200: hello spiffe://sno.mylab.com/ns/spiffe-demo/sa/client, this is spiffe://hub.mylab.com/ns/spiffe-demo/sa/echo-server
```

(The allowlist ConfigMap takes a minute to reach the pod; a `403` straight
after 7e is that.) Two authorities, neither signing for the other, and a
workload in each proves who it is to a workload in the other.

---

## Explore - Optional

**X1. Expiry is the revocation.** Take the registration away from the running
client, and it keeps working - for a while:

```bash
lab hub
POD=$(oc -n $DEMO_NS get pod -l app=client -o name)
oc -n $DEMO_NS label $POD $LABEL-                 # the pod no longer matches
spire entry show -spiffeID spiffe://$TD/ns/$DEMO_NS/sa/client   # Found 0 entries, within seconds
call client https://echo-server:8443/ spiffe://$TD/ns/$DEMO_NS/sa/echo-server   # still HTTP 200
svid client                                        # notAfter: that is how long
oc -n $DEMO_NS rollout restart deploy/client       # a new pod, labelled from the template
```

The SVID already issued stays valid until it expires; nothing can recall it.
That is the whole reason SVIDs live an hour and not a year.

**X2. Watch rotation.** Shorten the demo's SVIDs to five minutes, and watch
the certificate change under a running pod:

```bash
sed 's|^spec:|spec:\n  ttl: 5m|' "$M/lab07-clusterspiffeid.yaml" > "$M/x2-clusterspiffeid.yaml"
oc apply -f "$M/x2-clusterspiffeid.yaml"
for i in 1 2 3 4 5 6; do svid client | grep -e notBefore -e notAfter; sleep 60; done
oc apply -f "$M/lab07-clusterspiffeid.yaml"       # back to the default hour
```

The agent renews at half-life; spiffe-helper rewrites `/svid`; the echo
server reads the files on every connection. Nothing restarts.

**X3. What the agent sees.** Every selector the entry demands is something
the agent learned from the kubelet about the calling process:

```bash
spire entry show -spiffeID spiffe://$TD/ns/$DEMO_NS/sa/echo-server
oc -n $ZT_NS logs ds/spire-agent --tail=50 | grep -i -e attest -e "no identity"
```

**X4. A federated bundle, rotating.** `spire bundle list -id spiffe://$PEER_TD`
on one cluster shows the peer's CAs. The CA lives 24 hours; a new one is
prepared ahead of time and published in the bundle. Compare the list over a
day and watch the new CA arrive by itself, fetched from the peer's endpoint -
the bootstrap copy in the `ClusterFederatedTrustDomain` never changes.

---

## Part C - Optional: SPIFFE in a real application

The demo in Part B was written *for* SPIFFE. Online Boutique was not: eleven
services from Google's microservices demo, in five languages, talking
plaintext gRPC, none of which presents or checks a certificate. You register
every one of them, then put one hop - `checkoutservice → paymentservice` - under
mutual TLS without touching a line of their code, and finally send the hub's
payments to the SNO's paymentservice, across the two trust domains.

The tool is [ghostunnel](https://github.com/ghostunnel/ghostunnel), a small TLS
proxy that fetches its certificate and trust bundle straight from the
Workload API socket - no spiffe-helper, no files - and checks the peer's SPIFFE
ID itself. The application is used exactly as
[sadiquepp/openshift](https://github.com/sadiquepp/openshift/tree/main/test-workloads/online-boutique)
ships it; everything SPIFFE is a kustomize overlay you write on top.

About 1.4 GiB of memory per cluster, most of it the application and its load
generator, which places orders continuously so the hop always has traffic.

### C1. The application, as shipped

> **Where:** the hub, then the SNO.

```bash
lab hub
[ -d "$BQ_CLONE/.git" ] || git clone "$BQ_REPO" "$BQ_CLONE"
git -C "$BQ_CLONE" checkout -q "$BQ_REF"
oc kustomize "$BQ_SRC/overlays/default" > "$M/c1-boutique.yaml"
oc apply -f "$M/c1-boutique.yaml"
oc -n $BQ_NS rollout status deploy/frontend --timeout=15m
oc -n $BQ_NS get route frontend -o jsonpath='https://{.spec.host}{"\n"}'   # a shop, in your browser
```

Now the point of this part. Part B's `intruder` - no registration, no SVID,
no identity of any kind - can open a connection to the service that takes
the payments:

```bash
inpod intruder python3 -c "import socket; socket.create_connection(('paymentservice.$BQ_NS.svc', 50051), 5); print('connected')"
# connected
```

Nothing in the application would stop it asking for a charge. Identity is not
in the picture at all.

**Now the SNO:** `lab sno`, and paste both blocks again. C5 needs a
paymentservice there.

### C2. Register every service

> **Where:** the hub, then the SNO.

```bash
lab hub
cat > "$M/c2-clusterspiffeid.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: $BQ_NS
spec:
  className: $CLASS
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: $BQ_NS
  federatesWith:              # Lab 7 must be done: naming an unknown trust domain fails the entries
    - $PEER_TD
EOF
oc apply -f "$M/c2-clusterspiffeid.yaml"
```

No `podSelector`: every pod in the namespace. Each service already has its own
ServiceAccount, so each gets a distinct identity for free.

**Check**

```bash
oc get clusterspiffeid $BQ_NS -o jsonpath='{.status.stats}{"\n"}'     # entriesToSet = the pod count
spire entry show | grep "SPIFFE ID" | grep $BQ_NS | sort -u
inpod intruder python3 -c "import socket; socket.create_connection(('paymentservice.$BQ_NS.svc', 50051), 5); print('connected')"
# still: connected
```

Twelve identities - and nothing changed. The services were not asked to fetch
an SVID, so none did, and none checks anyone else's. Registration makes an
identity *available*; using it is the workload's job.

**Now the SNO:** `lab sno`, and paste again.

### C3. Put the payment hop under mTLS

> **Where:** the hub, then the SNO.

Four small files, in an overlay directory next to your other manifests:

```bash
lab hub
mkdir -p "$M/boutique"
```

**paymentservice**: the app moves to port 50052, where only ghostunnel - in
the same pod, over `localhost` - is meant to reach it, and a ghostunnel
*server* takes the Service's traffic on 8443. It requires a
client SVID, and admits two SPIFFE IDs: this cluster's checkoutservice, and
the other cluster's (for C5 - inert until then, since that certificate does
not even chain yet).

```bash
cat > "$M/boutique/payment-server.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paymentservice
spec:
  template:
    spec:
      containers:
        - name: server
          env:
            - {name: PORT, value: "50052"}
          readinessProbe: {grpc: {port: 50052}}
          livenessProbe: {grpc: {port: 50052}}
        - name: ghostunnel
          image: $GHOSTUNNEL_IMAGE
          args:
            - server
            - --listen=0.0.0.0:8443
            - --target=localhost:50052
            - --use-workload-api-addr=unix:///spiffe-workload-api/spire-agent.sock
            - --allow-uri=spiffe://$TD/ns/$BQ_NS/sa/checkoutservice
            - --allow-uri=spiffe://$PEER_TD/ns/$BQ_NS/sa/checkoutservice
            - --status=0.0.0.0:8081
          ports:
            - {name: mtls, containerPort: 8443}
            - {name: status, containerPort: 8081}
          readinessProbe:
            httpGet: {path: /_status, port: 8081}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
          volumeMounts:
            - {name: spiffe-workload-api, mountPath: /spiffe-workload-api, readOnly: true}
      volumes:
        - name: spiffe-workload-api
          csi: {driver: csi.spiffe.io, readOnly: true}
EOF
```

**checkoutservice**: payments go to a ghostunnel *client* on
`localhost:50051`, which dials the paymentservice with this pod's SVID and
refuses any server that is not the paymentservice:

```bash
cat > "$M/boutique/checkout-client.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkoutservice
spec:
  template:
    spec:
      containers:
        - name: server
          env:
            - {name: PAYMENT_SERVICE_ADDR, value: "localhost:50051"}
        - name: ghostunnel
          image: $GHOSTUNNEL_IMAGE
          args:
            - client
            - --listen=localhost:50051
            - --target=paymentservice:50051
            - --use-workload-api-addr=unix:///spiffe-workload-api/spire-agent.sock
            - --verify-uri=spiffe://$TD/ns/$BQ_NS/sa/paymentservice
            - --status=0.0.0.0:8081
          ports:
            - {name: status, containerPort: 8081}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
          volumeMounts:
            - {name: spiffe-workload-api, mountPath: /spiffe-workload-api, readOnly: true}
      volumes:
        - name: spiffe-workload-api
          csi: {driver: csi.spiffe.io, readOnly: true}
EOF
```

**The NetworkPolicy** - without which all of the above is decoration. The
paymentservice app still listens on every interface; anything that can reach
the pod IP could dial `:50052` and walk around ghostunnel. Only the ghostunnel
ports get in:

```bash
cat > "$M/boutique/networkpolicy.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: paymentservice-mtls-only
  namespace: $BQ_NS
spec:
  podSelector:
    matchLabels: {app: paymentservice}
  policyTypes: [Ingress]
  ingress:
    - ports:
        - {protocol: TCP, port: 8443}
        - {protocol: TCP, port: 8081}
EOF
```

**The overlay** ties it together on top of the application as shipped, and
re-points the Service - callers still dial `paymentservice:50051`, and land on
ghostunnel. The Route is for C5. kustomize refuses an absolute path to a base,
hence `realpath --relative-to`:

```bash
cat > "$M/boutique/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $(realpath --relative-to="$M/boutique" "$BQ_SRC/overlays/default")
  - networkpolicy.yaml
  - payment-route.yaml
patches:
  - path: payment-server.yaml
  - path: checkout-client.yaml
  - target: {kind: Service, name: paymentservice}
    patch: |
      - {op: test, path: /spec/ports/0/port, value: 50051}
      - {op: replace, path: /spec/ports/0/targetPort, value: 8443}
  - target: {kind: Deployment, name: paymentservice}
    patch: |
      - {op: test, path: /spec/template/spec/containers/0/name, value: server}
      - {op: replace, path: /spec/template/spec/containers/0/ports, value: [{containerPort: 50052}]}
EOF
cat > "$M/boutique/payment-route.yaml" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: paymentservice, namespace: $BQ_NS}
spec:
  host: payment-$BQ_NS.$APPS
  to: {kind: Service, name: paymentservice, weight: 100}
  port: {targetPort: 8443}
  tls: {termination: passthrough, insecureEdgeTerminationPolicy: None}
EOF
oc kustomize "$M/boutique" > "$M/c3-boutique-spiffe.yaml"
diff "$M/c1-boutique.yaml" "$M/c3-boutique-spiffe.yaml" | head -80   # exactly what SPIFFE changed
oc apply -f "$M/c3-boutique-spiffe.yaml"
oc -n $BQ_NS rollout status deploy/paymentservice --timeout=10m
oc -n $BQ_NS rollout status deploy/checkoutservice --timeout=10m
```

**Now the SNO:** `lab sno`, and paste every block of C3 again - `$TD`,
`$PEER_TD` and `$APPS` follow `lab`.

### C4. Who gets through now

> **Where:** the hub (the SNO behaves the same).

```bash
lab hub
bq_status
# {"ok":true,"status":"ok","backend_ok":true,"backend_status":"ok",...}
oc -n $BQ_NS logs deploy/checkoutservice -c ghostunnel --since=5m | grep -c 'opening pipe'   # orders, paying
```

`backend_ok` is checkoutservice's ghostunnel reporting that it just completed a
full mTLS handshake with the paymentservice and found
`spiffe://$TD/ns/$BQ_NS/sa/paymentservice` in its certificate. The load
generator's orders are going through the tunnel.

**The intruder, plaintext, as in C1:** the TCP connection still opens -
ghostunnel is listening - but it now speaks only TLS, and wants a certificate:

```bash
call intruder https://paymentservice.$BQ_NS.svc:50051/ spiffe://$TD/ns/$BQ_NS/sa/paymentservice --no-cert
# REFUSED: TLSV13_ALERT_CERTIFICATE_REQUIRED
```

**A registered workload with a perfect SVID - that is not checkoutservice:**

```bash
call client https://paymentservice.$BQ_NS.svc:50051/ spiffe://$TD/ns/$BQ_NS/sa/paymentservice
# server is spiffe://hub.mylab.com/ns/online-boutique/sa/paymentservice - verified against the trust bundle
# REFUSED: ...
oc -n $BQ_NS logs deploy/paymentservice -c ghostunnel --since=2m | grep 'TLS handshake'
# error on TLS handshake from 10.x.x.x: ... unauthorized: invalid principal, or principal not allowed
```

The client verified the paymentservice - same trust domain, valid chain, the
right SPIFFE ID - and the paymentservice looked at the client's and said no.
Authentication succeeded in both directions; authorisation did not.

**Around ghostunnel, straight to the app:**

```bash
IP=$(oc -n $BQ_NS get pod -l app=paymentservice -o jsonpath='{.items[0].status.podIP}')
inpod client python3 -c "import socket; socket.create_connection(('$IP', 50052), 5)"   # TimeoutError
inpod client python3 -c "import socket; socket.create_connection(('$IP', 8443), 5); print('connected')"
```

The same IP answers on 8443 and not on 50052: the NetworkPolicy, not the
network.

### C5. Pay in the other trust domain

> **Where:** the hub, after C1-C3 on both clusters.

The SNO's paymentservice already admits `spiffe://hub.mylab.com/.../checkoutservice`
(C3 listed it), both namespaces' identities federate (C2), and the SNO's
paymentservice has a passthrough Route. Only the hub's checkoutservice has to
be told where to go - and whom to expect:

```bash
lab hub
sed -e "s|--target=paymentservice:50051|--target=payment-$BQ_NS.$PEER_APPS:443|" \
    -e "s|--verify-uri=spiffe://$TD/|--verify-uri=spiffe://$PEER_TD/|" \
    "$M/boutique/checkout-client.yaml" > "$M/boutique/checkout-client.yaml.new"
mv "$M/boutique/checkout-client.yaml.new" "$M/boutique/checkout-client.yaml"
grep -e target -e verify-uri "$M/boutique/checkout-client.yaml"
oc kustomize "$M/boutique" > "$M/c5-boutique-remote-payments.yaml"
oc apply -f "$M/c5-boutique-remote-payments.yaml"
oc -n $BQ_NS rollout status deploy/checkoutservice --timeout=5m
bq_status
# backend_ok: true - a handshake with spiffe://sno.mylab.com/ns/online-boutique/sa/paymentservice
```

Watch the payments arrive on the other cluster:

```bash
lab sno
oc -n $BQ_NS logs deploy/paymentservice -c ghostunnel -f --since=1m | grep 'opening pipe'
# ctrl-c when you have seen enough
```

Some of those connections now come from the hub, through the SNO's router: a
checkout in `hub.mylab.com` proving who it is to a payment service in
`sno.mylab.com`, each checking the other against a CA it holds only because
the two SPIRE servers exchanged bundles in Lab 7.

To put the hub's payments back on the hub, reverse the `sed`, rebuild and
apply - or `./build-lab.sh --only boutique --cluster hub`.

**Check**

```bash
cd /root/hcp-backup-restore/spiffe-spire
./build-lab.sh --workshop --only boutique-verify     # both clusters, the same asserts as the full build
```

---

## Part D - Optional: the same application on Service Mesh

Part C put one hop under mTLS with a sidecar pair you wrote yourself. A
service mesh does that for every hop - but by default the mesh is its own
certificate authority: istiod signs every Envoy's certificate, with a
SPIFFE-shaped name, from a CA that has nothing to do with SPIRE. Here you
make SPIRE that CA. Every Envoy fetches its certificate from the SPIRE agent,
through the same CSI driver your demo pods use, and the payment allowlist
becomes an `AuthorizationPolicy` on a SPIFFE ID.

Red Hat supports this from Zero Trust Workload Identity Manager 1.1.0, with
OpenShift Service Mesh 3 in sidecar mode. Ambient mode is not an option:
its node proxy, ztunnel, can only get certificates from istiod's
certificate-signing API, never from a SPIRE socket.

A separate namespace, `$MESH_NS`, so Part C's `$BQ_NS` is untouched. About
2.8 GiB of memory on the hub: istiod, an Envoy in every pod, and the
application again. Do it on the hub; the SNO works the same way if it has
room (README "Memory budget").

### D1. The operator

> **Where:** the hub.

Service Mesh 3 is an AllNamespaces operator, so it goes in
`openshift-operators`, under the OperatorGroup that namespace already has.
If `oc get subscriptions.operators.coreos.com -A | grep $MESH_PKG` shows one
already, skip this block. The label marks it as yours, so that cleanup
removes it.

```bash
lab hub
CHANNEL=$(oc get packagemanifests -n openshift-marketplace -l catalog=$CATALOG \
          -o jsonpath="{.items[?(@.metadata.name=='$MESH_PKG')].status.defaultChannel}")
echo "channel: $CHANNEL"
cat > "$M/d1-mesh-operator.yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $MESH_PKG
  namespace: $MESH_OP_NS
  labels:
    $MESH_OWNER: spiffe-spire
spec:
  channel: $CHANNEL
  name: $MESH_PKG
  source: $CATALOG
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
oc apply -f "$M/d1-mesh-operator.yaml"
until oc wait --for=condition=Established crd/istios.sailoperator.io --timeout=10s 2>/dev/null; do sleep 10; done
```

### D2. A mesh whose CA is SPIRE

> **Where:** the hub.

Two custom resources. `IstioCNI` sets up each pod's traffic redirection from
a DaemonSet, so pods need no privileges. `Istio` is the control plane, and
these parts of it are the point of this part:

- **`trustDomain: $TD`**: the mesh names workloads
  `spiffe://<trustDomain>/ns/<ns>/sa/<sa>`, which is exactly the ID your
  ClusterSPIFFEIDs have issued since Lab 5. Different trust domains, and
  every policy would name identities that no certificate carries.
- **`WORKLOAD_IDENTITY_SOCKET_FILE`**: when the sidecar's pilot-agent finds a
  socket of that name in `/run/secrets/workload-spiffe-uds`, it points Envoy
  straight at it for certificates (SDS) instead of asking istiod. That
  socket is the SPIRE agent's Workload API.
- **The `spire` template** puts it there: a `csi.spiffe.io` volume, the same
  one your demo pods mount, added to `istio-proxy`. It patches `istio-proxy`
  under `initContainers` because the proxy runs as a *native sidecar*, an
  init container that keeps running. That way the app's own init containers
  are already in the mesh, which the load generator needs: its first step is
  a request to the frontend.
- **`spireGateway`**: the same for gateways, whose proxy is an ordinary
  container.

```bash
cat > "$M/d2-mesh-istio.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $MESH_CNI_NS
---
apiVersion: v1
kind: Namespace
metadata:
  name: $MESH_CP_NS
---
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
  labels:
    $MESH_OWNER: spiffe-spire
spec:
  namespace: $MESH_CNI_NS
---
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  labels:
    $MESH_OWNER: spiffe-spire
spec:
  namespace: $MESH_CP_NS
  updateStrategy:
    type: InPlace
  values:
    meshConfig:
      trustDomain: $TD
      defaultConfig:
        proxyMetadata:
          WORKLOAD_IDENTITY_SOCKET_FILE: spire-agent.sock
    pilot:
      env:
        ENABLE_NATIVE_SIDECARS: "true"
      resources: {requests: {cpu: 50m, memory: 256Mi}, limits: {memory: 1Gi}}
    global:
      proxy:
        resources: {requests: {cpu: 10m, memory: 48Mi}, limits: {memory: 256Mi}}
    sidecarInjectorWebhook:
      templates:
        spire: |
          spec:
            initContainers:
            - name: istio-proxy
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
            - name: workload-socket
              csi:
                driver: "$CSI_DRIVER"
                readOnly: true
        spireGateway: |
          spec:
            containers:
            - name: istio-proxy
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
            - name: workload-socket
              csi:
                driver: "$CSI_DRIVER"
                readOnly: true
EOF
oc apply -f "$M/d2-mesh-istio.yaml"
oc wait istiocni/default istio/default --for=condition=Ready --timeout=10m
oc get istio default -o jsonpath='{.spec.version}{"\n"}'
```

No version is set, so the operator picks its default and both resources get
the same one.

### D3. The application, in the mesh - and not yet registered

> **Where:** the hub.

An overlay on the same upstream `overlays/default` as C1. It moves the
application to `$MESH_NS`, turns injection on for the namespace, and asks
for the `spire` template on every Deployment. It changes nothing in the
application itself. Leave the ClusterSPIFFEID out for now, on purpose.

```bash
[ -d "$BQ_CLONE/.git" ] || git clone "$BQ_REPO" "$BQ_CLONE"
git -C "$BQ_CLONE" checkout -q "$BQ_REF"
mkdir -p "$M/boutique-mesh"
cat > "$M/boutique-mesh/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $MESH_NS
resources:
  - $(realpath --relative-to="$M/boutique-mesh" "$BQ_SRC/overlays/default")
patches:
  - target: {kind: Namespace}
    patch: |
      apiVersion: v1
      kind: Namespace
      metadata: {name: any, labels: {istio-injection: enabled}}
  - target: {kind: Deployment, labelSelector: app.kubernetes.io/part-of=online-boutique}
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata: {name: any}
      spec: {template: {metadata: {annotations: {inject.istio.io/templates: "sidecar,spire"}}}}
EOF
oc kustomize "$M/boutique-mesh" > "$M/d3-boutique-mesh.yaml"
oc apply -f "$M/d3-boutique-mesh.yaml"
sleep 60; oc -n $MESH_NS get pods
```

Nothing comes up. Each pod has its `istio-proxy` and the CSI volume, and
the SPIRE agent answers on the socket, but it has no registration entry for
these pods. So Envoy gets no certificate and the proxy never reports ready.
As a native sidecar it starts first, and the application containers wait
behind its startup probe:

```bash
oc -n $MESH_NS get pod -l app=paymentservice -o jsonpath='{.items[0].spec.volumes[*].csi.driver}{"\n"}'   # csi.spiffe.io
oc -n $MESH_NS logs deploy/paymentservice -c istio-proxy --tail=5
spire entry show | grep "SPIFFE ID" | grep -c $MESH_NS           # 0
```

This is Lab 4 again, with a mesh in front of it. In the mesh, no SPIRE
identity means no traffic at all, not just a refused handshake.

### D4. Register them, and look at what Envoy holds

> **Where:** the hub.

The same ClusterSPIFFEID as C2, for the new namespace. It is cluster-scoped,
so it is applied on its own, outside the kustomize overlay (kustomize would
give it a namespace).

```bash
cat > "$M/d4-clusterspiffeid.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: $MESH_NS
spec:
  className: $CLASS
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: $MESH_NS
  federatesWith:
    - $PEER_TD
EOF
oc apply -f "$M/d4-clusterspiffeid.yaml"
oc -n $MESH_NS rollout status deploy/frontend --timeout=10m
oc -n $MESH_NS get pods                             # 2/2 each: the app and istio-proxy
spire entry show | grep "SPIFFE ID" | grep $MESH_NS | sort -u
```

(Drop `federatesWith` if you did not do Lab 7. With it, the SNO's CA is in
every sidecar's trust bundle as well.)

The pods come up without you touching them (a proxy that gave up waiting
is restarted by its probe): the entries appear, the agent can answer, and
Envoy gets its certificate. Ask Envoy what it holds:

```bash
envoy_cert paymentservice
# spiffe://hub.mylab.com/ns/boutique-mesh/sa/paymentservice 2026-...T10:00:00Z -> 2026-...T11:00:10Z
envoy_cert checkoutservice
```

The certificate is valid for **one hour**, your SpireServer's
`defaultX509Validity` from Lab 2. A certificate from istiod would be valid
for 24 hours. Envoy rotates it as the agent does, and nobody restarts
anything.

### D5. Lock it down

> **Where:** the hub.

So far mTLS is *permissive*: Envoys use it with each other, but anything
without a sidecar can still talk plaintext. Three things change that, added to the
same overlay. The kustomization is D3's again, plus two resources and a
patch for the Route:

- `PeerAuthentication` STRICT: mTLS or nothing, for the whole namespace.
- `AuthorizationPolicy` on paymentservice: what ghostunnel's `--allow-uri`
  did in C3, now as policy. The principal is the caller's SPIFFE ID without
  `spiffe://`.
- An ingress gateway. The OpenShift router is not in the mesh, so under
  STRICT it can no longer reach the frontend. A gateway, with a SPIRE
  certificate of its own (`spireGateway`), takes the router's traffic and
  opens mTLS onward. The application's Route is repointed at it.

```bash
cat > "$M/boutique-mesh/policy.yaml" <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: paymentservice
spec:
  selector:
    matchLabels:
      app: paymentservice
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - $TD/ns/$MESH_NS/sa/checkoutservice
EOF
cat > "$M/boutique-mesh/gateway.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $MESH_GW
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $MESH_GW
spec:
  selector:
    matchLabels: {istio: $MESH_GW}
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway,spireGateway
      labels:
        istio: $MESH_GW
        sidecar.istio.io/inject: "true"
    spec:
      serviceAccountName: $MESH_GW
      containers:
        - name: istio-proxy
          image: auto
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            runAsNonRoot: true
---
apiVersion: v1
kind: Service
metadata:
  name: $MESH_GW
spec:
  selector: {istio: $MESH_GW}
  ports:
    - {name: http, port: 8080, targetPort: 8080}
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: $MESH_GW
spec:
  selector: {istio: $MESH_GW}
  servers:
    - port: {number: 8080, name: http, protocol: HTTP}
      hosts: ["*"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: frontend
spec:
  hosts: ["*"]
  gateways: [$MESH_GW]
  http:
    - route:
        - destination: {host: frontend, port: {number: 80}}
EOF
cat > "$M/boutique-mesh/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $MESH_NS
resources:
  - $(realpath --relative-to="$M/boutique-mesh" "$BQ_SRC/overlays/default")
  - policy.yaml
  - gateway.yaml
patches:
  - target: {kind: Namespace}
    patch: |
      apiVersion: v1
      kind: Namespace
      metadata: {name: any, labels: {istio-injection: enabled}}
  - target: {kind: Deployment, labelSelector: app.kubernetes.io/part-of=online-boutique}
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata: {name: any}
      spec: {template: {metadata: {annotations: {inject.istio.io/templates: "sidecar,spire"}}}}
  - target: {kind: Route, name: frontend}
    patch: |
      - {op: replace, path: /spec/to/name, value: $MESH_GW}
      - {op: replace, path: /spec/port/targetPort, value: 8080}
EOF
oc kustomize "$M/boutique-mesh" > "$M/d5-boutique-mesh.yaml"
oc apply -f "$M/d5-boutique-mesh.yaml"
oc -n $MESH_NS rollout status deploy/$MESH_GW --timeout=5m
oc -n $MESH_NS get route frontend -o jsonpath='https://{.spec.host}{"\n"}'   # the shop, through the gateway
```

### D6. Who gets through now

> **Where:** the hub.

**checkoutservice → paymentservice.** paymentservice's Envoy counts every
request it accepts, labelled with the caller's SPIFFE ID, taken from the
certificate SPIRE issued, and with whether it arrived over mTLS:

```bash
oc -n $MESH_NS exec deploy/paymentservice -c istio-proxy -- pilot-agent request GET stats/prometheus \
  | grep '^istio_requests_total{' | grep 'reporter="destination"' \
  | grep -o 'source_principal="[^"]*"\|connection_security_policy="[^"]*"\|response_code="[^"]*"\|} [0-9]*$' \
  | paste - - - -
# source_principal="spiffe://hub.mylab.com/ns/boutique-mesh/sa/checkoutservice"  response_code="200"  connection_security_policy="mutual_tls"  } 42
```

Those are the load generator's orders, paid.

**Inside the mesh, but not checkoutservice.** The load generator has a
perfectly good SPIRE certificate. Its Envoy wraps the request in mTLS, and
paymentservice's Envoy turns it away before the application sees anything:

```bash
oc -n $MESH_NS exec deploy/loadgenerator -c main -- python3 -c \
  "import http.client as h; c = h.HTTPConnection('paymentservice', 50051, timeout=10); c.request('GET', '/'); r = c.getresponse(); print(r.status, r.read(60))"
# 403 b'RBAC: access denied'
```

**Outside the mesh.** Part B's `client` has an SVID, but no Envoy, so it
talks plaintext, and STRICT means the frontend's Envoy drops it. The Route
is the one way in, through the gateway:

```bash
inpod client python3 -c "import http.client as h; c = h.HTTPConnection('frontend.$MESH_NS.svc', 80, timeout=10); c.request('GET', '/'); print(c.getresponse().status)"
# ... ConnectionResetError (or RemoteDisconnected)
HOST=$(oc -n $MESH_NS get route frontend -o jsonpath='{.spec.host}')
inpod client python3 -c "import http.client as h, ssl; c = h.HTTPSConnection('$HOST', 443, context=ssl._create_unverified_context()); c.request('GET', '/'); print(c.getresponse().status)"
# 200
```

**Compared with Part C.** The same allowlist, but nothing was added to the
application: no ports moved, no tunnel per hop, and every hop is mTLS, not
one. The identities are the same SPIFFE IDs from the same SPIRE server, and
a certificate still lasts an hour. The cost is a control plane and an Envoy
in every pod.

**Check**

```bash
cd /root/hcp-backup-restore/spiffe-spire
./build-lab.sh --workshop --only mesh-verify --cluster hub
```

The full build's own asserts, run against what you built: every Envoy holds
its own SPIFFE ID with a SPIRE lifetime, orders are paid over mTLS as
checkoutservice, and the load generator and the outsider are refused.

To take this part away again, mesh and all, and leave SPIRE, Part B and
Part C as they were:

```bash
./build-lab.sh --only mesh-cleanup --cluster hub
```

---

## Catching up, checking, and when something is wrong

**Check what you built.** The automated build's own asserts, against your
objects - they test outcomes (Ready conditions, entries, SVIDs, handshakes),
not how the manifests were written:

```bash
cd /root/hcp-backup-restore/spiffe-spire
./build-lab.sh --workshop --only check              # Labs 1-6, both clusters
./build-lab.sh --workshop --only xverify            # Lab 7, both directions
```

**Catch up.** Every step of the full build is reachable, and creates the
same objects under the same names as the labs - so it converges on what you
have rather than duplicating it:

```bash
./build-lab.sh --workshop --only spire              # Labs 1-3, both clusters
./build-lab.sh --workshop --only demo               # Labs 4-5
./build-lab.sh --workshop --only federation         # Lab 7
```

| Symptom | Look at |
| --- | --- |
| SpireServer never Ready, PVC `Pending` | `oc -n $ZT_NS get pvc,pv` - is `storageClass` `$SPIRE_SC`? `persistence` is immutable: delete the SpireServer and the PVC, and re-apply |
| fewer agents than workers | `oc -n $ZT_NS logs ds/spire-agent` - node attestation errors say why |
| ClusterSPIFFEID `.status` empty | `className` |
| a pod never gets `/svid/svid.pem` | `oc -n $DEMO_NS logs deploy/<pod> -c spiffe-helper` - `no identity issued` means no entry matches |
| the intruder has an SVID | `oc get clusterspiffeid` - a `...-spire-default` fallback exists only if someone created a `SpireOIDCDiscoveryProvider`, which registers every pod |
| `federation refresh` fails | the message: `no such host` (DNS), connection refused or 503 (the Route), `x509` (the endpoint's SVID / the bootstrap bundle) |
| cross-cluster `SERVER NOT TRUSTED` | 7d: `federatesWith`, then wait for the bundle file to hold 2 certificates |
| cross-cluster `HTTP 403` | 7e, and a minute for the ConfigMap to arrive |
| D4: pods still not Ready a few minutes after the ClusterSPIFFEID | `oc get clusterspiffeid $MESH_NS -o yaml` - `className`, entries; `oc -n $MESH_NS get pod <pod> -o yaml \| grep -e templates -e csi.spiffe` |
| `envoy_cert` shows 24 hours | that certificate is istiod's: the pod lacks the `spire` template - check D3's annotation, then `oc -n $MESH_NS rollout restart deploy/<name>` |
| D5: the shop's Route answers 503 | `oc -n $MESH_NS get pods -l istio=$MESH_GW` - Ready? the `VirtualService` must name the `Gateway` |

## Tearing it down

```bash
./build-lab.sh --only cleanup
```

Removes, from both clusters: Part D's mesh (only what carries the
`$MESH_OWNER` label), `spiffe-demo`, every SPIRE CR, the federation
Route, the operator, the SPIRE server's PV and StorageClass, and the data
directory on the node - the trust domain's CA keys, so a rebuild is a new
root. The base lab is untouched. The operator's CRDs stay; OLM never removes
them.
