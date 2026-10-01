// `schema` -- a schema is data (`docs/design.md`).
//
// A `Schema` is a value built once, at start-up, and walked for every request:
// an arena of nodes in a few `Vec[int]`s plus a byte pool for names, so there is
// nothing to drop but the four allocations and nothing to chase but indices.
// It is `res`: `drop` ends it.
//
//     var s = schema.empty(heap);
//     let (s1, name) = schema.new_string(heap, s, 1, 64);
//     let (s2, age) = schema.new_int(heap, s1, 0, 150);
//     let (s3, user) = schema.new_object(heap, s2, true);
//     s = schema.add_field(heap, s3, user, "name", name, true);
//     s = schema.add_field(heap, s, user, "age", age, false);
//
// `validate` walks the schema and a `std.json` tape together and fills two
// slices the caller provides, the way `http.parse` fills its table:
//
//   * `slots`, one entry per field of the schema (`slot_count`), holds the tape
//     node of the value each field had, or -1. A field's slot is its ordinal
//     in the order `add_field` was called across the whole schema, and
//     `add_field` answers it. Fields reached through an array are not
//     recorded: an object in an array has many values for one field, and the
//     application reads those with `json.at`, which is safe because validation
//     said the shape is right.
//   * `errs` holds every error found, not the first: `errs[0]` is how many were
//     found, followed by four ints each. The slice has room for as many as it
//     has room for; the rest are counted and not stored, so a hostile body
//     cannot make the list large.
//
// Decided, in `docs/design.md` §3 and §11: no coercion (`"3"` is not an integer;
// `1.0` is, as in JSON Schema); the first of a duplicate key wins, as it does in
// `json.get`, so the validator and the reader agree on which value a field has;
// a string's length is counted in **bytes of the decoded text**, because
// counting code points of an escaped string needs somewhere to decode it and a
// validator has no heap.

module schema;

import std.buffer;
import std.json;
import std.vec;

// ---------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------

// A node is eight ints: its kind, flags, and six that mean different things per
// kind. Written as functions so no number is bare at a use.
fn node_width() -> [] int {
    return 8;
}

fn kind_any() -> [] int {
    return 1;
}

fn kind_bool() -> [] int {
    return 2;
}

fn kind_int() -> [] int {
    return 3;
}

fn kind_number() -> [] int {
    return 4;
}

fn kind_string() -> [] int {
    return 5;
}

fn kind_array() -> [] int {
    return 6;
}

fn kind_object() -> [] int {
    return 7;
}

// flags: bit 0, the value may be `null`.
fn flag_nullable() -> [] int {
    return 1;
}

// A field is five ints: where its name starts in `text`, its length, the
// schema node of its value, 1 if it is required, and the next field of the same
// object (or -1).
fn field_width() -> [] int {
    return 5;
}

// An enum member is three ints: where it starts in `text`, its length, and the
// next member of the same string (or -1).
fn member_width() -> [] int {
    return 3;
}

// No lower bound is the lowest `int`, and no upper bound the highest: a bound
// that nothing can violate is exactly no bound, so there is no separate "unset".
pub fn int_min() -> [] int {
    return 0 - 9223372036854775807 - 1;
}

pub fn int_max() -> [] int {
    return 9223372036854775807;
}

pub res struct Schema {
    nodes: vec.Vec[int],
    fields: vec.Vec[int],
    members: vec.Vec[int],
    // Every field name and enum member, back to back.
    text: buffer.Buffer,
}

pub fn empty[&h](heap: &!h Heap) -> [heap] Schema {
    return Schema { nodes: vec.empty(heap, 64, 0), fields: vec.empty(heap, 32, 0), members: vec.empty(heap, 8, 0), text: buffer.empty(heap, 256) };
}

pub fn drop[&h](heap: &!h Heap, s: Schema) -> [heap] int {
    let Schema { nodes, fields, members, text } = s;
    let n = vec.drop(heap, nodes) / node_width();
    vec.drop(heap, fields);
    vec.drop(heap, members);
    buffer.drop(heap, text);
    return n;
}

