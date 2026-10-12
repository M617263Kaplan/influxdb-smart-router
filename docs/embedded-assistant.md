# Embedded assistant

An in-console assistant that helps operators — often non-technical — understand
what ISR is doing and get things done in plain language. It is **read-first and
human-gated**: it explains, answers, and points at the exact fields; anything
that changes state is staged as a confirmation card that a human clicks. Nothing
the assistant proposes ever executes on its own.

Open it from the top bar (the ✨ button) or press `Cmd/Ctrl-J`. It's available on
every page and knows which page you're on.

## Her avatar is the topology

Laura's mark is ISR's routing graph, not a face — she reads the graph, so the
mark **is** the graph, with a node for each kind of evidence she reasons over.

She parks in the corner and breathes on a slow cycle: a still mark on a system
that claims to observe continuously reads as switched off. Click her, or say
**"Laura, give me a status"**, and she expands to a full observation surface —
topology, the mesh at hero size, her open findings, and counters. Minimise her
with the `–` at her corner and she parks as a chip in the dock rail beside
*Guide me* and *Getting started*.

The status phrase is matched **in the console**, not sent to a model, so it works
with no API key configured — including on an air-gapped hub. An illustrated
figure is also available: right-click Laura for preferences.

### What the status surface shows

Everything is read live from that ISR. Nothing is cached or sampled.

- Metrics are labelled for what ISR **actually measures** — queries/s and a mean
  latency, not a P99. CPU and memory say *(estimated)* when ISR could not read
  cgroup counters. Relabelling a mean as a P99 is the kind of small inaccuracy
  someone later plans capacity on.
- With **no InfluxDB cluster attached**, it reports ISR itself — CPU, memory,
  connections, throughput, open alerts — rather than a column of dashes.
- The evidence nodes are the proposal kinds Laura really emits: **schema,
  routing, compaction, risk, scaling**.
- An observer that is **switched off draws hollow and says so**. "No open
  compaction proposals" is a reassuring sentence and a false one when nothing is
  watching compaction; silence from a disabled observer is not a clean bill of
  health.

Four states drive each node, its label dot and the insight row together, so the
picture and the words cannot disagree:

| State | Reads as | Meaning |
|---|---|---|
| needs review | warn, filled, **with a count** | open proposals waiting on a human |
| clear | ok | observing, nothing to approve |
| not observing | hollow, dashed | that observer is switched off — silence means nothing |
| health only | hollow, dashed | this class emits no proposals at all |

The count sits on the label rather than only in the hue: colour alone is
invisible to a red/green-deficient operator and to a greyscale screenshot in a
ticket. The whole labelled group — node, dot and word — is one click target
through to the evidence, and the word is reachable by keyboard.

## Two brains

- **Scenario planner (default, no setup).** A deterministic matcher that covers
  the common intents out of the box — migration, replication, backfill,
  clone-with-policy, mirror-first setup, saving endpoints, validating that data
  landed — plus block/unblock-IP actions and the parallel-run flow. No API key
  required.
- **Model (optional).** Configure a model API key and the assistant runs a
  server-side conversation with the model, handing it ISR's read tools so it can
  answer free-form questions with live data. The planner remains the fallback if
  the model is unavailable.

## What it can do

### Answer and guide (read-only)
Ask "what's unhealthy?" or "explain the most expensive queries" and it reads live
state (node health, open alerts, query cost, migration/replication status,
routing decisions). Ask "help me migrate Cloud 2 to Cloud 3" and it opens a
**dynamic guide**: each step navigates to the right page and highlights the exact
fields to fill, with a floating note. It points — you fill and click.

### Governed writes (propose → confirm)
For an operator or admin, the assistant can **propose** actions from a closed
catalog of named operations. A proposal never runs: it becomes a confirmation
card. Click **Confirm** to apply (audited as "via assistant") or **Reject** to
drop it. No destructive operation — delete, reset, teardown — is exposed at all.

| Operation | Needs to confirm |
|---|---|
| `block_ip`, `unblock_ip`, `snooze_alert`, `close_alert` | Operator |
| `create_database` | Operator |
| `create_cloud_connection`, `deploy_spoke` | **Admin** |

Deploying a spoke spends money; adding a cloud connection widens who ISR can act
as. Both need an **admin** to click Confirm, because confirming runs the action
with the confirmer's authority — that is the check that actually binds, not who
proposed it. An operator's Confirm on one of these is refused and **the action
stays staged** for an admin.

Some arguments are refused when the card is *created*, so a bad one never reaches
a human looking routine: a spoke whose console is open to `0.0.0.0/0`, or a cloud
credential pasted as a raw access key instead of a reference.

#### Why a closed catalog and not a general admin power

