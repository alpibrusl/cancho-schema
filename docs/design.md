# lexsys-schema: a schema as data

> **Status: design.** Nothing in this document is built. Where a claim rests on
> something measured it says what and where; where it does not, it says so.

## 1. What it is for

`lex-sys` has the pieces of a request path: `std.http` parses, `std.route`
picks a handler, `std.json` reads and writes. What an API needs next, and what
`examples/api` does by hand in `add`, is *checking the body*: is `a` present,
is it an integer, did it fit, what do we say when it is not. Written by hand
that is forty lines per endpoint, the first error wins, and the documentation
is a separate artefact that drifts.

The aim is one declaration of a body's shape, from which three things follow
and cannot disagree: validation, the error response, and the OpenAPI document.
It is the principle `lex-os` states for its grant -- *one declaration, several
enforcement points* -- applied to a request body.

## 2. Why data, not types

Python's answer (pydantic) is a class whose annotations are read by a library.
`lex-sys` has no reflection, no macros and no traits, so there is nothing to
read an annotation. It has the opposite property: a value built once and walked
many times is the idiom the library already uses (`route.Router`, `std.map`).
So a schema is a **value** -- an arena of nodes in a `Vec[int]` plus a byte pool
for names and messages -- built at start-up:

```
var s = schema.empty(heap);
let (s1, user) = schema.object(heap, s);
let (s2, _) = schema.field(heap, s1, user, "name",  schema.string(1, 64), required);
let (s3, _) = schema.field(heap, s2, user, "age",   schema.int(0, 150),   optional);
```

(Shape indicative; the real signatures follow `std.route`'s conventions and are
settled in the first slice.) A schema is `res`, ended with `drop`, threaded
through the builder like a `Buffer` is. Because it is data it can also be
**hashed**: the canonical JSON Schema it generates (§5) is deterministic, so a
schema has an identity in the sense `docs/canonical-ast.md` gives a function.

## 3. Validation

`validate(schema, root, body, tape, slots, errors)` walks the schema and the
`std.json` tape together and fills two caller-provided slices, the way
`http.parse` fills its table:

* **`slots`**: for each field of the schema, in declaration order, the tape node
  of the value found (or `-1`). After a successful validation the application
  reads values through them without searching again --
  `json.to_int(body, tape, slots[AGE])` -- and cannot meet a missing or
  mistyped one, because validation said so. There is no generated struct; the
  slot table is the typed view.
* **`errors`**: every error found, not the first. Each is a few ints: which
  schema node, which tape node, which code. Beyond a limit (default 32) they are
  counted, not stored, so a hostile body cannot make the error list large.

**v1 vocabulary** (each is cheap with a tape and a pool; none needs a library
that does not exist):

| | |
|---|---|
| types | object, array, string, integer, number, boolean, null (as `nullable`), any |
| object | per-field `required`; unknown fields `reject` or `ignore` (default `reject`) |
| integer | `minimum`, `maximum`; a value outside `int`'s range is an error, not a wrap (`json.fits_int`) |
| number | `minimum`, `maximum` |
| string | `min_length`, `max_length` in **code points** (`std.utf8`), `enum` of strings |
| array | `min_items`, `max_items`, one item schema |

**Decided, so it is not rediscovered:**

* **No coercion.** `"3"` is not an integer. A framework that silently converts
  is deciding what the client meant.
* **Duplicate keys: the first wins**, because that is what `json.get` does
  (`std/json.ls`, the comment on `get`). The validator and the reader must agree
  on which `age` an object has; if they did not, a body could pass validation on
  one and be read as the other.
* **Strict JSON underneath** (`std.json` refuses what RFC 8259 refuses), so
  "valid" never means "valid after a lenient parse".

**Not in v1, and why:** `pattern` (there is no regex in `std`, and building one
to serve a schema is the wrong order); `oneOf`/`allOf`/`$ref` and recursion (a
schema that refers to itself needs ids and a cycle check -- real work with no
asker yet); `format` (`email`, `date-time`: each is a small grammar, added when
an endpoint needs one); `uniqueItems`; defaults.

## 4. Errors

RFC 9457 `application/problem+json`:

```json
{"type":"about:blank","title":"Unprocessable Content","status":422,
 "errors":[{"pointer":"/age","code":"maximum","detail":"must be at most 150"},
           {"pointer":"/name","code":"required","detail":"is required"}]}
```

`pointer` is an RFC 6901 JSON pointer, built from the tape path on demand (an
error stores node indices, not strings, so recording one allocates nothing).
Messages are fixed text selected by `code`; the body's own bytes are never
echoed into an error without going through `json.put_string`'s escaping.

## 5. OpenAPI and JSON Schema

`to_json_schema(heap, schema, root) -> Buffer` writes the JSON Schema (2020-12,
the dialect OpenAPI 3.1 uses) for a node. Field order is declaration order and
nothing is hashed or sorted by address, so the output is deterministic:
the same schema yields the same bytes on every run, which is what lets it be
hashed, diffed and checked in.

The web layer assembles the whole OpenAPI document from its route table and
these fragments; this crate is responsible only for the schema half.

## 6. How it will be tested

The standard this repository inherits from `lex-sys`:

* **Differential, against an independent implementation.** A corpus of
  (schema, body) pairs, validated here and by a reference validator in another
  language, compared by *verdict and error set*. `std.json`'s float parsing was
  tested this way and it found real bugs.
* **Mutation checks.** A test that survives a deliberate break of the rule it
  names is not testing it.
* **Hostile input.** Deep nesting, a million-element array, a body of one
  hundred thousand unknown keys, a string of invalid UTF-8: none may reach a
  panic or allocate more than the limits say. `lex-sys` requires that no input
  reach a trap it did not declare.
* **The generated schema validates what the validator accepts**: bodies the
  validator accepts must be accepted by a stock JSON Schema validator given
  `to_json_schema`'s output, and the reverse. That is the check that the two
  halves of "one declaration" are really one.

## 7. Packaging

A `lex-sys` package (`docs/package-system.md` in that repo): `src/schema.ls`
published into a `.lex-sys-vcs` store with `vcs publish --std`, consumed by
`vcs lock` + `vcs fetch` + `build --std`. It needs the compiler's bundled `std`
and **nothing pins which `std`**: a store records no hash of the library it was
published against (`package-system.md` §4.8). This repository will record the
`lex-sys` version it is tested against in CI, because the toolchain will not.

## 8. Open questions

1. **Where the builder's ergonomics land.** Threading a linear `Schema` through
   every call is the idiom, but a schema of thirty fields is thirty
   `let (s, _) = ...`. Whether a table-driven builder (one call taking a
   declarative `[int]` description) is better is a question for the first
   slice, decided by writing both for the `/add` and `/users` examples.
2. **Code points or bytes** for string length. Code points are what a client
   means; they cost a UTF-8 walk per checked string. The cost is to be measured,
   not assumed.
3. **Recursion.** Deferred, but the node layout should not make it impossible.