// How many nodes there are.
pub fn node_count[&s](s: &s Schema) -> [] int {
    return vec.size(s.nodes) / node_width();
}

// How many fields there are across the whole schema: the size of the `slots`
// slice `validate` wants.
pub fn slot_count[&s](s: &s Schema) -> [] int {
    return vec.size(s.fields) / field_width();
}

// ---------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------

fn push_node[&h](heap: &!h Heap, s: Schema, kind: int, a: int, b: int, c: int, d: int, e: int) -> [heap] (Schema, int) {
    let Schema { nodes, fields, members, text } = s;
    var v = nodes;
    var id = 0;
    borrow v as &vr in {
        id = vec.size(vr) / node_width();
    }
    v = vec.push(heap, v, kind);
    v = vec.push(heap, v, 0);
    v = vec.push(heap, v, a);
    v = vec.push(heap, v, b);
    v = vec.push(heap, v, c);
    v = vec.push(heap, v, d);
    v = vec.push(heap, v, e);
    v = vec.push(heap, v, 0);
    return (Schema { nodes: v, fields: fields, members: members, text: text }, id);
}

// Any value at all, `null` included.
pub fn new_any[&h](heap: &!h Heap, s: Schema) -> [heap] (Schema, int) {
    return push_node(heap, s, kind_any(), 0, 0, 0, 0, 0);
}

pub fn new_bool[&h](heap: &!h Heap, s: Schema) -> [heap] (Schema, int) {
    return push_node(heap, s, kind_bool(), 0, 0, 0, 0, 0);
}

// An integer in `lo..=hi`: `int_min()` and `int_max()` for no bound. A JSON
// number with a fraction or an exponent is not an integer, even `1.0`, and one
// outside `int`'s range is an error of its own rather than a wrap.
pub fn new_int[&h](heap: &!h Heap, s: Schema, lo: int, hi: int) -> [heap] (Schema, int) {
    return push_node(heap, s, kind_int(), lo, hi, 0, 0, 0);
}

// Any JSON number. (Bounds on a float need the inverse of `bits_of`, which the
// language does not have yet.)
pub fn new_number[&h](heap: &!h Heap, s: Schema) -> [heap] (Schema, int) {
    return push_node(heap, s, kind_number(), 0, 0, 0, 0, 0);
}

// A string of `min..=max` bytes once decoded. `add_choice` restricts it to a
// set of values.
pub fn new_string[&h](heap: &!h Heap, s: Schema, min: int, max: int) -> [heap] (Schema, int) {
    return push_node(heap, s, kind_string(), min, max, 0 - 1, 0 - 1, 0);
}

// An array of `min..=max` elements, each matching `item`.
pub fn new_array[&h](heap: &!h Heap, s: Schema, item: int, min: int, max: int) -> [heap] (Schema, int) {
    return push_node(heap, s, kind_array(), item, min, max, 0, 0);
}

// An object. `strict` refuses a key no field names; otherwise it is ignored.
pub fn new_object[&h](heap: &!h Heap, s: Schema, strict: bool) -> [heap] (Schema, int) {
    var flag = 0;
    if strict {
        flag = 1;
    }
    return push_node(heap, s, kind_object(), 0 - 1, 0 - 1, flag, 0, 0);
}

// The node may also be `null`.
pub fn make_nullable(s: Schema, node: int) -> [] Schema {
    let Schema { nodes, fields, members, text } = s;
    var v = nodes;
    borrow mut v as &!w in {
        vec.set(w, node * node_width() + 1, 1);
    }
    return Schema { nodes: v, fields: fields, members: members, text: text };
}

