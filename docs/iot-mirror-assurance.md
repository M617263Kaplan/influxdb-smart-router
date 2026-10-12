# IoT mirrors: delivery, evidence, and what a bounded buffer costs

A mirror copies writes to a second cluster as they pass through ISR. This page
is about the difference between a mirror that *reports* success and one that has
*evidence* of it.

## Delivered is not verified

`delivered` means the destination answered **2xx** — an acceptance, not a
durable, queryable row.

`verified` is a third state, alongside owed and delivered. With **read-back**
enabled on a mirror, ISR later asks the destination to **count what it was sent**
and only then moves `rows_verified`.

| Level | Means |
|---|---|
| `accepted` | read-back is off — the destination returned 2xx, nothing more |
| `checking` | delivered; the first read-back has not completed |
| `partial` | some windows confirmed, others still being checked |
| `verified` | the destination was queried and holds the rows |
| `failed` | accepted, but the rows are **not** there |
| `unknown` | the destination did not answer — **not evidence of loss** |

Read-back is **off by default**: it costs a query per delivered payload per
measurement against someone else's cluster.

### Rows, not lines

The count compared is **rows**, not lines. Line protocol is last-write-wins by
(series, time), so several lines carrying one series and timestamp are correctly
**one row** at the destination. Comparing lines against rows would report healthy
deduplication as data loss — and a tolerance cannot fix it, because the collapse
can be arbitrary. Tag order is canonicalised, since two orderings of one tag set
are one series.

### What it refuses to claim

- **Lines written without a timestamp are counted as unverifiable**, never folded
  into a neighbouring window. The server assigns their timestamps on receipt, so
  there is no window to ask about, and a verifier that guessed would confirm rows
  it never located.
- **"We could not look" is not "it is not there."** A read-back query that fails
  to run retires as `unreachable`, with the error.
- **Zero rows never verify**, even against a zero expectation.

## A destination that refuses a payload does not stall the ones behind it

The durable queue retries on failure — right for a target that is down, wrong for
a payload the target *refuses*. If the drain stopped at the first failure, one
refused row would stall every mirror queued behind it, indefinitely, against a
perfectly healthy destination. So a refused payload is retired instead of
retried.

Only **400, 413 and 422** condemn a payload. The exclusions carry the weight:
`401/403` mean the credential is wrong rather than the data (dead-lettering these
would let a token rotation discard every queued mirror), `404` may be a database
that does not exist *yet*, `408/429` are what a queue is for, and a transport
error is no answer at all.

A retired mirror is **not deleted**. It goes to a dead letter with the payload and
the destination's own words, and the ledger keeps `lines_rejected`, so the
reconciliation identity still holds:

```
owed − delivered − rejected − evicted − live backlog = 0
```

## The buffer is bounded, and what it drops is written down

An uncapped queue would let a destination that is unreachable for long enough
grow the state database until the disk is full, taking ISR with it. The queue
is therefore bounded.

`ISR_MIRROR_QUEUE_MAX` takes a **size** (`10GB`, `512MB`) or a **share of the
filesystem** holding the state database (`5%`). The default is 5% — a proportion
rather than a constant, because the same binary runs on a 20 GB appliance and a
4 TB server. The budget is **global**, shared among the destinations currently
holding data: a per-destination byte cap would multiply by the number of spokes.

A row count would not do. Measured: a single-point write parks ~44 bytes and a
realistic 500-point batch parks 139 KB — a 35,000× spread for the same setting.
The resolved budget is logged at startup, so how much disk the buffer may use is
never a silent decision.

**The oldest are evicted**, because the primary still holds that data and can
replay it, while the newest exists nowhere else yet. Each eviction is recorded as
a **window**, and that window is the cursor a backfill reads from.

### Closing a gap

ISR re-reads the window from the source cluster and re-sends it. Two states never
close on their own, and both say so:

- **`unrecoverable`** — the primary no longer holds that window (retention aged it
  out, or a delete removed it).
- **`unreplayable`** — the lines were written without a timestamp, so there is no
  window to replay *from*.

Gaps are reported apart from the backlog. A gap has already left the queue;
folding the two together would let an unrecoverable gap read as a queue still
catching up.

## Retention on the mirror policy

`dest_retention` sets how long the destination keeps what it is sent. ISR creates
the destination **with** that window before the first mirrored write can create it
without one — after that the window can no longer be set by creating the database,
so a policy of `30d` would silently be a policy of forever.

The response says what **happened**, not what was asked:

- *created* — with the warning that the target refuses writes older than the
  window, so a backlog aging past it during an outage can never be delivered
- *already existed* — retention was **not** applied; the database keeps whatever
  retention it already had
- *no destination database* — a mirror keeping each source's own name has nothing
  single to create

Durations are validated at creation, because the destination applies retention at
**write** time: an unparseable duration would otherwise surface much later as
mirrored data being rejected, which reads like a broken mirror rather than a typo.

## What a mirror costs

Per mirror: source writes, lines and bytes; mirrored lines and bytes; and
**amplification** — mirrored ÷ source.

Both halves are counted in one place at one moment, so they always cover the same
writes, and `measuring_since` says from when. With no source write observed the
figure is **null**, not `0.0` or `1.0` — those are different claims and neither is
known. Under 1.0 is normal and is not floored: a device-precise mirror carries a
slice, and that saving is the point of the filter.

The basis travels with the number: it covers **the writes this mirror matched**,
never the cluster's total ingest.

## Device location

`ISR_GEOIP_FILE` points at a mapping you own:

```
10.20.0.0/16,Plant 3 — Rotterdam
203.0.113.0/24,US-East
2001:db8::/32,EU-Central
```

Longest prefix wins. Bad lines are skipped and counted rather than fatal. The
mapping is yours rather than a bundled GeoIP database, and it is the mapping that
matters for IoT, where most devices sit behind private address space that no
public database can say anything about.
