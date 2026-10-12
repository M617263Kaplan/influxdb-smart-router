# Ingest Gateway

ISR accepts many common push-telemetry protocols on its **data-plane** listener
(the same host:port you already write InfluxDB line protocol to — `:8181` by
default) and translates each to InfluxDB 3 line protocol *in flight*. Because the
translation happens before the rest of the proxy runs, everything downstream —
schema correction, PII/residency enforcement, the write-time tee, and the durable
write queue — applies to gateway traffic exactly as it does to native writes.

No agent-side plugins or sidecars are required: you point the agent's existing
exporter/output at ISR.

## Target database

Every protocol writes to a database. Set it with:

- the `?db=<name>` query parameter, or
- the `X-ISR-DB` header (for gRPC, the `x-isr-db` metadata key).

If neither is given, the default is `metrics`.

## Protocol reference

| Source | Endpoint | Body |
| --- | --- | --- |
| Graphite | `POST /graphite` | plaintext `path value [ts]` |
| Prometheus remote-write | `POST /api/v1/prom/write` | snappy + protobuf |
| OTLP metrics | `POST /otlp/v1/metrics` · gRPC `MetricsService/Export` | protobuf — gauge / sum / histogram / summary |
| OTLP traces | `POST /otlp/v1/traces` · gRPC `TraceService/Export` | protobuf → `otel_spans` |
| OTLP logs | `POST /otlp/v1/logs` · gRPC `LogsService/Export` | protobuf → `otel_logs` |
| collectd | `POST /collectd` | `write_http` JSON |
| StatsD / DogStatsD | `POST /statsd` · **UDP** `:8125` | text `name:value|type|#tags` |
| Datadog agent | `POST /api/v1/series` | JSON series (gzip/deflate) |
| Loki push | `POST /loki/api/v1/push` | protobuf + snappy, or JSON → `loki_logs` |

Native InfluxDB `v1 /write`, `v2 /api/v2/write`, and `v3 /api/v3/write_lp`, plus
the OSS/Core 2.x **Edge Data Replication** receiver, are also accepted directly.

Live per-protocol counters (requests / points / bytes / errors / last-seen) are on
the console at **Data & Schema → Ingest Gateway**, or via
`GET /api/isr/gateway/protocols`.

## Access control

Two independent gates decide whether a gateway write is admitted.

### 1. Accept / deny per protocol (gateway-wide)

On the **Data & Schema → Ingest Gateway** page each protocol has an **Accept**
checkbox. Turn one off and the gateway refuses that protocol for every client —
HTTP `403` (gRPC `PERMISSION_DENIED`) — without touching any client config. All
protocols are accepted by default.

```
# deny Graphite + StatsD, leave the rest accepted
PUT /api/isr/gateway/protocols
{ "enabled": { "graphite": false, "statsd": false } }
```

The response returns the resulting `accepted` / `disabled` sets. Protocol names:
`graphite`, `prometheus`, `otlp_metrics`, `otlp_traces`, `otlp_logs`, `collectd`,
`statsd`, `datadog`, `loki`.

### 2. Per-token protocol scope

A client token carries an explicit ingest-gateway protocol allow-list. **A token
supports no gateway protocols by default** — enable them one at a time under
**Tokens → (token) → Ingest gateway protocols**, where only protocols currently
accepted on the gateway are offered. When a bearer token is presented (or
data-plane auth is enforced) it must be scoped for the protocol it is using, or
the write is refused with `403`. Anonymous writes (Graphite/StatsD/collectd carry
no token) are admitted only while data-plane auth is not enforced.

```
# scope a token to Graphite + Prometheus only
POST /api/isr/auth/tokens
{ "username": "collector", "databases": ["metrics"],
  "gateway_protocols": ["graphite", "prometheus"] }
```

## Client configuration

### Graphite

```
echo "servers.web01.cpu 42.5 $(date +%s)" | \
  curl --data-binary @- "http://<isr>:8181/graphite?db=metrics"
```

### Prometheus remote-write

`prometheus.yml`:

```yaml
remote_write:
  - url: http://<isr>:8181/api/v1/prom/write?db=metrics
```

### OpenTelemetry — OTLP/HTTP

OpenTelemetry Collector:

```yaml
exporters:
  otlphttp:
    metrics_endpoint: http://<isr>:8181/otlp/v1/metrics?db=metrics
    traces_endpoint:  http://<isr>:8181/otlp/v1/traces?db=metrics
    logs_endpoint:    http://<isr>:8181/otlp/v1/logs?db=metrics
```

### OpenTelemetry — OTLP/gRPC

Point the collector's gRPC exporter at ISR's data-plane host:port. ISR terminates
the gRPC `Export` call and returns a standard unary response
(`grpc-status: 0`). Set the database with an `x-isr-db` metadata header:

```yaml
exporters:
  otlp:
    endpoint: <isr>:8181
    tls:
      insecure: true
    headers:
      x-isr-db: metrics
```

Metric fidelity: gauge, sum, **histogram** (→ `count`, `sum`, `min`, `max`), and
**summary** (→ `count`, `sum`, and a field per quantile: `q50`, `q90`, `q99`, …).

### collectd

`collectd.conf` (the `write_http` plugin, JSON format):

```
LoadPlugin write_http
<Plugin write_http>
  <Node "isr">
    URL "http://<isr>:8181/collectd?db=metrics"
    Format "JSON"
    StoreRates true
  </Node>
</Plugin>
```

### StatsD / DogStatsD

StatsD is UDP. Enable the listener on ISR with `ISR_STATSD_LISTEN=0.0.0.0:8125`
(target db via `ISR_STATSD_DB`, default `metrics`), publish the port, then point
your client at `<isr>:8125`. DogStatsD `#tag:value` tags become line-protocol
tags. A batch can also be POSTed to `/statsd` over HTTP.

```
echo "api.requests:1|c|#env:prod,route:checkout" | nc -u -w0 <isr> 8125
```

### Datadog agent

Repoint the agent at ISR (`datadog.yaml`):

```yaml
dd_url: http://<isr>:8181
api_key: any-value-isr-does-its-own-auth
```

The agent POSTs gzip-compressed JSON to `/api/v1/series`; ISR inflates and
translates it. Metric name → measurement, `host` + `tags` → tags.

### Loki push (Promtail / Grafana Agent)

Promtail `clients` config:

```yaml
clients:
  - url: http://<isr>:8181/loki/api/v1/push?db=metrics
```

Both the protobuf+snappy (Promtail default) and JSON encodings are accepted. Log
entries land in the `loki_logs` measurement — stream labels become tags, the log
text is the `line` field, and the nanosecond timestamp is preserved.

## Anything else — bridge via Telegraf

For any other source — SNMP, MQTT, Kafka, JMX, SNMP traps, Windows perf
counters, … — run [Telegraf](https://github.com/influxdata/telegraf) with the
appropriate input plugin and its `influxdb_v2` output pointed at ISR:

```toml
[[outputs.influxdb_v2]]
  urls = ["http://<isr>:8181"]
  token = "<your-isr-token>"
  organization = ""
  bucket = "metrics"
```

Telegraf's hundreds of input plugins then reach the cluster through ISR — with the
same scope, schema, compliance, and routing controls as every other write.
