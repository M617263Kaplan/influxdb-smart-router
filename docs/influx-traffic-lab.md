# Influx Traffic Lab has moved

**→ https://github.com/influxdata/Influx-Traffic-Lab**

The Traffic Lab has its own repository. Documentation, releases and the
download all live there.

| | |
|---|---|
| Repository | https://github.com/influxdata/Influx-Traffic-Lab |
| Releases | https://github.com/influxdata/Influx-Traffic-Lab/releases |
| Install, and the Gatekeeper step | https://github.com/influxdata/Influx-Traffic-Lab/blob/main/docs/install.md |
| The 25 datasets | https://github.com/influxdata/Influx-Traffic-Lab/blob/main/docs/datasets.md |

## Traffic Lab agents — what ISR is expected to do

The Lab ships an **agent**: the same workload engine as a headless Linux
container, meant to be **launched by ISR rather than by a person**. It has no
interface, keeps no profile, and never enrols — so it never appears in the tools
queue and holds no certificate.

**That is the decision that makes it work.** ISR injects a scoped write token at
launch, which is why the agent needs none of the Lab's Darwin-bound code and why
it builds on Linux at all.

| | |
|---|---|
| Documentation | https://github.com/influxdata/Influx-Traffic-Lab/blob/main/docs/agent.md |
| Image | built by ISR from a Lab-supplied context — see below |

### ISR builds the image

The agent image is built where it runs. The Lab hands over a **generated build
context** — its engine staged into a self-contained Swift package with a
Dockerfile beside it — and ISR builds it, exactly as `scripts/build-local.sh`
builds ISR's own image.

```bash
docker build --build-arg TRAFFIC_LAB_VERSION=<lab-version> \
             --build-arg TRAFFIC_LAB_BUILD=<build> \
             -t influx-traffic-lab-agent:<lab-version> <context>
```

Building where the agent runs makes the architecture right by construction — no
cross-build and no emulation — and `imagePullPolicy: IfNotPresent` means ISR
resolves it locally with no registry lookup.

**Pass the version arguments.** The agent has no app bundle to read a version
from, so without them the image reports `dev` and every `RunSummary` it produces
carries no engine version — which makes the run unattributable the moment two
results disagree. Every context ships a `PROVENANCE.txt` naming the source
commit it was staged from; record it beside the runs.

### What ISR supplies

The agent reads **one JSON plan on stdin**. Nothing about the workload can come
from the environment — a workload half-specified by an operator's shell is one
nobody can reproduce. The credential is the only thing that arrives that way.

1. **`TRAFFIC_LAB_TOKEN`** — a write token scoped to the one database in the
   plan.
2. **An absolute write rate.** Scenario rates may be expressed as a multiple of
   the cluster's compaction throughput; ISR resolves that multiplier to an
   absolute rate before launch. The agent **refuses** an unresolved multiplier
   rather than picking a number, so this cannot fail quietly.
3. **`agent_index` and `agent_count`** per container. Without distinct indices
   every agent writes **the same series**, so a fleet covers a quarter of the
   breadth it reports while the throughput number still looks plausible.
4. **A telemetry database, and a token for it** (`TRAFFIC_LAB_TELEMETRY_TOKEN`).
   Optional, but without it the container's per-request journal is discarded on
   exit and the run leaves only a summary. It **must not** be the database under
   test — the agent refuses that, because one telemetry row per request written
   into the measurement being measured puts the harness inside its own result.

### What to expect back

Progress is posted to `/callhome/v1/activity` on the tool plane while the run is
live. The final `RunSummary` is JSON on **stdout**; every human-facing line goes
to stderr, so stdout stays parseable.

**A refused plan exits non-zero with the reason on stderr.** ISR launched the
container, so its log and exit code are all that comes back — the refusals are
written to be actionable by whoever built the plan.

### Sizing the telemetry database

One row per **request**, roughly 635 bytes, regardless of what the request did.
Against a 500-point write batch that is a rounding error; against a query, which
sends almost nothing, it is pure overhead. A query-heavy test set measured at
**31% of its load volume**. Size against request count, not point count.

### Two things not to assume

- **The image comes from a build context, not a registry.** ISR builds the image
  from a Lab-supplied context, so the thing to ask for is a context — not a pull
  secret, and not access to a repository.
- **ISR should not autoscale a pool mid-run** unless the run is meant to measure
  exactly that. A benchmark against moving capacity measures something else,
  which is why the grant records whether autoscaling applies.

## Why this page still exists

This page is left in place because links to it exist. The version of this
document that is kept current is the
[README on the new repository](https://github.com/influxdata/Influx-Traffic-Lab).
