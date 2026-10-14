# Schema registry: declared data contracts

The schema registry (Data & Schema → Schema Registry, `/api/isr/config/schema-registry`)
holds an operator-declared contract per database and table. ISR checks every
write against it before the write reaches a node, on the hub and, after
`…/propagate`, on every spoke. This page says what a contract declares, what it
does not, and how to change one safely.

## What a contract declares

```json
{
  "schemas": {
    "telemetry": {
      "public": {
        "fields": { "value": "integer", "note": "string" },
        "required_tags": ["region"],
        "allowed_tags": ["region", "host"]
      }
    }
  }
}
```

| Key | Meaning |
| :-- | :-- |
| `fields` | field name → type. A write whose value for a declared field is another type is refused. |
| `required_tags` | tag keys every point must carry. A point without one is refused. |
| `allowed_tags` | when non-empty, the only tag keys a point may carry, in addition to the required ones. |

Accepted field types are the five line protocol can express: `boolean`,
`float`, `integer`, `string`, `uinteger`. A contract that declares any other
word is refused on save with the declaration named, so a mistake is found in
the editor rather than one write at a time.

## The boundaries, stated plainly

- **Declared fields are the checked fields.** A field the contract does not
  name is accepted with whatever type it arrives in. List every field you
  want governed.
- **Required tags are allowed tags.** A key in `required_tags` need not be
  repeated in `allowed_tags`; it is always permitted.
- **Only tables in the registry are governed.** A write to a table without a
  contract passes untouched.
- **A contract governs writes, not existing data.** Changing a field's declared
  type refuses writes of the old type from then on; it does not convert the
  column InfluxDB already holds. Pick the type the table was created with, or
  introduce the new type on a new field.
- **Mixed batches are refused whole.** A write body with one violating point
  is refused and none of its points is stored, so a producer sees the
  violation at once.

## Changing a contract

Every save increments the registry version and records who saved it. Save
from the console or with `PUT /api/isr/config/schema-registry` carrying the
whole `schemas` object; the hub then pushes the new version to every spoke
with `POST /api/isr/config/schema-registry/propagate`.

A good order for a change producers will feel:

1. Add the new field or tag to the contract first, so the new producer is
   accepted.
2. Ship the producer.
3. Tighten the contract (make the tag required, drop the old field) once the
   old producer is gone.

A refused write answers `422` with the table, column and reason:

```text
schema contract public.value: expected integer, got float
schema contract public: missing required tag 'region'
schema contract public: tag 'rack' is not in the allowed set
```

See also: the [README's schema registry section](../README.md#fleet-wide-schema-registry-apiisrconfigschema-registry)
and the console's **Docs → Data & Schema**.
