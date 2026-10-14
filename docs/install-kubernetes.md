# Running ISR on Kubernetes

ISR runs on Kubernetes as a Deployment installed from the Helm chart in
[`charts/isr`](../charts/isr). With node management on (the default), ISR
provisions InfluxDB 3 Enterprise clusters into the same Kubernetes cluster
through its API and console: one namespace per cluster, MinIO on a persistent
volume, and nodes that serve through ISR as soon as their pods are ready.

---

## Before you start

- **An InfluxDB 3 Enterprise licence** (the JWT file). Getting Started asks for
  it when you create the first cluster.
- **The ISR image in your cluster's container runtime** — see the next section.
- `helm` 3 and `kubectl` pointed at the cluster.

## Load the image

ISR images are distributed as release tarballs and tagged per architecture
(`isr:v4.0.9-arm64`, `isr:v4.0.9-amd64`). Download the tarball for your nodes
from the [release](https://github.com/M617263Kaplan/influxdb-smart-router/releases/latest),
load it into Docker, then put it where the kubelet looks.

Kubernetes does not read Docker's image store. Docker Desktop's Kubernetes runs
**containerd**, which keeps its own store, so an image that is right there in
`docker images` is still invisible to the node. Import it into the node's
containerd, in the `k8s.io` namespace:

```bash
docker load < isr-v4.0.9-linux-arm64-image.tar.gz
docker save isr:v4.0.9-arm64 | docker exec -i desktop-control-plane ctr -n k8s.io images import -
```

Other distributions have a first-class equivalent:

| distribution | command |
|---|---|
| kind | `kind load docker-image isr:v4.0.9-arm64` |
| minikube | `minikube image load isr:v4.0.9-arm64` |
| k3s / k3d | `k3d image import isr:v4.0.9-arm64` |
| anything else | push to a registry the cluster can pull from, and set `image.repository` |

In production, use a registry: an image imported by hand does not survive a
node being replaced.

## Install with Helm

```bash
git clone https://github.com/M617263Kaplan/influxdb-smart-router.git
cd influxdb-smart-router

kubectl create namespace isr
# Encryption at rest is required. The key never enters a values file.
kubectl -n isr create secret generic isr-encryption \
  --from-literal=key="$(openssl rand -base64 32)"

helm install isr ./charts/isr -n isr \
  --set image.tag=v4.0.9-arm64 \
  --set encryption.existingSecret=isr-encryption

kubectl -n isr port-forward svc/isr 9800:9800
```

Open <http://localhost:9800>, create the first administrator, and run
**Getting Started**. `image.tag` is required: it is the arch-suffixed tag you
loaded, and the chart refuses to render without one.

Readiness reports what the pod is actually doing. A fresh ISR fronts nothing,
so `/_admin/ready` answers 503 and the pod shows `0/1 Ready` until a cluster
serves through it. The console Service is reachable regardless, which is how
you create that first cluster; the data Service routes traffic once the pod is
Ready, so nothing can hand writes to a front door with no storage behind it.
`helm install --wait` therefore returns when ISR fronts a cluster, not when
the pod starts.

## Your first cluster

Choose the Kubernetes target in Getting Started. ISR creates a namespace named
`isr-<cluster>` holding the licence and admin-token Secrets, one Deployment and
Service per node mode, and MinIO as the cluster's object store on a
PersistentVolumeClaim. Getting Started reports the cluster licensed and serving
from the pods themselves, and the nodes join ISR's routing pool the moment
they are ready — the next steps (database, first token, first write) run
against them through ISR.

The MinIO volume is 20Gi on the cluster's default StorageClass. Set its size
or class through the chart's `extraEnv`:

```yaml
extraEnv:
  - name: ISR_K8S_MINIO_STORAGE
    value: "100Gi"
  - name: ISR_K8S_MINIO_STORAGE_CLASS
    value: "fast-ssd"
```

To bring your own object store instead, create the cluster with S3, Blob or
GCS in Getting Started.

## Values worth knowing

| value | what it does |
|---|---|
| `image.tag` | **Required.** The arch-suffixed tag you loaded. |
| `image.repository` | `isr` by default; set it when you pushed the image to a registry. |
| `encryption.existingSecret` | A Secret you made, key `key`. Preferred over `encryption.key`, which puts the key in your values. |
| `persistence.size`, `persistence.storageClass` | The PVC that holds ISR's own state (10Gi by default). |
| `state.backend=postgres` + `state.postgres.existingSecret` | Shared state for more than one replica; SQLite supports exactly one. |
| `nodeManagement.enabled` | On by default: ISR provisions clusters into this Kubernetes cluster through its ServiceAccount. Off gives a console-and-proxy-only ISR with no cluster-scoped RBAC. |
| `tls.console.enabled`, `tls.console.sans` | ISR terminates TLS on the console listener itself; name the Service DNS name and every hostname clients use. |
| `advertise.host`, `advertise.toolPort` | What ISR hands out in connection strings and fleet callbacks when it sits behind a Service or Ingress. |
| `config.content` | ISR's config file. It ships with the query cache, the durable write queue, Prometheus metrics and Arrow Flight SQL enabled. |
| `podSecurityContext.fsGroup` | 10001, so the unprivileged ISR user can read the projected encryption key. |

`helm show values ./charts/isr` lists everything, with the reasoning beside
each setting.

## ISR's own TLS listeners

**Security → Cluster TLS** can serve the console over HTTPS and the data plane
over TLS on ISR's own certificate authority, with client certificates required
if you want them. The listeners bind inside the pod on ports 9443 (console)
and 8443 (data plane); reach them through your Ingress, a Service you add, or
a port-forward to the pod. Arrow Flight SQL clients connect to the data-plane
listener with `grpc+tls://`.

## Without Helm

A Deployment and Service of your own work too — ISR fronts, routes and adopts
clusters exactly as it does on Docker, and `/api/isr/k8s/*` provisions
clusters once it is running. The chart is the reference for what a complete
deployment carries: the ServiceAccount and ClusterRole for node management,
the encryption key as a projected Secret at `ISR_ENCRYPTION_KEY_FILE`, a
persistent volume at `/var/lib/isr`, and the readiness probe on
`/_admin/ready`. Render it to see the objects:

```bash
helm template isr ./charts/isr --set image.tag=v4.0.9-arm64 \
  --set encryption.existingSecret=isr-encryption
```

Whatever you deploy by hand, give `/var/lib/isr` a persistent volume: it holds
ISR's administrators, tokens and cluster registry.

---

## Adoption works across the boundary

The orchestrator ISR runs on and the orchestrator its cluster runs on are
independent.

**A Kubernetes ISR adopting a Docker cluster** — the probe reaches the cluster,
auth is detected, adopt verifies the admin token and mints a scoped service
token, the roster comes back from `system.nodes`, the object store is learned,
then a write returns `204` and a query returns `200` with the row just written.

**A Docker ISR adopting a Kubernetes cluster** — the same, in reverse.

The reason it does not matter is worth knowing: **ISR's boundary is not drawn on
orchestrator at all.** It is drawn on `launched_by_isr`. A node ISR created may
be scaled, replaced and pruned; a node it adopted is fronted and observed and
never actuated, whatever it runs on. The `docker ps` pruner is guarded by that
flag, which is why a Kubernetes ISR with no Docker socket never consults one.

### One consequence to expect

An adopted node reports `mode: unknown` in ISR's routing pool, whichever
orchestrator it came from. ISR does not learn a node's mode from adoption — it
reads the cluster's own roster instead, and shows that beside the pool without
claiming which row is which node. See the Cluster Nodes page.
