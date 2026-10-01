# lexsys-schema

> **Status: design only.** Nothing here is built. [`docs/design.md`](docs/design.md)
> says what will be, and marks every claim as measured or not.

A schema for [lex-sys](https://github.com/alpibrusl/lex-sys), written as **data**:
one value, built when the program starts, that drives

* **validation** of a JSON body (`std.json` tape in, every error out, not the first),
* **error bodies** (RFC 9457 `application/problem+json`, with JSON-pointer paths),
* **OpenAPI 3.1 / JSON Schema generation**,

so that what the API accepts and what its documentation says are the same
object and cannot drift. It is the half of a FastAPI-shaped stack that
[`lexsys-web`](https://github.com/alpibrusl/lexsys-web) builds on.

No C: it is ordinary lex-sys over `std.json`, `std.buffer`, `std.vec` and
`std.utf8`, and `lex-sys authority` should report nothing but `heap`.

## Licence

[EUPL-1.2](LICENSE).
