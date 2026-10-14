# Importing a directory of line-protocol files

A folder of line-protocol files, in the shape `influx export` and
`influxd inspect export-lp` write, becomes an InfluxDB 3 database through ISR:
discovered first, imported as a tracked job, and verified by a row count on
the target at the end.

## What ISR reads

- Files named `*.lp` or `*.txt`, in the directory you name and up to four
  levels below it.
- `# CONTEXT-DATABASE: <name>` headers set the database for the lines that
  follow. A file with no header belongs to a database named after the file.
- `#` comment lines and DDL (`CREATE DATABASE …`, `CREATE RETENTION POLICY …`)
  are skipped. A line with no measurement or no field set is counted as
  skipped and reported.
- Timestamps are taken as nanoseconds, as the export formats write them.

The directory must sit under ISR's import root, `/var/lib/isr/import` inside
the container by default (`ISR_MIGRATION_IMPORT_ROOT` widens it). Mount or
copy the files there; the same root serves the
[1.x backup migration](backup-file-migration.md).

## From the console

Replication & Migration → Migration → **Migration wizard**:

1. Source: **Local files / directory**, and the path relative to the import
   root (for example `exports/2026-10`).
2. Target: the cluster, and the database to write into. One target database
   receives every discovered database; or map each source database to its
   own target.
3. Review, then **Start migration**.

Before anything is written the wizard shows what it found: databases, tables,
points and files. With nothing to import it says so and does not start. Once
started, the message follows the job: points written against points
discovered, files done, and at the end the job's state, the number of errors,
and **parity**: the rows ISR counted on the target against the points it
wrote.

## From the API

```bash
# what a path holds
curl -s -X POST http://<isr-host>:9800/api/isr/migration/discover-local \
  -H "X-ISR-Admin-Session: $SESSION" -H 'content-type: application/json' \
  -d '{"path":"exports/2026-10"}'

# start the import
curl -s -X POST http://<isr-host>:9800/api/isr/migration/import-local \
  -H "X-ISR-Admin-Session: $SESSION" -H 'content-type: application/json' \
  -d '{"path":"exports/2026-10","target_cluster":"prod",
       "mappings":[{"source_db":"demo","target_db":"demo_imported","retention":"none"}]}'

# follow it
curl -s "http://<isr-host>:9800/api/isr/migration/import-local/status?id=<id>" \
  -H "X-ISR-Admin-Session: $SESSION"
```

Discovery answers `databases` (each with its tables and point counts),
`files`, `total_rows` and `skipped_lines`. The import answers `400` with the
reason when the path is missing, holds no points, or a mapping names a
database that was not discovered; otherwise it answers the job `id`, the
counts, and a `status_url`. The status carries `status` (`running`, `done`,
`done_with_errors`, `failed`), `points_total`, `points_written`, `files_done`,
`errors`, `last_error`, and per database `verified_rows` and `parity`.

## Reading parity

`parity: ok` means every point ISR wrote was accepted and the target held at
least that many rows in the imported tables when the job ended. `mismatch`
names the table whose count fell short or could not be read; the job's
`last_error` says why a batch was refused. A target that already held rows
counts them too, so parity is a floor, not an equality.