// Add `value` to the values the string node `node` may take. A string with no
// member may be anything; with some, only those.
pub fn add_choice[&h, &v](heap: &!h Heap, s: Schema, node: int, value: &v [byte]) -> [heap] Schema {
    let Schema { nodes, fields, members, text } = s;
    var t = text;
    var at = 0;
    borrow t as &tr in {
        at = buffer.size(tr);
    }
    t = buffer.append(heap, t, value);
    var m = members;
    var id = 0;
    borrow m as &mr in {
        id = vec.size(mr) / member_width();
    }
    m = vec.push(heap, m, at);
    m = vec.push(heap, m, len(value));
    m = vec.push(heap, m, 0 - 1);
    var n = nodes;
    borrow mut n as &!w in {
        let base = node * node_width();
        let tail = vec.get(w, base + 5);
        if tail < 0 {
            vec.set(w, base + 4, id);
        }
    }
    var m2 = m;
    var n2 = n;
    borrow mut n2 as &!w in {
        let base = node * node_width();
        let tail = vec.get(w, base + 5);
        if tail >= 0 {
            borrow mut m2 as &!mw in {
                vec.set(mw, tail * member_width() + 2, id);
            }
        }
        vec.set(w, base + 5, id);
    }
    return Schema { nodes: n2, fields: fields, members: m2, text: t };
}

// Give the object node `object` a field `name` whose value matches `node`.
// Answers the schema -- and, through `last_slot`, the field's slot is
// `slot_count - 1` straight after.
pub fn add_field[&h, &v](heap: &!h Heap, s: Schema, object: int, name: &v [byte], node: int, required: bool) -> [heap] Schema {
    let Schema { nodes, fields, members, text } = s;
    var t = text;
    var at = 0;
    borrow t as &tr in {
        at = buffer.size(tr);
    }
    t = buffer.append(heap, t, name);
    var f = fields;
    var id = 0;
    borrow f as &fr in {
        id = vec.size(fr) / field_width();
    }
    var req = 0;
    if required {
        req = 1;
    }
    f = vec.push(heap, f, at);
    f = vec.push(heap, f, len(name));
    f = vec.push(heap, f, node);
    f = vec.push(heap, f, req);
    f = vec.push(heap, f, 0 - 1);
    var n = nodes;
    var f2 = f;
    borrow mut n as &!w in {
        let base = object * node_width();
        let tail = vec.get(w, base + 3);
        if tail < 0 {
            vec.set(w, base + 2, id);
        } else {
            borrow mut f2 as &!fw in {
                vec.set(fw, tail * field_width() + 4, id);
            }
        }
        vec.set(w, base + 3, id);
        vec.set(w, base + 5, vec.get(w, base + 5) + 1);
    }
    return Schema { nodes: n, fields: f2, members: members, text: t };
}

// The slot of the field most recently added: `slot_count - 1`.
pub fn last_slot[&s](s: &s Schema) -> [] int {
    return slot_count(s) - 1;
}

// ---------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------

// An error is four ints: its code, the schema node that was being checked, the
// tape node it is about (the offending value, or for `required` the object
// that lacks the field, or for `unknown` the key), and the field's slot for
// `required` (else -1).
fn error_width() -> [] int {
    return 4;
}

pub fn err_type() -> [] int {
    return 1;
}

pub fn err_required() -> [] int {
    return 2;
}

pub fn err_unknown() -> [] int {
    return 3;
}

pub fn err_minimum() -> [] int {
    return 4;
}

pub fn err_maximum() -> [] int {
    return 5;
}

pub fn err_min_length() -> [] int {
    return 6;
}

pub fn err_max_length() -> [] int {
    return 7;
}

pub fn err_choice() -> [] int {
    return 8;
}

pub fn err_min_items() -> [] int {
    return 9;
}

pub fn err_max_items() -> [] int {
    return 10;
}

pub fn err_range() -> [] int {
    return 11;
}

// The size of an `errs` slice that can hold `n` errors.
pub fn errors_len(n: int) -> [] int {
    return 1 + n * error_width();
}

// How many errors validation found, including any it had no room to store.
pub fn error_count[&e](errs: &e [int]) -> [] int {
    return errs[0];
}

// How many of them are stored.
pub fn errors_stored[&e](errs: &e [int]) -> [] int {
    let room = (len(errs) - 1) / error_width();
    if errs[0] < room {
        return errs[0];
    }
    return room;
}

pub fn error_code[&e](errs: &e [int], i: int) -> [] int {
    return errs[1 + i * error_width()];
}

