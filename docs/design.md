# cancho-schema: a schema as data

> **Status: slices 1 and 2 built** (builder, validator, pointers, `problem+json`,
> JSON Schema generation); assembling the OpenAPI document is `cancho-web`'s. §9 records what building it found, and
> corrects the sections it contradicted. Where a claim rests on something
> measured it says what and where; where it does not, it says so.

## 1. What it is for

`cancho` has the pieces of a request path: `std.http` parses, `std.route`
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
`cancho` has no reflection, no macros and no traits, so there is nothing to
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
  (`std/json.cho`, the comment on `get`). The validator and the reader must agree
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

The standard this repository inherits from `cancho`:

* **Differential, against an independent implementation.** A corpus of
  (schema, body) pairs, validated here and by a reference validator in another
  language, compared by *verdict and error set*. `std.json`'s float parsing was
  tested this way and it found real bugs.
* **Mutation checks.** A test that survives a deliberate break of the rule it
  names is not testing it.
* **Hostile input.** Deep nesting, a million-element array, a body of one
  hundred thousand unknown keys, a string of invalid UTF-8: none may reach a
  panic or allocate more than the limits say. `cancho` requires that no input
  reach a trap it did not declare.
* **The generated schema validates what the validator accepts**: bodies the
  validator accepts must be accepted by a stock JSON Schema validator given
  `to_json_schema`'s output, and the reverse. That is the check that the two
  halves of "one declaration" are really one.

## 7. Packaging

A `cancho` package (`docs/package-system.md` in that repo): `src/schema.cho`
published into a `.cancho-vcs` store with `vcs publish --std`, consumed by
`vcs lock` + `vcs fetch` + `build --std`. It needs the compiler's bundled `std`
and **nothing pins which `std`**: a store records no hash of the library it was
published against (`package-system.md` §4.8). This repository will record the
`cancho` version it is tested against in CI, because the toolchain will not.

## 8. Open questions

1. **Where the builder's ergonomics land.** Threading a linear `Schema` through
   every call is the idiom, but a schema of thirty fields is thirty
   `let (s, _) = ...`. Whether a table-driven builder (one call taking a
   declarative `[int]` description) is better is a question for the first
   slice, decided by writing both for the `/add` and `/users` examples.
2. **Code points or bytes** for string length. *Answered for v1 in §9: bytes.*
3. **Recursion.** Deferred, but the node layout should not make it impossible.

## 9. What building slice 1 found

**Open question 2, string length: first answered "bytes", then corrected (§12).**
Slice 1 counted the bytes of the decoded text, reasoning that counting code points
of an escaped string needs somewhere to decode it and the validator has no heap.
That reasoning was wrong -- the source text can be counted without decoding it --
and the answer was wrong for clients: JSON Schema's `maxLength` counts code points,
so a 16-character tag of Japanese was refused as 48 bytes. §12 has the fix; the
text that stood here said bytes and said the divergence was disclosed. It was
disclosed in a keyword no client reads.

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

**(Corrected in §12.)** This section first said one difference could not be
removed: string length in bytes, disclosed by an `x-length-unit` keyword. It could
be removed, the keyword is gone, and the generated schema is plain JSON Schema.

