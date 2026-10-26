# ISR Helm chart

Deploys the **ISR control plane only**. InfluxDB Enterprise clusters, nodes
and Traffic Lab agents are then created and managed **through the ISR API and
console** — with `nodeManagement.enabled` (the default) the chart sets
`ISR_ORCHESTRATOR=k8s` and ISR's kubectl driver launches node workloads into
this same Kubernetes cluster under the chart's ServiceAccount, one namespace
per cluster.

## The image

ISR images are **not in a registry**. They are distributed as release
tarballs and tagged per arch (`isr:v4.0.17-arm64` / `isr:v4.0.17-amd64`).
Load one into your cluster runtime first — on Docker Desktop the node runs
containerd, so the image has to be imported into it, not just into Docker:

```bash
kind load docker-image isr:v4.0.17-arm64        # kind
docker save isr:v4.0.17-arm64 | docker exec -i desktop-control-plane \
  ctr -n k8s.io images import -                # Docker Desktop
# or push to a registry you control and point image.repository at it
```

`image.tag` is **required** and must be the arch-suffixed tag you loaded; the
chart refuses to render without it, because the chart's appVersion is not a
tag any runtime holds.

## Install

```bash
# Encryption at rest is REQUIRED by default — see below. Create the key first:
kubectl create secret generic isr-encryption \
  --from-literal=key="$(openssl rand -base64 32)"

helm install isr ./charts/isr \
  --set image.tag=v4.0.17-arm64 \
  --set encryption.existingSecret=isr-encryption
kubectl port-forward svc/isr 9800:9800
```

The pod reports `0/1 Ready` until ISR fronts a cluster — see *Readiness on a
fresh install* below; `helm install --wait` therefore times out on a fresh
hub and is not the way to install it.

## Encryption at rest — required by default

ISR encrypts the secrets it must read back — **upstream service tokens, the
internal CA private key, object-store credentials** — with AES-256-GCM. Without
a key it keeps them in **plaintext** and warns once at boot. On a cluster that
warning is a line in a pod log nobody reads, so **this chart fails the install
instead** and names the fix.

| value | meaning |
|---|---|
| `encryption.existingSecret` | **Preferred.** A Secret you made; the key never enters a values file or `helm get values` output. |
| `encryption.key` | Inline. The chart writes the Secret for you — and the key sits in plain text wherever your values live. |
| `encryption.required=false` | Throwaway evaluation only. |

The key is mounted as a **file** (`ISR_ENCRYPTION_KEY_FILE`), never as an
environment variable: env is readable by anything that can reach
`/proc/<pid>/environ` and is copied into crash dumps. Projected `defaultMode:
0400`, mounted read-only.

**Rotation is a boot operation**, not a live one. Set `encryption.previousKey`
(or `previousSecret`) so both keys are present for one restart, then clear it.

## TLS, and how ISR describes itself

The control plane and console carry bearer credentials — admin sessions and API
tokens ride in headers, so anyone on the path can read or replay them. Either
terminate TLS in front, or:

- `tls.console.enabled=true` — ISR terminates TLS on the console listener.
  **Set `tls.console.sans`** to the Service DNS name and any hostname clients
  actually use, or verification fails against a certificate that does not name
  them.
- `tls.gateway.listen` — a separate TLS listener for the ingest gateway.
- `advertise.host` / `advertise.toolPort` — behind a Service or Ingress, ISR's
  pod address is not where anything can reach it. These are what ISR hands out
  in connection strings, agent registrations and fleet callbacks; leave them
  empty and it advertises somewhere clients cannot go.

## StatsD over UDP

`gateway.statsd.enabled=true` (plus `gateway.statsd.database`) sets
`ISR_STATSD_LISTEN` and publishes the UDP port on the Service. It is read at
**startup**, so it is a pod restart rather than a live toggle. Off by default,
so the UDP port is only published when a listener exists behind it.

## State

- Default: SQLite on a PVC (`/var/lib/isr`). **Exactly one replica** — the
  chart refuses `replicaCount > 1` on SQLite rather than corrupting a
  single-writer database.
- Scale-out: `state.backend=postgres` plus a DSN
  (`state.postgres.existingSecret` holding key `dsn`, or an inline
  `state.postgres.dsn`, which the chart wraps in a Secret).

## What this chart deliberately does not do

- No Docker socket: the docker orchestrator, Docker-provisioned object store
  and self-upgrade paths that need `/var/run/docker.sock` don't apply in a
  pod. Nodes go through the k8s driver instead.
- No Ingress: bring your own, or use ISR's own TLS termination above.
- No agent images: ISR builds Traffic Lab agent images from a Lab-supplied
  context on hosts with a Docker daemon; that flow is outside this chart.

## Readiness on a fresh install

ISR refuses a routeless config, and readiness (`/_admin/ready`) reports
degraded while no upstream is healthy and no managed nodes exist — which is
true of every fresh install. The chart handles the bootstrap window honestly
instead of faking green:

- the chart's config ships one `bootstrap` route with a health-checked
  loopback placeholder upstream (correctly unhealthy);
- the **console Service** (`<release>`) sets `publishNotReadyAddresses` so
  you can reach the console and create the first cluster while NotReady;
- the **data Service** (`<release>-data`) respects readiness, so clients
  cannot hand writes to a front door with nothing behind it.

Expect `0/1 Ready` (and `helm --wait` timeouts) until ISR fronts something.
Once ISR manages healthy nodes, the route check flips to
`served by managed nodes` and the pod turns Ready.

## Probes

Mirrors ISR's own Kubernetes generator: liveness = `/health` (static — proves the
process is alive; a transient upstream outage must not flap the pod),
readiness = `/_admin/ready` (sheds traffic when degraded), startup probe
gives a slow first boot room. Termination grace 30s for graceful drain.