// A short stable name for a code: what a client switches on.
pub fn code_name(code: int) -> [] &static [byte] {
    if code == 1 {
        return "type";
    }
    if code == 2 {
        return "required";
    }
    if code == 3 {
        return "unknown";
    }
    if code == 4 {
        return "minimum";
    }
    if code == 5 {
        return "maximum";
    }
    if code == 6 {
        return "min_length";
    }
    if code == 7 {
        return "max_length";
    }
    if code == 8 {
        return "choice";
    }
    if code == 9 {
        return "min_items";
    }
    if code == 10 {
        return "max_items";
    }
    if code == 11 {
        return "range";
    }
    return "unknown";
}

// The sentence for a code.
pub fn code_message(code: int) -> [] &static [byte] {
    if code == 1 {
        return "has the wrong type";
    }
    if code == 2 {
        return "is required";
    }
    if code == 3 {
        return "is not a known field";
    }
    if code == 4 {
        return "is below the minimum";
    }
    if code == 5 {
        return "is above the maximum";
    }
    if code == 6 {
        return "is too short";
    }
    if code == 7 {
        return "is too long";
    }
    if code == 8 {
        return "is not one of the allowed values";
    }
    if code == 9 {
        return "has too few items";
    }
    if code == 10 {
        return "has too many items";
    }
    if code == 11 {
        return "is outside the range of an integer";
    }
    return "is invalid";
}

fn fail[&e](errs: &!e [int], code: int, node: int, at: int, slot: int) -> [] int {
    let n = errs[0];
    let room = (len(errs) - 1) / error_width();
    if n < room {
        let base = 1 + n * error_width();
        errs[base] = code;
        errs[base + 1] = node;
        errs[base + 2] = at;
        errs[base + 3] = slot;
    }
    errs[0] = n + 1;
    return 0;
}

// ---------------------------------------------------------------------
// Validating
// ---------------------------------------------------------------------

fn node_at[&s](s: &s Schema, node: int, field: int) -> [] int {
    return vec.get(s.nodes, node * node_width() + field);
}

// Whether `at` is a string equal to any member of the string node `node`.
fn is_member[&s, &b, &t](s: &s Schema, node: int, body: &b [byte], tape: &t [int], at: int) -> [] bool {
    var m = node_at(s, node, 4);
    let pool = buffer.bytes(s.text);
    while m >= 0 {
        let off = vec.get(s.members, m * member_width());
        let n = vec.get(s.members, m * member_width() + 1);
        if json.string_equals(body, tape, at, pool[off..off + n]) {
            return true;
        }
        m = vec.get(s.members, m * member_width() + 2);
    }
    return false;
}

fn field_name[&s](s: &s Schema, field: int) -> [] &s [byte] {
    let off = vec.get(s.fields, field * field_width());
    let n = vec.get(s.fields, field * field_width() + 1);
    return buffer.bytes(s.text)[off..off + n];
}

// Whether the object at `obj` has a key `key` names no field of `object_node`.
fn check_unknown[&s, &b, &t, &e](s: &s Schema, object_node: int, body: &b [byte], tape: &t [int], obj: int, errs: &!e [int]) -> [] int {
    var k = obj + 1;
    var left = json.count(tape, obj);
    while left > 0 {
        var known = false;
        var f = node_at(s, object_node, 2);
        while f >= 0 && !known {
            if json.string_equals(body, tape, k, field_name(s, f)) {
                known = true;
            }
            f = vec.get(s.fields, f * field_width() + 4);
        }
        if !known {
            fail(errs, err_unknown(), object_node, k, 0 - 1);
        }
        k = json.skip(tape, k + 1);
        left = left - 1;
    }
    return 0;
}

