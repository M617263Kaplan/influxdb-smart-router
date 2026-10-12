# Query cache

ISR keeps an in-memory cache of query responses in front of the query pool, so a
repeated read is answered by ISR instead of the cluster. It is node-local: each
ISR instance has its own cache, and nothing is shared between a hub and its
spokes.

## What gets cached

| | |
|---|---|
| **Methods** | `GET` / `HEAD`, plus `POST` on read paths (`/api/v3/query_sql`, `query_influxql`) — the v3 query API puts the SQL in the body, so a GET-only cache would never engage |
| **Never** | writes, `configure` endpoints, and any request whose route or governance rule sets bypass |
| **Status** | `200` only |
| **Refused** | responses carrying `Set-Cookie`, or `Cache-Control: no-store` / `private` |
| **Key** | host + path-and-query, and for POST reads a SHA-256 of the request body — so two different queries, or the same query against two databases, never share an entry |
| **Size cap** | per response `cache.max_body_bytes` (1 MiB default); a larger response is passed through uncached |

Entries expire after `cache.default_ttl_seconds` (30 by default). A 60-second
sweep drops expired entries even if nobody reads them again, and the cache is
bounded in aggregate by `ISR_CACHE_MAX_ENTRIES` (10,000) and
`ISR_CACHE_MAX_BYTES` (256 MiB), evicting soonest-to-expire first.

## How a cached response is framed

**ISR frames the response it serves; it does not replay the upstream's framing.**
Hop-by-hop headers (`connection`, `keep-alive`, `te`, `trailer`,
`transfer-encoding`, `upgrade`, the `proxy-*` pair) and `content-length` describe
one specific transfer between ISR and the node — not the transfer between ISR and
your client. They are dropped when the entry is stored *and* skipped when it is
served, and the length is derived from the body ISR actually writes.

This matters concretely: InfluxDB 3 streams query results with
`transfer-encoding: chunked` and no `content-length`, while a cached entry is a
fixed-length body. Framing the served response from that body, rather than from
the headers the node sent, is what keeps the second and every later request as
valid as the first — and it is enforced at both ends of the cache.

End-to-end headers are preserved as the node sent them (`content-type`,
`x-influxdb-version`, and so on).

## Reading `x-isr-cache`

Every proxied response carries ISR's own verdict:

| Value | Meaning |
|---|---|
| `miss` | fetched from the cluster on this request (and stored, if cacheable) |
| `hit` | served from this ISR's cache |

The header is always ISR's verdict for *this* hop. If you run ISR behind ISR, the
inner instance's verdict is not passed through — you will never see `miss, hit`.

**Sanity-check a repeat** — ask the same question twice; the second answer should
be a hit with a byte-identical body:

```bash
for i in 1 2; do
  curl -sS -D- -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $ISR_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"db":"mydb","q":"SELECT 1","format":"json"}' \
    http://isr:8181/api/v3/query_sql | grep -iE 'x-isr-cache|^[0-9]{3}$'
done
# expect: x-isr-cache: miss, then x-isr-cache: hit — and 200 both times.
```

**Force a fresh fetch** by sending `x-isr-cache: bypass`. That is honoured by the
`bypass-cache-header` governance rule shipped in the default config; if you have
replaced the governance config, keep a rule with `action: bypass_cache` or the
header does nothing.

```yaml
governance:
  rules:
    - name: bypass-cache-header
      enabled: true
      priority: 20
      header_name: "x-isr-cache"
      header_value: "bypass"
      action: bypass_cache
```

## Counters

`GET /_admin/api/cache` reports `enabled`, `entries`, `hits`, `misses`, the TTL,
and the per-response cap; `/metrics` exposes `isr_cache_hits_total` and
`isr_cache_misses_total`.

**A hit is counted only when a cached response was actually returned to a
client.** If an entry can no longer be turned into a valid response, ISR drops
it, counts a **miss**, and fetches from the cluster, so the ratio always
describes answers clients received.

A sustained low hit rate means either the traffic is mostly unique (absolute
timestamps in a dashboard's time filter make every refresh a new key) or the TTL
is shorter than the refresh interval. Rising evictions alongside a low hit rate
mean the working set does not fit — raise `ISR_CACHE_MAX_BYTES` /
`ISR_CACHE_MAX_ENTRIES`.

## Operating it

- `POST /_admin/api/cache/toggle` — enable or disable caching at runtime
- `POST /_admin/api/cache/purge` — drop entries (the cache is in-memory, so a
  restart also starts it empty)
- Console: **Traffic & Routing → Cache** for status, entry inspection, and flush;
  **Docs → Query Cache** for the same reference as this page
