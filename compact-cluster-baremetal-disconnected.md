# Disconnected three-node compact cluster on bare metal (agent-based installer)

This guide installs the same cluster as
[compact-cluster-baremetal.md](compact-cluster-baremetal.md): three
schedulable masters on physical servers, `platform: baremetal` with two VIPs,
and every server's address on an **LACP bond** over two NICs. The difference
is that the servers have **no internet access**. Every image comes from a
**mirror registry** on your network.

What changes for a disconnected install:

- **`openshift-install` is extracted from the release image in the mirror**
  with `oc adm release extract --idms-file=...`. The extracted binary
  has the mirror's release image built in, so the ISO and the cluster use the
  mirror instead of quay.io.
- **`install-config.yaml` carries the mirror configuration**: the
  `imageDigestSources` from the same IDMS file, the mirror's CA certificate,
  and a pull secret for the mirror.
- **`openshift-install agent create image` has no `--idms` flag.** It reads
  `imageDigestSources` from `install-config.yaml`. It uses them for its own
  pulls when it builds the ISO, and writes them into the ISO so the servers
  pull from the mirror too. Details in [Step 13](#step-13---build-the-agent-iso).

The hardware, switch, bond and boot steps are the same as for the connected
install. For those steps, this guide links to the bare-metal guide instead of
repeating them.

All names, addresses and paths are **examples**. Replace them in
[Step 6](#step-6---record-the-plan-as-shell-variables).

- [Before you start](#before-you-start)
- [Manual deployment](#manual-deployment)
  1. [Steps 1-4: hardware, switches, MACs and firmware](#steps-1-4---hardware-switches-macs-and-firmware)
  5. [Prepare the installer host](#step-5---prepare-the-installer-host)
  6. [Record the plan as shell variables](#step-6---record-the-plan-as-shell-variables)
  7. [Check the addresses are free](#step-7---check-the-addresses-are-free)
  8. [DNS](#step-8---dns)
  9. [Check that the mirror has the release](#step-9---check-that-the-mirror-has-the-release)
  10. [Extract openshift-install and oc from the mirror](#step-10---extract-openshift-install-and-oc-from-the-mirror)
  11. [Turn the IDMS into imageDigestSources](#step-11---turn-the-idms-into-imagedigestsources)
  12. [Write install-config.yaml](#step-12---write-install-configyaml)
  13. [Write agent-config.yaml and build the agent ISO](#step-13---build-the-agent-iso)
  14. [Boot the servers and watch the install](#step-14---boot-the-servers-and-watch-the-install)
  15. [Verify the cluster uses the mirror](#step-15---verify-the-cluster-uses-the-mirror)
  16. [Day 2: catalogs, tag mirrors and signatures](#step-16---day-2-catalogs-tag-mirrors-and-signatures)
- [Troubleshooting](#troubleshooting)

---

## Before you start

This guide assumes the mirror registry **already exists and is populated**.
Before you start, you need:

| What | Example | Notes |
|---|---|---|
| Mirror registry | `mirror.example.com:8443` | Reachable from the installer host and from the servers' node network |
| The release, mirrored | `mirror.example.com:8443/openshift/release-images:4.22.10-x86_64` | The whole payload, mirrored with `oc mirror`. The version must be the one you install. |
| The IDMS file from `oc mirror` | `~/oc-mirror-output/working-dir/cluster-resources/idms-oc-mirror.yaml` | `ImageDigestMirrorSet`: maps each quay.io source to its mirror |
| The mirror's CA certificate | `~/mirror-ca.pem` | PEM. The servers and the installer host must trust it. |
| Credentials for the mirror | `~/mirror-auth.json` | A `{"auths": {...}}` file with an entry for the mirror registry |
| Other `oc mirror` output | `~/oc-mirror-output/working-dir/cluster-resources/` | CatalogSources, ImageTagMirrorSets, signature ConfigMap. Used on day 2 (Step 16). |

`oc mirror` (v2) writes the IDMS and the other cluster resources under
`<workspace>/working-dir/cluster-resources/`. Older `oc mirror` (v1) writes an
`imageContentSourcePolicy.yaml` instead. If that is all you have, use
`--icsp-file` wherever this guide uses `--idms-file`, and convert its
`repositoryDigestMirrors` the same way in Step 11.

On this repo's lab mirror (`setup_mirror_registry.yaml`), the registry is
`registry.hub.mylab.com:8443`. The release is at
`openshift/release-images:<version>-x86_64`. The IDMS is under
`/root/mirror/oc-mirror-output/` on the mirror registry VM.

---

## Manual deployment

You run most steps from an **installer host**. This is a RHEL 9 or Fedora
x86_64 machine that can reach the mirror registry, the server BMCs and the
node network. It does not need internet access if you can copy an `oc` binary
onto it (Step 5).

### Steps 1-4 - Hardware, switches, MACs and firmware

These steps are the same as for the connected install. Follow them in the
bare-metal guide:

1. [Check the hardware](compact-cluster-baremetal.md#step-1---check-the-hardware)
2. [Prepare the switches](compact-cluster-baremetal.md#step-2---prepare-the-switches)
   for LACP. Consult your network admin, as noted there.
3. [Collect each server's MACs and disk ID](compact-cluster-baremetal.md#step-3---collect-each-servers-macs-and-disk-id)
4. [Prepare the firmware](compact-cluster-baremetal.md#step-4---prepare-the-firmware)

One addition: the node network must reach the **mirror registry** (port 8443 in
the example), your **DNS** server and an **NTP** server inside your network.
Nothing else is needed outside the node network.

### Step 5 - Prepare the installer host

```bash
sudo dnf install -y nmstate jq python3-pyyaml
ssh-keygen -t ed25519 -N '' -f ~/.ssh/compact
```

**An `oc` client, 4.13 or newer.** You need it for `oc adm release extract
--idms-file` in Step 10. Older clients only have `--icsp-file`. If the
installer host has no internet access, download
`openshift-client-linux.tar.gz` from mirror.openshift.com on a connected
machine and copy it over. Step 10 then extracts an `oc` that exactly matches
the release.

```bash
oc version --client
oc adm release extract --help | grep -- --idms-file    # must print the flag
```

**Trust the mirror's CA** on the installer host, so `oc` can talk to the
registry without `--insecure`:

```bash
sudo cp ~/mirror-ca.pem /etc/pki/ca-trust/source/anchors/mirror-ca.pem
sudo update-ca-trust
curl -s -o /dev/null -w '%{http_code}\n' https://mirror.example.com:8443/v2/   # 200 or 401, NOT a TLS error
```

The installer host needs to reach:

| Destination | Port | Why |
|---|---|---|
| Mirror registry | 8443/tcp | Extract the installer (Step 10), build the ISO (Step 13) |
| Each BMC | 443 | Virtual media, power, remote console |
| master1 (rendezvous host) | 8090/tcp | `agent wait-for` reads install progress |
| API VIP | 6443/tcp | `agent wait-for install-complete` and `oc` |
| Ingress VIP | 443/tcp | Web console |
| Each node | 22/tcp | `ssh core@<node>` for debugging |

The **servers** need to reach only the mirror registry, DNS and NTP.

### Step 6 - Record the plan as shell variables

The same variables as the connected guide, plus the mirror:

```bash
export DOMAIN=example.com
export CLUSTER=compact
export ZONE=$CLUSTER.$DOMAIN
export OCP=4.22.10                      # must be a release that is in the mirror
export WORK=~/compact_install

export MACHINE_NET=10.20.30.0/24
export PREFIX=24
export GATEWAY=10.20.30.1
export DNS1=10.20.30.10
export NTP1=10.20.30.10                 # must be inside your network
export API_VIP=10.20.30.5
export INGRESS_VIP=10.20.30.6

export PORT1=ens1f0
export PORT2=ens2f0

# The mirror
export MIRROR=mirror.example.com:8443                                   # host:port, as in the auth file
export RELEASE=$MIRROR/openshift/release-images:$OCP-x86_64             # the mirrored release image
export IDMS=~/oc-mirror-output/working-dir/cluster-resources/idms-oc-mirror.yaml
export MIRROR_CA=~/mirror-ca.pem
export MIRROR_AUTH=~/mirror-auth.json

# hostname  ip  port1-mac  port2-mac  install-disk-wwn
cat > ~/compact-nodes.txt <<'EOF'
master1  10.20.30.11  b8:ca:3a:00:00:11  b8:ca:3a:00:01:11  0x5000c500a0000011
master2  10.20.30.12  b8:ca:3a:00:00:12  b8:ca:3a:00:01:12  0x5000c500a0000012
master3  10.20.30.13  b8:ca:3a:00:00:13  b8:ca:3a:00:01:13  0x5000c500a0000013
EOF
export RENDEZVOUS=$(awk 'NR==1 {print $2}' ~/compact-nodes.txt)
```

If `oc mirror` wrote more than one IDMS file, for example one for the release
and one for operators, set `IDMS` to the one whose sources include
`quay.io/openshift-release-dev`. That is the file `oc adm release extract`
needs. Step 11 uses all of them.

```bash
grep -l 'openshift-release-dev' ~/oc-mirror-output/working-dir/cluster-resources/*idms*
```

### Step 7 - Check the addresses are free

Same as the connected install:
[Step 7 in the bare-metal guide](compact-cluster-baremetal.md#step-7---check-the-addresses-are-free).

### Step 8 - DNS

Create the same records as for the connected install
([Step 8 in the bare-metal guide](compact-cluster-baremetal.md#step-8---dns)):
`api`, `api-int` and `*.apps` for the VIPs, and A + PTR records for the three
masters.

One difference: the resolver in `$DNS1` does **not** need to answer internet
names. It **must** resolve the mirror registry's name, because the agent and
every node pull from it by name:

```bash
dig +short api.$ZONE                    # API VIP
dig +short anything.apps.$ZONE          # ingress VIP
dig +short @$DNS1 ${MIRROR%%:*}         # the mirror registry - from the NODE network's resolver
```

### Step 9 - Check that the mirror has the release

Before you build anything, confirm the mirror really has this release:

```bash
oc adm release info -a $MIRROR_AUTH $RELEASE | head -20
```

The output names the version (`Name: 4.22.10`) and lists the component
images. The component pullspecs still say `quay.io/openshift-release-dev/...`.
That is expected: the payload always lists the original names, and the IDMS
maps them to the mirror. If this command fails, fix the mirror first. Nothing
later in this guide can work around a missing or incomplete release.

### Step 10 - Extract openshift-install and oc from the mirror

This is the main difference from the connected install. Do not download
`openshift-install` from mirror.openshift.com. Extract it from the release
image **in the mirror**:

```bash
rm -rf $WORK                    # start empty; back up an old auth/kubeconfig first if you need it
mkdir -p $WORK && cd $WORK

oc adm release extract -a $MIRROR_AUTH \
  --idms-file=$IDMS \
  --command=openshift-install \
  $RELEASE

oc adm release extract -a $MIRROR_AUTH \
  --idms-file=$IDMS \
  --command=oc \
  $RELEASE

./openshift-install version
./oc version --client
```

Why this matters:

- **The release image is built into the binary.** `openshift-install`
  installs the release it was extracted from. Extracted from the mirror, its
  default release image is the **mirror's** pullspec. Check this in the
  output of `./openshift-install version`:

  ```
  ./openshift-install 4.22.10
  ...
  release image mirror.example.com:8443/openshift/release-images@sha256:...
  ```

  If this line says `quay.io/...`, you are using a downloaded installer, not
  the extracted one. The ISO would then try to pull the release from quay.io.
- **`--idms-file` lets `oc` find the installer inside the mirror.** The
  payload refers to the installer image by its quay.io name. Without the IDMS,
  `oc` tries quay.io. On a host without internet access that fails. On a host
  with internet access it succeeds silently and gives you an installer you
  did not take from your mirror.
- **`--command=oc`** gives you a client that exactly matches the release.
  Step 13 puts it on `PATH` for the ISO build.

`oc adm release extract` takes **one** `--idms-file`. Use the file that maps
`quay.io/openshift-release-dev` (Step 6).

### Step 11 - Turn the IDMS into imageDigestSources

`install-config.yaml` describes the same source-to-mirror mappings as the
IDMS, in its `imageDigestSources` key. Generate it **from the IDMS** instead of
typing it, so the two cannot drift apart:

```bash
python3 - ~/oc-mirror-output/working-dir/cluster-resources/*idms*.yaml \
  > ~/idms-sources.yaml <<'EOF'
import sys, yaml
out = []
for path in sys.argv[1:]:
    for doc in yaml.safe_load_all(open(path)):
        if doc and doc.get('kind') == 'ImageDigestMirrorSet':
            for m in doc['spec']['imageDigestMirrors']:
                entry = {'mirrors': m['mirrors'], 'source': m['source']}
                if entry not in out:
                    out.append(entry)
print(yaml.safe_dump({'imageDigestSources': out}, default_flow_style=False, sort_keys=False), end='')
EOF
cat ~/idms-sources.yaml
```

For a release mirrored with `oc mirror` v2 to the root of the registry, the
result looks like this:

```yaml
imageDigestSources:
- mirrors:
  - mirror.example.com:8443/openshift/release
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
- mirrors:
  - mirror.example.com:8443/openshift/release-images
  source: quay.io/openshift-release-dev/ocp-release
```

Both release entries are required: `ocp-release` is the release image itself,
and `ocp-v4.0-art-dev` holds every component image. The script reads every
IDMS file, including the operator ones, so the nodes can also pull mirrored
operator images by digest. It drops IDMS-only fields such as
`mirrorSourcePolicy`, which `install-config.yaml` does not accept.

### Step 12 - Write install-config.yaml

Three additions compared with the connected install: a **pull secret for the
mirror**, **`imageDigestSources`**, and the mirror's **CA**.

**The pull secret needs only the mirror's credentials.** Reduce the auth file
to that one entry:

```bash
jq -c --arg r "$MIRROR" '{auths: {($r): .auths[$r]}}' $MIRROR_AUTH > ~/pull-secret-mirror.json
jq -e --arg r "$MIRROR" '.auths[$r].auth' ~/pull-secret-mirror.json >/dev/null && echo OK
```

If your mirror's auth file has no entry for `$MIRROR` (`jq` prints `null`),
create one from the registry user and password:

```bash
printf '{"auths":{"%s":{"auth":"%s"}}}' "$MIRROR" "$(printf '%s' 'user:password' | base64 -w0)" > ~/pull-secret-mirror.json
```

Do not add your quay.io or registry.redhat.io credentials. With
`imageDigestSources`, the cluster pulls everything from the mirror and never
needs them. Leaving them out means a missing mirror entry fails clearly, and
the cluster cannot quietly pull from the internet if a route exists.

Then write the file:

```bash
cat > $WORK/install-config.yaml <<EOF
apiVersion: v1
baseDomain: $DOMAIN
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 3
metadata:
  name: $CLUSTER
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: $MACHINE_NET
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  baremetal:
    apiVIPs:
    - $API_VIP
    ingressVIPs:
    - $INGRESS_VIP
    provisioningNetwork: Disabled
pullSecret: $(jq -c . ~/pull-secret-mirror.json | jq -R .)
sshKey: '$(cat ~/.ssh/compact.pub)'
$(cat ~/idms-sources.yaml)
additionalTrustBundlePolicy: Always
additionalTrustBundle: |
$(sed 's/^/  /' $MIRROR_CA)
EOF

python3 -c "import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print(len(c['imageDigestSources']), 'mirror entries; CA lines:', len(c['additionalTrustBundle'].splitlines()))" $WORK/install-config.yaml
```

What each addition does:

- **`pullSecret`** holds only the mirror's credentials. `jq -R .` writes the
  JSON as one quoted YAML string, so no character in the credentials can
  break the file.
- **`imageDigestSources`** (from Step 11) is what makes the install use the
  mirror. The installer uses it when it builds the ISO, writes it into the
  ISO's `/etc/containers/registries.conf` for the agent, and turns it into the
  cluster's own `ImageDigestMirrorSet`, which configures the nodes after the
  install.
- **`additionalTrustBundle`** is the mirror's CA. It is added to the trust
  store of every node, so CRI-O can pull from the mirror over TLS. The ISO
  gets it too.
- **`additionalTrustBundlePolicy: Always`** also adds the CA to the
  cluster-wide trusted CA bundle, for pods that talk to the registry
  themselves. The default (`Proxyonly`) adds it there only when a proxy is
  configured.

Do **not** copy `oc mirror`'s IDMS into a `$WORK/openshift/` extra-manifests
directory as well. The installer already creates an `ImageDigestMirrorSet` from
`imageDigestSources`. A second copy of the same mirrors has to match it
exactly, or the nodes fail their first configuration check. The other
`oc mirror` resources go on the cluster on day 2 (Step 16).

### Step 13 - Build the agent ISO

Write `agent-config.yaml` exactly as for the connected install, with the LACP
bonds, disk hints and NTP:
[Step 11 in the bare-metal guide](compact-cluster-baremetal.md#step-11---write-agent-configyaml-with-the-bonds).
Nothing in it changes for a disconnected install. The `additionalNTPSources`
entry is more important here, because the servers cannot reach a public NTP
pool.

Keep a copy of both files, because the build deletes them. Then build the ISO
with the **extracted** installer and `oc`:

```bash
mkdir -p $WORK/rendered && cp $WORK/install-config.yaml $WORK/agent-config.yaml $WORK/rendered/

cd $WORK
PATH=$WORK:$PATH ./openshift-install --dir $WORK agent create image --log-level=debug 2>&1 | tee $WORK/create-image.log
ls -lh $WORK/agent.x86_64.iso
```

**There is no `--idms` flag on this command, and it does not need one.**
`openshift-install agent create image` takes the mirror configuration from
`install-config.yaml`:

1. **For its own pulls.** To build the ISO, the installer pulls the RHCOS
   base ISO and some agent files out of the release payload. It does this by
   running `oc` (`oc adm release info` and `oc image extract`). It turns
   `imageDigestSources` into a temporary mirror file and passes it to those
   `oc` commands as `--icsp-file`. This is the same job `--idms-file` did
   for you in Step 10, done automatically. It authenticates with the
   `pullSecret`.
2. **For the servers.** It writes the same mirrors into the ISO as
   `/etc/containers/registries.conf`, and the CA from `additionalTrustBundle`
   into the ISO's trust store. The agent on each server then pulls the release
   from the mirror.

With `--log-level=debug`, you can see this in the log:

```bash
grep -iE 'mirror|icsp|release image' $WORK/create-image.log | head
```

That is why the `oc` from Step 10 must be first on `PATH`. If `oc` is missing,
the installer cannot apply the mirror configuration for these pulls.

### Step 14 - Boot the servers and watch the install

Boot the three servers from the ISO as for the connected install:
[Step 13 in the bare-metal guide](compact-cluster-baremetal.md#step-13---boot-the-three-servers-from-the-iso).
The HTTP server for Redfish virtual media has to run on a host the BMCs can
reach. The installer host is fine.

Once a server is up on the ISO, check that it uses the mirror before you wait
for the whole install:

```bash
ssh -i ~/.ssh/compact core@$RENDEZVOUS 'grep -A3 "^\[\[registry\]\]" /etc/containers/registries.conf | head -20'
ssh -i ~/.ssh/compact core@$RENDEZVOUS "curl -s -o /dev/null -w '%{http_code}\n' https://$MIRROR/v2/"   # 200 or 401, not a TLS error
```

Then wait as usual:

```bash
cd $WORK
./openshift-install --dir $WORK agent wait-for bootstrap-complete --log-level=info
./openshift-install --dir $WORK agent wait-for install-complete  --log-level=info
```

If the agent reports that it cannot pull the release image, the problem is
between the servers and the mirror: DNS for the mirror's name, the CA, the
credentials or a firewall. See [Troubleshooting](#troubleshooting).

### Step 15 - Verify the cluster uses the mirror

Do the cluster and bond checks from the connected install first:
[Steps 15 and 16 in the bare-metal guide](compact-cluster-baremetal.md#step-15---verify-the-cluster-and-the-bonds).

Then check the mirror configuration:

```bash
export KUBECONFIG=$WORK/auth/kubeconfig
alias oc=$WORK/oc

# The cluster's release image is the mirror's
oc get clusterversion version -o jsonpath='{.status.desired.image}{"\n"}'

# The ImageDigestMirrorSet the installer created from imageDigestSources
oc get imagedigestmirrorset
oc get imagedigestmirrorset -o yaml | grep -E 'source:|- ' | head -20

# The nodes pull through the mirror
oc debug node/master1 -- chroot /host grep -c "location = \"$MIRROR" /etc/containers/registries.conf
```

### Step 16 - Day 2: catalogs, tag mirrors and signatures

`oc mirror` produced more resources than the install used. Add them now that
the cluster is up.

**Turn off the default OperatorHub catalogs.** They point at
registry.redhat.io, which the cluster cannot reach, so their pods would fail
to pull forever:

```bash
oc patch operatorhub cluster --type merge -p '{"spec":{"disableAllDefaultSources":true}}'
```

**Apply the remaining `oc mirror` resources:** CatalogSources,
ImageTagMirrorSets and the release signature ConfigMap. You need the
signatures for upgrades.

```bash
CR=~/oc-mirror-output/working-dir/cluster-resources
ls $CR
oc apply -f $CR/ --dry-run=server        # check first
oc apply -f $CR/
```

Two things to know about this step:

- **ImageDigestMirrorSets and ImageTagMirrorSets roll out as a node
  configuration change.** On a compact cluster, all three masters reboot one
  at a time. The cluster stays up, but plan for it.
  `oc get machineconfigpool` shows the progress.
- **`oc mirror`'s IDMS overlaps the one the installer created.** Applying it
  is harmless, because the mappings are identical. You can skip the release
  IDMS file if you prefer one reboot round fewer.

---

## Troubleshooting

For hardware, LACP and boot problems, see the
[bare-metal guide's troubleshooting table](compact-cluster-baremetal.md#troubleshooting).
These problems are specific to the disconnected install:

| Symptom | Likely cause | Check |
|---|---|---|
| `oc adm release extract` fails with `unknown flag: --idms-file` | `oc` is older than 4.13 | Use a newer `oc` (Step 5), or use `--icsp-file` with an ImageContentSourcePolicy |
| `oc adm release extract` fails to find the installer image, or tries quay.io | `--idms-file` is missing, or it is the operator IDMS and not the release IDMS | Pass the file whose sources include `quay.io/openshift-release-dev` (Step 6) |
| `x509: certificate signed by unknown authority` on the installer host | The mirror's CA is not trusted on the installer host | Step 5: add it to `/etc/pki/ca-trust/source/anchors/` and run `update-ca-trust` |
| `openshift-install version` shows a `quay.io` release image | You are using a downloaded installer, not the one extracted from the mirror | Use `$WORK/openshift-install` from Step 10 |
| `agent create image` fails with `Failed to extract base ISO from release payload` | The installer could not pull from the mirror: no `oc` on `PATH`, missing `imageDigestSources`, or a pull secret without the mirror entry | Read `create-image.log` (debug). Check `which oc` with `PATH=$WORK:$PATH`, the `imageDigestSources` in `rendered/install-config.yaml`, and `jq '.auths' ~/pull-secret-mirror.json`. |
| `agent create image` warns `Using older version of "oc" that does not support mirroring` | The `oc` on `PATH` is too old for the installer's mirror handling | Put the `oc` extracted in Step 10 first on `PATH` |
| `install-config.yaml` fails to parse, or the pull secret is rejected | The pull secret broke the YAML quoting, or `additionalTrustBundle` is not indented | Write `pullSecret` with `jq -R .` and indent the CA as in Step 12. Run the `python3` check from Step 12. |
| The agent reports it cannot pull the release image | The servers cannot reach the mirror: DNS for the mirror's name, the CA, the credentials or a firewall | On a node: `getent hosts <mirror host>`, `curl -v https://$MIRROR/v2/`, and `/etc/containers/registries.conf` |
| Pods are stuck in `ImagePullBackOff` for an image under `quay.io/...` or `registry.redhat.io/...` | That image is not in the mirror, or it is pulled by tag and only an IDMS (digest) mapping exists | Mirror the image. For tag pulls, apply `oc mirror`'s ImageTagMirrorSet (Step 16). |
| OperatorHub shows no operators, or catalog pods fail to pull | The default catalogs are still enabled, or the mirrored CatalogSources are not applied | Step 16 |
| Nodes report `rendered-master-... do not match` on first boot | An IDMS was also placed in `$WORK/openshift/` and does not match the one from `imageDigestSources` | Remove the extra manifest and rebuild the ISO (Step 12) |
| `oc adm upgrade` refuses an update with a signature error | The release signature ConfigMap from `oc mirror` is not applied | Apply it from `cluster-resources/` (Step 16) |
