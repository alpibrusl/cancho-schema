# lexsys-schema

> **Status: slices 1 and 2 built** -- the schema builder, the validator,
> JSON-pointer error locations, `problem+json`, and JSON Schema generation, in
> [`src/schema.ls`](src/schema.ls). Not yet built: assembling an OpenAPI document
> (that is `lexsys-web`'s, from its routes plus these fragments). [`docs/design.md`](docs/design.md)
> says what will be and marks every claim as measured or not; §9 there is what
> building the first slice found.

A schema for [lex-sys](https://github.com/alpibrusl/lex-sys), written as **data**:
one value, built when the program starts, that drives

* **validation** of a JSON body (`std.json` tape in, every error out, not the first),
* **error bodies** (RFC 9457 `application/problem+json`, with JSON-pointer paths),
* **OpenAPI 3.1 / JSON Schema generation**,

so that what the API accepts and what its documentation says are the same
object and cannot drift. It is the half of a FastAPI-shaped stack that
[`lexsys-web`](https://github.com/alpibrusl/lexsys-web) builds on.

No C: it is ordinary lex-sys over `std.json`, `std.buffer` and `std.vec`, and
`lex-sys authority` on a program that validates a body reports **`heap` and
nothing else** -- no console, filesystem, network, command line or foreign code
(checked, not assumed).

## Use

```
lex-sys vcs publish --std --store .lex-sys-vcs src/schema.ls   # already done: .lex-sys-vcs/ is checked in
lex-sys vcs lock  --store <path to this repo>/.lex-sys-vcs -o schema.lock new_object add_field validate ...
lex-sys vcs fetch --lock schema.lock --store <path>/.lex-sys-vcs -o deps/
lex-sys build --std app.ls deps/*.ls -o app
```

`tests/schema_test.ls` shows every call. The shape:

```
var s = schema.empty(heap);
let (s1, name) = schema.new_string(heap, s, 1, 64);
let (s2, age)  = schema.new_int(heap, s1, 0, 150);
let (s3, user) = schema.new_object(heap, s2, true);
s = schema.add_field(heap, s3, user, "name", name, true);
s = schema.add_field(heap, s, user, "age", age, false);
// per request: parse with std.json, then
let n = schema.validate(sc, user, body, tape, slots, errs);   // 0: it has the shape
let problem = schema.problem(heap, sc, body, tape, errs, 422, "Unprocessable Content");
// and the same declaration as JSON Schema 2020-12 (what OpenAPI 3.1 uses):
let doc = schema.json_schema(heap, sc, user);
```

## Tests

```
lex-sys test tests/schema_test.ls src/schema.ls --std          # 18 unit tests
python3 tests/differential.py --cases 250 --seed 1             # vs the jsonschema package
```

The differential test generates random (schema, document) pairs, builds each
schema both as JSON Schema and as a lex-sys program, and compares the *set of
(pointer, code)* the two report. 250 cases on each of 24 seeds agree. The same
test also checks the generated JSON Schema: it must equal the schema the generator
meant, and must give the reference the same verdicts the library's own validator
gave. Both suites are mutation-checked: a deliberate off-by-one in a bound, in the escaping
of `~`, in the unknown-key check, or in the item counts fails them.

Tested against `lex-sys` at `c5ee956` (a store records no hash of the `std` it
was published against, so the compiler version is stated here).

## Licence

[EUPL-1.2](LICENSE).
