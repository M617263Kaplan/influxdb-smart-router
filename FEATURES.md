# ISR features, and what makes each one compelling

Put an operations layer in front of InfluxDB 3 Enterprise, in minutes.

InfluxDB 3 Enterprise is the storage engine: ingest, compaction, query, and
object-store durability. ISR is the operations layer in front of it, shipped as
one container. Everything on this page is something an operator would otherwise
build, script, or go without. Each feature is described twice: what it does,
and the reason it earns its place.

Running theme: **ISR explains itself.** Every routing decision, scaling action,
refused query and alert carries the reasoning that produced it. You should
never have to guess why something happened.

Contents: [Getting running](#getting-running) · [Access and security](#access-and-security) ·
[Traffic, routing and performance](#traffic-routing-and-performance) ·
[Data governance and schema](#data-governance-and-schema) · [Fleet, cloud and edge](#fleet-cloud-and-edge) ·
[Getting data in](#getting-data-in) · [Operations and visibility](#operations-and-visibility) ·
[Intelligence](#intelligence) · [Integrations](#integrations)

---

## Getting running

### One-command install
`install-mac.sh`, `install-linux.sh` or `install-windows.ps1` brings ISR up on Docker Desktop or Docker Engine; a Helm chart does the same on Kubernetes. Every release carries a signed manifest, and the installers verify it before loading an image.

**Compelling because:** the console is open, a cluster is adopted and the first database exists inside a few minutes, with nothing else to assemble, and you know the bytes you ran are the bytes that were published.

### Provision, or adopt what you have
ISR launches and scales InfluxDB 3 Enterprise nodes for you, with MinIO or your own S3, Blob or GCS behind them. It also adopts a cluster you already run, and InfluxDB 3 Cloud or Cloud Dedicated instances, using each instance's own token for every data-plane operation.

**Compelling because:** you keep the cluster you have and the way you built it; ISR takes over the operating of it, not the owning of it.

### Getting Started wizard
A guided first run: administrator account, licence, cluster, database with retention, first token.

**Compelling because:** the first hour is a checklist, not a search through documentation.

### In-app update
Operations → ISR Updates verifies a release against its signed manifest, loads the image and recreates ISR on it. Admins, tokens, policies, pools and routing rules stay; the InfluxDB nodes are untouched; a hub pushes the new image to its spokes.

**Compelling because:** upgrading the operations layer is a button, and it cannot be fed an image nobody signed.

---

## Access and security

### Scoped tokens
An ISR token is scoped to databases, actions (read, write, both), tables, fields, tags and query protocols (HTTP, Flight SQL). ISR mints the cluster credential behind the token and that credential never leaves ISR. Tokens are stored fingerprinted, never in the clear, and every use is attributable in the audit, cost and bad-query journals.

**Compelling because:** an InfluxDB cluster token is close to all-or-nothing and belongs to the cluster. With ISR you hand a contractor, a dashboard or a device exactly what it needs, and revoking it is one click that touches nothing else. See [Scoped tokens](docs/scoped-tokens.md).

### Enforce on queries
With the switch on, ISR reads each query a token sends, on SQL, InfluxQL and Flight SQL, and checks every table, field and tag the statement reaches against the token's lists, before the query is routed and before the query cache answers.

**Compelling because:** per-table and per-tag read scope is something InfluxDB cannot express natively. ISR enforces it in the data path, on every protocol, and a change to a token applies on its next request.

### Roles and access review
Admin, operator and viewer roles for the console, with an access review that answers "who can do what".

**Compelling because:** the console controls the cluster, so it is governed like the production surface it is.

### Two-factor and password policy
TOTP enrolment and reset by email for console accounts.

**Compelling because:** a second factor on the one login that can reach everything.

### Blocklist
Block an IP, user, token or agent as one control, applied at the proxy before any routing or scope logic runs, and at login.

**Compelling because:** there is no second door. One entry stops a bad actor everywhere.

### Tarpit and honeypot
Blocked or abusive traffic is not refused; it is answered slowly by a decoy serving plausible synthetic data, until a dwell timer ends the session. The decoy is a separate node on its own network, backed by a memory store, holding no object-store credential and no admin token.

**Compelling because:** a scanner that would find a refusal in milliseconds and move on instead burns minutes on data that was never real. Your cluster never sees the request, every second is attributed, and the decoy is a dead end by construction.

### Mutual TLS, built-in CA
mTLS listeners for the data plane and for replication, with certificates issued and rotated from ISR's own CA, and a one-click bundle for a replication peer.

**Compelling because:** encrypted, authenticated transport without hand-built PKI, and rotation that refuses a certificate whose key does not match.

### Hardening and resource safety
Decompression ceilings, bounded admission by request count and by bytes in flight, bounded response buffering, a finite durable write queue, disk-aware backpressure, graceful drain on shutdown, supervised background loops. Every limit is a setting with a stated default.

**Compelling because:** the defaults shed load and recover rather than exhaust the host, so one flood of large requests or one filling disk does not take the operations layer down with it.

---

## Traffic, routing and performance

### Routing rules and pools
Send traffic to the right pool by database, region, token, agent or query cost. Simulate a rule against live traffic before applying it.

**Compelling because:** good traffic gets the fast path and expensive traffic is isolated, and you can see what a rule would have done before it does it.

### Query cost engine
ISR runs `EXPLAIN` before a query executes, scores it, and can slow it, divert it to an isolated pool, or kill it, with the plan and the score kept in the query audit.

**Compelling because:** one runaway `SELECT *` never becomes everybody else's latency, and the evidence for "which query is hurting us" is already collected.

### Query cache
LRU and TTL caching in front of the query pool, with a cache-hit header on every answer. Scope is judged before the cache is consulted.

**Compelling because:** repeated dashboard queries stop reaching the cluster at all, and a narrowed token cannot keep reading its earlier answer. See [Query cache](docs/query-cache.md).

### Durable write queue
When the cluster is unreachable a write is acknowledged, parked on disk and replayed. The queue is durable across a host power loss and finite by default, so an extended outage applies backpressure before it fills the disk.

**Compelling because:** an ingest outage costs latency, not data.

### Load balancing
Latency-aware selection across healthy upstream nodes.

**Compelling because:** the healthy, nearest node serves each request without a separate balancer to run.

### Autoscaler
Scales vertically, then horizontally, then throttles, against your licensed core count.

**Compelling because:** capacity follows load without provisioning cores you are not entitled to run.

### Usage-based isolation
Give a noisy tenant a dedicated pool.

**Compelling because:** one tenant stops being everyone's problem, and the move is a routing change rather than a migration.

### Governance rules
Header and policy rules over live traffic, changed without a restart.

**Compelling because:** behaviour changes are a setting, not a deployment.

---

## Data governance and schema

### Databases with retention
Create a database with its retention before the first write, from the console or the wizard.

**Compelling because:** you never inherit a schema or a retention you did not choose.

### Schema data-type policy
ISR observes the type of every written field, learns or takes an expected type per field, and on a mismatch coerces when the conversion is exact, refuses, or records, by a per-database mode. Mismatches collect as amendments an operator approves, declines or resolves by renaming.

**Compelling because:** in a schema-on-write database one mistyped field can split or poison a series. ISR catches it at the door, and tells you what it saw.

### Schema registry
A versioned, declared contract per database and table: field types, required tags, an allowed-tag set. Enforced on write on the hub and, after one propagate, on every spoke. A change takes effect on the next write.

**Compelling because:** producers are held to a contract you wrote down, the way Confluent holds Kafka topics to one, and nothing has offered that for time series. See [Schema registry](docs/schema-registry.md).

### Compliance enforcement
PII redaction per tag or field (redact, hash, or drop) and data-residency routing: a write carrying a residency tag goes to a compliant destination, mixed batches are split per line, and a write with nowhere compliant to go is refused rather than stored locally.

**Compelling because:** the policy is enforced where the data moves, not in a document, and regulated data fails safe.

### Query-log retention
Keep classes of query logs for different periods.

**Compelling because:** compliance without unbounded storage.

### Data lifecycle and tiering
One policy expresses "keep raw at the edge for N days, continuously ship a downsampled rollup to the hub". Applying it creates the replication job and sets the edge retention.

**Compelling because:** you manage intent; ISR manages the moving parts.

---

## Fleet, cloud and edge

### Hub and spokes
One hub, many spokes, across regions and clouds, enrolled over a mutually authenticated management channel. Jobs, logs and upgrades are visible and driven from the hub.

**Compelling because:** one place to operate a fleet, and a spoke's work never means opening its console.

### Federated query
Ask one question and get one answer from clusters in several regions and clouds, adopted Cloud instances included. Any instance ISR could not reach is named.

**Compelling because:** a partial fleet is never presented as the whole one.

### Multi-region replication
Mirror databases between ISRs over mutual TLS with confirm-before-clear: a write leaves the local buffer only when the destination acknowledges it. Per-target cursors, so one unreachable destination cannot stall the others; an audit ledger of every batch shipped; fidelity counters for anything that could not be reproduced exactly.

**Compelling because:** resilience and residency without building a pipeline, with a queryable record of what went where.

### Edge autonomy
When the link drops an edge ISR keeps accepting writes into a durable queue and replays them when connectivity returns.

**Compelling because:** an occasionally connected site keeps working, and writes are never lost during a disconnection.

### High availability
Leader election with VRRP failover, reads and writes continuing through it; an embedded consensus backend as an opt-in alternative with no external database.

**Compelling because:** the operations layer is not the single point of failure. See [High Availability](docs/high-availability.md).

### Cloud accounts and spoke provisioning
Connect AWS, Google Cloud or Azure. ISR provisions a regional spoke itself through a verified account, or emits a Terraform bundle you run where your credentials already live. The hub holds a reference, never a key.

**Compelling because:** a control plane holding static cloud keys has a blast radius of the whole account. ISR acts through roles, profiles and references instead. See [Deploying a spoke on AWS](docs/deploying-a-spoke-on-aws.md).

### Cloud adoption
Adopt InfluxDB 3 Cloud and Cloud Dedicated instances: discover with a management token, operate with each instance's own token, route live client traffic transparently, copy or migrate into or out of them.

**Compelling because:** managed cloud without giving up ISR's routing, governance, tokens and observability.

---

## Getting data in

### Multi-protocol ingest gateway
Prometheus remote write, OTLP, Datadog, Graphite, StatsD, collectd and Loki land as line protocol, compressed bodies included. v1 and v2 clients speak to a v3 cluster.

**Compelling because:** every writer you already have reaches InfluxDB 3 unchanged. See [Ingest Gateway](docs/ingest-gateway.md).

### Flight SQL, terminated at ISR
Arrow Flight SQL is served by ISR itself, with the same tokens, scopes, policies and journals as HTTP.

**Compelling because:** Grafana, ADBC and JDBC clients get governed access rather than a tunnel around the gateway.

### Migration from a 1.x backup
Point ISR at an InfluxDB 1.x portable backup on disk and it streams straight into InfluxDB 3.

**Compelling because:** no old cluster to resurrect. See [Migrating from a backup](docs/backup-file-migration.md).

### Import a directory of line-protocol files
Point the wizard at a folder of `influx export` files under the import root. ISR discovers the databases, tables and point counts, refuses to start with nothing to import, writes in batches through its own path as a job with a status you can follow, and ends by counting the rows on the target.

**Compelling because:** an export you already have becomes an InfluxDB 3 database with parity shown, not assumed. See [Importing line-protocol files](docs/line-protocol-import.md).

### Migration readiness
A metadata-only dry run that says what a migration will do before it does it.

**Compelling because:** conflicts are found before the first row moves. See [Migration readiness](docs/migration-readiness.md).

### Migration from OSS and SQL sources
Guided migration into an InfluxDB 3 cluster from local files and live sources, readiness first, with per-destination batch sizing.

**Compelling because:** the move is planned and paced for each destination, not assumed.

### Edge Data Replication receiver
An OSS 2.x edge replicates through ISR into the database you pick.

**Compelling because:** edges join InfluxDB 3 without touching the edge.

### Backfill and Cloud Copy
Move history into a new cluster, or copy an adopted cloud database.

**Compelling because:** the past comes along.

---

## Operations and visibility

### Command Center
A live hierarchical map of every component and the traffic between them, on one canvas.

**Compelling because:** when something is slow you see where, rather than inferring it. See [Command Center](docs/command-center.md).

### Engine log and fleet-wide logging
One durable journal of what ISR's own subsystems did, across hub and spokes, distinct from the request log.

**Compelling because:** an incident reads in time order across the whole fleet. See [Engine log](docs/engine-log.md).

### Alerts and notifications
Slack, email, PagerDuty and incident.io, with the reasoning and the remediation attached to each alert.

**Compelling because:** an alert tells you what to do, not just that something is red.

### Connectivity and authentication alerting
Unreachable nodes, object stores and failing credentials raise alerts that resolve when the subject recovers.

**Compelling because:** the things that break quietly are the things that page.

### Rolling node upgrades
Upgrade one InfluxDB node at a time, compactor last, with rollback, from the console, after ISR has discovered which builds exist.

**Compelling because:** version changes without a maintenance window.

### Per-database analytics
Storage, writes, reads and retention per database.

**Compelling because:** cost and growth have an owner.

### Backup and restore
Configuration snapshots with authenticated download; secrets omitted and tokens redacted by design.

**Compelling because:** disaster recovery for the control plane that cannot leak a credential.

### Telemetry export
Push ISR's own metrics to any InfluxDB you choose.

**Compelling because:** ISR is monitored with the tooling you already have.

### Reporting to the maintainers
A daily, fixed, coarse report that this deployment exists. Every field is listed in [TELEMETRY.md](TELEMETRY.md); one switch turns it off.

**Compelling because:** you can read exactly what leaves, and stop it.

---

## Intelligence

### Laura
An operator-grade assistant that reads real state, answers questions about the cluster in plain language, proposes tuning with its reasoning attached, and acts when you hand it the wheel. Every action is logged and alerted.

**Compelling because:** expertise on the cluster at any hour, that never guesses and never acts unseen. See [Embedded assistant](docs/embedded-assistant.md).

### Learning engine
Proposals with confidence and reasoning; optional autonomy, granted per instance.

**Compelling because:** approve a change, or let it run, and never fleet-wide by accident.

### Pipeline optimisation
Schema, write and query recommendations grounded in the official guidance, scored by impact.

**Compelling because:** the advice is ranked and sourced, not generic.

### Compaction knowledge base
What every compactor metric means and which flag helps.

**Compelling because:** compactor telemetry becomes an action.

### Training Mode
Learn ISR on a sandbox before pointing it at production.

**Compelling because:** the first mistakes are made somewhere that does not matter. See [Training Mode](docs/training-and-journey.md).

---

## Integrations

### Grafana, SQL and InfluxQL
Grafana connects through ISR over SQL or InfluxQL; its queries appear in the decision log and expensive-query views with full attribution.

**Compelling because:** dashboards get the same controls as every other client.

### MCP server
ISR's operations exposed to agents and LLM tools over the Model Context Protocol.

**Compelling because:** your automation speaks to the operations layer, with its tokens and audit, not to the cluster directly.

### Call Home
External tools ask to connect; an administrator approves what each may use.

**Compelling because:** integrations join on your terms. See [Call Home](docs/call-home.md).

### Admin API
Everything the console does is an authenticated API, documented in the [README](README.md#admin-api-reference).

**Compelling because:** anything you can click, you can script.

---

Next: [install in minutes](README.md#2-get-started-in-five-minutes), the [one-page glance](docs/features.md), the [docs index](docs/README.md), and [all releases](https://github.com/M617263Kaplan/influxdb-smart-router/releases).
