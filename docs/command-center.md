# Command Center (Monitor → Data Flow)

One canvas for the whole platform, tiered by its actual object graph. Instead of
choosing between a global fleet map, this hub's component topology, and a
per-spoke detail view, you ask every question of one page.

The design goal is that you should be able to answer most questions about the
platform without leaving the page, and leave it only when you want to *change*
something.

## The tiers

| Tier | What it holds | Read from |
|---|---|---|
| **ISR control plane** | this ISR, its HA peers, every enrolled spoke | `/api/isr/version`, `/ha/status`, `/ha/members`, `/fleet/spokes`, `/fleet/spokes/:id/live` |
| **Organizations** | tenants that own databases and pools | `/api/isr/billing/orgs` |
| **Clusters** | the InfluxDB estates managed from here, plus adopted cloud clusters | `/api/isr/scaling/nodes`, `/cluster/license`, `/cloud/clusters` |
| **Pools** | ingest · query · compact · process · honeypot | grouped from `/scaling/nodes`, plus `/cloud/pools` |
| **Nodes** | the individual InfluxDB nodes, grouped under their pool | `/api/isr/scaling/nodes`, `/node-metrics` |
| **Routing rules** | first-match routing, with bonds to the pools they target | `/api/isr/rules` |

Status rolls **up**: a node's saturation makes its pool degraded, which makes its
cluster degraded. It never rolls down — a healthy cluster badge never hides a
sick node.

## Bonds — the half a per-object view cannot show

A **bond** is the line between two objects, and it is a first-class thing with
its own status, its own tooltip, and its own modal. It carries the state no
per-object view can express: **a cluster can be perfectly green while the bond
feeding it is amber**, and the bond is where that shows.

| Bond | Drawn as | Means |
|---|---|---|
| **HA peer** | doubled line | leader ↔ standby, with peer freshness against the stale threshold |
| **Management channel** | solid | the mTLS control channel to a spoke |
| **Config replication** | fine dash | centralised policy pushed hub → spoke |
| **Data replication** | long dash | a real replication job, with state, lag and error count |
| **Federated read** | dotted | a spoke answering reads for the hub |
| **Residency routing** | long dash, distinct hue | rows pinned to a region |

Each kind is distinguishable by **shape as well as colour**, so the relationship
type survives a greyscale screenshot or a colour-blind operator.

Peer bonds route through a **relationship bus** — a reserved band above the ISR
lane, one fixed row per bond kind (HA, channel, config, data, federation,
residency, bottom-up). Two consequences: a strand never passes behind an
intervening card, so its identity chip stays visible and clickable; and because
the row height is fixed per kind, "config replication" is always at the same
height on the page and becomes learnable.

**A bond is drawn only where the platform reports the relationship.** An absent
bond means none is configured — not that nobody looked. Config replication, for
instance, is only drawn when the fleet policy actually centralises a domain.

## Arcs

Clicking an object opens an arc of detail modals around it. The arc varies by
role and, for nodes, **by mode** — a compactor is offered compaction and storage
where an ingestor is offered WAL and the durable write queue, because a modal
that applies to everything applies to nothing.

Selecting an object also dims what is unrelated and lights its **lineage**:
ancestors, descendants, and bonded peers. The arc opens *away* from that lineage
(preferring below) rather than covering the context you just asked for.

Every modal footer carries a hand-off to the page that owns the subject, so the
canvas stays a place to understand and the owning page stays the place to act.

## Identity — which cluster owns what

**A pool belongs to the cluster its record names, never to whichever cluster its
name resembles.** Pools are conventionally named `<cluster>-<mode>`, but reading
that convention as a membership test is not a shortcut, it is a different
question with occasionally the same answer — a cluster called `prod` must not
claim `prod-east-ingest` and the other pools of a *different* cluster that
happens to share the prefix.

Membership comes from a recorded field. Where a pool records only a **family**
(`demo-bad`, `prod-east-expensive` — a set of pools that scale together, not a
cluster), the family is resolved against the clusters that actually exist, taking
the longest match at a `-` boundary: with `prod` and `prod-east` both registered,
`prod-east-bad` is `prod-east`'s and never `prod`'s, and `production-bad` is
neither's.

A pool whose cluster cannot be established appears in an **`unattributed`** strip
on the Pools tier and is excluded from cluster-scoped operations, **including
delete**, until one is set. Unattributed is a state an operator can see and fix;
mis-attributed is one they cannot, and it is what would get deleted alongside a
stranger.

