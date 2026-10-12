# Personal navigation

The console has 144 pages across 20 workspaces. Delivered to every operator in
the same order, a person who spent their day on ingest health would have to walk
past twenty pages of configuration they would never open to get to it.

Navigation is **per person**, saved to the account rather than the browser, so
it follows an operator from a laptop to a wall display, and two people sharing a
workstation do not share one layout.

**Nothing here removes access.** A hidden page is still reachable from search,
from ⌘K, and from its own link, and every permission is still decided by the
server on every call. This changes what is in front of you, not what you may do.

## Two surfaces

They are easy to confuse, so it is worth being explicit:

| Surface | Lists | Changed by |
|---|---|---|
| **The rail**, down the left | workspaces | *Show this workspace on my rail* |
| **The tab strip**, across the top | the pages inside the workspace you have open | the per-page setting |

The per-page setting acts on the **tab strip**. Pinning a page never adds it to
the rail.

## Three layers, in a fixed order

1. **Role** gives a starting rail. A viewer opens on the read-only workspaces
   rather than on twenty-one surfaces of configuration they cannot change. A
   workspace whose every page is above a role is dropped, so this list cannot
   drift from the real permission gate.
2. **Adaptive** watches which pages you actually open and promotes the ones you
   use, displacing a default page you open less.
3. **What you set yourself always wins.** A pinned page is never demoted and a
   hidden page is never promoted, whatever the other two layers would prefer.

Open it from **Customize nav** at the foot of the rail, or ⌘K → *Customize
navigation*.

## The per-page setting

| Setting | Effect |
|---|---|
| **Automatic** | whatever the product and the adaptive layer decide |
| **Pin to the tab strip** | holds a tab slot; never demoted |
| **Keep under More** | stays off the strip however often you open it |
| **Hidden** | off this workspace entirely — still in ⌘K, search, and its own link |

A tab strip shows at most **seven** pages; the rest sit one click away under
**More**, which is what lets the leading tabs mean anything. Pins are the
exception: pin eight and you get eight, because a pin is never the page that
gets cut.

**Pinning is a priority, not a move.** In a workspace whose pages all already
fit, pinning changes nothing you can see that day — it holds that page's slot as
the workspace grows and takes it out of reach of adaptive demotion. The editor
says which of those situations you are in before you try it, and says when a
page is where it is because the console moved it rather than because you asked.

## What adaptive will and will not do

- It only rearranges **between sessions**, never while you are working. A strip
  that reshuffled on your fifth click would move the tab you were reaching for.
- It only ever moves pages you have **not** set yourself.
- Every move is a swap inside one workspace, against a page you open strictly
  less often — so it can always be explained in one sentence, which the notice
  then does, with **Put it back**. Undoing records the decision, so the same
  guess is not made again next session.
- It will not demote a workspace's first tab, or the Danger Zone. A page you
  rarely open is not a page you do not need: nobody opens a factory reset often,
  and a page left on screen all day never registers as "opened" at all.
- It can be switched off entirely, for a layout that never changes.

## Storage

Preferences are one small JSON blob per user, held against the signed-in
username — never against a name supplied in the request, so no caller can read
or write another operator's settings by asking. Both this and Laura's settings
live in that one blob, and each replaces only its own top-level key, so neither
can delete the other.

The blob is capped at 8 KB. Usage counters are the only part that grows; if the
cap is hit they are shed and the write retried, rather than leaving an operator
whose settings have silently stopped saving.

**If the saved layout cannot be read at sign-in** — a network blip, a restart
mid-request — the console does *not* fall back to defaults. Doing so would mean
the next click writes those defaults over the real thing and destroys settings
that were never seen. Instead the session goes read-only for preferences: it
keeps what it has, changes nothing, and waits for a successful read to prove
what is actually stored. A lost session of changes is recoverable; a silent
overwrite is not.

## Resetting

**Reset to default** clears your choices and returns you to your role's layout.
Usage history survives, so a reset means "go back to the product's layout", not
"forget who I am".

Nothing takes effect until **Save** — the editor works on a draft, so opening it
to look around, or changing your mind halfway, leaves your console alone.
