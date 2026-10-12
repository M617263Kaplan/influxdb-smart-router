# Training Mode and the ISR journey

Two surfaces that answer different questions.

**Training Mode** (🎓 in the top bar) fills every page with browser-local
synthetic data, so you can see what ISR looks like fully populated before you
have built anything. Action controls are blocked while it is on, and a dock at
the bottom of the screen says so for as long as it is active.

**The journey** is the other half: four levels of real work on your real
cluster, scored, with the exact fields for every step.

## Points come from your cluster, not from clicking

Nothing in the journey is awarded for reading a page or pressing a button.
`GET /api/isr/training/progress` probes actual state — a node pool row, a
replication watermark that has advanced, a cache that has served a hit — and
awards the badge only when ISR can **see** the thing you built.

That has three consequences worth knowing:

- it cannot be gamed, so the score means something to someone evaluating ISR;
- it needs no click-tracking, so there is nothing extra stored about what you did;
- it survives a reinstall, because the evidence is the cluster itself.

Two rules keep the score honest.

**Configured is not proven.** Fourteen of the thirty-two achievements require
evidence that the feature actually did its job, not merely that it exists. A
replication job with a watermark that never moves is the most dangerous state
there is — it looks like a backup and is not one — so that badge waits for the
watermark. A cache that has served no hits does not count.

**Badges are sticky.** Tearing down a test rig must not un-teach you. Once
earned, an achievement stays earned; a separate indicator shows whether what you
built is running *right now*. An earned badge marked "learned" means you did it
and it is currently switched off.

## The four levels

Levels unlock on **completion, not points** — you cannot federate a fleet you do
not have.

| Level | | What it is | Unlocks at |
|---|---|---|---|
| 1 | **Awesome** | A cluster running, authenticated, serving reads and writes, with you in control of it | — |
| 2 | **Uber Awesome** | Everything the cluster alone cannot do for you: routing rules, pools, cache, bad-query defence, the honeypot, Laura | 6 of Level 1 |
| 3 | **Super Mega Uber Awesome** | Routes, schemas, fleet and federation — one ISR in front of many places at once | 5 of Level 2 |
| 4 | **Indestructible** | Not a superhero, just genuinely hard to bring down: ISR itself redundant, spokes replicating, a proven way back from anything | 5 of Level 3 |

Level 4 is the resiliency capstone — ISR's own HA state backend and leader
election, front-door redundancy so the *address* survives losing an instance, an
encrypted disaster-recovery backup with a rehearsed restore, two or more spokes
in separate failure domains with independently advancing watermarks, and a write
queue that held during an outage and drained afterwards.

## Every step names the field

Each achievement carries ordered steps, and each step names the page, the
section, the field, the shape of the value and a worked example — followed by
what you should see when it worked, and a plain statement of what ISR watches
for to award the badge.

Those instructions live next to the probe that awards the points, so a step can
never tell you to fill in a field that no longer earns the badge.

## Time to awesome

The journey panel shows the clock from your first sign-in to Level 1 complete.
That is the number the whole feature is named after, and the one worth showing
someone evaluating ISR.

## Laura

Laura is ISR's AI — the engine that watches the cluster, tunes compaction and
files proposals. The figure in the console is her face. She polls the same
probe that scores you, so she only ever celebrates something that actually
happened. Click her to open the journey; "Not now" hides her.

She is drawn as a **translucent volumetric figure rather than an orb**, and the
reason is functional rather than stylistic: a person-shaped projection can
stand next to a control and *point at it*, which an abstract icon cannot do.
The translucency earns its keep too — you read the UI straight through her, so
she can stand right beside a field without covering it.

Four independent axes combine freely, so she can be worried, pointing left and
speaking at once:

| Axis | Values |
| --- | --- |
| mood | idle · think · happy · wow · worry |
| pose | rest · point left/right/up/down · present |
| state | speaking · listening · alert |
| placement | free, or pinned to a corner at reduced scale |

Under `prefers-reduced-motion` she stays and simply stops moving. Every
reaction also lands as bubble text and a toast, so nothing is communicated by
motion alone. The one motion kept is the **pose change** — an arm that points
is information, not decoration, so it snaps into place instead of animating
there. Reactions are announced to assistive technology via `aria-live`.

## Her cap is the system's health

Laura wears the cluster's state. It is the **cap** and not the whole figure on
purpose: a character that recolours entirely reads as a different character and
the eye stops trusting it, whereas one small, consistently placed patch is
something an operator learns to read at a glance from across a room.

| Cap | Meaning |
| --- | --- |
| green | nothing is erroring |
| amber | open warnings or errors — under pressure |
| red | an open critical — running hot (the only state allowed to pulse) |
| her own violet | no status known yet |

Three rules keep it honest.

**It reads the poll that already runs.** The cap is driven by the same alert
feed as the security banner, so the two can never disagree.

**A failed check clears the cap.** If ISR cannot reach the alert feed, she goes
back to her own colour rather than holding the last one. A stale green is the
most dangerous thing she could wear: it says "checked, fine" when the truth is
"could not check".

**Colour is never the only signal.** The state is also on the element as text
for assistive technology, because red/green deficiency turns two different caps
into two identical grey ones.

Health is independent of mood — she can be delighted you finished a migration
while the compactor is still hot.

## The stop sign

When ISR turns an attacker away, Laura holds up a stop sign. It fires on
**growth** of the blocklist, never on its size, and the first reading only
establishes a baseline — otherwise every page load would claim a block that
happened last week, and a gesture that fires when nothing happened is one
operators learn to ignore. Which costs you the one time it matters.

## Your settings follow you, not your browser

Laura's preferences — voice, microphone mode, pinned corner, hidden — are
stored against your ISR user, not the browser. Two operators sharing a
workstation get their own Laura, and yours is the same on a laptop and a wall
display. They are keyed off your signed-in session, so no one can read or
change yours by naming you.

## Where to find it

- **Training Mode** — 🎓 in the top bar (you must be signed in).
- **Tour this page** — the training dock, once Training Mode is on.
- **Your journey** — the training dock, or click Laura. The journey
  works whether or not Training Mode is on, because it is about your real
  cluster.