// Whether the number at `at` is an integer, JSON Schema's way: `150`, and also
// `150.0` and `1.5e2`, which is what a client that serializes a float sends for
// a whole number. 0: it is not one (a string, a boolean, `1.5`); 1: it is, and it
// fits an `int`; 2: it is, and it does not.
//
// `docs/design.md` §11: this used to be "`1.0` is not an integer", and a
// Schemathesis run against a real service showed that the generated schema said
// `"type":"integer"` -- which accepts `150.0` -- while the validator refused it.
fn integral[&b, &t](body: &b [byte], tape: &t [int], at: int) -> [] int {
    if json.is_int(tape, at) {
        if json.fits_int(body, tape, at) {
            return 1;
        }
        return 2;
    }
    if json.kind(tape, at) != json.kind_float() {
        return 0;
    }
    let x = json.to_float(body, tape, at);
    // 2^63: every float at or past it is a whole number that no `int` holds.
    if x >= 9223372036854775808.0 || x < 0.0 - 9223372036854775808.0 {
        return 2;
    }
    if float_of(truncate(x)) == x {
        return 1;
    }
    return 0;
}

// The value of an integer node, `150` and `150.0` alike. For use on a slot after
// `validate` said 0, where the node is known to be an integer that fits; 0 for
// anything else.
pub fn to_int[&b, &t](body: &b [byte], tape: &t [int], at: int) -> [] int {
    if json.is_int(tape, at) {
        return json.to_int(body, tape, at);
    }
    if integral(body, tape, at) == 1 {
        return truncate(json.to_float(body, tape, at));
    }
    return 0;
}

// Check the value at tape node `at` against schema node `node`. `track` says
// whether fields may be written to `slots`: false inside an array.
fn check[&s, &b, &t, &u, &e](s: &s Schema, node: int, body: &b [byte], tape: &t [int], at: int, slots: &!u [int], errs: &!e [int], track: bool) -> [] int {
    let kind = node_at(s, node, 0);
    if kind == kind_any() {
        return 0;
    }
    if json.is_null(tape, at) {
        if node_at(s, node, 1) & flag_nullable() == 0 {
            fail(errs, err_type(), node, at, 0 - 1);
        }
        return 0;
    }
    if kind == kind_bool() {
        if !json.is_bool(tape, at) {
            fail(errs, err_type(), node, at, 0 - 1);
        }
        return 0;
    }
    if kind == kind_number() {
        if !json.is_number(tape, at) {
            fail(errs, err_type(), node, at, 0 - 1);
        }
        return 0;
    }
    if kind == kind_int() {
        let shape = integral(body, tape, at);
        if shape == 0 {
            fail(errs, err_type(), node, at, 0 - 1);
        } else if shape == 2 {
            fail(errs, err_range(), node, at, 0 - 1);
        } else {
            let value = to_int(body, tape, at);
            if value < node_at(s, node, 2) {
                fail(errs, err_minimum(), node, at, 0 - 1);
            }
            if value > node_at(s, node, 3) {
                fail(errs, err_maximum(), node, at, 0 - 1);
            }
        }
        return 0;
    }
    if kind == kind_string() {
        if !json.is_string(tape, at) {
            fail(errs, err_type(), node, at, 0 - 1);
        } else {
            let n = json.string_length(body, tape, at);
            if n < node_at(s, node, 2) {
                fail(errs, err_min_length(), node, at, 0 - 1);
            }
            if n > node_at(s, node, 3) {
                fail(errs, err_max_length(), node, at, 0 - 1);
            }
            if node_at(s, node, 4) >= 0 && !is_member(s, node, body, tape, at) {
                fail(errs, err_choice(), node, at, 0 - 1);
            }
        }
        return 0;
    }
    if kind == kind_array() {
        if !json.is_array(tape, at) {
            fail(errs, err_type(), node, at, 0 - 1);
        } else {
            let n = json.count(tape, at);
            if n < node_at(s, node, 3) {
                fail(errs, err_min_items(), node, at, 0 - 1);
            }
            if n > node_at(s, node, 4) {
                fail(errs, err_max_items(), node, at, 0 - 1);
            }
            var j = at + 1;
            var left = n;
            while left > 0 {
                check(s, node_at(s, node, 2), body, tape, j, slots, errs, false);
                j = json.skip(tape, j);
                left = left - 1;
            }
        }
        return 0;
    }
    // An object.
    if !json.is_object(tape, at) {
        fail(errs, err_type(), node, at, 0 - 1);
        return 0;
    }
    var f = node_at(s, node, 2);
    while f >= 0 {
        let name = field_name(s, f);
        let v = json.get(body, tape, at, name);
        if v >= 0 {
            if track {
                slots[f] = v;
            }
            check(s, vec.get(s.fields, f * field_width() + 2), body, tape, v, slots, errs, track);
        } else if vec.get(s.fields, f * field_width() + 3) == 1 {
            fail(errs, err_required(), node, at, f);
        }
        f = vec.get(s.fields, f * field_width() + 4);
    }
    if node_at(s, node, 4) == 1 {
        check_unknown(s, node, body, tape, at, errs);
    }
    return 0;
}

