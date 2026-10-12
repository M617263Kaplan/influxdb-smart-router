# Running ISR on Kubernetes

ISR runs on Kubernetes as an ordinary Deployment — adopting a cluster and
serving reads and writes through it, exactly as it does on Docker.

---

## Loading a locally built image

If you build an ISR image locally and deploy it with `imagePullPolicy: Never`,
the pod fails:

```
NAME                   READY   STATUS               RESTARTS   AGE
isr-769c798446-gtrrp   0/1     ErrImageNeverPull    0          3m
```

The image is right there in `docker images`. The pod still cannot see it.

**Because Kubernetes is not looking at Docker's image store.** Docker Desktop's
Kubernetes runs **containerd**, which keeps its own store, and the Docker daemon's
images are not in it. `imagePullPolicy: Never` means "the image is already on the
node" — and on the node, it is not. The error is accurate and reads as though it
is about a policy, which is what makes it cost time.

This is not specific to ISR. It bites anything deployed from a local build.

### Docker Desktop

Save the image out of Docker and import it into the node's containerd store.
Docker Desktop's Kubernetes node is itself a container called
`desktop-control-plane`, so it can be piped straight in:

```bash
docker save isr:<tag> -o /tmp/isr.tar
docker exec -i desktop-control-plane ctr -n k8s.io images import - < /tmp/isr.tar
```

The `-n k8s.io` namespace matters: containerd namespaces are isolated, and an
image imported into the default namespace is invisible to the kubelet.

Then roll the Deployment so the pod is rescheduled against the newly present
image — an existing `ErrImageNeverPull` pod will not retry on its own:

```bash
kubectl -n <namespace> rollout restart deploy/isr
kubectl -n <namespace> wait --for=condition=available --timeout=180s deploy/isr
```

### Other distributions

Each has a first-class equivalent, and any of them is better than the `ctr`
pipe above where available:

| distribution | command |
|---|---|
| kind | `kind load docker-image isr:<tag>` |
| minikube | `minikube image load isr:<tag>` |
| k3s / k3d | `k3d image import isr:<tag>` |
| anything else | push to a registry the cluster can pull from |

**In production, use a registry.** Importing images by hand is a development
convenience; it does not survive a node being replaced, which is the one thing
Kubernetes is most likely to do.

---

## A minimal Deployment

ISR needs no Docker socket to run on Kubernetes: it fronts, routes, and
**adopts** clusters exactly as it does on Docker. ISR itself is deployed with a
manifest like the one below; `/api/isr/k8s/*` is how ISR provisions InfluxDB
clusters onto Kubernetes once it is running.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: isr
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: isr
  namespace: isr
spec:
  replicas: 1
  selector:
    matchLabels: { app: isr }
  template:
    metadata:
      labels: { app: isr }
    spec:
      containers:
        - name: isr
          image: isr:<tag>
          env:
            - name: ISR_LISTEN
              value: "0.0.0.0:9800"
            - name: ISR_DATA_LISTEN
              value: "0.0.0.0:8086"
            - name: ISR_STATE_DB
              value: "/var/lib/isr/state.db"
          ports:
            - containerPort: 9800   # admin API + console
            - containerPort: 8086   # data plane
---
apiVersion: v1
kind: Service
metadata:
  name: isr
  namespace: isr
spec:
  selector: { app: isr }
  ports:
    - { name: admin, port: 9800, targetPort: 9800 }
    - { name: data,  port: 8086, targetPort: 8086 }
```

**This manifest does not persist the state database.** The right answer depends
on your cluster, so choose it explicitly: a PVC for a single replica, or an
external Postgres via `ISR_STATE_DSN` for HA. Deployed exactly as written, a pod
restart loses ISR's administrators, tokens and cluster registry, so add
persistence before this is more than a test deployment. See
`docs/high-availability.md`.

Reach it while testing:

```bash
kubectl -n isr port-forward svc/isr 9800:9800 8086:8086
```

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
