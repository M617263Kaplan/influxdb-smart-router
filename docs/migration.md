# Migrating into InfluxDB 3

Everything ISR can move into InfluxDB 3 Enterprise, and how to drive each one.

InfluxDB 3's schema is **immutable and first-write-wins**: the first point to
create a column fixes its name, its type and whether it is a tag or a field.
Nothing later can change it. That single fact shapes every path below — the
source has to be made v3-legal *on the way in*, not afterwards, which is why
each route starts with a read-only step that tells you what will happen before
anything is written.

| You have | Route | Deep dive |
| :-- | :-- | :-- |
| A running InfluxDB 1.x / 2.x you can reach | [Live source](#live-source) | [Migration readiness](migration-readiness.md) |
| A folder of `influx export` line-protocol files | [Local files](#local-files) | [Line-protocol import](line-protocol-import.md) |
| A folder of Parquet files | [Local files](#local-files) | below |
| A portable 1.x backup directory | [Portable backup](#portable-backup) | [Backup-file migration](backup-file-migration.md) |

All calls below need an admin session. Replace `<isr>` with your ISR host and
`<session>` with the session header the console uses; every example is a `POST`
with `content-type: application/json` unless noted.

---

## Live source

ISR reads the source over its own query API and writes line protocol into the
target, measurement by measurement, in time windows. It never needs filesystem
access to the source.

**Sources that work this way**

| `kind` | What it is | Read via |
| :-- | :-- | :-- |
| `influx-oss-v1` | InfluxDB OSS 1.x | InfluxQL |
| `influx-ent-v1` | InfluxData 1.x Enterprise | InfluxQL |
| `influx-oss-v2` | InfluxDB OSS 2.x | Flux, falling back to InfluxQL |
| `cloud2` | InfluxDB Cloud 2 (TSM) | Flux, falling back to InfluxQL |
| `serverless` | InfluxDB Cloud Serverless | Flux, falling back to InfluxQL |

The fallback matters: when a source's Flux API is unavailable or disabled, ISR
switches to the InfluxQL compatibility endpoint and says so in the job feed
(`source Flux API unavailable — reading via native InfluxQL`). You do not need
to configure which one is used.

### 1. Check the source answers

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/test-source" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"kind":"influx-oss-v2","host":"http://src:8086","org":"acme","bucket":"telemetry","token":"<source token>"}'
```

`source-discover` then lists the measurements and field keys ISR can see — the
same view the migration wizard shows.

### 2. Assess before you write

The readiness assessment is read-only and reports every v3-illegal thing in the
source schema, each with a menu of fixes. **Run it first.** It is covered in
full in [Migration readiness](migration-readiness.md), and it is the step that
produces the `resolution_plan` used below.

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/assess" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"host":"http://src:8086","bucket":"telemetry","kind":"influx-oss-v1"}'
```

It finds tag/field collisions, type conflicts, and tables over the target
engine's column or table ceilings.

### 3. Preview the transform

`preview` converts a sample through the plan and hands back the exact line
protocol that would be written. Nothing is sent to the target.

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/preview" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"source":{...},"plan":{"measurements":{}},"sample":10}'
```

### 4. Start

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/start" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{
        "source": {"kind":"influx-oss-v1","host":"http://src:8086","bucket":"telemetry"},
        "target": {"cluster":"prod","schema_aware":true},
        "mappings": [{"source_bucket":"telemetry","target_bucket":"telemetry","retention":"30d"}],
        "mode": "sequential",
        "resolution_plan": {"measurements":{}}
      }'
```

| Field | Meaning |
| :-- | :-- |
| `source` | `kind`, `host`, `bucket`, and `org`/`token` for v2-family sources. `connection` names a saved Connection instead, and its URL and token are filled in for you. |
| `target.cluster` | The registered cluster to write to. A cluster is a hard routing boundary — ISR will not write a database to a cluster that does not own it. |
| `target.schema_aware` | Reconcile each batch against the destination's existing column types on the way in. See [Schema-aware writes](#schema-aware-writes). |
| `mappings` | One entry per source database → target database, with an optional `retention`. |
| `mode` | `sequential` (default) or `concurrent`. Concurrent overlaps the time windows **within** a database; databases are still migrated one after another. |
| `resolution_plan` | The remediation from step 2, applied to every window on the way in. Empty means a straight copy. It is stored with the job, so it survives a resume. |
| `org` | Optional. Bills the job to an Organization, so it appears on that tenant's Billing page. |

**One migration runs at a time.** A second `start` while one is running returns
`409 a migration is already running`. This is deliberate — two concurrent runs
would compete for the same write path — but it does mean an automated caller
should check `status` first rather than assume.

### 5. Watch it

```bash
curl -s "http://<isr>:9800/api/isr/migration/status?id=<job id>" \
  -H "X-ISR-Admin-Session: <session>"
```

`running` is the field to poll. The terminal `status` is one of:

| `status` | Meaning |
| :-- | :-- |
| `completed` | Every row landed. |
| `completed_with_drops` | Finished, but rows were discarded as uncoercible — `rows_dropped` says how many. |
| `completed_with_errors` | Finished with at least one rejected batch; `errors` is non-zero. |
| `failed` | At least one database failed outright. |
| `canceled` | Stopped by an operator. |

The three `completed*` values are distinct on purpose: a run that discarded
rows is not a clean one, and a dashboard that shows only "completed" would hide
it. `points` against `total_points` tells you the same story in numbers.

### 6. Cancel, if you need to

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/cancel" \
  -H "X-ISR-Admin-Session: <session>"
```

Cancellation takes effect at the next window boundary and the job finalises as
`canceled` with the rows already written left in place. It is honoured whether
the job is still setting up or part-way through writing.

### 7. Verify at the destination

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/validate" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"source":{...},"target":{"cluster":"prod"},"target_db":"telemetry","plan":{"measurements":{}}}'
```

Per measurement it compares the source row count against the destination's, and
the sums of numeric fields the plan did not touch. Read `rows_verdict`:

| Verdict | Meaning |
| :-- | :-- |
| `match` | Counts agree, allowing for rows the plan drops. |
| `target-short` | Rows the source has never arrived — re-run or backfill. |
| `target-surplus` | The target holds rows the source does not, the signature of a delete that did not follow. Re-running will **not** fix this. |
| `unverified` | The target count could not be read. **This is not a statement about your data** — `target_rows_error` says why, and `rows_unverified` counts how many measurements are in this state. |

A surplus and a shortfall have opposite remedies, which is why they are
reported separately rather than as one "parity failed".

---

## Local files

For data you already have on disk: line protocol from `influx export`, or
Parquet.

### The import root

ISR only reads files beneath a confined **import root**, so a path cannot
escape it. Inspect and set it from Migration → Import root, or:

```bash
curl -s "http://<isr>:9800/api/isr/migration/import-root" -H "X-ISR-Admin-Session: <session>"
```

The response lists candidate roots ISR can see — including any directory you
have bind-mounted into the container — and which one is active. You can also
set it before start-up with `ISR_MIGRATION_IMPORT_ROOT`.

If the files are on your machine rather than ISR's, upload them instead:
`POST /api/isr/migration/upload?name=<file>&offset=<n>` takes raw bytes in
16 MiB chunks and resumes from an offset, so a large file survives a dropped
connection. `GET /api/isr/migration/uploads` lists what has landed.

### Line protocol

`browse-local` and `scan-local` show what is there; `discover-local` reads the
`# CONTEXT-DATABASE:` markers `influx export` writes and reports the databases
it found. Then:

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/import-local" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"path":"exports","target_cluster":"prod",
       "mappings":[{"source_db":"telemetry","target_db":"telemetry"}]}'
```

Full walkthrough: [Importing a directory of line-protocol files](line-protocol-import.md).

### Parquet

`parquet-preview` reads only the file footer — no rows — and infers a mapping:
which column is the timestamp, which columns become tags, which become fields.

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/parquet-preview" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"path":"backfill/day_1.parquet"}'
```

Check that mapping before importing. **A column placed in the series key cannot
be moved later** — that is the immutability rule again — and a high-cardinality
column promoted to a tag is expensive to live with. Override anything the
inference got wrong with `time`, `tags` and `fields`:

```bash
curl -s -X POST "http://<isr>:9800/api/isr/migration/import-parquet" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"path":"backfill","target_cluster":"prod","target_db":"backfill",
       "measurement":"readings",
       "time":"UPDATED_AT","tags":["REGION","METRIC_TYPE"],
       "fields":["ACTIVITY_TO_DATE","THIS_DAY"],
       "dry_run":true,"max_rows":1000}'
```

| Field | Meaning |
| :-- | :-- |
| `path` | A file, or a directory — every Parquet file beneath it is imported in name order. **Required**: a request with no path is refused rather than importing the whole root. |
| `measurement` | The destination table. Defaults to the directory name for a multi-file import, else the file stem. |
| `time` / `tags` / `fields` | Override the inferred roles. An explicit empty `time` means "stamp at write time". |
| `dry_run` | Convert and count, write nothing. Returns `rows_read`, `lines`, a `sample` of the line protocol, and the plan. |
| `max_rows` | Stop after exactly this many rows. Useful with `dry_run` to see a mapping cheaply on a large file. |

Run it with `dry_run` first, read the `sample`, then run it for real.

---

## Portable backup

A 1.x portable backup directory can be expanded straight into InfluxDB 3
without standing the old server back up. `backup/scan` registers a backup
directory under the import root, `backup/export` runs the conversion, and
`backup/status` follows it. Fan-out to several destinations, resume, and
time-windowing are all supported.

Full walkthrough: [Migrating from an InfluxDB 1.x portable backup](backup-file-migration.md).

---

## Schema-aware writes

With `target.schema_aware` set, ISR reads the destination table's existing
column types before each batch and reconciles the incoming points against them:
a value that fits the existing column is coerced, and one that cannot be
represented is discarded rather than rejecting the whole batch.

That trade is worth being explicit about. Reconciliation keeps a run moving
when a handful of points disagree with a column established months ago — but
**discarded rows are gone**. The job reports them: the database's bucket ends
`done_with_drops`, the feed says how many rows were discarded and why, and the
job's terminal status is `completed_with_drops` rather than `completed`.

If you would rather not lose anything, leave `schema_aware` off and fix the
type conflict in the `resolution_plan` instead — an explicit `coerce_fields`
entry converts every point rather than discarding the ones that disagree.

---

## The resolution plan

The plan is how a source is made v3-legal on the way in. It is produced by the
readiness assessment, editable before you start, and applied to every window.
Per measurement:

| Operation | Use it for |
| :-- | :-- |
| `rename_measurement` | Route a measurement's points to a different table — the workhorse for a tag/field collision or a column-limit split. |
| `rename_fields`, `rename_tags` | Old name → new name. |
| `drop_fields`, `drop_tags` | Leave a column behind entirely. |
| `coerce_fields` | Field → `integer`, `float`, `boolean` or `string`. A float coerced to integer floors; `0` becomes `false` and non-zero `true`. |
| `add_tags` | Add a tag to every point — a distinguishing marker when deduping into a new table. Skipped where the point already carries that tag. |

```json
{"measurements":{
  "cpu":{"rename_measurement":"cpu_v3",
         "rename_fields":{"usage":"usage_pct"},
         "coerce_fields":{"usage_pct":"float"},
         "drop_tags":["host_legacy"],
         "add_tags":{"migrated":"2026"}}}}
```

An empty plan is a straight copy.

---

## Values and types

Two things ISR guarantees, both of which are easy to get wrong and expensive to
discover afterwards:

**Integers stay exact.** A 64-bit integer from the source arrives intact,
including values above 2⁵³ that no double can represent, and an unsigned 64-bit
value keeps both its magnitude and its unsignedness — it lands in a `UInt64`
column, not a saturated signed one.

**A declared type does not override the data.** InfluxDB 1.x field types are
per-shard, so a field written as an integer in one shard and a float in the
next reports one type for both. Where a value cannot be represented by the
declared type, ISR preserves the value rather than truncating it to match the
declaration.

---

## Where jobs show up

Every migration is a tracked job. `GET /api/isr/migration/jobs` lists the
recent ones; the console shows them under Migration, and each completed run
gets a dashboard under Data Movement with the plan that was configured against
what actually happened, source rows sent against destination rows written, and
throughput. Jobs attributed to an Organization also appear on its Billing page.

---

## See also

- [Migration readiness — the dry run](migration-readiness.md)
- [Importing a directory of line-protocol files](line-protocol-import.md)
- [Migrating from an InfluxDB 1.x portable backup](backup-file-migration.md)
- [ISR Cross-Cloud Migration & Replication — Admin Validation Runbook](cross-cloud-validation-runbook.md)
- [Schema registry](schema-registry.md) — what ISR knows about a destination's schema
