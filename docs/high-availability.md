# High Availability

ISR has three independent layers of redundancy. Use only what your risk model
needs — most deployments want **ISR HA** (control-plane failover) plus a load
balancer; VRRP and BFISR are for on-prem virtual IPs and multi-site front doors.

In the console these live under the **ISR HA** workspace (Overview, High
Availability, VRRP) and, when enabled, **BFISR**.

## 1. ISR HA — control-plane failover

Two or more ISR instances share one Postgres **state store**. A Postgres
**advisory lock** elects a single **leader** that runs the singletons (autoscaler,
reconcilers, scheduled jobs). Every instance serves data-plane traffic; passive
ones proxy control-plane mutations to the leader. If the leader dies, its lock
releases and a follower is promoted in seconds.

Set the same `ISR_STATE_DSN` on every instance:

```bash
# NOTE the single quotes — the DSN's "?" is a glob character in zsh (macOS
# default) and will fail with "no matches found" if unquoted. Quoting is harmless
# in bash.
-e 'ISR_STATE_DSN=postgres://USER:PASS@PGHOST:5432/isr_ha?sslmode=require'
```

The **data plane does not need Postgres on the request path** — writes, queries,
and the ingest gateway keep flowing during a brief Postgres outage; only
leader-gated control operations (config changes, autoscaling, failover) pause
until it returns.

### Docker (with an isolated state DB)

Put Postgres on a dedicated network that only the ISRs join, with no published
port, so neither the InfluxDB nodes nor external clients can reach it:

```bash
docker network create isr-ha-net

docker run -d --name isr-ha-pg --network isr-ha-net \
  -e POSTGRES_USER=isr -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=isr_ha \
  postgres:16

docker run -d --name isr-b --network isr-ha-net \
  -p 9801:9800 -p 8087:8086 -p 8182:8181 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e 'ISR_STATE_DSN=postgres://isr:secret@isr-ha-pg:5432/isr_ha?sslmode=disable' \
  isr:latest
```

Attach your primary ISR to the same network and DSN.

### AWS

