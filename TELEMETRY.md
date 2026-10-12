# What ISR reports to its maintainers

Once a day, ISR tells its maintainers that this deployment exists and roughly
how it is configured. This page is the complete account of that report: every
field it carries, when it is sent, what comes back, what the maintainers keep,
and how to switch it off.

The report is small, coarse and fixed. It carries no data you store, no
database or cluster names, no tokens, no hostnames, no query text and no
customer identities. The request body is checked against a published schema
that rejects any field not listed below, so the list on this page is the whole
list.

It is non-blocking by construction. If the report fails, is switched off, or
can never reach the internet, nothing about how ISR runs changes: no request
waits on it, no feature depends on it, and startup does not wait for it.

> **This is not Telemetry Export.** Telemetry Export (Operations → Telemetry
> Export) sends *your* metrics to *your* InfluxDB. It is a separate feature with
> a separate switch, and enabling one never enables the other. It is also not
> [Call Home](docs/call-home.md), which is external tools enrolling with your
> ISR.

## What is sent

One JSON object per report. Every key is always present; a count ISR has not
computed is sent as `null`.

| Field | Example | What it is |
| :-- | :-- | :-- |
| `protocol` | `1` | The version of this report format. |
| `deployment_id` | `isr_70e101c7f6478021` | A random identifier ISR mints on its first boot. It is not derived from a hostname, an account, a licence or anything else about you. It survives restarts and upgrades on the same state volume and changes after a factory reset. |
| `ha_group_id` | `null` | On a high-availability deployment, a random identifier shared by the members so the maintainers count the group once. `null` on a standalone deployment. |
| `instance_id` | `isr-a` | The instance name from ISR's own configuration. |
| `version` | `4.0.0` | The ISR version running. |
| `build_rev` | `87a15b6` | The source revision the binary was built from, or `unknown`. |
| `arch` | `aarch64` | CPU architecture: `aarch64`, `x86_64` or `unknown`. |
| `os` | `linux` | Operating system: `linux`, `macos`, `windows` or `unknown`. |
| `platform` | `docker` | How ISR was deployed: `docker`, `kubernetes`, `vm` or `unknown`. |
| `started_at` | `2026-10-10T21:02:11Z` | When this ISR process started. |
| `uptime_s` | `86400` | Seconds since it started. |
| `fleet_role` | `standalone` | `standalone`, `hub` (fronts spokes) or `spoke` (enrolled to a hub). |
| `product_licence` | `null` | The identifier of the installed ISR licence, if one is installed. |
| `org_name` | `null` | Your organisation name, **only if you opted in** on the Updates card and typed one. |
| `contact_email` | `null` | A contact address, **only if you opted in** and typed one. |
| `counters.clusters` | `2` | How many clusters this ISR manages. |
| `counters.node_pools` | `5` | How many node pools. |
| `counters.databases` | `12` | How many databases. |
| `counters.client_tokens` | `40` | How many ISR client tokens exist. |
| `counters.ha_members` | `1` | How many members in the HA group. |
| `counters.licensed_cores` | `16` | How many cores the InfluxDB licence covers. |

The counters are totals only. They never name the things they count.

Two things travel with the body rather than in it:

- **A per-deployment credential.** ISR mints a random secret the first time it
  reports and presents it with every report, so nobody else can report as your
  deployment. The secret is stored sealed on your ISR and only as a hash by the
  maintainers.
- **The usual HTTP facts.** The maintainers' server sees the source IP address
  of the request, as any server does, and ISR sends `User-Agent: isr/<version>`.

## What is never sent

- Points, rows, measurements, fields, tags or query text.
- Database, table, cluster, pool, node or host names.
- InfluxDB tokens, ISR client tokens, passwords, certificates or keys.
- Usernames, console accounts, or anything identifying your users or customers.
- Your organisation name or contact address unless you typed them in and ticked
  the box.
- Logs, metrics, alerts, backups or configuration.

## When it is sent

| Moment | Behaviour |
| :-- | :-- |
| Before you have seen it | Nothing. The first report waits until the disclosure step in Getting Started has been shown, or until `ISR_CHECKIN` has been set explicitly. Setting it either way counts as having been told. |
| After startup | Between 30 and 120 seconds after ISR's state store is ready. The delay is randomised. |
| Steady state | Once every 24 hours, give or take an hour at random. |
| After an upgrade | Immediately on the first boot of a new version. |
| On failure | Retried after 1 minute, then 5, then 30, then 60, then back to the daily schedule. The first failure is logged at `INFO`; later ones at `DEBUG`. |

Each attempt is a single request with a 10-second limit. It runs in its own
background task, never on the path of a read or a write.

## What comes back

The maintainers' server answers with a signed reply. ISR verifies the signature
against a key built into the binary and keeps the reply only if it verifies.
The reply carries:

- the standing of your ISR licence as the maintainers' records have it;
- the latest published ISR version, shown on the Updates card;
- an optional notice from the maintainers, shown on the same card;
- an expiry, after which ISR treats the reply as stale.

The latest-version value is informational. Checking for and installing updates
is done through the release feed on the Updates card, which is a separate
mechanism.

## What the maintainers keep

| Record | Kept |
| :-- | :-- |
| The deployment's latest reported values | For as long as the deployment keeps reporting, and after. |
| Each instance's version and start time | As above. |
| Report history (one row per report) | 90 days. |
| Country of origin | Derived at the edge from the source address and stored as a two-letter code. |
| Source address | Truncated to the first 24 bits (IPv4) or 48 bits (IPv6) before storage. The full address is not stored. |
| Server logs | 30 days. They carry the deployment id and the truncated address, never the credential or a contact address. |
| Organisation name and contact address | Only if you opted in; replaced by each report that carries them. |

## Switching it off, and other controls

Everything is on the **Reporting to the ISR maintainers** card under Operations
→ ISR Updates.

- **Report to the maintainers** — untick to stop reporting. Nothing else
  changes.
- **Also include my organisation name and contact email** — opt in to send the
  two fields below it. Off by default. Untick and they are no longer sent, even
  if the text stays in the boxes.
- **Check in now** — sends a report immediately and shows the result, useful
  when checking outbound connectivity.
- **Deployment id · Copy** — the identifier above, for quoting to the
  maintainers.

The same control is available to automation:

| Setting | Effect |
| :-- | :-- |
| `ISR_CHECKIN=off` | Reporting off. Overrides the console switch. |
| `ISR_CHECKIN=on` | Reporting on without waiting for the disclosure step. For headless installs. |
| `ISR_CHECKIN` unset | The console switch decides; reporting starts only after the disclosure step. |
| `GET /api/isr/checkin/status` | Current state: enabled, last success, last error, latest version and notice. |
| `POST /api/isr/checkin/now` | Same as **Check in now**. Administrator only. |

A factory reset (Danger Zone, or `ISR_FRESH_START`) mints a new deployment id;
the maintainers will see a new deployment, not a continuation of the old one.

## Where the report goes

Reports are sent over HTTPS to `pigpen.mysecureconnection.com`, operated by the
ISR maintainers. If your network restricts outbound traffic, that is the one
hostname to allow; if you would rather not allow it, switch reporting off and
ISR behaves identically.
