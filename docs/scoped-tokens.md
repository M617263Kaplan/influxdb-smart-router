# Scoped tokens and the Enforce on queries switch

An ISR token (`isrt_…`) is what your applications, dashboards and devices hold.
ISR validates it, applies its scope, and speaks to the cluster with a credential
of its own. This page is the how-to for the scope itself: what each dimension
restricts, when the fine-grained lists are applied to queries, and what a client
sees when a request falls outside them.

## The dimensions

| Dimension | Field in the API | Applies to |
| :-- | :-- | :-- |
| Databases | `databases` | every request, every protocol |
| Actions | `actions` (`read`, `write`, `read,write`, `all`) | every request |
| Query protocols | `query_protocols` (`http`, `flightsql`, `all`) | queries |
| Tables | `allowed_tables` | writes always; queries with the switch on |
| Fields | `allowed_fields` | writes always; queries with the switch on |
| Tags | `allowed_tags` | writes always; queries with the switch on |

Every list is an allow-list of names. An empty list leaves that dimension
unrestricted: a token with no `allowed_tables` may use every table in its
databases.

The database scope is the one to lean on for separation that has to hold. One
database per tenant, one token per tenant, and nothing a client sends can reach
another tenant's rows on any path.

## Enforce on queries

The switch is `query_scope_enabled` in the API and **Enforce on queries** in the
token editor (Auth → Tokens). It is off on a new token.

- **Off** — the token's table, field and tag lists govern its writes. Its
  queries are governed by the database, action and protocol scope only.
- **On** — ISR also reads every query the token sends and checks the tables,
  fields and tags the statement reaches against the lists, before the query is
  routed and before the query cache is consulted.

Turn it on when a token should read less than its database holds: a Grafana
data source that may see one measurement, a partner that may read one field, a
device that may read its own tags and nothing else.

### What is checked, on which path

| Path | Language | Checked |
| :-- | :-- | :-- |
| `POST /api/v3/query_sql` | SQL | yes |
| Flight SQL (Arrow Flight, ADBC, JDBC, Grafana's Flight SQL source) | SQL | yes |
| `POST /api/v3/query_influxql`, `GET /query` | InfluxQL | yes |
| `POST /api/v2/query` | Flux | ISR cannot read Flux; a token with a table, field or tag list is refused here |

The whole statement is read: the projection, predicates, grouping, ordering,
`HAVING`, window definitions, join conditions, subqueries and common table
expressions. A name that appears anywhere in the statement is checked. A
statement ISR cannot read, or one that is not a `SELECT` (`SHOW`, `EXPLAIN`),
is refused when the token carries any of the three lists.

Name the columns you read. A wildcard projection (`SELECT *`, `t.*`, an
aggregate over `*` other than `count(*)`) is not something a field or tag list
can approve, because the engine decides what it expands to. `count(*)` is
fine: it reads no column.

### Fields and tags are different lists

When a token carries only one of the two lists, ISR asks the cluster's
catalogue which kind each referenced column is, so a field-only token can
still filter on tags and a tag-only token can still read fields. When it
carries both, a column is allowed when either list names it. A column ISR
cannot place — not in either list and not in the table's schema — is refused;
if the column was written a moment ago, ISR reads the schema again before it
refuses.

### What the client sees

A refusal is `403 Forbidden` on HTTP with the reason in the body, and
`PERMISSION_DENIED` on Flight SQL with the same reason in the status message.
The reason names the table, field or tag that was refused:

```text
field secret is not allowed
tag host is not allowed
table private is not allowed
a wildcard projection is not allowed under a field or tag scope: name the columns
```

A token ISR does not recognise, or one that has been revoked, is `401` on HTTP
and `UNAUTHENTICATED` on Flight.

## Changing a token

Edits take effect on the next request. Narrowing a list, turning the switch
on, changing the actions or revoking the token all apply immediately, including
to a query whose answer is already in ISR's query cache: scope is judged before
the cache is consulted, so a narrowed token does not keep reading its earlier
answer.

Revoking a token also revokes the upstream credential ISR minted for it on the
cluster, so the token is dead on both sides of ISR.

## Minting one from the API

```bash
curl -s -X POST http://<isr-host>:9800/api/isr/auth/tokens \
  -H "X-ISR-Admin-Session: $SESSION" -H 'content-type: application/json' \
  -d '{
    "label": "grafana-public",
    "databases": ["telemetry"],
    "actions": "read",
    "query_protocols": "all",
    "allowed_tables": ["public"],
    "allowed_fields": ["value"],
    "query_scope_enabled": true
  }'
```

The response carries the token value once. Afterwards the list shows its
fingerprint, which is what `PATCH` and `DELETE` on `/api/isr/auth/tokens/<fingerprint>`
take.

See also: the [README's tokens section](../README.md#8-tokens-the-part-people-underestimate)
for why ISR tokens replace cluster tokens, and the console's **Docs → Guides →
Authentication**.
