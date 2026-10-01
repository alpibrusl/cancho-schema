# lexsys-schema: a schema as data

> **Status: slices 1 and 2 built** (builder, validator, pointers, `problem+json`,
> JSON Schema generation); assembling the OpenAPI document is `lexsys-web`'s. §9 records what building it found, and
> corrects the sections it contradicted. Where a claim rests on something
> measured it says what and where; where it does not, it says so.

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
| integer | `minimum`, `maximum`; a whole number written as a float (`150.0`, `1.5e2`) is an integer, as in JSON Schema (§11); a value outside `int`'s range is an error, not a wrap (`json.fits_int`) |
| number | `minimum`, `maximum` |
| string | `min_length`, `max_length` in **code points** (`std.utf8`), `enum` of strings |
| array | `min_items`, `max_items`, one item schema |

**Decided, so it is not rediscovered:**

* **No coercion.** `"3"` is not an integer. A framework that silently converts
  is deciding what the client meant. (`150.0` *is* an integer -- see §11, which
  corrects this section: it said it was not.)
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
2. **Code points or bytes** for string length. *Answered for v1 in §9: bytes.*
3. **Recursion.** Deferred, but the node layout should not make it impossible.

## 9. What building slice 1 found

**Answered open question 2: string length is in bytes of the decoded text.**
Counting code points of an escaped string needs somewhere to decode it into, and
`validate` is deliberately heapless (`lex-sys authority` on a program that
validates reports `heap` from the caller's own allocations and nothing else). A
plain string could be counted with `utf8.count` for free; one with escapes
cannot, and two rules for one field would be worse than one. For ASCII the two
agree. The differential test keeps length-bounded strings ASCII for that reason,
and the divergence from JSON Schema's `maxLength` (code points) is real and
documented here, not hidden.

**§3 said number bounds were in v1; they are not.** `bits_of` reads a float's
bits but the language has no inverse, so a `Vec[int]` arena cannot hold a float
bound and read it back. `new_number` takes no bounds. This waits on either the
inverse builtin or a second arena of floats.

**The pointer for a missing required field was not escaped -- and the hand-written
test blessed it.** `required` pointers appended the field's name raw, so a field
named `c~d` produced `/c~d` where RFC 6901 says `/c~0d`. The unit test had the
same wrong expectation, written from the implementation instead of the RFC. The
differential test, whose reference is an independent library, caught it on its
second seed; both are fixed, and the unit test now says `/c~0d`.

**Decided where the reference and the design differed, so it is not rediscovered:**

* **`nullable` wins over `choice`.** A nullable string with a set of allowed
  values accepts `null` (FastAPI's `Optional[Literal[...]]` does). JSON Schema's
  `enum` applies to every type, so the *generator in slice 2 must add `null` to
  the `enum`*; the differential test's reference already does.
* **A value of the wrong type is one error.** JSON Schema reports `type` and
  `enum` both for `true` against an enum of strings; `schema` reports `type` and
  stops. The reference drops the `enum` error at a path that already has a `type`
  one.
* **An integer outside `int` is `range`, not `type`**, and its bounds are not
  consulted. `1.0` is `type`.
* **Fields under an array leave their slots unset** (§3's slot table): an object
  in an array has many values for one field. Tested.

**Measured.** 13 unit tests; the differential test on 18 seeds of 250 cases each
agrees; five deliberate off-by-ones (`max`, `min`, `~` escaping, `max_length`,
`min_items`) each fail it on every one of four seeds, and the unknown-key check
disabled fails 26 of 250. A first version of the generator let `max` and `~`
survive (it rarely produced a value exactly at a bound, or an error under a key
with a `~`); biasing it to the ends of ranges is what made it catch them.

## 10. What building slice 2 found

`json_schema(heap, schema, node)` writes JSON Schema 2020-12, compact and in the
order things were added (properties, `required`, `enum` members), so the same
schema is the same bytes on every run.

**The check §6 promised, and what it turned up.** The differential test now has
the library *generate* each schema, then (a) requires it to equal the schema the
test generator meant, and (b) validates every document with the reference
library against *the generated schema* and requires the same errors the
library's own validator reported. Six deliberate breakages of the generator
(drop `null` from a nullable `enum`, drop `additionalProperties`, invert
`maximum`, invert `required`, off-by-one `minLength`, and the others in the
README's list) each fail it; and 24 seeds of 250 cases agree.

**One disclosed difference that cannot be removed.** `minLength`/`maxLength` in
JSON Schema count code points; this validator counts bytes (§9). A schema that
only said `maxLength: 8` would promise clients something the server does not do
for non-ASCII text, so a string with a length bound also carries
`"x-length-unit": "bytes"`. JSON Schema validators ignore unknown keywords, so it
costs nothing, and the divergence is stated in the document the client reads
rather than only here. Closing it needs code points (§8.2), which needs a heap.

**A nullable choice lists `null` in its `enum`** (§9's note to this slice, done):
`{"type":["string","null"],"enum":["red","green",null]}`.

**Not done.** `$ref`/`$defs`: a schema node used twice is written twice. That is
correct but not compact, and it is the first thing a large API will want;
recursion (§8.3) needs it and is still deferred. The OpenAPI document itself --
paths, parameters, responses -- is assembled by `lexsys-web` from its route
table and these fragments.

## 11. What running a real service against it found

`lexsys-web` has `examples/users`: a service that validates with `schema`, answers
with `problem+json`, and serves an OpenAPI document that embeds `json_schema` of
the same nodes. Its end-to-end test generates requests *from that document* with
Schemathesis. The first run found one defect in this repository that nothing here
had caught.

**`150.0` is an integer, and the validator said it was not.** §3 and slice 1
decided "`1.0` is not an integer" -- no coercion. But `json_schema` writes
`"type":"integer"`, and in JSON Schema that accepts `150.0`: so the document
promised clients something the server refused, and Schemathesis, whose generator
follows the standard, sent `"age": 150.0` and was refused. Python's `json.dumps(150.0)` is
`150.0`, so a Python client does this by accident every day.

Two things made it possible, and both are worth recording:

* The differential test did not catch it **because it had been bent to agree**:
  the reference's `integer` type was redefined to reject floats, to match the
  decision. A reference that has been adjusted to a decision cannot disagree with
  it. The decision was wrong, and only a tool with its own opinion of what the
  *generated document* means -- Schemathesis, reading the schema as the standard
  does -- could say so.
* The unit test pinned the decision, so it passed.

**The fix.** `integral` accepts a number that is a whole value however it is
spelled (`150`, `150.0`, `1.5e2`); a fraction is `type`; a whole value beyond
`int` is `range`; bounds are checked on the value. Reading it back is a new
public function, `schema.to_int(body, tape, node)`, because the obvious
`json.to_int` answers 0 for a float node -- the example called it and would have
stored `"age": 0` for a request that said `150.0`, silently. The differential
test's reference is no longer bent on this point (it only adds the int64 bound),
and it generates float-spelled integers; disabling float acceptance now fails it
on every seed.

**Also found, in `lexsys-web`'s example rather than here** (recorded there): an
unknown query parameter had to be refused for the same reason unknown body fields
are, and the document had to state the integer maximum the server enforces.
