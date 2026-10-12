# ISR Cross-Cloud Migration & Replication — Admin Validation Runbook

This runbook walks an ISR administrator through the **entire cross-cloud workflow in the console UI** and, at every step, shows exactly **where to look to confirm the job succeeded** and **how to prove the destination matches the source** (row counts *and* first/last point).
<img width="612" height="344" alt="image" src="https://github.com/user-attachments/assets/4e9fbeca-d51d-4158-8cbd-f5f4778ec68f" />

The scenario: two OSS instances feed two InfluxDB 3 Cloud instances on different providers, then the migrated databases are cross-replicated so **AWS and Azure end up holding the same data from both OSS sources** — only the database names and the path differ.

```
OSS_Azure  (iiot)      ──EDR──▶      Azure 3 Cloud : OSS_Azure_EDR
OSS2_AWS   (satellite) ──Migration▶  AWS 3 Cloud   : OSS_AWS_migration
AWS OSS_AWS_migration  ──Cloud Copy▶ Azure 3 Cloud : OSS_AWS_Azure_migration
Azure OSS_Azure_EDR    ──Cloud Copy▶ AWS 3 Cloud   : OSS_Azure_EDR
```

---

## 0. Environment

Fill this in before you start (example values are shown):

| Role | Endpoint | Org / Account | Database / Bucket | Token |
|---|---|---|---|---|
| Source — OSS_Azure | `http://localhost:8087` | `azure-industrial` | `iiot` | *(OSS admin token)* |
| Source — OSS2_AWS | `http://localhost:8088` | `aws-space` | `satellite` | *(OSS admin token)* |
| Target — Azure 3 Cloud | `https://<id>.<region>.azure.influxdb.io` | *(from provider)* | `OSS_Azure_EDR`, `OSS_AWS_Azure_migration` | *(data token, read+write)* |
| Target — AWS 3 Cloud | `https://<id>.<region>.aws.influxdb.io` | *(from provider)* | `OSS_AWS_migration`, `OSS_Azure_EDR` | *(data token, read+write)* |

> **Container networking note:** if ISR runs in Docker and the OSS servers are on the host, reach them from ISR as `http://host.docker.internal:8087` / `:8088` (not `localhost`).

---

## 1. The three validation surfaces

You will use the same three places to validate **every** step. Learn them once:

> **Start at Data Movement → Overview.** All movement tools live under one **Data Movement** left-nav group (Overview, Events, Migration, Cloud Copy, Edge Data Replication, Jobs, Backfill, Metrics). The Overview's outcome cards launch each step; the Events tab is the inventory of every run.

1. **The engine's own page — job success + live progress.**
   - EDR → **Data Movement → Edge Data Replication** (live per-stream metrics)
   - Migration → **Data Movement → Migration** (per-bucket progress, MB/s, feed)
   - Cloud Copy → **Data Movement → Cloud Copy** (per-table progress, read/written, verify)

2. **The alert — one per completed/failed move.** **Logs & Alerts → Notifications.** Every migration, EDR forward error, and cloud copy raises a `movement:*` alert stating how much moved, **source-db → dest-db**, and any errors.

3. **The parity proof — source vs destination side by side.** **Data Movement → Cloud Copy → “Compare source ↔ destination”** card. Enter a source (adopted cloud instance *or* OSS v2 bucket) and a target cloud database; it counts rows per table on both ends and reads the **first point** and **last point** on each side, with an aligned/gap flag.

A fourth, optional surface aggregates volume over time: **Monitor → Influx Cloud** (push/pull rows & bytes, by instance, by source→database flow).

---

## 2. Prerequisites (do these once, before Step 1)

**P1 — Adopt both 3 Cloud instances.** See Step 1 for the Azure one; repeat for AWS.

**P2 — Pre-create every target database on its 3 Cloud instance.** Hosted 3 Cloud databases are provisioned on the provider's management plane, so create each target database before you start, with the `influxdb3` CLI (or the provider console):

```
# Azure 3 Cloud
influxdb3 create database --retention-period 0 OSS_Azure_EDR
influxdb3 create database --retention-period 0 OSS_AWS_Azure_migration
# AWS 3 Cloud
influxdb3 create database --retention-period 0 OSS_AWS_migration
influxdb3 create database --retention-period 0 OSS_Azure_EDR
```

> `--retention-period 0` = infinite. Use a finite value only if you want points older than the window dropped on write; with a finite window, older OSS timestamps are rejected as they arrive.

**P3 — Token scope.** Each adopted instance's **data token** must have:
- **write** on its target databases (needed by EDR, migration, and cloud-copy *into* it), and
- **read** on any database used as a **cloud-copy source** or a **compare source** (Steps 4, 5, and the parity checks).

For the OSS sources you'll use the OSS admin token (read is enough for migration and compare).

---

## 3. Step 1 — Connect ISR to Azure 3 Cloud

