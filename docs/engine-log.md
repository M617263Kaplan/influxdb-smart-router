# Engine log

ISR keeps two logs, and picking the right one is most of the work:

| | **Engine log** | **Request log** |
|---|---|---|
| What it holds | What ISR's own subsystems did — migrations, replication, fleet | Every query and write that crossed the data-plane proxy |
| Answers | "Why did job X fail?", "Which destination is erroring?" | "Who ran that query?", "What returned 500?" |
| Where | Logs & Alerts → Logs → **Engine log** | Logs & Alerts → Logs → **Request log** |
| API | `GET /api/isr/logs` | `GET /api/isr/router/decisions` |

**A backup migration never passes through the proxy**, so it does not appear in
the request log. When a migration fails, the engine log is where the record is.

## What a line looks like

| Field | Meaning |
|---|---|
| `ts` | Unix seconds |
| `level` | `debug` / `info` / `warn` / `error` |
| `source` | Subsystem — `migration`, `replication`, `fleet`, `auth`, `scaling` |
| `event` | **Stable machine key**, e.g. `shard_failed`. Filter and alert on this, not on the message |
| `job_id` | Correlates every line of one run. Indexed |
| `target` | The destination a line is about, in a fan-out. Indexed |
| `message` | One human sentence |
| `fields` | JSON detail — counts, sizes, the error text |

`event` and `message` are separate deliberately. The sentence is written for the
operator reading the page; the key is what your filters and support scripts
match on, and it does not move underneath them.

## What the migration engine records

| Event | Level | Why it is there |
|---|---|---|
| `run_started` | info | The **effective** concurrency, scratch budget, batch bytes/lines, window, shard count and destinations. Effective, not requested — every value has been defaulted or clamped, and the final report only exists once a run *finishes*, while the runs you most need to explain are the ones that didn't |
| `shard_complete` | info | Shard id, lines read/written, headers skipped, TSM size |
| `shard_failed` | **error** | The real error text, plus how many shards have failed so far |
| `run_finished` | follows outcome | Totals, shards failed, destinations left behind. `error` if the run failed, `warn` if a destination lagged or a shard failed, otherwise `info` — so filtering on level alone surfaces bad runs |

Per-destination back-off and throughput are intentionally *not* duplicated here.
They already ride the run heartbeats and both dashboards at per-batch resolution,
and repeating them would make the journal noisy in exactly the way that trains
people to stop reading it.

A run that stops making progress also records `migration_stalled` (warn) after
`ISR_MIGRATION_STALL_SECS` (default 1800, minimum 60). It distinguishes two
failures that look identical on the page: an **engine that is stuck** (the job
document is still being updated, but its byte and shard counts are frozen) from
a **writer that died** (the document itself stopped changing). Each carries its
own restart guidance — including that re-running the same job id moves only what
is missing, since completed shards report "already done".

The stall watcher also counts movement *inside* the current shard. Neither
`bytes_written` nor `shards_done` advances while a shard's TSM is being
unpacked, so a growing unpack counts as progress and a large shard whose unpack
outlasts the threshold is not reported as stalled. An unpack that genuinely
wedges freezes the same counter, so a real hang is still caught on schedule.
Only *running* shards are summed, so a finished shard never reads as perpetual
progress.

## What the other engines record

Everything below writes to the same journal, with the same filters and the same
redaction.

| Source | Events | Notes |
|---|---|---|
| `replication` | job state changes, error-count growth | **Edge-triggered.** Instrumented at `upsert_status`, the one function every status writer passes through, so no transition can be missed. A replication tick runs on a timer; a line per tick would bury the three events that matter — began failing, went partial, recovered — under thousands of "still idle" rows. `partial` is **warn**, not error: data moved, but not all of it, and that is how a destination silently falls behind |
| `fleet` | `spoke_upgraded`, `spoke_upgrade_failed`, `spoke_upgrade_uncommitted`, `sync_scope_changed` | `spoke_upgrade_uncommitted` is the honest case where the spoke serves the right version but the apply was never confirmed |
| `auth` | `login_locked_out` | The visible edge of credential stuffing. Username and source IP only — never the submitted password |
| `scaling` | `autoscale` | Both the Docker and Kubernetes actuation paths |

