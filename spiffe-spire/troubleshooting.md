<!--
  Case files, not a manual. README.md and workshop.md say how the lab is meant
  to work; this records what happened when it did not, in enough detail that
  the next person recognises the shape before spending time on it.

  Convention (as in ../udn-bgp-evpn/troubleshooting.md): one section per
  non-obvious debug. Symptom first with the real output, then the trail in the
  order it was walked - wrong turns included - then the root cause, the fix,
  and what the lab now does so it cannot happen silently again.
-->

# Troubleshooting case files

Long-form records of faults that were hard to find, kept apart from
[README.md](README.md) and [workshop.md](workshop.md) so those stay about how
the lab works.

---

## Case 1 - `spire-server` is not where anything says it is

**Date:** 2026-10-03 · **Cluster:** hub · **Phase:** workshop Lab 2, `spire healthcheck`

### Symptom

The SPIRE server was up - StatefulSet 1/1, pod 2/2 Running, its PVC bound on
`lvms-vg1` - and the workshop's `spire` helper could not run the CLI:

```text
# spire healthcheck
executable file `spire-server` not found in $PATH: No such file or directory
command terminated with exit code 1
```

`spire` was `oc -n $ZT_NS exec spire-server-0 -c spire-server -- spire-server "$@"`.
The playbook's own checks (agent list, bundle show, entry show, federation
refresh) used the same bare name, so they would have failed the same way on
their first live run - the simulation's fake `oc` accepted any `spire-server`
argument, which is why nothing caught it.

### The trail

1. **The operator source** (`pkg/controller/spire-server/statefulset.go`)
   sets only `Args` (`-expandEnv -config /run/spire/config/server.conf`) on
   the container - so the binary is the image's entrypoint, and its path is
   whatever the image says. Nothing in the operator names it.
2. **Wrong turn: the documented path.** Red Hat's own procedure runs
   `oc exec ... -- /opt/spire/bin/spire-server healthcheck`, which is also
   upstream's layout. The lab switched to it. On the live hub:

   ```text
   executable file `/opt/spire/bin/spire-server` not found: No such file or directory
   ```

   The Red Hat image keeps it somewhere else. (An `ls /opt/` on the lab host
   proves nothing either way - that is the host, not the container.) The
   image is distroless, so there is no shell in it to go and look.
3. **The process, not the path.** The server container's PID 1 is the
   entrypoint - spire-server itself - and the pod does not set
   `shareProcessNamespace`, so `oc exec` lands in that container's own PID
   namespace. `/proc/1/exe` is therefore the running server's binary,
   wherever the image put it, and `exec` of it needs no shell:

   ```text
   # oc -n zero-trust-workload-identity-manager exec spire-server-0 -c spire-server -- /proc/1/exe healthcheck
   Server is healthy.
   # spire healthcheck
   Server is healthy.
   ```

### Root cause

The lab assumed the upstream image layout. Red Hat's SPIRE server image puts
`spire-server` neither on `$PATH` nor at `/opt/spire/bin`, and the
documentation shows the upstream path.

### Fix, and what the lab does now

- `spire_server_cli: /proc/1/exe` in `vars.yaml`, used by every `oc exec`
  of the CLI in the playbook and by the workshop's `spire` helper. No image
  path to keep in sync with a product image that may move it again.
- The fake `oc` used for simulation now rejects both `spire-server` and
  `/opt/spire/bin/spire-server` with the live error messages, so a
  regression to either fails the simulated run.
- A README troubleshooting row for the error text.

Caveat for anyone reusing it: `/proc/1/exe` is right only while the server is
the container's PID 1. If the operator ever adds `shareProcessNamespace` or
an init wrapper to the pod, PID 1 changes and this needs revisiting; the
image's entrypoint (`oc image info <image> -o json | jq .config.config.Entrypoint`)
is then the place to read the real path from.