**A node card shows the build the node reports for itself**, read from `/ping`'s
`x-influxdb-version`. That is not the image tag: a floating tag like
`influxdb:3-enterprise` reads as "3-enterprise" and resolves to whatever was last
pulled. A node that has not answered yet shows its tag prefixed `~`, so *reported*
and *requested* stay distinguishable rather than collapsing into one confident
string.

**The honeypot decoy hangs off the ISR site, not a cluster.** It is a Core
container belonging to no Enterprise estate, so counting it as cluster membership
would break the one-compactor-per-cluster invariant. It contributes to no
cluster's pool count or health rollup.

**On load the canvas scopes itself to a cluster that is running something** —
live nodes decide, pool count breaks the tie. A cluster whose containers are gone
keeps its pool records, so registrations alone are never the ranking.

## Scale — the page rolls up rather than enumerating

Laid out flat, 300 node cards run **54,618 px wide** in a 1,428 px viewport —
38 screen-widths. Rendering is not the constraint; the flat horizontal strip is.
So above a threshold a tier groups instead of listing:

| Tier | Threshold | Becomes |
|---|---|---|
| Pools | more than 10 in scope | one chip per cluster, carrying the counts that decide whether to open it |
| Nodes | more than 8 in a pool | one chip per pool, expanding in place |

Rollup rows **wrap**, which is what keeps a fleet on one screen: 20 clusters go
from 3.6 screens wide to one. The no-shrink rule that governs cards does not
apply to chips — a squeezed card lies about its metrics, a chip carries counts
and can wrap without lying. Below the thresholds every object is listed: a small
deployment shows every card, and the thresholds are fixed, so there is no
setting to configure. The Pools tier starts collapsed, being the tier most
likely to sprawl.

## Three rules the page enforces

**Liveness is judged on progress, not on self-report.** A replication job that
reports `running` with zero errors, while its last sync has not advanced, is
marked **STALLED** — amber after 5 minutes, critical after 30. This is the state
an error-driven status model shows as perfectly healthy: nothing has failed, so
nothing is red, while nothing is moving either. The bond carries a `progress`
row of its own ("none in 1h" rather than a lag figure), and the finding says so
in words: *no errors reported, so nothing has failed and nothing is moving*.

Two guards keep the rule from crying wolf. Scheduled, parked and idle jobs are
exempt — an old last sync is precisely what they are supposed to have. And a
running job that reports no last sync at all reads as **not reported**, never as
stalled: being unable to see progress is a different claim from seeing none.

**An unmeasured value renders as an em-dash, never a zero.** A zero reads as a
measurement — "0 buffered points" — and an em-dash reads as ignorance. On an
operations page those must never be confused. Where a modal lists a metric that
is not instrumented, it says so explicitly rather than leaving a
plausible-looking gap.

**Colour is never the only signal.** Unreachable objects dash their outline,
changing objects pulse, and every card carries a text status chip. Domain pips
(performance · capacity · security · movement) use a *hollow* pip for "not
applicable" rather than a green one, so the page never claims to have checked
something it did not.

## Cost

The page refreshes on a tiered cadence, and only while it is visible:

| Cadence | What refreshes |
|---|---|
| 5 s | tier summaries (sites, HA, nodes, pools, rules, replication) |
| 20 s | remote spoke live-probes (each one forwards a request to that site) |
| 30 s | tenancy, licence, compliance, fleet policy, object store |
| never, while off screen | nothing is fetched at all unless the page is visible |

Each endpoint is guarded individually: a `401` for a viewer-role operator, or a
subsystem that was never provisioned, degrades that one tile rather than blanking
the page.

## Controls

| Control | Effect |
|---|---|
| **All objects / Needs attention** | filters the canvas to objects at attention or worse, keeping the tier structure |
| **Compact view** | collapses the Pool, Node and Rule tiers to a count — on a large cluster this is the difference between a command center and a wall of cards |
| **Flow animation** | direction-of-travel animation on active bonds |
| Click a **cluster** | scopes the Pool and Node tiers to it; sibling clusters collapse to chips |
| Click a **rollup chip** | expands that group in place; the expansion survives a repaint |

## Notes

- The per-client drilldown (by token or source IP) lives on **Monitor → Client
  Apps** ("Drilldown by token / IP"), which groups by User-Agent where the
  drilldown groups by identity.
- The single-compactor invariant is reported on the cluster's Topology modal,
  at the object that owns it.
- ISR reports the object store's state; its availability is managed by the
  storage provider, not by ISR. The Object store modal states that boundary so
  nobody waits for ISR to fix a bucket.