**Goal:** adopt the Azure 3 Cloud instance as a routable upstream. (Repeat for AWS.)

**UI actions**
1. Go to **Fleet → Influx Cloud**.
2. In the adopt form set **Name** (e.g. `Azure 3Cloud`), **Provider** = `azure`, **Region**, **Instance URL**, and paste the **Data token**.
3. (Optional) click **Probe** to confirm reachability.
4. Click **Adopt**.

**✅ Success check**
- The instance appears in the table below the form with a **Database** column and a routable indicator.
- **Fleet → Influx Cloud** and the picker dropdowns on the Cloud Copy / Migration pages now list it.

**📊 Metric availability check**
- Open **Monitor → Influx Cloud** — the instance is selectable; with no traffic yet the panels read zero (they populate as you run Steps 2–5).

Repeat Step 1 for **AWS 3 Cloud** (Provider = `aws`).

---

## 4. Step 2 — EDR: OSS_Azure → Azure `OSS_Azure_EDR`

**Goal:** stream `OSS_Azure`'s `iiot` bucket into the Azure instance's `OSS_Azure_EDR` database via ISR's EDR receiver.

**UI actions (ISR side)**
1. Go to **Tokens** and mint an **ISR client token** (this is the credential OSS will authenticate to ISR with).
2. Go to **Data Movement → Edge Data Replication**. Turn EDR **on**. Set the **cloud destination**: **Instance** = `Azure 3Cloud`, **Database** = `OSS_Azure_EDR`. Save.

**Actions (OSS_Azure side)** — point its replication at ISR's v2 endpoint:
```
influx remote create --name isr \
  --remote-url http://host.docker.internal:8900 \
  --remote-api-token <ISR client token> --remote-org-id 0000000000000001
influx replication create --name iiot-to-isr \
  --local-bucket iiot --remote-bucket OSS_Azure_EDR --remote-id <remote-id>
```

**✅ Success check** — **Data Movement → Edge Data Replication**, *Live metrics* (auto-refreshes every 5 s):
- A stream row `OSS_Azure → cloud:OSS_Azure_EDR` shows **status = active**, rising **points** and **KiB/s**, and **batches_error = 0**.

**📊 Metric-match check** — **Data Movement → Cloud Copy → Compare source ↔ destination**:
- **Source kind** = `OSS v2`; **OSS URL** = `http://host.docker.internal:8087`, **Org** = `azure-industrial`, **Bucket** = `iiot`, **Token** = OSS admin token.
- **Target instance** = `Azure 3Cloud`, **Target database** = `OSS_Azure_EDR`. Click **Compare**.
- Because EDR is a live stream, run the compare **after replication has drained**. Expect the **First point** to match on both sides and the **Last point** on the destination to approach the source; row counts converge to a ✓ per measurement.

> If an EDR forward to the cloud fails, a `movement:edr` alert appears under **Logs & Alerts → Notifications** with the failure detail (it dedups so a flapping stream is one refreshed alert, not a flood).

---

## 5. Step 3 — Migration: OSS2_AWS → AWS `OSS_AWS_migration`

**Goal:** bulk-migrate `OSS2_AWS`'s `satellite` bucket into the AWS instance's `OSS_AWS_migration` database.

**UI actions** — **Data Movement → Migration**:
1. **Source:** kind `InfluxDB OSS v2`, host `http://host.docker.internal:8088`, org `aws-space`, bucket `satellite`, token = OSS2_AWS admin token.
2. **Target:** pick the adopted **AWS 3Cloud** instance, database `OSS_AWS_migration`.
3. Start the migration.

**✅ Success check** — the Migration page (auto-refreshes every 3 s):
- The status pill reaches **done**; the per-bucket row shows **state = done, 100%**, `points ≈ total_points`, **errors = 0**; the feed ends with “all migrations complete”.
- A **`movement:migration` completed** alert appears under **Logs & Alerts → Notifications** with `satellite → OSS_AWS_migration`, rows, MB, and error count.

**📊 Metric-match check** — **Cloud Copy → Compare source ↔ destination**:
- **Source kind** = `OSS v2` (host `:8088`, org `aws-space`, bucket `satellite`, OSS2_AWS token); **Target** = `AWS 3Cloud` / `OSS_AWS_migration`. Click **Compare**.
- Expect **Total rows** ✓ parity and per-measurement **✓ match**, with **First point** and **Last point** aligned S vs D.

---

## 6. Step 4 — Cloud Copy: AWS `OSS_AWS_migration` → Azure `OSS_AWS_Azure_migration`

**Goal:** copy the migrated database from AWS into Azure (cross-provider).

**UI actions** — **Data Movement → Cloud Copy**:
1. **Source** instance = `AWS 3Cloud`, database = `OSS_AWS_migration`.
2. **Target** instance = `Azure 3Cloud`, database = `OSS_AWS_Azure_migration` *(pre-created in P2)*.
3. Leave **Tables** blank (all), keep **Read-back verify** on, choose a **Window** (6 h default; use 1–2 h for very dense tables). Click **Start copy**.