**A nullable choice lists `null` in its `enum`** (§9's note to this slice, done):
`{"type":["string","null"],"enum":["red","green",null]}`.

**Not done.** `$ref`/`$defs`: a schema node used twice is written twice. That is
correct but not compact, and it is the first thing a large API will want;
recursion (§8.3) needs it and is still deferred. The OpenAPI document itself --
paths, parameters, responses -- is assembled by `cancho-web` from its route
table and these fragments.

## 11. What running a real service against it found

`cancho-web` has `examples/users`: a service that validates with `schema`, answers
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

**Also found, in `cancho-web`'s example rather than here** (recorded there): an
unknown query parameter had to be refused for the same reason unknown body fields
are, and the document had to state the integer maximum the server enforces.

## 12. A second defect from the same service: string length

The same Schemathesis run, once `150.0` was fixed, sent `"tags": ["日本語…"]`
(sixteen characters, forty-eight bytes) against a `maxLength: 16` and was refused.

The slice-1 reasoning for counting bytes (§9, now corrected) was that counting
code points of an *escaped* string needs somewhere to decode it. It does not:
`std.json` has already checked the source is well-formed UTF-8 with no lone
surrogate, so a code point can be counted straight off the text between the
quotes -- a byte that is not a continuation byte starts one, a short escape
(`\n`) is one, `\uXXXX` is one, and a surrogate pair (`\ud83d\ude00`, twelve
characters) is one. `code_points` does that, allocates nothing, and the
validator stays heapless.

The differential test had a rule that **kept length-bounded strings ASCII**, so
that bytes and code points agreed. That rule is how the divergence stayed
invisible; it is gone, and the generator's alphabet now has one-, two- and
three-byte characters and astral ones (an escaped pair half the time). Three
deliberate breakages of the counter (a pair counted twice, bytes counted instead
of code points, an escape not counted) each fail the unit and differential tests.

**The pattern, twice now (§11, §12):** a decision recorded as "disclosed" is not
a decision a client can see, and a test restricted to the inputs where two
semantics agree cannot find the day they stop agreeing.

## 13. A constraint the store imposes belongs in the schema (U+0000)

Found by Schemathesis against `cancho-web`'s users service on PostgreSQL (`cancho-pg`): the body
`{"name":"\u0000"}` satisfies the schema -- a JSON string may hold U+0000, and `"type":"string"` accepts it
-- and PostgreSQL `text` cannot store it. The first answer was a 503; correcting it to a 422 is wrong too,
because the OpenAPI document says that body is valid, and a request the contract accepts and the service then
refuses is the same defect as the `150.0` of §11 from the other side. So the refusal is *in* the schema, where
the document is generated from: `forbid_nul(s, node)` makes a string node refuse the escape `\u0000`
(error `nul`, "must not contain U+0000"), and the JSON Schema for that node carries
`"pattern":"^[^\\u0000]*$"`, which is what Schemathesis, `jsonschema` and a client generator all read.

* **Only the escape.** A raw U+0000 byte is not valid inside a JSON string, so `std.json` has refused it before
  the schema looks; the escape is the one spelling. The scan walks escapes the way `code_points` does, so
  `\\u0000` (an escaped backslash, then the characters `u0000`) is not a NUL, and `\u00000` is a NUL and a zero.
* **Per node, not global.** A tag in a `json` column may hold it (PostgreSQL's `json` stores the text; `jsonb`
  would not), so the node that does not need the rule does not carry it.
* **Checked** by the unit tests (the cases above, other escapes, a surrogate pair, a node that did not ask,
  length and `nul` reported together, and the document), and by the differential test, which now gives a
  random fifth of string nodes the flag and puts a U+0000 into a fifth of generated strings; the reference
  is `jsonschema` with a `pattern`. Four mutations (the scan always false, the flag not consulted, the pattern
  not written, an escape skipped one byte too short) each fail a suite; the last only the unit test, because
  the differential alphabet has no backslash.

## 14. Text that is not JSON (`check_text`)

`cancho-web` designs validating a request's path, query and header parameters before the handler
runs (its `docs/design.md` §9). Those arrive as text, with no tape, and the node that documents
a parameter -- the same node, so the contract cannot say one thing and the server another -- has
to judge it. The first slice of that is here: `check_text(s, node, text)`, with `int_of_text` and
`bool_of_text` to read a value after it said 0.

**Decided.**

* **The same codes, the same bounds, the same order of kinds as `check`.** A parameter that
  breaks a rule gets the code a body would: `type`, `range`, `minimum`, `maximum`, `min_length`,
  `max_length`, `choice`, `nul`. A client that switches on codes handles both.
* **One error per text, the first.** A body can have many errors because it has many values; one
  text has one value, and "too short" together with "not a choice" adds a sentence, not
  information. The order is the order `check` tests them in. (`cancho-web` collects an error per
  *parameter*, which is the useful axis.)
* **No coercion.** An integer is an optional `-` and one or more ASCII digits and nothing else:
  `+5`, `5.0`, `1e2`, `0x5`, ` 5` and the empty text are `type`. This is *not* §11's rule for
  bodies, and the difference is deliberate: `150.0` is JSON Schema's integer because JSON has one
  number syntax and a client that serializes a float sends it; a query string has no float to
  serialize. Leading zeros are digits (the hand-written parser in `cancho-web`'s example accepted
  them; changing which requests are valid is a contract change and belongs in its own slice).
* **`range`, not a 17-digit cap.** `cancho-web`'s sketch carried over the 17-digit limit of its
  hand-written `number_of`. A cap the node does not state is the defect §11 and `cancho-web`
  §7 describe -- true of the server, false of the contract -- so the limit here is `int`'s own: a
  magnitude past `int_max()` is `range`, and a node that wants a tighter limit declares one, as the
  users example's `id` already does (`maximum` 99999999999999999). `-9223372036854775808` is
  `range`: the one value a magnitude built as a non-negative number cannot hold, and not worth a
  second code path.
* **UTF-8 is checked.** `std.json` has already refused malformed text before `check` counts code
  points; a header or a decoded path segment has been checked by no one, and `check_text` counts
  code points the same way (§12), so it must not count a malformed sequence. Malformed is `type`:
  shortest forms only, no surrogate (U+D800..U+DFFF), nothing past U+10FFFF.
* **The text is decoded.** Percent-decoding needs a destination buffer and a validator that
  allocates would not be this one, so a caller with an encoded value decodes it first. A header
  needs none.
* **A node that is not a parameter refuses.** `number`, `array` and `object` nodes judge every
  text `type`, so a declaration made by mistake cannot become a validator that accepts anything;
  `any` accepts everything. Nullability is not consulted: text has no `null`.

**Checked** by 8 unit tests: the integer grammar (including each of the non-integers above); the
edges of `int` (`9223372036854775807` is a value, `...808` and thirty nines are `range`, a non-digit
after a value that no longer fits is still `type`, and 36 leading zeros are a 7); bool; code points
(2-byte and 4-byte) and `add_choice`; well-formed UTF-8 against 24 byte sequences (the ends of each
range, a lone continuation, a truncated lead, overlong two-, three- and four-byte forms, a surrogate
both ends, past U+10FFFF, `0xFE` and `0xFF`); `forbid_nul` on a real zero byte; the order of errors;
and the kinds that are not parameters. Five mutations (the overflow guard off by one, the surrogate
range's edge, the four-byte overlong limit, `forbid_nul` ignored, `0xC0` and `0xC1` accepted as
leads) each fail a test. **Not extended:** `tests/differential.py`. It compares the validator with
`jsonschema` on JSON documents; text has no reference implementation there, and the rule that
matters (an integer is digits) would be tested against the same rule written again in Python.
The existing differential run (seeds 1-2, 250 cases each) and both examples' output are unchanged.
