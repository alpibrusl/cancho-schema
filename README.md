# cancho-schema

[![ci](https://github.com/alpibrusl/cancho-schema/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/cancho-schema/actions/workflows/ci.yml)

A schema for [cancho](https://github.com/alpibrusl/cancho), written as **data**: one
value, built when the program starts, that drives

* **validation** of a JSON body (`std.json` tape in, *every* error out, not the first),
* **error bodies** (RFC 9457 `application/problem+json`, with JSON Pointer paths),
* **JSON Schema 2020-12 generation** (what OpenAPI 3.1 embeds),

so that what an API accepts and what its documentation says are the same object and
cannot drift. It is the half of a FastAPI-shaped stack that
[`cancho-web`](https://github.com/alpibrusl/cancho-web) builds on.

No C: it is ordinary cancho over `std.json`, `std.buffer` and `std.vec`, and
`cancho authority` on a program that validates a body reports **`heap` and nothing
else** -- no console, filesystem, network, command line or foreign code (checked, not
assumed).

## Status

Built: the builder, the validator, JSON-pointer error locations, `problem+json` and JSON Schema generation, all in
[`src/schema.cho`](src/schema.cho), tested against an independent validator ([below](#tests)).
[`docs/design.md`](docs/design.md) says what was decided and marks every claim as measured or not; sections 9 to 13 are what
building against real services found.

Not built: see [Limitations](#limitations).

## Requirements

- The **cancho** compiler at the revision this repository's CI builds with (below). A package store records no hash of the `std`
  it was published against, so the compiler revision is part of the contract.
- Rust, to build that compiler (its `rust-toolchain.toml` pins the toolchain).
- To run the differential test: `python3` and `pip install jsonschema`.

## Quick start

**1. Get the compiler**, at the revision CI builds and tests against (it is read from `ci.yml`, so it cannot drift from this text):

```
git clone https://github.com/alpibrusl/cancho
git clone https://github.com/alpibrusl/cancho-schema && cd cancho-schema
REV=$(sed -n 's/^ *CANCHO_REV: *//p' .github/workflows/ci.yml)
(cd ../cancho && git checkout "$REV" && cargo build --release -p cancho)
export PATH=$PWD/../cancho/target/release:$PATH         # now `cancho` works
```

**2. Run the smallest program** -- one schema, two bodies
([`examples/quickstart.cho`](examples/quickstart.cho), 64 lines, 30 of them the `check` helper):

```
$ cancho run --std examples/quickstart.cho src/schema.cho
ok
{"type":"about:blank","title":"Unprocessable Content","status":422,"count":3,"errors":[{"pointer":"/name","code":"required","detail":"is required"},{"pointer":"/age","code":"maximum","detail":"is above the maximum"},{"pointer":"/admin","code":"unknown","detail":"is not a known field"}]}
```

Three problems in one body, each with its JSON Pointer and a code a client can switch on.
The schema that did it is six lines:

```
var s = schema.empty(h);
let (s1, name) = schema.new_string(h, s, 1, 20);          // 1..20 code points
let (s2, age)  = schema.new_int(h, s1, 0, 150);
let (s3, user) = schema.new_object(h, s2, true);          // true: refuse unknown keys
s = schema.add_field(h, s3, user, "name", name, true);    // required
s = schema.add_field(h, s, user, "age", age, false);      // optional
```

**3. Use it in your own project** -- no copy of `schema.cho`: lock the names you call, fetch them
(`fetch` refuses a store that no longer matches the lock), build. Here with the example as the
"app":

```
mkdir ../myapp && cd ../myapp && cp ../cancho-schema/examples/quickstart.cho app.cho
STORE=../cancho-schema/.cancho-vcs
cancho vcs lock  --store $STORE -o schema.lock empty drop new_string new_int new_object add_field \
                                               validate problem slot_count errors_len
cancho vcs fetch --lock schema.lock --store $STORE -o deps/
cancho build --std app.cho deps/*.cho -o app && ./app         # the same two lines of output
```

**4. Take the full tour:** `cancho run --std examples/validate.cho src/schema.cho` adds a string
enum, an array, a nested JSON Pointer, malformed JSON, and prints the schema as JSON Schema
2020-12. Its output is below and CI checks it (`examples/validate.out`).

```
valid        : ok
two problems : {"type":"about:blank","title":"Unprocessable Content","status":422,"count":2,"errors":[{"pointer":"/name","code":"min_length","detail":"is too short"},{"pointer":"/age","code":"maximum","detail":"is above the maximum"}]}
nested path  : {"type":"about:blank","title":"Unprocessable Content","status":422,"count":1,"errors":[{"pointer":"/tags/1","code":"type","detail":"has the wrong type"}]}
unknown key  : {"type":"about:blank","title":"Unprocessable Content","status":422,"count":1,"errors":[{"pointer":"/admin","code":"unknown","detail":"is not a known field"}]}
not JSON     : not JSON

JSON Schema 2020-12:
{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":64},"email":{"type":"string","minLength":3,"maxLength":120},"age":{"type":"integer","minimum":0,"maximum":150},"role":{"type":"string","minLength":1,"maxLength":5,"enum":["admin","user","guest"]},"tags":{"type":"array","items":{"type":"string","minLength":1,"maxLength":16},"maxItems":8}},"required":["name"],"additionalProperties":false}
```

## Examples

Two runnable programs, both checked in CI against their recorded output:

- [`examples/quickstart.cho`](examples/quickstart.cho): one schema, two bodies, every error at once (step 2 above).
- [`examples/validate.cho`](examples/validate.cho): a string enum, an array, a nested JSON Pointer, malformed JSON, and the schema
  printed as JSON Schema 2020-12 (step 4 above, output in [`examples/validate.out`](examples/validate.out)).

## Usage

(`&s` below is shorthand for a borrow of the schema, `borrow s as &sr in { ... }` -- the
example program has the real syntax.)

**1. Declare the shape once**, at start-up. Each constructor takes the schema and returns
it with a new node, and the node's id; fields are added to an object by id:

```
var s = schema.empty(heap);
let (s1, name) = schema.new_string(heap, s, 1, 64);        // 1..64 code points
let (s2, age)  = schema.new_int(heap, s1, 0, 150);
let (s3, user) = schema.new_object(heap, s2, true);        // true: refuse unknown keys
s = schema.add_field(heap, s3, user, "name", name, true);  // required
s = schema.add_field(heap, s, user, "age", age, false);    // optional
```

**2. Validate per request:** parse with `std.json`, then

```
let tape  = box_slice(heap, json.tape_len(body), 0);
let slots = box_slice(heap, schema.slot_count(&s) + 1, 0);
let errs  = box_slice(heap, schema.errors_len(16), 0);     // room for 16 errors
// ... borrow them mutably, then:
json.parse(body, t);                                        // < 0: not JSON at all (a 400)
let n = schema.validate(&s, user, body, t, slots, errs);   // 0: the body has the shape
```

`slots[k]` is then the tape node of the value of the `k`-th field you added (`-1` if the
body omitted it), so a handler reads its inputs without a second lookup
(`schema.to_int(body, t, slots[k])` for an integer).

**3. Answer the errors** -- all of them, with where they are:

```
let problem = schema.problem(heap, &s, body, t, errs, 422, "Unprocessable Content");
// {"type":"about:blank","title":"Unprocessable Content","status":422,"count":2,
//  "errors":[{"pointer":"/name","code":"min_length","detail":"is too short"}, ...]}
```

**4. Document it** from the same value:

```
let doc = schema.json_schema(heap, &s, user);               // JSON Schema 2020-12, deterministic
```

The full program is [`examples/validate.cho`](examples/validate.cho); every call is also
exercised in [`tests/schema_test.cho`](tests/schema_test.cho).

## API

| Build (each returns the schema and the new node's id, except where noted) | |
|---|---|
| `schema.empty(heap)` / `schema.drop(heap, s)` | a new schema / end it (it owns an allocation: a `res`) |
| `new_string(heap, s, min, max)` | a string of `min..=max` **code points** (as JSON Schema counts them, not bytes) |
| `new_int(heap, s, lo, hi)` | an integer; `int_min()` / `int_max()` for no bound |
| `new_number(heap, s)` | any JSON number (no bounds yet) |
| `new_bool(heap, s)` / `new_any(heap, s)` | a boolean / any value |
| `new_array(heap, s, item, min, max)` | `min..=max` elements, each matching node `item` |
| `new_object(heap, s, strict)` | an object; `strict` refuses a key no field names |
| `add_field(heap, s, object, name, node, required)` | a field of an object (returns the schema) |
| `add_choice(heap, s, node, value)` | restrict a string node to a set of values (`enum`; returns the schema) |
| `make_nullable(s, node)` | the node may also be `null` (returns the schema) |
| `forbid_nul(s, node)` | the string node refuses U+0000 (`\u0000`), and its JSON Schema says `"pattern":"^[^\\u0000]*$"` (returns the schema); for a store whose text cannot hold it |

| Validate and report | |
|---|---|
| `validate(&s, root, body, tape, slots, errs)` | number of errors found; fills `slots` (`slot_count(&s)` ints) and `errs` |
| `slot_count(&s)` / `last_slot(&s)` / `node_count(&s)` | sizes |
| `errors_len(n)` | the size of an `errs` slice that holds `n` errors |
| `error_count(errs)` / `errors_stored(errs)` | how many were found / how many fit (the list is bounded; the count is not) |
| `error_code(errs, i)` / `code_name(code)` / `code_message(code)` | the `i`-th error's code, its short name and its sentence |
| `pointer(heap, &s, body, tape, errs, i)` | its RFC 6901 JSON Pointer (`/tags/1`, `~0` `~1` escaped) |
| `problem(heap, &s, body, tape, errs, status, title)` | the whole RFC 9457 body |
| `json_schema(heap, &s, root)` | the schema node as a JSON Schema 2020-12 document |
| `to_int(body, tape, at)` | the value of an integer slot (`150` and `150.0` alike), after `validate` said 0 |
| `check_text(&s, node, text)` | judge a parameter that is text, not JSON (a path segment, a query value, a header) against a scalar node: 0, or the first error code. Integer (decimal digits only, no `5.0`), bool (`true`/`false`), string (well-formed UTF-8, code points, `add_choice`, `forbid_nul`); `text` must already be percent-decoded |
| `int_of_text(text)` / `bool_of_text(text)` | the value, after `check_text` said 0 |
| `is_int(&s, node)` / `is_bool(&s, node)` / `is_string(&s, node)` | which scalar a node is (none of them for `any`, `number`, an array or an object) |

Error codes: `type`, `required`, `unknown`, `minimum`, `maximum`, `min_length`,
`max_length`, `choice`, `min_items`, `max_items`, `range` (an integer that does not fit
in 64 bits -- an error, not a wrap), `nul` (U+0000 in a string that forbids it).

## Behaviour (so you do not have to guess)

* **No coercion.** `"36"` is not an integer; `true` is not a string.
* **Whole floats are integers**, as in JSON Schema: `150.0` and `1.5e2` are; `1.5` is a
  `type` error; `1e30` is `range`. (A client that serializes a float sends `150.0`;
  refusing it while the generated schema says `"type":"integer"` was a defect a real
  service exposed -- `docs/design.md` §11.)
* **String length is in code points**, counted from the source text (an escaped
  `😀` is one, as is the 4-byte `😀`).
* **Every error is reported**, not the first -- up to the room you gave `errs`; the count
  is always exact.
* **Strict objects refuse unknown keys**, at the key's own pointer.
* A repeated key: the first occurrence is the one validated and stored in the slot.

## Using it in another project

Step 3 of the [quick start](#quick-start) is the whole consumer path. Lock the *names you
call*; the closure they need comes with them. [`cancho-web`](https://github.com/alpibrusl/cancho-web)'s
`deps/schema.lock` is a larger real one. Publishing a change is `rm -rf .cancho-vcs && cancho vcs
publish --std --store .cancho-vcs src/schema.cho` (a store refuses a changed body, so it is
regenerated), followed by re-locking every consumer -- the signatures do not change for a
comment, but every source hash does.

## Tests

```
cancho test tests/schema_test.cho src/schema.cho --std          # 29 unit tests
python3 tests/differential.py --cases 250 --seed 1             # vs the jsonschema package
```

(`pip install jsonschema`; `CANCHO=` names the compiler if it is not on `PATH`.)

The differential test generates random (schema, document) pairs, builds each schema both as
JSON Schema and as a cancho program, and compares the *set of (pointer, code)* the two
report. 250 cases on each of 24 seeds agree. The same test also checks the generated JSON
Schema: it must equal the schema the generator meant, and must give the reference the same
verdicts the library's own validator gave. Both suites are mutation-checked: a deliberate
off-by-one in a bound, in the escaping of `~`, in the unknown-key check, or in the item
counts fails them. CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the
pinned compiler and runs the unit tests, four differential seeds and both examples.

## Documentation

- [`docs/design.md`](docs/design.md): why the schema is data and not types, the validation rules, the error format, how it is
  tested, and what building each slice found (sections 9 to 13: a real service exposed the whole-float, string-length and U+0000
  defects).

## Layout

```
src/schema.cho          the whole library: builder, validator, JSON Pointer, problem+json, JSON Schema
tests/schema_test.cho   unit tests (cancho)
tests/differential.py  random (schema, document) pairs against the jsonschema package
examples/              quickstart.cho and validate.cho, with their recorded output
docs/design.md         the design and what building it found
```

## Limitations

Not built: `$ref` / `$defs` (a node used twice is written twice), bounds on floats, and assembling an OpenAPI document (that is
[`cancho-web`](https://github.com/alpibrusl/cancho-web)'s job, from its routes plus these fragments). The list of errors is
bounded by the room you give `errs`; the count is always exact.

## Contributing

Every change goes through what CI runs: the unit tests, the differential test and both examples (their output must match the recorded files). Design
before code, in `docs/`, with claims measured; a claim that turns out false is corrected in place.

## Licence

[EUPL-1.2](LICENSE).
