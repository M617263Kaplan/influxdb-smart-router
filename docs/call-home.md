# Call Home — external tools asking to connect

Call Home lets an external tool enrol with an ISR, be approved by an
administrator, and then connect over mutual TLS to report telemetry and to ask
for the databases and tokens its runs need. It ships **disabled**. Turning it on
opens an **additional inbound port** that admits external machines — a decision
an administrator makes deliberately rather than inherits from a default.

---

## What it is

An external tool — for example the [Influx Traffic Lab](influx-traffic-lab.md) —
needs to reach an ISR for telemetry, and to be given the databases and tokens its
runs require without a human copying credentials out of a console and into an
application.

The shape is deliberately narrow:

> **A person asks. An administrator decides. The tool never holds the ability to
> create a credential, only to ask a human for one.**

## Why enrolment and the channel are different legs

They look inconsistent until you try to draw it the other way.

The ongoing channel is mutual TLS — the tool proves who it is with a client
certificate. But a tool that has never connected has no certificate, so it cannot
authenticate over the channel it is asking to be admitted to. Something has to
happen first, and that something has to be a **person**:

| | Enrolment | The channel |
|---|---|---|
| Transport | the ordinary API, ordinary TLS | mutual TLS |
| Who authenticates | a **person**, with this ISR's second factor if it requires one | the **tool**, with its certificate |
| What it produces | a *request*, waiting for a human | an authenticated session |
| Grants anything? | **no** | only what the approval granted |

This also satisfies the constraint that shaped the design: *the user has to
authenticate to create the channel*. Enrolment introduces **no new
authentication mechanism** — it rides the console's existing session, so
lockout, password policy and two-factor all apply without being reimplemented.

## The identity in the certificate is ISR's decision

The certificate signing request is treated as a request for a *key* to be
signed, never as a claim about *who the holder is*. ISR discards the subject the
CSR asks for and substitutes its own.

A CSR requesting `CN=i-am-the-hub, O=AttackerCo` is issued as

```
subject = CN=tool.influx-traffic-lab.<the person who asked>
issuer  = CN=ISR Tool CA
X509v3 Extended Key Usage: TLS Web Client Authentication
X509v3 Basic Constraints: critical, CA:FALSE
```

— no subject-alternative names, client authentication only, not a CA. The
certificate is bound to the tool's own key, which never leaves the machine that
generated it.

## Tools get their own certificate authority

Tool certificates are signed by an **ISR Tool CA**, not by the management CA
that the hub↔spoke channel uses.

The reason is specific. A spoke's management listener verifies that a client
certificate *chains to the management CA*; that check is one of the channel's
four defence layers, alongside the IP allowlist and the HMAC handshake. Keeping
tool certificates under a separate authority means "signed by the management CA"
continues to mean "is the hub". An issued tool certificate validates against the
tool CA and **fails** against the management CA with *unable to get local issuer
certificate*.

## A connecting tool is not a fourth role

ISR's roles are a ladder — viewer → operator → admin, checked as *at least this
much*. A tool sits nowhere on it. It must report its own telemetry, which is
above viewer; it must never read the query audit log, which any viewer can. Every
rung is simultaneously too much and too little.

So a tool's permissions are a **set**, granted per approval:

| Grant | Default | Why the default |
|---|---|---|
| Pools it may use | none | an empty list means *none*, never *all* |
| Databases | none | the administrator creates them; the tool asks |
| Report telemetry | off | |
| Request resources | off | asking is not creating |
| **Influences autoscaling** | **off** | see the note below — ISR records and reports this one, it does not enforce it |

### Which of these ISR enforces, and which it only reports

| Grant | ISR enforces it? |
|---|---|
| Report telemetry | **yes** — without it the telemetry route answers 403 and names the missing grant |
| Request resources | **yes** — without it the request route answers 403 |
| Influences autoscaling | **no** — recorded, and reported to the tool on `/callhome/v1/resources`, which the tool is expected to honour |

So leaving *influences autoscaling* off states an expectation the tool is
trusted to keep; it is not a restriction ISR applies to the tool's traffic. The
approval dialog says so on the tick-box, so an operator reads the grant for what
it is.

## Three addresses, never merged

Only one of them is an observation:

- **`peer_ip_observed`** — the socket ISR accepted the connection on. The caller
  cannot choose it.
- **`forwarded_for_claimed`** — whatever the network path asserted in a header.
  Any client can set this.
- **`ip_claimed_by_tool`** — what the tool says about itself. A tool behind NAT
  cannot know its own public address.

The approval queue shows all three under their own labels, so the administrator
deciding whether to trust a tool sees which address was observed and which was
merely claimed.

## Where an approved tool dials

Once approved, `GET /api/isr/callhome/v1/enroll/{id}` carries a `tool_channel`:

```json
"tool_channel": {
  "port": 9843,
  "scheme": "https",
  "mutual_tls": true,
  "first_route": "/callhome/v1/session",
  "host": null,
  "host_note": "Dial the SAME host you reached this API on...",
  "port_is_declared": false,
  "port_note": "The port ISR BINDS..."
}
```

**`host` is null on purpose.** Behind NAT, a proxy, or a published container
port, the address a client reaches ISR on is not something ISR can observe, and
a guess presented as a fact is worse than a blank. The client already holds a
host that works — the one it just reached this API on — and should reuse it.

**The port can carry the same uncertainty.** An ISR run as `-p 19843:9843` binds
9843 and is reachable on 19843. So `port_is_declared` says which kind of number
you are holding:

| | what `port` is | what to do if dialling fails |
|---|---|---|
| `false` | the port ISR **binds** | ask the operator for the external port |
| `true` | what the operator **declared** is reachable | a real connectivity fault |

