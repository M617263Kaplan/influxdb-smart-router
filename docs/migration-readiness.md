# Migration readiness — the dry run

Migrating from InfluxDB v1 (Enterprise) or v2 into InfluxDB 3 (Enterprise / Cloud
Dedicated / Clustered) is rarely a straight copy: v3's schema is **immutable and
first-write-wins**, so the source has to be made v3-legal *on the way in*. ISR's
migration **readiness assessment** is a read-only "dry run" that scans the source
schema and reports every problem up front, each with a menu of fixes — so nothing
is discovered broken half-way through a run.

It automates, live against the source, the same checks operators would otherwise
run by hand with shell scripts over `SHOW TAG/FIELD KEYS`.

## Run it

```bash
curl -s -X POST "http://<isr-host>:9800/api/isr/migration/assess" \
  -H "X-ISR-Admin-Session: <session>" -H 'content-type: application/json' \
  -d '{"host":"http://<source>:8086","bucket":"<database>","kind":"influx-ent-v1"}'
```

Optional query params: `?target=pachatree` relaxes the limits for a 3.11 PachaTree
Enterprise target (the default is the strict Cloud Dedicated / Clustered profile);
`?db=a,b` limits the scan to specific databases.

The scan is **metadata-only** — no data is read. It reads an InfluxQL source
(`kind: influx-ent-v1`), where `SHOW FIELD KEYS` exposes per-field types and so
surfaces type conflicts directly.

## In the console

The migration wizard carries the whole loop as a **Readiness dry-run** step, so an
operator never has to touch the API:

1. **Assess** — one click scans the configured source and renders the verdict table
   below, each row with a **remediation drop-down** pre-filled with the safe default.
2. **Resolve** — the drop-down selections are folded into a resolution plan as you
   pick them (no separate build step).
3. **Preview** — shows the plan applied to a live sample as **before → after** line
   pairs, so you can confirm the fixes do what you expect before committing.
4. **Migrate** — the plan rides the normal *Start migration* button (it is attached
   to the run config automatically).
5. **Validate** — after a run, pick the job and validate parity against the expected
   post-transform values.

**Multiple dry runs at once** are handled by a **job selector**, not stacked panes:
each assessment/run is a persisted job labelled by *source · database → target*, and
the selector switches between them. Dry runs are cheap read-only jobs; many can
exist, while one migration *runs* at a time.

## What it checks

| Verdict | What it means | Remediations offered |
|---------|---------------|----------------------|
| **tag/field collision** | a key is used as both a tag and a field (v3 forbids it) | rename the field · rename the tag · keep one · route the field to a new table |
| **field-type conflict** | a field was written as more than one type (e.g. `float` and `integer`) | coerce to one type · split into typed columns · latest-wins |
| **column limit** | a table's column count is over the target's cap | split the table · drop columns · relax the target |
| **table limit** | a database's table count is over the target's cap | split across databases · drop unused measurements |

Column and table limits are **target-aware**: the strict Cloud Dedicated numbers
(250/1000 columns, 500/2000/5000 tables) by default, or a relaxed profile for a
3.11 PachaTree target with wide/sparse tables. ISR sits between source and target,
so it can give the *accurate* limit rather than a generic one.

## Example

```json
{
  "ok": true, "supported": true, "target_engine": "cloud-dedicated",
  "summary": { "blocking": 2, "warning": 1, "databases": 1, "tables": 3 },
  "verdicts": [
    { "severity": "blocking", "kind": "tag_field_collision",
      "database": "surftest", "measurement": "wifi", "field": "channel",
      "detail": "'channel' is used as both a tag and a field",
      "remediations": ["rename_field","rename_tag","keep_field","route_new_table"] },
    { "severity": "blocking", "kind": "type_conflict",
      "database": "surftest", "measurement": "hm", "field": "activeClients",
      "detail": "field 'activeClients' has conflicting types: float, integer",
      "remediations": ["coerce","split_columns","latest_wins"] },
    { "severity": "warning", "kind": "column_limit",
      "database": "surftest", "measurement": "wide",
      "detail": "261 columns is over the cloud-dedicated soft limit of 250",
      "remediations": ["split_table","drop_columns","ignore"] }
  ]
}
```

## From verdict to validated run

- **Resolve** — the operator picks a remediation per verdict; the choices become
  a re-runnable, resume-safe **resolution plan**. `POST /api/isr/migration/preview`
  applies a candidate plan to a live sample and returns **before/after** line pairs
  so the choices can be validated against real data before the run.
- **Migrate** — the run applies the plan as a transform on each window: coerce
  (`bool↔numeric`, `float→int` floor), rename fields/tags, drop, add a tag, and
  **route a measurement to a new table** (for a collision, a column-split, or a
  dedupe). It reports what it changed and the plan is persisted on the job. Pass
  the plan as `resolution_plan` in the migration start config.
- **Validate** — `POST /api/isr/migration/validate` confirms the migrated data
  against the *expected* post-transform values (a coercion legitimately changes
  values, so the plan is the contract, not a naive `source == target`): row-count
  parity (minus dropped rows, against the renamed table) and exact SUM parity on
  the numeric fields the plan didn't touch, with coerced/renamed fields reported
  for information. The **console wizard** (above) drives assess → preview → validate
  against the selected job.