## Node logs

ISR already drives the cluster's nodes, so it reads their logs over the same
orchestrator seam — `docker logs --timestamps --since` or
`kubectl logs --since-time` — with nothing to configure per node. The result is
the **Node Logs** page. A syslog listener is also available for nodes that push
their logs.

- The per-node cursor advances from **the line's own timestamp**, not the wall
  clock. Trusting the clock drops lines when a node is slow; re-reading a window
  duplicates them.
- A per-node, per-cycle line cap stops one crash-looping node evicting every
  other node's history from the shared ring.
- Lines with no parseable timestamp are kept **verbatim** — panics and stack
  traces are exactly the unprefixed output most worth reading.

| Variable | Default | Meaning |
|---|---|---|
| `ISR_NODE_LOG_PULL` | `1` | Set `0` to disable, e.g. where syslog already ships logs |
| `ISR_NODE_LOG_PULL_SECS` | `30` | Interval, minimum 5 |
| `ISR_NODE_LOG_PULL_MAX_LINES` | `400` | Per-node, per-cycle cap |

## Reading it across a fleet

The journal is per-instance, so a hub aggregates:

    GET /api/isr/fleet/logs?limit=200&min_level=warn&source=migration

It merges the hub's own journal with every reachable spoke's in timestamp order
and **names the instances it could not reach**, rather than presenting a partial
fleet as the whole one. Filters are forwarded from a fixed allowlist (`source`,
`level`, `min_level`, `job_id`, `target`, `event`, `since`, `contains`,
`limit`); arbitrary caller input is not passed through to another instance.

In the console this is **Fleet → metrics → Fleet-wide log**, and the per-spoke
**Logs** button reads the same journal.

## Channels that never delivered

Notification dispatch results are recorded, so a Slack webhook or SMTP server
that has never once succeeded is distinguishable from one working perfectly.

    GET /api/isr/notify/health

Each channel reports `ok` (with a timestamp), `failing`, `never delivered`, or
`disabled`. Anything that can fail quietly needs a state you can read.

## Reading it

Console: **Logs & Alerts → Logs**, *Engine log* card. It defaults to `warn+`, so
the first thing you see is problems. The source and job dropdowns are built from
what the journal actually holds, so they never offer an empty filter.

```bash
# Everything that went wrong, newest first
curl -s -H "X-ISR-Admin-Session: $S" 'http://isr:9800/api/isr/logs?min_level=warn'

# One run, end to end
curl -s -H "X-ISR-Admin-Session: $S" 'http://isr:9800/api/isr/logs?job_id=barracuda-ccs-1'

# One destination's failures in a fan-out
curl -s -H "X-ISR-Admin-Session: $S" 'http://isr:9800/api/isr/logs?target=cloud-a&min_level=error'
```

| Parameter | Notes |
|---|---|
| `min_level` | Inclusive floor — `warn` returns warn and error |
| `source`, `level`, `event`, `job_id`, `target` | Exact match |
| `contains` | Substring over message and fields |
| `since` | Unix seconds |
| `limit` | Default 250, max 5000 |

Requires viewer or above — reading what the engine did is the first thing an
on-call operator needs, and gating it behind admin is how people end up sharing
an admin session to debug.

## Retention and durability

SQLite on the instance's own state volume, capped at 200,000 rows (oldest
dropped). **It survives a restart**, which matters most on a spoke: the way to
stop a wedged migration is to recreate the container, and the record of what
went wrong is still there afterwards.

The log is per-instance. A migration that ran on a spoke is logged on that spoke
— which is why a hub offers the fleet-wide view described above.

## Container stdout and redaction

Every journal line is also mirrored to the container's stdout, so `docker logs
isr` shows everything the journal holds. EDR writes to container stdout; read
its output there.

Credential-shaped text (`isrt_`, `israpi_`, `apiv3_`, `Bearer …`, `token=`,
`password=`) is redacted before storage, keeping a short prefix so two mentions
of the same credential can still be correlated. Do not put secrets in
`fields` from new call sites: this journal is exported to support.