An operator who knows the external port sets `ISR_TOOL_ADVERTISE_PORT`, and the
Tools page shows both the bound and the advertised port whenever they differ.
Where the two coincide — most deployments — nothing changes.

## A tool is sponsored by a person

The person who enrolled a tool remains accountable for it.

- Deactivating or deleting that account **suspends** their tools, with a reason
  the Tools view can show.
- An administrator can **reassign** to another active account. This does *not*
  re-mint the certificate — the common name keeps the original requester, so
  accountability moves and the credential does not.
- Reassignment does **not** resurrect a *declined* tool. Only a suspension —
  which is ISR's own doing rather than a decision anyone made about that tool —
  clears this way.

Enforcement re-reads the live account row on **every** connection rather than
trusting a copy taken at approval, so no deprovisioning path has to notify
anything. A deleted sponsor is refused, not waved through: otherwise deleting the
person would be the one way to make their tool permanent.

## What declining does, and what it does not

Declining is a **record, not a deletion** — a declined tool must not be able to
re-ask its way in unnoticed, and an administrator reading the queue later should
see that someone said no rather than an absence to interpret.

Stated plainly, because the difference matters: **declining does not revoke the
certificate.** It remains cryptographically valid. What stops the tool is the
listener refusing it by fingerprint at connection time — and because
authorisation is re-read per REQUEST, a decline takes effect on the tool's next
request rather than its next reconnect.

**Declining reaches the data plane too.** It revokes every client token bound to
the tool and returns the count:

```json
{ "ok": true, "status": "declined", "tokens_revoked": 3 }
```

That number is reported rather than assumed, **including zero** — a tool torn
down with no bound tokens either never had any, or has some that were never bound
and will survive this. Both are worth seeing, and an empty field would hide the
second.

## Resource requests

With the *request resources* grant, a tool asks for a database or token by name;
it never creates one. An administrator creates the resource and confirms the
request, and the tool can see that its request reached `confirmed` and under
what name. A confirmed request delivers a **name, not a credential**: the
administrator hands any token the tool needs to it directly.

## Turning it on

From the console: **Operations → Tools**, the switch at the top of the page —
which also lists what is connected, what each tool was granted, and how to
disconnect it. The API below does the same, for automation.

```bash
# read the state
curl -s -H "X-ISR-Session: $SESSION" http://<isr>:9800/api/isr/callhome/config

# enable on a test rig
curl -s -X PUT -H "X-ISR-Session: $SESSION" -H 'content-type: application/json' \
     -d '{"enabled":true}' http://<isr>:9800/api/isr/callhome/config
```

While it is off, every `/api/isr/callhome/*` route answers **503** with a
sentence explaining that an administrator has not enabled it — deliberately not
404, which would claim the route does not exist, and deliberately not 401, which
would blame the caller's credentials for an administrator's setting.

Clients should not need any of this: **`capabilities` on the public
`/api/isr/version`** is the negotiation surface, and `callhome/v1` stays absent
from it until the listener answers.

## Approving a tool

Everything ISR can enumerate is **picked** rather than typed:

- **Capabilities** are tick-boxes, each showing the exact name the server
  understands beside what ticking it does.
- **Databases** and **pools** are offered from what this ISR can actually see.
  When a list is empty it says why and links to the page that creates them,
  rather than showing an empty box.
- The only typing left is the audit note, and the name of a database on a
  cluster this ISR does not front — which arrives ticked, dashed, in the same
  list, so what was typed sits beside what was picked.
- A summary line states what the grant **will** say, in the same words the
  Tools table shows afterwards.

**On refusal the form survives.** If the server rejects an approval the dialog
stays open with every tick and the note intact, and the server's own reason
appears on a message line inside it. The operator corrects the one thing that
was refused rather than starting over.

*Reassign sponsor* requires an existing **active** account, so it is a picker of
active accounts, with the current sponsor greyed out.

## A tool is a fleet, and each agent holds its own token

One tool runs many agents at once — that is the point of a ramp — so a token
carries **which agent instance** it belongs to, not only which tool:

| field | means |
|---|---|
| `subject_type` | `tool` |
| `subject_id` | the Call Home peer — the **fleet** |
| `instance` | the **agent**, e.g. `agent-1` |

The instance is its own field rather than a convention inside the label, because
reading identity off a name a person typed is how a fleet of ten becomes
indistinguishable from one agent restarted ten times.

**Both parts are validated, on create and on edit.** `subject_id` must be an
existing, *approved* peer; `instance` must be non-empty. This is not
bookkeeping: teardown revokes **by subject**, so a token bound to a name that
does not exist would survive the teardown meant to remove it while the console
reported the tool as gone. The same rule covers `device` subjects. `user` and
`group` are not checked against ISR's own tables, on purpose — those identities
can be external (SSO, LDAP) and are not ISR's to adjudicate.

The Tools page shows the fleet as an **Agents** column — `3 agents`,
`1 agent / 1 retired`, or `none bound`. That last one is stated rather than left
blank: an approved tool holding no bound token is either idle, or sending data on
a credential this ISR cannot attribute or revoke, and a blank cell would hide
exactly the state the binding exists to end. Disconnect names the number it is
about to revoke *before* you confirm.

## What a tool reports about its runs

`POST /callhome/v1/activity` accepts a `run_id`. ISR **stores it** — one row per
(tool, run) in `isr_tool_runs`, readable at
`GET /api/isr/callhome/peers/:id/runs` — so a run can be queried rather than
searched for in a log sentence.

`last_event` and `counts` are kept **verbatim**, and `terminal_at` stays null:
which of a tool's outcomes *end* a run is the tool's vocabulary, not ISR's, and
deciding it here on an assumption would be the guess this design exists to avoid.
The log is kept as well — the table is a run's current state, the log is its
history.