// Validate the document parsed into `tape` (node 0) against schema node `root`.
// Fills `slots` (`slot_count` ints, each -1 or a tape node) and `errs` (at least
// `errors_len(1)` ints), and answers how many errors were found: 0 means the
// body has the shape.
pub fn validate[&s, &b, &t, &u, &e](s: &s Schema, root: int, body: &b [byte], tape: &t [int], slots: &!u [int], errs: &!e [int]) -> [] int {
    var i = 0;
    while i < len(slots) {
        slots[i] = 0 - 1;
        i = i + 1;
    }
    errs[0] = 0;
    check(s, root, body, tape, 0, slots, errs, true);
    return errs[0];
}

// ---------------------------------------------------------------------
// Where an error is: an RFC 6901 JSON pointer
// ---------------------------------------------------------------------

// Append `text` to `out` as the body of a pointer segment: `~` written `~0` and
// `/` written `~1` (RFC 6901 §3).
fn push_escaped[&h, &r](heap: &!h Heap, out: buffer.Buffer, text: &r [byte]) -> [heap] buffer.Buffer {
    var o = out;
    var i = 0;
    while i < len(text) {
        let c = int_of(text[i]);
        if c == 126 {
            o = buffer.append(heap, o, "~0");
        } else if c == 47 {
            o = buffer.append(heap, o, "~1");
        } else {
            o = buffer.push(heap, o, text[i]);
        }
        i = i + 1;
    }
    return o;
}

// Append the key at tape node `k`, decoded, to `out` as a whole pointer segment.
fn append_segment[&h, &b, &t](heap: &!h Heap, out: buffer.Buffer, body: &b [byte], tape: &t [int], k: int) -> [heap] buffer.Buffer {
    var o = buffer.push(heap, out, byte_of(47));
    let n = json.string_length(body, tape, k);
    if n <= 0 {
        return o;
    }
    let raw = box_slice(heap, n, byte_of(0));
    borrow mut raw as &!w in {
        let d = contents(w);
        json.string_into(body, tape, k, d);
        o = push_escaped(heap, o, d);
    }
    unbox_slice(heap, raw);
    return o;
}

// The JSON pointer to stored error `i`: the path from the document root to the
// value it is about, found by walking the tape (it has no parent links, and an
// error stores indices rather than strings, so recording one allocates
// nothing). For a missing required field the pointer names the field that is
// not there.
pub fn pointer[&h, &s, &b, &t, &e](heap: &!h Heap, s: &s Schema, body: &b [byte], tape: &t [int], errs: &e [int], i: int) -> [heap] buffer.Buffer {
    let base = 1 + i * error_width();
    let target = errs[base + 2];
    let slot = errs[base + 3];
    var out = buffer.empty(heap, 32);
    var cur = 0;
    var walking = true;
    while walking && cur != target {
        let kind = json.kind(tape, cur);
        var next = 0 - 1;
        if kind == json.kind_object() {
            var k = cur + 1;
            var left = json.count(tape, cur);
            while left > 0 && next < 0 {
                let v = k + 1;
                let end = json.skip(tape, v);
                if target == k {
                    out = append_segment(heap, out, body, tape, k);
                    next = target;
                } else if target >= v && target < end {
                    out = append_segment(heap, out, body, tape, k);
                    next = v;
                }
                k = end;
                left = left - 1;
            }
        } else if kind == json.kind_array() {
            var j = cur + 1;
            var index = 0;
            var left = json.count(tape, cur);
            while left > 0 && next < 0 {
                let end = json.skip(tape, j);
                if target >= j && target < end {
                    out = buffer.push(heap, out, byte_of(47));
                    out = buffer.push_nat(heap, out, index);
                    next = j;
                }
                j = end;
                index = index + 1;
                left = left - 1;
            }
        }
        if next < 0 {
            walking = false;
        } else {
            cur = next;
        }
    }
    if slot >= 0 {
        out = buffer.push(heap, out, byte_of(47));
        out = push_escaped(heap, out, field_name(s, slot));
    }
    return out;
}

