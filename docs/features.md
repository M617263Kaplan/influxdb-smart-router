# ISR at a glance: every feature, and why it matters

Put an operations layer in front of InfluxDB 3 Enterprise, in minutes.

InfluxDB 3 Enterprise is a storage engine, and a very good one: ingest,
compaction, query, object-store durability. ISR is the operations layer that
sits in front of it, as one container. It adds what an operator reaches for
every day without changing the engine, and it explains every decision it makes:
every routing choice, scaling action and refused query carries the reasoning
that produced it.

This page is the short tour; [FEATURES.md](../FEATURES.md) is the full list with what makes each feature compelling. Each feature is one row: what it does, and what
that is worth to you. The [README](../README.md) has the long form, the
[docs index](README.md) has the how-to for each area, and
[install in minutes](../README.md#2-get-started-in-five-minutes) is one command.

## Get running

| Feature | What it does | Why it matters |
| :-- | :-- | :-- |
| One-command install | `install-mac.sh`, `install-linux.sh` or `install-windows.ps1` brings up ISR on Docker Desktop or Docker Engine; a Helm chart does the same on Kubernetes. | Console open, cluster adopted and first database created inside a few minutes, with nothing else to assemble. |
| Provision or adopt | ISR launches and scales InfluxDB 3 Enterprise nodes for you, with MinIO or your own S3, Blob or GCS behind them, or adopts a cluster you already run, including InfluxDB 3 Cloud and Cloud Dedicated. | You keep the cluster you have; ISR takes over the operating of it. |
| Getting Started wizard | A guided first run: administrator account, licence, cluster, database with retention, first token. | The first hour is a checklist, not a search. |
| Signed releases and in-app update | Every release ships a signed checksum manifest; the installers and the console's Update now verify it before loading an image. | You know what you are running, and upgrading is a button that keeps your state. |

## Security and access

| Feature | What it does | Why it matters |
| :-- | :-- | :-- |
| Scoped tokens | An ISR token is scoped to databases, actions, tables, fields, tags and query protocols. ISR mints the cluster credential behind it and the cluster credential never leaves ISR. | Hand a contractor, a dashboard or a device exactly what it needs. Revoke it in one click without touching the cluster. See [Scoped tokens](scoped-tokens.md). |
| Enforce on queries | With the switch on, ISR reads each query and checks the tables, fields and tags it reaches against the token's lists, on SQL, InfluxQL and Flight SQL, before the query is routed or served from cache. | Per-table and per-tag read scope that InfluxDB cannot express natively, enforced in the data path. |
| Roles and access review | Admin, operator and viewer roles, with an access review that answers "who can do what". | The console is an admin surface and is governed like one. |
| Two-factor and password policy | TOTP enrolment and reset by email for console accounts. | A second factor on the surface that controls everything else. |
| Blocklist | Block an IP, user, token or agent at the proxy and at login, as one control. | One switch that stops a bad actor everywhere, with no second door. |
| Tarpit and honeypot | Blocked or abusive traffic is answered slowly, by an isolated decoy serving synthetic data, until a dwell timer ends the session. The decoy is a separate node on its own network, with a memory store and no credentials. | A scanner that would find a refusal in milliseconds burns minutes on data that was never real, your cluster never sees the request, and every second is attributed. |
| Mutual TLS and request hardening | mTLS listeners for the data plane and replication, with certificate issue and rotation from ISR's own CA; request size, rate and shape limits. | Encrypted, authenticated transport and a safe-by-default envelope without hand-built PKI. |

## Traffic, routing and performance

| Feature | What it does | Why it matters |
| :-- | :-- | :-- |
| Routing rules and pools | Send traffic to the right pool by database, region, token, agent or cost, and simulate a rule before applying it. | Good traffic takes the fast path; expensive traffic is isolated. |
| Query cost engine | ISR runs `EXPLAIN` before a query executes, scores it, and can slow it, divert it to an isolated pool, or kill it. | One runaway `SELECT *` never becomes everybody else's latency. |
| Query cache | LRU and TTL caching in front of the query pool, with a hit header on every answer. | Repeated dashboard queries stop reaching the cluster at all. See [Query cache](query-cache.md). |
| Durable write queue | A write is acknowledged and parked on disk when the cluster is unreachable, then replayed. | An ingest outage costs latency, not data. |
| Load balancing | Latency-aware upstream selection across healthy nodes. | The healthy, nearest node serves the request. |
| Autoscaler | Scales vertically, then horizontally, then throttles, against your licensed core count. | Capacity that responds to load without exceeding what you are entitled to run. |
| Usage-based isolation | Give a noisy tenant a dedicated pool. | One tenant stops being everyone's problem. |
| Governance rules | Header and policy rules over live traffic, changed without a restart. | Behaviour changes are a setting, not a deployment. |

## Data governance and schema

| Feature | What it does | Why it matters |
| :-- | :-- | :-- |
| Databases with retention | Create a database with its retention before the first write. | You never inherit a schema or a retention you did not choose. |
| Schema data-type policy | ISR observes the type of every field, learns or takes an expected type, and on a mismatch coerces when safe, refuses, or records, per database. | A single mistyped field cannot quietly split or poison a series. |
| Schema registry | A versioned, declared contract per database and table: field types, required tags, allowed tags, enforced on write on the hub and every spoke. | Producers are held to a contract, and a change to it takes effect on the next write. See [Schema registry](schema-registry.md). |
| Compliance enforcement | PII redaction and data-residency rules applied in the data path. | Rules enforced where the data moves, not in a document. |
| Query-log retention | Keep classes of query logs for different periods. | Compliance without unbounded storage. |
| Data lifecycle and tiering | One policy expresses "keep raw at the edge for N days, ship a downsampled rollup to the hub". | You manage intent; ISR manages the moving parts. |

## Fleet, cloud and edge

| Feature | What it does | Why it matters |
| :-- | :-- | :-- |
| Hub and spokes | One hub, many spokes, across regions and clouds, enrolled over a management channel. | One place to operate a fleet, with upgrades pushed from the hub. |
| Federated query | A query fans out across the fleet and comes back as one answer. | Ask once, across regions. |
| Multi-region replication | Replicate between ISRs with per-table checkpoints and an audit ledger of every batch. | Resilience and residency without building a pipeline. |
| Edge autonomy | Across a WAN partition the edge buffers rather than drops, and replays on reconnect. | An occasionally connected site keeps working and loses nothing. |
| Cloud accounts and spoke provisioning | Connect AWS, Google Cloud or Azure; ISR provisions a regional spoke itself through a verified account, or emits a Terraform bundle you run where your credentials live. The hub holds a reference, never a key. | Spokes without handing a control plane your cloud keys. See [Deploying a spoke on AWS](deploying-a-spoke-on-aws.md). |
| High availability | ISR HA, VRRP and BFISR: three layers of redundancy to choose from. | The operations layer is not the single point of failure. See [High Availability](high-availability.md). |
| Call Home | External tools ask to connect; an administrator approves what each may use. | Integrations join on your terms. See [Call Home](call-home.md). |

## Getting data in

| Feature | What it does | Why it matters |
| :-- | :-- | :-- |
| Multi-protocol ingest gateway | Prometheus remote write, OTLP, Datadog, Graphite, StatsD, collectd and Loki land as line protocol; v1 and v2 clients speak to a v3 cluster. | Every writer you already have reaches InfluxDB 3 unchanged. See [Ingest Gateway](ingest-gateway.md). |
| Flight SQL | Arrow Flight SQL is terminated at ISR, with the same tokens, scopes and policies as HTTP. | Grafana, ADBC and JDBC clients get governed access, not a tunnel. |
| Migration from a 1.x backup | Point ISR at an InfluxDB 1.x portable backup on disk and it streams into InfluxDB 3. | No old cluster to resurrect. See [Migrating from a backup](backup-file-migration.md). |
| Line-protocol file import | A folder of `influx export` files is discovered, imported as a tracked job, and verified by a row count on the target. | An export you already have becomes a database, with parity shown. See [Importing line-protocol files](line-protocol-import.md). |
| Migration readiness | A dry run that says what a migration will do before it does it. | Conflicts found before the first row moves. See [Migration readiness](migration-readiness.md). |
| Edge Data Replication receiver | An OSS 2.x edge replicates through ISR into the database you pick. | Bring edges into InfluxDB 3 without touching the edge. |
| Backfill and Cloud Copy | Move history into a new cluster, or copy an adopted cloud database. | The past comes along. |

## Operations and intelligence

| Feature | What it does | Why it matters |
| :-- | :-- | :-- |
| Command Center | A live hierarchical map of every component and the traffic between them. | When something is slow you see where, rather than inferring it. See [Command Center](command-center.md). |
| Engine log and fleet-wide logging | One durable journal of what ISR's subsystems did, across hub and spokes. | Read an incident in time order across the whole fleet. See [Engine log](engine-log.md). |
| Alerts and notifications | Slack, email, PagerDuty and incident.io, with the reasoning and the remediation attached. | An alert tells you what to do, not just that something is red. |
| Connectivity and authentication alerting | Unreachable nodes, object stores and failing credentials raise alerts that resolve on recovery. | The things that break quietly are the things that page. |
| Rolling node upgrades | Upgrade one node at a time, compactor last, with rollback, from the console. | Version changes without a maintenance window. |
| Laura | An operator-grade assistant that reads real state, answers in plain language, proposes tuning with its reasoning, and acts when you hand it the wheel. Every action is logged and alerted. | Expertise on the cluster, available at 3 a.m. See [Embedded assistant](embedded-assistant.md). |
| Learning engine | Proposals with confidence and reasoning; optional autonomy per instance. | Approve a change, or let it run, never fleet-wide by accident. |
| Compaction knowledge base | What every compactor metric means and which flag helps. | Compactor telemetry becomes an action. |
| Backup and restore | Configuration snapshots with authenticated download; secrets omitted, tokens redacted. | Disaster recovery for the control plane that cannot leak a credential. |
| Telemetry export | Push ISR's own metrics to any InfluxDB. | ISR is monitored with the tooling you already have. |
| MCP server | ISR's operations exposed to agents and LLM tools. | Your automation speaks to the operations layer, not to the cluster. |

## Where to go next

- [Install in minutes](../README.md#2-get-started-in-five-minutes), then the [Getting Started wizard](../README.md#getting-started-console-wizard).
- [Every console tab, and why it exists](../README.md#3-every-tab-and-why-it-exists).
- [Tokens: the part people underestimate](../README.md#8-tokens-the-part-people-underestimate).
- [All releases](https://github.com/M617263Kaplan/influxdb-smart-router/releases), each with signed assets and how to verify them.
- [TELEMETRY.md](../TELEMETRY.md): the one daily report ISR sends to its maintainers, every field listed, one switch to turn it off.