**✅ Success check** — the Cloud Copy page (auto-refreshes every 3 s):
- Status pill → **done**; **Rows read = Rows written**, **Errors = 0**; each per-table row shows **state = done, 100%**, and a **Verify** value of `✓ <n>` (destination window count).
- A **`movement:cloud-copy` completed** alert appears under **Notifications** with `OSS_AWS_migration → OSS_AWS_Azure_migration`, rows, MB, errors.

**📊 Metric-match check** — the **Compare** card, same page:
- **Source kind** = `Adopted cloud`, **Source** = `AWS 3Cloud` / `OSS_AWS_migration`; **Target** = `Azure 3Cloud` / `OSS_AWS_Azure_migration`. Click **Compare**.
- The **per-database panel** shows **Total rows**, **First point**, and **Last point** with **src vs dst side by side** and an **✓ aligned** flag; the per-table table shows ✓ match on every table.

---

## 7. Step 5 — Cloud Copy: Azure `OSS_Azure_EDR` → AWS `OSS_Azure_EDR`

**Goal:** copy the EDR'd database from Azure into AWS (cross-provider).

**UI actions** — **Data Movement → Cloud Copy**:
1. **Source** instance = `Azure 3Cloud`, database = `OSS_Azure_EDR`.
2. **Target** instance = `AWS 3Cloud`, database = `OSS_Azure_EDR` *(pre-created in P2)*.
3. Read-back verify on; **Start copy**.

**✅ Success check** — identical to Step 4: pill **done**, rows read = written, errors 0, per-table verify ✓, and a `movement:cloud-copy` alert under **Notifications**.

**📊 Metric-match check** — **Compare**: source `Azure 3Cloud` / `OSS_Azure_EDR` → target `AWS 3Cloud` / `OSS_Azure_EDR`; expect ✓ parity with **First/Last point aligned**.

---

## 8. Final cross-check — both clouds hold both datasets

Run these four compares from the **Compare source ↔ destination** card and confirm ✓ parity + aligned first/last on each:

| # | Source | Destination | Expect |
|---|---|---|---|
| A | AWS `OSS_AWS_migration` | Azure `OSS_AWS_Azure_migration` | ✓ (Step 4) |
| B | Azure `OSS_Azure_EDR` | AWS `OSS_Azure_EDR` | ✓ (Step 5) |
| C | OSS2_AWS `satellite` | AWS `OSS_AWS_migration` | ✓ (Step 3) |
| D | OSS_Azure `iiot` | Azure `OSS_Azure_EDR` | ✓ (Step 2, after drain) |

At the end, **AWS 3 Cloud** holds `OSS_AWS_migration` + `OSS_Azure_EDR`, and **Azure 3 Cloud** holds `OSS_Azure_EDR` + `OSS_AWS_Azure_migration` — the same underlying data from both OSS sources on both providers.

Optional volume review: **Monitor → Influx Cloud** shows the cumulative push/pull rows & bytes and the source→database→instance flows for every step.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Cloud Copy / Compare instance dropdown empty | Instance adopted without a data token | Re-adopt with a data token (**Fleet → Influx Cloud**). |
| Copy fails immediately: “target database not found” | Target DB not pre-created | Create it on the target instance (P2). |
| Compare shows a **gap** right after starting a copy | Compare ran while the copy was still writing | Wait for the copy pill to reach **done**, then re-Compare. |
| Migration/copy rows < source; old points “older than retention” in the feed | Target DB has finite retention shorter than the data | Recreate the target DB with `--retention-period 0`. |
| OSS compare returns an error | Wrong OSS URL/org/token, or ISR can't reach the OSS host | Use `host.docker.internal` from a containerized ISR; verify the OSS admin token. |
| FlightSQL / Grafana SQL against a cloud-routed DB fails | Cloud-routed databases are served over HTTP | Use Grafana's **InfluxQL** data source for cloud-routed databases, or a managed query node. |

---

## 10. Validation checklist

Copy this and tick as you go:

- [ ] **P1** Azure 3 Cloud adopted (routable) · AWS 3 Cloud adopted (routable)
- [ ] **P2** All four target DBs pre-created
- [ ] **P3** Data tokens scoped (write on targets; read on copy/compare sources)
- [ ] **Step 2** EDR stream *active*, 0 errors · movement alert seen (on error) · Compare D trending to ✓
- [ ] **Step 3** Migration *done*, 0 errors · movement alert *completed* · Compare C ✓ (rows + first/last)
- [ ] **Step 4** Cloud Copy *done*, verify ✓ · movement alert *completed* · Compare A ✓ aligned
- [ ] **Step 5** Cloud Copy *done*, verify ✓ · movement alert *completed* · Compare B ✓ aligned
- [ ] **Final** Both clouds hold both datasets · Monitor → Influx Cloud shows all flows