// ---------------------------------------------------------------------
// problem+json
// ---------------------------------------------------------------------

// `application/problem+json` (RFC 9457) for what `validate` found:
//
//     {"type":"about:blank","title":..,"status":422,"count":N,
//      "errors":[{"pointer":"/age","code":"maximum","detail":"is above the maximum"},..]}
//
// `count` is how many errors there were, which can exceed how many `errors`
// lists if `errs` had no room for them all.
pub fn problem[&h, &s, &b, &t, &e, &m](heap: &!h Heap, s: &s Schema, body: &b [byte], tape: &t [int], errs: &e [int], status: int, title: &m [byte]) -> [heap] buffer.Buffer {
    var w = json.writer(heap, 256);
    w = json.begin_object(heap, w);
    w = json.put_key(heap, w, "type");
    w = json.put_string(heap, w, "about:blank");
    w = json.put_key(heap, w, "title");
    w = json.put_string(heap, w, title);
    w = json.put_key(heap, w, "status");
    w = json.put_int(heap, w, status);
    w = json.put_key(heap, w, "count");
    w = json.put_int(heap, w, error_count(errs));
    w = json.put_key(heap, w, "errors");
    w = json.begin_array(heap, w);
    var i = 0;
    while i < errors_stored(errs) {
        w = json.begin_object(heap, w);
        w = json.put_key(heap, w, "pointer");
        let p = pointer(heap, s, body, tape, errs, i);
        borrow p as &pb in {
            w = json.put_string(heap, w, buffer.bytes(pb));
        }
        buffer.drop(heap, p);
        w = json.put_key(heap, w, "code");
        w = json.put_string(heap, w, code_name(error_code(errs, i)));
        w = json.put_key(heap, w, "detail");
        w = json.put_string(heap, w, code_message(error_code(errs, i)));
        w = json.end_object(heap, w);
        i = i + 1;
    }
    w = json.end_array(heap, w);
    w = json.end_object(heap, w);
    return json.finish(w);
}

// ---------------------------------------------------------------------
// JSON Schema (2020-12, which is what OpenAPI 3.1 uses)
// ---------------------------------------------------------------------

// The type keyword for a node: `"string"`, or `["string","null"]` if it may be
// `null`. (A nullable *choice* is `enum` with `null` among its members, below:
// `enum` applies to every type in JSON Schema, so that is the only way to say it.)
fn write_type[&h](heap: &!h Heap, w: json.Writer, name: &static [byte], nullable: bool) -> [heap] json.Writer {
    var o = json.put_key(heap, w, "type");
    if nullable {
        o = json.begin_array(heap, o);
        o = json.put_string(heap, o, name);
        o = json.put_string(heap, o, "null");
        o = json.end_array(heap, o);
    } else {
        o = json.put_string(heap, o, name);
    }
    return o;
}