Use **RDS PostgreSQL Multi-AZ** (so the DB isn't a SPOF) + ≥2 ISR instances behind
an NLB/ALB. Allow 5432 only from the ISR security group; health-check ISR with
`GET /_admin/ready`. DSN example: `…@isr-ha.abc123.us-east-1.rds.amazonaws.com:5432/isr_ha?sslmode=require`.

### GCP

**Cloud SQL PostgreSQL (HA/regional)**, private IP, + ≥2 ISR instances (GCE/GKE)
behind a Google Cloud load balancer, backend check `/_admin/ready`.

### Azure

**Azure Database for PostgreSQL – Flexible Server (zone-redundant HA)**, private
access, + ≥2 ISR instances (VMSS/AKS) behind an Azure Load Balancer or Application
Gateway, probe `/_admin/ready`.

### Kubernetes

Run ISR as a **Deployment with ≥2 replicas** that share one Postgres DSN (from a
Secret). Each pod competes for the advisory lock, so the leader is elected across
pods; a **Service** is the single client endpoint and the readiness probe pulls
unhealthy pods out of rotation. In Kubernetes the DSN is supplied via the
manifest. Give each pod a distinct `ISR_INSTANCE_ID` from its pod name and the
shared `ISR_STATE_DSN` from the Secret.
For the DB's own HA prefer a managed regional Postgres or a Postgres operator
(e.g. CloudNativePG) over a single StatefulSet pod. Scale with
`kubectl scale deploy/isr --replicas=3`.

```yaml
apiVersion: v1
kind: Secret
metadata: { name: isr-ha }
stringData:
  ISR_STATE_DSN: postgres://isr:PASS@postgres:5432/isr_ha?sslmode=require
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: isr }
spec:
  replicas: 2                      # >=2 for HA
  selector: { matchLabels: { app: isr } }
  template:
    metadata: { labels: { app: isr } }
    spec:
      containers:
      - name: isr
        image: isr:latest
        args: ["--config","/etc/isr/config.yaml"]
        env:
        - name: ISR_INSTANCE_ID     # unique per pod -> distinct HA member
          valueFrom: { fieldRef: { fieldPath: metadata.name } }
        - name: ISR_STATE_DSN       # shared -> same leader-election lock
          valueFrom: { secretKeyRef: { name: isr-ha, key: ISR_STATE_DSN } }
        ports:
        - { containerPort: 9800 }
        - { containerPort: 8181 }
        readinessProbe:
          httpGet: { path: /_admin/ready, port: 9800 }
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata: { name: isr }
spec:
  selector: { app: isr }
  ports:
  - { name: console, port: 9800, targetPort: 9800 }
  - { name: data,    port: 8181, targetPort: 8181 }
  type: LoadBalancer
```

Day-2 actions (promote / restart / scale / logs) are in the console at
**ISR HA → Dashboard → Admin tools → Kubernetes**.

## When you need an external load balancer

Whenever clients must reach ISR through one address and you're not using a VRRP
virtual IP — i.e. any cloud, or on-prem without keepalived. Generic setup (any
L4/L7 LB):

- **Frontend:** the client-facing port(s) — 8086/8181 (data) and/or 9800 (console).
- **Backends:** every ISR instance on those port(s).
- **Health check:** `GET /_admin/ready` (node-aware — fails if that ISR has no
  healthy upstream).
- **Algorithm:** round-robin/least-conn. No sticky sessions (state is shared).

```
# HAProxy — data plane
frontend isr_data
  bind *:8181
  default_backend isr_nodes
backend isr_nodes
  option httpchk GET /_admin/ready
  server isr-a 10.0.0.11:8181 check
  server isr-b 10.0.0.12:8181 check
```

You don't need an LB if you use VRRP (the VIP is the single address) or clients
carry both ISR addresses and fail over themselves.

## Monitoring HA — Dashboard, Alerts & Logs

The **⚖️ ISR HA** workspace in the console has two live pages backed by a
per-instance member registry (every instance — leader and followers — heartbeats
its own row each leader tick):

- **Dashboard** — consensus (current leader, leadership **term**, backend,
  `healthy / total` members, state-store connectivity), a **stability** verdict
  (`stable` / `warning` / `degraded`) with leader uptime, total failovers and
  recent leader flaps, election cadence, an auto-derived **open-issues** list
  (member unreachable, state disconnected, no fresh leader, leader flapping,
  single-member-no-failover), and a members table. It also carries **per-platform
  admin tools**: a Docker one-click *Launch standby* (when the socket is mounted)
  plus promote / restart / scale / logs commands for AWS, GCP, Azure and Kubernetes.
- **Alerts & Logs** — a severity-tagged event feed (`ha_leader_acquired`,
  `ha_leader_lost`, `ha_state_error`, `ha_state_recovered`, `ha_standby_launched`)
  with critical/warning/info counters and an HA-only vs all-events filter.

### API

```
GET /api/isr/ha/status      # this instance's leader bit + actuation capability
GET /api/isr/ha/members     # full member registry (role, uptime, freshness)
GET /api/isr/ha/events      # HA event feed (?limit=N&all=1 for all state events)
GET /api/isr/ha/dashboard   # computed stability / consensus / performance / issues
POST /api/isr/ha/standby/launch   # Docker: clone this instance into a standby

# Guided setup (form / grow an HA cluster):
GET  /api/isr/ha/setup/preflight          # assess this node; recommended path + blockers
POST /api/isr/ha/setup/validate-dsn       # test-connect a Postgres DSN (nothing persisted)
POST /api/isr/ha/setup/provision-postgres # Docker: launch a Postgres for HA state, return DSN
POST /api/isr/ha/setup/form               # one-click: this node adopts the DSN at runtime (no restart) + launches a peer
```

A member is flagged unreachable once its last heartbeat is older than
`3 × leader_tick_seconds + 5s`.

## 2. VRRP — floating virtual IP (on-prem only)

`keepalived` floats one **virtual IP** across the ISR hosts, no external LB. **L2
/ on-prem only** — clouds block gratuitous-ARP VIP takeover; use the cloud LB
there instead. A `vrrp_script` health check
(`curl -sf http://localhost:9800/_admin/ready`) drops priority when the local ISR
is unhealthy so the VIP fails over. Master `priority 150`, backup `priority 100`,
same `virtual_router_id`/`auth_pass`/VIP; open IP protocol 112 between hosts.

## 3. BFISR — multi-site front door

A stable front-door address spanning regions via anycast / a global LB with
readiness-gated failover. Env-aware: on-prem = BGP/anycast (FRR/BIRD); each cloud
uses its native global frontend.

### BFISR on AWS

Customer BGP/ECMP anycast isn't exposed, so use **AWS Global Accelerator**:

1. Deploy an **ISR HA pair per region**, each behind a regional **NLB**.
2. Create a **Global Accelerator**; add a **listener** on the client port (e.g.
   TCP 8181).
3. Add an **endpoint group per region**; add each region's **NLB** as an
   endpoint. Set traffic dial/weights (100/0 active-passive, or split for
   active-active).
4. Global Accelerator health-checks the NLBs and withdraws a failed region while
   clients keep the same two static anycast IPs.

DNS alternative: Route 53 health checks with failover/latency routing to the
regional NLBs (easier, but failover is bounded by DNS TTL).

## FAQ

**Can ISR deploy Postgres itself on an isolated interface?** On Docker, the
guided setup launches a Postgres for HA state and returns its DSN
(`POST /api/isr/ha/setup/provision-postgres`), and the Docker pattern above
isolates it to an ISR-only network. On the other platforms the administrator
supplies Postgres — the managed offerings listed above are the usual choice.

**Isn't external Postgres a single point of failure?** A *single* instance is.
ISR degrades gracefully (data plane keeps serving during a Postgres blip), and you
run Postgres in an HA configuration (RDS Multi-AZ / Cloud SQL HA / Azure
zone-redundant, or Patroni/Stolon self-managed) so it isn't a SPOF.

**Why not embedded leader election with no Postgres?** That's embedded consensus
(Raft). Postgres advisory locks are the default because they deliver correct
leader election + a durable shared config store at near-zero implementation cost,
whereas a correct Raft build (log replication, snapshots, membership, fencing) is
substantial. An **opt-in embedded-Raft backend** (via `openraft`) is also
available:

```bash
ISR_STATE_BACKEND=raft
ISR_RAFT_NODE_ID=1                       # 2, 3, … per node
ISR_RAFT_PEERS=1=http://a:9800,2=http://b:9800,3=http://c:9800
```

It gives peer-to-peer election, log replication, and failover over ISR's own HTTP
with no external database. Status and the replicated key-value store are at
`GET /api/isr/raft/status`, `POST /api/isr/raft/kv`, `GET /api/isr/raft/kv/{key}`.
The Raft backend replicates its own key-value store; ISR's configuration store is
Postgres for HA and SQLite for a single node, so run the Postgres state store
described above for control-plane failover.
