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
  column InfluxDB already holds. Declare the type a table was created with, or
  introduce the new type on a new field (see *Changing a contract* below).
- **Mixed batches are refused whole.** A write body with one violating point
  is refused and none of its points is stored, so a producer sees the
  violation at once.

## Changing a contract

Schema changes are an ordinary part of running the registry. Every save
increments the registry version, records who saved it, and takes effect on the
next write: a producer that no longer conforms is refused immediately, and one
that conforms to the new definition is accepted immediately. Save from the
console (Data & Schema → Schema Registry) or with
`PUT /api/isr/config/schema-registry` carrying the whole `schemas` object; the
hub then pushes the new version to every spoke with
`POST /api/isr/config/schema-registry/propagate`.

In the console, a contract is changed by entering the same database and table
again with the new definition. **Add contract** stages it in place of the old
row and **Save registry** applies it; the version shown advances. The ✕ on a row
removes that table's contract on the next save.

A good order for each kind of change:

| Change | Order |
| :-- | :-- |
| Add a field or a tag | Declare it in the contract and save, then ship the producer that sends it. The field is checked for type from its first write. |
| Make a tag required, or narrow the allowed tags | Ship the producer that sends the tag first, then tighten the contract. Tightening first refuses every point from the old producer at once. |
| Change a field's type | Declare the new type on a **new field name**, ship the producer, then drop the old field from the contract. InfluxDB keeps the type a column was created with, so a write of the new type to the old name is refused whether or not the contract says so. |
| Remove a table's contract | Remove the row and save. Writes to the table pass unchecked from then on; its data is untouched. |

A save that declares an unsupported type is refused with the declaration named
and the version does not advance, so a typo cannot reach producers.

## The data-type policy beside the registry

The registry is the declared side. ISR also keeps an **observed** schema per
database: the type each field has been seen with, the type expected, and the
writes refused. The Schema page (Data & Schema → Schema) shows it and sets the
per-database **mode** that decides what happens when a write disagrees with
the expected type:

| Mode | A write whose field type differs |
| :-- | :-- |
| `coerce_if_safe` (default) | is rewritten when the conversion is exact (`12.0` into an integer field becomes `12`, an integer into a float field becomes a float) and refused as unsafe otherwise (`12.5` into an integer field) |
| `strict` | is refused |
| `audit_only` | passes and is recorded as a mismatch for review |
| `learning`, `learn_no_store` | the expected type is learned from what arrives; `learn_no_store` acknowledges writes without storing them |

The expected type is learned from the first write of a field and can be set by
hand on the Schema page or with `PUT /api/isr/schema/expected`. Setting it to
the type a column should have is how a stray producer is caught before its
values land. Mismatches collect as **amendments**, which an operator approves,
declines, or resolves by renaming the offending field for future writes.

The two mechanisms stack: the data-type policy runs first, then the contract.
A refusal names which one spoke:

```text
unsafe schema coercion: sensor.value float->integer      (data-type policy)
schema contract sensor.value: expected float, got integer (registry contract)
```

A refused write answers `422` with the table, column and reason:

```text
schema contract public.value: expected integer, got float
schema contract public: missing required tag 'region'
schema contract public: tag 'rack' is not in the allowed set
```

See also: the [README's schema registry section](../README.md#fleet-wide-schema-registry-apiisrconfigschema-registry)
and the console's **Docs → Data & Schema**.