fn write_node[&h, &s](heap: &!h Heap, sc: &s Schema, node: int, w: json.Writer) -> [heap] json.Writer {
    let kind = node_at(sc, node, 0);
    let nullable = node_at(sc, node, 1) & flag_nullable() != 0;
    var o = json.begin_object(heap, w);
    if kind == kind_bool() {
        o = write_type(heap, o, "boolean", nullable);
    } else if kind == kind_number() {
        o = write_type(heap, o, "number", nullable);
    } else if kind == kind_int() {
        o = write_type(heap, o, "integer", nullable);
        if node_at(sc, node, 2) != int_min() {
            o = json.put_key(heap, o, "minimum");
            o = json.put_int(heap, o, node_at(sc, node, 2));
        }
        if node_at(sc, node, 3) != int_max() {
            o = json.put_key(heap, o, "maximum");
            o = json.put_int(heap, o, node_at(sc, node, 3));
        }
    } else if kind == kind_string() {
        o = write_type(heap, o, "string", nullable);
        let lo = node_at(sc, node, 2);
        let hi = node_at(sc, node, 3);
        if lo > 0 {
            o = json.put_key(heap, o, "minLength");
            o = json.put_int(heap, o, lo);
        }
        if hi != int_max() {
            o = json.put_key(heap, o, "maxLength");
            o = json.put_int(heap, o, hi);
        }
        // `minLength`/`maxLength` count code points in JSON Schema; this
        // validator counts bytes of the decoded text (`docs/design.md` §9). The two
        // agree for ASCII, so a document that is not says which one it means.
        if lo > 0 || hi != int_max() {
            o = json.put_key(heap, o, "x-length-unit");
            o = json.put_string(heap, o, "bytes");
        }
        if node_at(sc, node, 4) >= 0 {
            o = json.put_key(heap, o, "enum");
            o = json.begin_array(heap, o);
            var m = node_at(sc, node, 4);
            let pool = buffer.bytes(sc.text);
            while m >= 0 {
                let off = vec.get(sc.members, m * member_width());
                let n = vec.get(sc.members, m * member_width() + 1);
                o = json.put_string(heap, o, pool[off..off + n]);
                m = vec.get(sc.members, m * member_width() + 2);
            }
            if nullable {
                o = json.put_null(heap, o);
            }
            o = json.end_array(heap, o);
        }
    } else if kind == kind_array() {
        o = write_type(heap, o, "array", nullable);
        o = json.put_key(heap, o, "items");
        o = write_node(heap, sc, node_at(sc, node, 2), o);
        if node_at(sc, node, 3) > 0 {
            o = json.put_key(heap, o, "minItems");
            o = json.put_int(heap, o, node_at(sc, node, 3));
        }
        if node_at(sc, node, 4) != int_max() {
            o = json.put_key(heap, o, "maxItems");
            o = json.put_int(heap, o, node_at(sc, node, 4));
        }
    } else if kind == kind_object() {
        o = write_type(heap, o, "object", nullable);
        o = json.put_key(heap, o, "properties");
        o = json.begin_object(heap, o);
        var f = node_at(sc, node, 2);
        var required = 0;
        while f >= 0 {
            o = json.put_key(heap, o, field_name(sc, f));
            o = write_node(heap, sc, vec.get(sc.fields, f * field_width() + 2), o);
            required = required + vec.get(sc.fields, f * field_width() + 3);
            f = vec.get(sc.fields, f * field_width() + 4);
        }
        o = json.end_object(heap, o);
        if required > 0 {
            o = json.put_key(heap, o, "required");
            o = json.begin_array(heap, o);
            f = node_at(sc, node, 2);
            while f >= 0 {
                if vec.get(sc.fields, f * field_width() + 3) == 1 {
                    o = json.put_string(heap, o, field_name(sc, f));
                }
                f = vec.get(sc.fields, f * field_width() + 4);
            }
            o = json.end_array(heap, o);
        }
        if node_at(sc, node, 4) == 1 {
            o = json.put_key(heap, o, "additionalProperties");
            o = json.put_bool(heap, o, false);
        }
    }
    return json.end_object(heap, o);
}

// The JSON Schema for schema node `root`, compact. Deterministic: members, fields
// and `required` come out in the order they were added, so the same schema is the
// same bytes on every run and can be hashed, diffed and checked in.
//
// It says what `validate` accepts, with one disclosed difference: string length
// (see `x-length-unit` above). A nullable string with choices lists `null` among
// its `enum` members, because `enum` constrains every type.
pub fn json_schema[&h, &s](heap: &!h Heap, sc: &s Schema, root: int) -> [heap] buffer.Buffer {
    return json.finish(write_node(heap, sc, root, json.writer(heap, 256)));
}