The obvious way to grant "everything an admin can do" is one tool that takes a
method and a path. ISR deliberately does not do that.

The assistant reads text it did not write — cloud-connection names, backup
filenames, alert bodies. Anything hidden in that text is trying to steer it. A
method-and-path tool behind a blocklist hands that text every admin route nobody
thought to block; a closed set of named operations inverts the default, so
anything not deliberately added is unreachable. Every operation in the catalog
was reviewed on its own, and every one still ends at a human clicking Confirm.

### Guided flows (drive a multi-step operation)
The assistant can drive a full multi-step operation end to end — the flagship is
the **parallel-run migration** (Cloud 2 / Serverless → Cloud 3):
`configure → adopt → tee → migrate → cutover`. It reads the live status to know
what's next and proposes one step at a time. **Every step is a confirm card**;
on Confirm, ISR runs the real step through exactly the same validation as
clicking the button on the page — including the **server-enforced cutover gate**,
which refuses cutover until every readiness check passes. The assistant cannot
route around the gate.

## What she reads

With a model configured, Laura reads **eighteen** topics from the live ISR:
cluster health, expensive queries, cost calibration, open alerts, migration
status, replication jobs, routing decisions, resource metrics, mirror
reconciliation, IoT devices, certificate expiry, HA status, fleet spokes, node
pools, her own proposals, backup history, write-queue depth and recent audit
activity. A question outside these falls through to the scenario planner.

Laura's read topics and the `/mcp` tool catalog are the **same table** — an MCP
client sees exactly the read tools she has, and a change to one reaches both.

Each read is a few milliseconds; the time an answer takes is the model's own
turns deciding which tools to call and then writing. Adding topics does not make
her slower.

### She names what she is reading

A phase line appears per tool as it is dispatched — *"reading
cluster_health…"* — so the wait while the model decides which tools to call
shows named work rather than silence, and the name is honest: it is the topic
she is actually reading.

## Roles

- **Viewer** — can ask questions (read-only); changing anything needs operator
  access.
- **Operator / admin** — can propose actions and flow steps, and confirm them.

## Configuration

Open the settings gear in the assistant panel (admin only):

| Setting | Meaning |
|---|---|
| Provider | `Anthropic` (default) or `OpenAI-compatible`. |
| Model | The model id (e.g. `claude-haiku-4-5`, or an OpenAI/local model). |
| API base URL | Defaults per provider; point it at Azure OpenAI or a local OpenAI-compatible server (vLLM, Ollama, LiteLLM). **Validated on save** — a pasted `curl …`/quotes are stripped and a non-URL is rejected. |
| Test connection | Pings the server **from the ISR container** and checks the configured model exists — catches a bad URL or an unpulled/misspelled model at save time. |
| Request timeout | Per-request model timeout in seconds (default `120`). Raise it for a slow local model. |
| API key | Write-only — the API never returns it. Blank keeps the current key. |
| Allowed tools | Optional, comma-separated. Restricts the catalog the model may use; blank = all. |

The assistant is model-agnostic: with `OpenAI-compatible` selected, ISR speaks the
OpenAI wire format (Bearer auth, function tools) so it works with OpenAI, Azure
OpenAI, or a self-hosted OpenAI-compatible endpoint. The customer chooses the
model, and therefore the data path; with no key configured, the planner is the
brain and no data leaves ISR.

### Running a local model (Ollama)

ISR runs in a **container**, so a model on your host is reached at
`http://host.docker.internal:11434/v1` — **not** `localhost` (which, from inside the
container, is the container itself). The Ollama quick-setup preset fills this in.
Pull a **tool-capable** model (`llama3.1`, `qwen2.5`, `gpt-oss`, `mistral-nemo`),
click **Test connection**, then Save. On Linux the container needs
`--add-host=host.docker.internal:host-gateway` and Ollama should listen on
`0.0.0.0`, or run Ollama on ISR's Docker network and use `http://ollama:11434/v1`.

### No silent failures

If a model is configured but a call fails, the chat shows the **actual error** (and
that it fell back to the built-in planner) instead of letting a scripted reply pose
as the model. The transcript lives only in your browser — never stored server-side —
and is cleared on sign-out, with a **Clear** button in the panel for on-demand reset.

## Safety model

- Reads run and are **redacted** (tokens/secrets stripped) before they reach the model.
- Writes and flow steps **stage a confirmation card**; a human confirms.
- The server enforces its own gates (e.g. the cutover gate) regardless of what
  the model proposes.
- Tool results are treated as data, not instructions — prompt-injection in a log
  line or alert can't make the assistant act, because a human still clicks Confirm.
- Every confirmed action is audited, attributed "via assistant".
