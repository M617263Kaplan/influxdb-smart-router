# ISR and InfluxDB 3.11

InfluxDB 3.11 makes the **PachaTree** storage engine the default and adds
node-native tooling (Explorer), row-level deletes, and renamed launch flags. ISR
is engine-aware, so its storage analytics, query guardrails, token scoping, and
node provisioning work on PachaTree clusters.

**New clusters default to `influxdb:3.11.0-enterprise`.** The pinned tag is
deliberate rather than the floating `3.11-enterprise`: a floating tag moves under
a cluster that has already recorded what it launched.

**Upgrading to PachaTree is one-way.** Once a 3.11 node has written to a
PachaTree store, the checkpoint version moves forward and an earlier image does
not open it (`Unsupported V2 checkpoint version: 10 (expected 2..=9)`). Plan the
roll in one direction.

---

## PachaTree is the default engine — storage and cost are PachaTree-aware

On PachaTree, `system.parquet_files` is empty (there are no Parquet files — data
lives in `.pt` run-sets), and storage is accounted **cluster-wide, sharded by
window/shard**, not per database. Two places in ISR are engine-aware:

- **Database storage sizing** (Databases page). When `system.parquet_files`
  comes back empty, ISR reads a cluster total from `system.pt_compaction_files`
  (compacted) + `system.pt_ingest_files` (not-yet-compacted). Because PachaTree
  accounts storage cluster-wide, the per-database figure is shown as
  *cluster-sharded* and the real number appears in the cluster total, clearly
  labelled. Parquet clusters are sized per database as before.

- **Query cost / EXPLAIN guardrail.** ISR asks the node to `EXPLAIN` a query
  (plan only, nothing scanned) and scores its scan breadth. PachaTree plans have
  no `.parquet` files; the breadth lives in the `run_sets` / `wal_files` /
  `gen0_files` a `PachaTreeWindowExec` / `PachaTreeBufferExec` lists, and — most
  reliably — in the `est_rows` / `est_bytes` those nodes always print. ISR reads
  those and bands the cost on the engine's own byte estimate, so every query on a
  PachaTree cluster is scored for badness and the expensive-query pool.

## InfluxDB 3 Explorer runs as a webui-mode node

From 3.11, Explorer is served by an InfluxDB node running with `--mode webui` — a
normal data node (`mode=all`/`ingest`/`query`) returns **404** at `/` and does
not serve it. So the Getting Started "load a dashboard tool" step launches a
**dedicated `webui`-mode node** (the cluster's own image, an auto-generated
`--webui-session-secret`, the cluster's license) and hands back its URL plus the
connect values — a scoped, revocable `isrt_` token that routes Explorer's queries
through ISR's policy, routing, and caching (it shows up on **Monitor → Client
Apps**). If no license is on hand (for example a trial cluster), ISR mints the
token and hands you the connect values to use with the standalone Explorer app or
a `webui`-mode node you run yourself. Grafana is launched by ISR as a separate
container.

## Testing a release candidate

A release-candidate image can be made a **selectable node image** in ISR's
catalog. ISR offers it but never recommends it, and never selects an RC as the
default merely because it is newer — do not run an RC in production. An RC is
distributed as a **binary tarball**, not a Docker image, so wrap it once:

```dockerfile
FROM influxdb:3-enterprise
USER root
COPY influxdb3 /usr/bin/influxdb3            # from the RC tarball
COPY python    /usr/lib/influxdb3/python
RUN chmod 0755 /usr/bin/influxdb3
USER influxdb3
```

Build it as, for example, `influxdb:3.11.0-0.rc.1-enterprise` (the tag must
contain `enterprise` so ISR treats it as a data-plane image), then pick it in the
version catalog. A local image launches with no pull. Launch-gating, PachaTree
storage accounting, EXPLAIN cost, and the webui Explorer all apply to it.

## Row-level deletes are governed

3.11 adds `POST /api/v3/row_delete_requests`. Because a delete is neither a write
nor a query path, ISR gates it explicitly:

- **Token scope.** Deleting rows is a write-class mutation, so a read-only or
  query-only token is refused, and the request's target database + table must be
  inside the token's allow-lists. A request whose target can't be verified (for
  example an abort-by-sequence under a database-scoped token) fails closed.
- **Routing.** Delete requests are routed to an ingest-capable node, alongside
  writes, rather than a query-only node.

## Node launch flags are version-gated

With PachaTree the default, `--use-pacha-tree` is a deprecated, migration-loaded
opt-in, and the Enterprise license env vars are `INFLUXDB3_LICENSE_*` (the
older `INFLUXDB3_ENTERPRISE_LICENSE_*` names are accepted with a warning). When
ISR launches a node it emits the modern flags for any image that resolves to
3.11+, and for any image whose version it **cannot** determine. This applies to
both the Docker and Kubernetes node-launch paths.

ISR installs InfluxDB 3 Enterprise 3.11 or later, so an image whose version
cannot be read is a modern node and gets the modern flags; a deprecated flag is
never bolted onto it. The Docker path resolves the series from the image itself
(`influxdb3 --version`) rather than from its tag, so a floating or mislabelled
tag still gets the right answer; the fallback applies only when even that fails.
