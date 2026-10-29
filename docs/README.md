# ISR documentation

Every guide in this directory, by the question it answers. The console's own
**Docs** workspace carries the same material next to the page it describes.

## Start here

- [ISR at a glance: every feature, and why it matters](features.md) — the one-page tour: what each feature does and what it is worth to you.
- [ISR features, and what makes each one compelling](../FEATURES.md) — the full list, grouped by area, each with the reason it earns its place.

## Installing and upgrading

- [Release notes — ISR 4.0.18](https://github.com/M617263Kaplan/influxdb-smart-router/releases/tag/v4.0.18) — what this release improves, the assets it ships and how to verify them; [all releases](https://github.com/M617263Kaplan/influxdb-smart-router/releases).
- [Running ISR on Kubernetes](install-kubernetes.md) — the Helm chart, loading the image into your cluster's runtime, encryption at rest, state backends and every value worth knowing.
- [Deploying an ISR spoke on AWS](deploying-a-spoke-on-aws.md) — the Terraform bundle ISR emits for a regional spoke, and running it yourself.
- [ISR and InfluxDB 3.11](influxdb-3.11.md) — what the 3.11 series changes for a cluster ISR runs.
- [The provisioning engine](provisioning-engine.md) — how ISR provisions cloud spokes with OpenTofu, shipped inside the image.
- [The object store behind your cluster](object-store.md) — the store ISR runs for you, choosing another server (including MinIO AIStor with your licence), and bringing your own.
- [Cloud accounts](cloud-accounts.md) — connecting AWS, Google Cloud and Azure so ISR can deploy and adopt there.

## Getting data in

- [Ingest Gateway](ingest-gateway.md) — Prometheus, OTLP, Datadog, Graphite, StatsD, collectd and Loki writers landing as line protocol.
- [**Migrating into InfluxDB 3**](migration.md) — every route in and how to drive each one: a live 1.x/2.x source, line-protocol or Parquet files, a portable backup. Start here if you are moving existing data.
- [Migration readiness — the dry run](migration-readiness.md) — what a migration will do before it does it.
- [Migrating from an InfluxDB 1.x portable backup](backup-file-migration.md) — expanding a portable backup straight into InfluxDB 3.
- [Importing a directory of line-protocol files](line-protocol-import.md) — a folder of `influx export` files discovered, imported as a tracked job, and verified by a row count on the target.
- [ISR Cross-Cloud Migration & Replication — Admin Validation Runbook](cross-cloud-validation-runbook.md) — proving a replication or migration end to end.
- [IoT mirrors: delivery, evidence, and what a bounded buffer costs](iot-mirror-assurance.md) — mirrored device writes and how to read their evidence.

## Securing access

- [Scoped tokens and the Enforce on queries switch](scoped-tokens.md) — what each scope restricts, when the table, field and tag lists apply to queries, what is checked on each protocol, and what a refused client sees.
- [Schema registry: declared data contracts](schema-registry.md) — what a contract declares, the accepted field types, what it does and does not govern, and how to change one producers will feel.

## Operating

- [Command Center (Monitor → Data Flow)](command-center.md) — the whole platform on one canvas.
- [Query cache](query-cache.md) — what is cached, for how long, and how to read a hit.
- [High Availability](high-availability.md) — ISR HA, VRRP and BFISR: three layers of redundancy and which to use.
- [Call Home — external tools asking to connect](call-home.md) — approving the tools that want ISR's management channel.
- [Engine log](engine-log.md) — what ISR's own subsystems did, and how it differs from the request log.

## Working in the console

- [Personal navigation](personal-navigation.md) — pinning the pages you use and sharing a link to one.
- [Embedded assistant](embedded-assistant.md) — the in-console assistant and what it can do on each page.
- [Training Mode and the ISR journey](training-and-journey.md) — learning ISR on a sandbox before pointing it at production.
- [Influx Traffic Lab has moved](influx-traffic-lab.md) — where the traffic generator lives now.
