# Migrating from an InfluxDB 1.x portable backup

ISR can read an InfluxDB 1.x *portable* backup off disk, expand it to line
protocol, and write it into one or more InfluxDB 3 destinations — without
standing the old server back up.

```bash
curl -sS -X POST http://ISR_HOST:9800/api/isr/migration/backup/export \
  -H "X-ISR-Admin-Session: $SESSION" -H 'content-type: application/json' -d '{
    "backup_dir": "mybackup",
    "database": "centralCounterStore",
    "retention_policy": "autogen",
    "background": true,
    "job_id": "counterstore-2026-07",
    "concurrency": 4,
    "max_scratch_mb": 100000,
    "batch_bytes": 8388608,
    "batch_lines": 60000,
    "targets": [
      {"name": "prod", "host": "https://influx.example.com", "db": "counters",
       "token": "…"}
    ]
  }'
```

`backup_dir` resolves inside the import root (`/var/lib/isr/import` by default,
widened with `ISR_MIGRATION_IMPORT_ROOT`); anything outside it is refused.
`background: true` requires `job_id`, because that id is the resume key — an
interrupted run restarts from its completed shards rather than from zero. Poll
`GET /api/isr/migration/backup/status?job_id=…`.

Run with `"dry_run": true` first. A dry run walks the same path, including the
unpack, so it exercises everything below.

## The scratch budget is what actually sets your throughput

Every in-flight shard unpacks its TSM to scratch, so parallelism is bounded
twice: by `concurrency` (worker count, default 4) and by `max_scratch_mb`
(default 24576, i.e. 24 GiB). **Admission is byte-weighted** — a shard takes
permits equal to its own size — so the budget, not the worker count, usually
decides how many shards actually run at once.

This is the single most common reason a tuned migration is slow. Measured on a
real 70 GB backup: one 13.6 GB shard held most of a 24 GiB budget, so
`concurrency: 4` ran as about **one** worker. The host looked idle — 6.6% CPU,
disk and network barely touched — and the run moved 6.17 MB/s, which reads
exactly like a slow network or a slow destination.

Size the budget to fit the shards you want in flight at once:

```
max_scratch_mb  ≈  largest_shard_MiB  ×  desired_concurrency
```

A shard larger than the whole budget still runs, alone, rather than deadlocking.

ISR tells you when the budget is the constraint. Watch the engine log
(**Operations → Engine Log**, or `GET /api/isr/logs`, source `migration`):

| Event | Level | Meaning |
| --- | --- | --- |
| `run_started` | info | The **effective** settings, after defaulting and clamping — `max_scratch_mb`, `max_scratch_mb_requested`, `scratch_free_mb`, `concurrency`, batch sizing. Always check these against what you sent. |
| `scratch_budget_limits_concurrency` | warn | The budget admits fewer shards than you have workers. Carries `max_scratch_mb_for_full_concurrency` — the value to raise it to. |
| `scratch_budget_wait` | warn | A shard actually parked on the budget. Proof the run is budget-bound rather than network-bound. |
| `scratch_budget_clamped` | warn | Your `max_scratch_mb` exceeded free space and was reduced (see below). |

`batch_bytes` and `batch_lines` must be raised **together**. A batch closes on
whichever trips first, and the default of 20,000 lines is only a few MB of
typical line protocol — so raising `batch_bytes` alone does nothing.

## Scratch space, and when a run is refused outright

Scratch goes to the process temp directory (`TMPDIR`, else `/tmp`). In a
container that is the **writable layer**, which is usually *not* the volume
holding the backup. Size against the filesystem scratch actually lands on, and
mount a volume at `TMPDIR` if the writable layer is small.

At the start of every run ISR measures that filesystem and reacts:

- **Refused** if the largest shard in scope cannot fit. That run cannot
  succeed, so it fails immediately with the free space, the usable space after
  headroom, and the size needed — rather than failing on ENOSPC hours in.
- **Clamped** otherwise, if `max_scratch_mb` is larger than the space available.
  The run proceeds with a smaller budget, which is slower rather than wrong, and
  logs `scratch_budget_clamped`. The report carries both
  `max_scratch_mb_requested` and the effective `max_scratch_mb`.

Headroom is the shared disk watermark `ISR_DISK_MIN_FREE_BYTES` (512 MiB
default), the same threshold behind the readiness alert and write-queue
backpressure.

The free-space measurement runs on Linux, which is where container deployments
live. On other platforms the budget is taken at face value, with neither the
refusal nor the clamp — relevant for local development, not for a container
deployment.

Abandoned scratch is reclaimed at the start of every run: a hard kill (an OOM,
or recreating the container, which is the clean way to stop a run) leaves an
unpacked shard behind, and the next run deletes any scratch not belonging to a
live run.

### Running more than one migration at once

`max_scratch_mb` is **per run**. Two migrations running at once each take the
budget they were given, so the ceiling on the host is the *sum*: two runs at a
tuned 100000 occupy ~195 GiB between them. If you migrate two databases
concurrently, give each run its share of the host's scratch — half the budget
you would give a single run — or run them in sequence. The refusal and clamp
above are measured against real free space at each run's start, so the second
run to start adapts to what the first has already taken.

## Interpreting the counters

`bytes_written` counts bytes **per destination**: a three-way fan-out sends every
line to all three, so divide by the target count to get line protocol produced.
It is also the only smooth live signal — `lines_written` and `shards_done` only
advance when a whole shard completes.

`lines_read`/`lines_written` are **lines, not rows**. The exporter emits one line
per field, so a three-field measurement produces three lines that InfluxDB 3
collapses into a single row. Comparing this counter to a row count in the
destination will look like losing two thirds of your data.

Cancellation (`POST /api/isr/migration/backup/cancel`) is observed at shard
boundaries, so on a very large shard it can take a while. Nothing is lost:
checkpoints are per completed shard, and the run resumes under the same `job_id`.
