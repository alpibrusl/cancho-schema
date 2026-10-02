#!/usr/bin/env python3
"""Differential test: `schema.validate` against an independent implementation.

    python3 tests/differential.py [--cases N] [--seed S] [--lex-sys PATH]

Random (schema, document) pairs are generated in Python as JSON Schema and
also as a lex-sys program that builds the same schema. The program validates
every document and prints, for each, how many errors it found and each stored
error's (JSON pointer, code). The reference is the `jsonschema` package
(Draft 2020-12), with the verdicts compared as *sets of (pointer, code)* and
counted.

Where the two are specified differently on purpose (`docs/design.md` §3) the
reference is bent to the lex-sys rule, and the generator stays out of the
corners that are only *documented* differences. Bending the reference is how a
wrong decision hides (`docs/design.md` §11, §12), so each bend is listed:

  * an integer is a JSON integer as JSON Schema has it (`1.0` is one), and one
    outside int64 is an error of its own, `range` (the reference's `integer` type
    is redefined to add the int64 bound);
  * the first of a duplicate key wins; documents here have no duplicates.

Exits 0 if every case agrees, 1 and prints the first disagreements otherwise.
"""
import argparse
import json
import os
import random
import subprocess
import sys
import tempfile

import jsonschema
from jsonschema import Draft202012Validator, validators

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src", "schema.ls")
INT_MIN, INT_MAX = -(2**63), 2**63 - 1

KEYS = ["a", "b", "name", "n", "x y", "a/b", "c~d", "é", "", "k1", "k2", "tags"]
WORDS = ["red", "green", "blue", "é", "日本", "a/b", "éé"]


# --------------------------------------------------------------------- schemas
class Gen:
    def __init__(self, rng):
        self.rng = rng

    def schema(self, depth=0):
        r = self.rng
        kinds = ["bool", "int", "number", "str", "choice", "any"]
        if depth < 3:
            kinds += ["array", "object", "object"]
        kind = r.choice(kinds)
        s = {"kind": kind}
        if kind == "int":
            lo = r.choice([None, None, r.randint(-5, 5)])
            hi = r.choice([None, None, (lo if lo is not None else 0) + r.randint(0, 10)])
            s["min"], s["max"] = lo, hi
        elif kind == "str":
            lo = r.choice([None, 0, 1, 2])
            hi = r.choice([None, 3, 6, (lo or 0) + r.randint(0, 5)])
            if lo is not None and hi is not None and lo > hi:
                lo, hi = hi, lo
            s["min"], s["max"] = lo, hi
            # a node that refuses U+0000 (a store that cannot hold it): `pattern` in JSON Schema
            s["nul"] = r.random() < 0.35
        elif kind == "choice":
            s["values"] = r.sample(WORDS, r.randint(1, 3))
        elif kind == "array":
            s["item"] = self.schema(depth + 1)
            lo = r.choice([None, 0, 1])
            hi = r.choice([None, 3, 5])
            s["min"], s["max"] = lo, hi
        elif kind == "object":
            n = r.randint(0, 3)
            keys = r.sample(KEYS, n)
            s["fields"] = [(k, self.schema(depth + 1), r.random() < 0.6) for k in keys]
            s["strict"] = r.random() < 0.6
        s["nullable"] = kind != "any" and r.random() < 0.15
        return s


def json_schema(s):
    k = s["kind"]
    if k == "any":
        return {}
    t = {"bool": "boolean", "int": "integer", "number": "number", "str": "string",
         "choice": "string", "array": "array", "object": "object"}[k]
    out = {"type": [t, "null"] if s["nullable"] else t}
    if k == "int":
        if s["min"] is not None:
            out["minimum"] = s["min"]
        if s["max"] is not None:
            out["maximum"] = s["max"]
    elif k == "str":
        # A zero minimum says nothing.
        if s["min"]:
            out["minLength"] = s["min"]
        if s["max"] is not None:
            out["maxLength"] = s["max"]
        if s.get("nul"):
            out["pattern"] = "^[^\\u0000]*$"
    elif k == "choice":
        # A nullable choice accepts `null` (`docs/design.md` §3); JSON Schema's
        # `enum` applies to every type, so null has to be one of the members.
        out["enum"] = s["values"] + ([None] if s["nullable"] else [])
    elif k == "array":
        out["items"] = json_schema(s["item"])
        if s["min"]:
            out["minItems"] = s["min"]
        if s["max"] is not None:
            out["maxItems"] = s["max"]
    elif k == "object":
        out["properties"] = {name: json_schema(sub) for name, sub, _ in s["fields"]}
        req = [name for name, _, required in s["fields"] if required]
        if req:
            out["required"] = req
        if s["strict"]:
            out["additionalProperties"] = False
    return out


# ------------------------------------------------------------------- documents
# ASCII, two-byte, three-byte and astral (a surrogate pair once escaped): length
# is in code points, so every width must count as one.
ALPHABET = "abcxyz09 _-" + "éñü" + "日本語" + "😀🎉"


def ascii_str(r, lo, hi):
    n = r.randint(lo, hi)
    return "".join(r.choice(ALPHABET) for _ in range(n))


def valid_value(r, s):
    k = s["kind"]
    if s["nullable"] and r.random() < 0.2:
        return None
    if k == "any":
        return r.choice([None, 1, "x", [1, 2], {"q": True}, 2.5, False])
    if k == "bool":
        return r.random() < 0.5
    if k == "int":
        lo = s["min"] if s["min"] is not None else -20
        hi = s["max"] if s["max"] is not None else lo + 40
        # The ends of the range are where an off-by-one lives.
        v = r.choice([lo, max(lo, hi), r.randint(lo, max(lo, hi))])
        # A client that serializes a float sends a whole number as `150.0`.
        return float(v) if r.random() < 0.2 else v
    if k == "number":
        return r.choice([r.randint(-9, 9), r.randint(-900, 900) / 8, 1e3, 0])
    if k == "str":
        lo = s["min"] or 0
        hi = s["max"] if s["max"] is not None else lo + 6
        text = ascii_str(r, *r.choice([(lo, lo), (hi, hi), (lo, hi)]))
        if r.random() < 0.2:
            # U+0000 (written `\u0000` by json.dumps): an error where the node refuses it,
            # fine where it does not -- and a length one longer than asked for
            at = r.randint(0, len(text))
            text = text[:at] + "\x00" + text[at:]
        return text
    if k == "choice":
        return r.choice(s["values"])
    if k == "array":
        lo = s["min"] or 0
        hi = s["max"] if s["max"] is not None else lo + 3
        return [valid_value(r, s["item"]) for _ in range(r.choice([lo, max(lo, hi), r.randint(lo, max(lo, hi))]))]
    out = {}
    for name, sub, required in s["fields"]:
        if required or r.random() < 0.5:
            out[name] = valid_value(r, sub)
    return out


def corrupt(r, s, v):
    """Make `v` (valid for `s`) wrong in one or two places, or leave it alone."""
    k = s["kind"]
    if r.random() < 0.25:
        return r.choice([None, True, 7, -3, 2.5, "zz", [], {}, [1], {"zz": 1}, 1.0, 10**30, "é", "😀"])
    if k == "array" and isinstance(v, list):
        out = [corrupt(r, s["item"], x) if r.random() < 0.5 else x for x in v]
        if r.random() < 0.2:
            out = out + [valid_value(r, s["item"])] * r.randint(1, 4)
        return out
    if k == "object" and isinstance(v, dict):
        out = {}
        subs = {name: sub for name, sub, _ in s["fields"]}
        for name, x in v.items():
            if r.random() < 0.15:
                continue
            out[name] = corrupt(r, subs[name], x) if r.random() < 0.5 else x
        if r.random() < 0.3:
            out[r.choice(["extra", "a/b", "ñ", "q~r"])] = r.choice([1, None, [1], {}])
        return out
    if k == "int" and isinstance(v, (int, float)) and not isinstance(v, bool):
        return v + r.choice([-1000, -1, 1, 1000, 2**63, 0.5, -0.5, 1e19, -1e19, 0.0])
    if k == "str" and isinstance(v, str):
        return ascii_str(r, 0, 12)
    if k == "choice":
        return r.choice(WORDS + ["pink"])
    return v


# ---------------------------------------------------------------- the reference
def _whole(x):
    """A JSON integer, JSON Schema's way: `150` and `150.0` alike (not a boolean)."""
    if isinstance(x, bool):
        return False
    return isinstance(x, int) or (isinstance(x, float) and x.is_integer())


def _is_int(checker, x):
    return _whole(x) and INT_MIN <= x <= INT_MAX


class Ref:
    def __init__(self):
        checker = Draft202012Validator.TYPE_CHECKER.redefine("integer", _is_int)
        self.cls = validators.extend(Draft202012Validator, type_checker=checker)

    @staticmethod
    def pointer(path):
        return "".join("/" + str(p).replace("~", "~0").replace("/", "~1") for p in path)

    def errors(self, schema, doc):
        out = set()
        count = 0
        for e in self.cls(schema).iter_errors(doc):
            base = list(e.absolute_path)
            v = e.validator
            if v == "type":
                wanted = e.schema.get("type")
                wanted = wanted if isinstance(wanted, list) else [wanted]
                big = "integer" in wanted and _whole(e.instance)
                out.add((self.pointer(base), "range" if big else "type")); count += 1
            elif v == "required":
                # "'name' is a required property"
                import ast
                name = ast.literal_eval(e.message.rsplit(" is a required property", 1)[0])
                out.add((self.pointer(base + [name]), "required")); count += 1
            elif v == "additionalProperties":
                import ast
                head = e.message.split(" (", 1)[1].rsplit(" ", 2)[0]
                names = ast.literal_eval("(" + head + ",)") if not head.startswith("(") else ast.literal_eval(head)
                for n in names:
                    out.add((self.pointer(base + [n]), "unknown")); count += 1
            else:
                code = {"minimum": "minimum", "maximum": "maximum", "minLength": "min_length",
                        "maxLength": "max_length", "enum": "choice", "minItems": "min_items",
                        "maxItems": "max_items", "pattern": "nul"}[v]
                out.add((self.pointer(base), code)); count += 1
        # `enum` applies to a value of any type, and the bounds to any number;
        # `schema` reports the type and stops (`docs/design.md` §3), so a value
        # of the wrong type is one error here, not two.
        for pointer, code in list(out):
            # (`minimum`/`maximum` likewise apply to any *number*, so `2.5` against
            # an integer range is a `type` error and also a bound one there.)
            if code in ("choice", "minimum", "maximum") and (pointer, "type") in out:
                out.discard((pointer, code))
                count -= 1
        # A number outside int64 is one error, `range`; its bounds are not
        # consulted.
        for pointer, code in list(out):
            if code == "range":
                for bound in ("minimum", "maximum"):
                    if (pointer, bound) in out:
                        out.discard((pointer, bound))
                        count -= 1
        return count, out


# --------------------------------------------------------------- the lex program
def lex_str(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def int_expr(n, lo):
    if n is None:
        return "schema.int_min()" if lo else "schema.int_max()"
    return str(n) if n >= 0 else "0 - %d" % -n


class Emit:
    def __init__(self):
        self.lines = []
        self.n = 0

    def fresh(self):
        self.n += 1
        return self.n

    def node(self, s):
        k = s["kind"]
        i = self.fresh()
        t, v = "t%d" % i, "n%d" % i
        if k == "any":
            self.lines.append("let (%s, %s) = schema.new_any(heap, s);" % (t, v))
        elif k == "bool":
            self.lines.append("let (%s, %s) = schema.new_bool(heap, s);" % (t, v))
        elif k == "number":
            self.lines.append("let (%s, %s) = schema.new_number(heap, s);" % (t, v))
        elif k == "int":
            self.lines.append("let (%s, %s) = schema.new_int(heap, s, %s, %s);" % (
                t, v, int_expr(s["min"], True), int_expr(s["max"], False)))
        elif k in ("str", "choice"):
            lo = s.get("min") if k == "str" else None
            hi = s.get("max") if k == "str" else None
            self.lines.append("let (%s, %s) = schema.new_string(heap, s, %s, %s);" % (
                t, v, "0" if lo is None else str(lo), int_expr(hi, False)))
        elif k == "array":
            item = self.node(s["item"])
            self.lines.append("let (%s, %s) = schema.new_array(heap, s, %s, %s, %s);" % (
                t, v, item, "0" if s["min"] is None else str(s["min"]), int_expr(s["max"], False)))
        elif k == "object":
            kids = []
            for name, sub, required in s["fields"]:
                kid = self.node(sub)
                kids.append((name, kid, required))
            self.lines.append("let (%s, %s) = schema.new_object(heap, s, %s);" % (
                t, v, "true" if s["strict"] else "false"))
            self.lines.append("s = %s;" % t)
            for name, kid, required in kids:
                self.lines.append("s = schema.add_field(heap, s, %s, %s, %s, %s);" % (
                    v, lex_str(name), kid, "true" if required else "false"))
            if s["nullable"]:
                self.lines.append("s = schema.make_nullable(s, %s);" % v)
            return v
        else:
            raise AssertionError(k)
        self.lines.append("s = %s;" % t)
        if k == "str" and s.get("nul"):
            self.lines.append("s = schema.forbid_nul(s, %s);" % v)
        if k == "choice":
            for value in s["values"]:
                self.lines.append("s = schema.add_choice(heap, s, %s, %s);" % (v, lex_str(value)))
        if s["nullable"]:
            self.lines.append("s = schema.make_nullable(s, %s);" % v)
        return v


def case_source(index, s, doc_text):
    e = Emit()
    root = e.node(s)
    body = "\n    ".join(e.lines)
    return f"""fn case_{index}[&h, &i](heap: &!h Heap, io: &!i Io) -> [heap, io_write] int {{
    var s = schema.empty(heap);
    {body}
    borrow s as &sr in {{
        report(heap, io, sr, {root}, {lex_str(doc_text)}, {index});
    }}
    schema.drop(heap, s);
    return 0;
}}
"""


PRELUDE = """import std.buffer;
import std.io;
import std.json;
import schema;

fn report[&h, &i, &s, &b](heap: &!h Heap, io: &!i Io, sc: &s schema.Schema, root: int, body: &b [byte], index: int) -> [heap, io_write] int {
    let tape = box_slice(heap, json.tape_len(body), 0);
    let slots = box_slice(heap, schema.slot_count(sc) + 1, 0);
    let errs = box_slice(heap, schema.errors_len(64), 0);
    var line = buffer.append(heap, buffer.empty(heap, 64), "C ");
    line = buffer.push_nat(heap, line, index);
    line = buffer.push(heap, line, byte_of(32));
    borrow mut tape as &!tw in {
        let t = contents(tw);
        json.parse(body, t);
        borrow mut slots as &!sw in {
            borrow mut errs as &!ew in {
                let e = contents(ew);
                let n = schema.validate(sc, root, body, t, contents(sw), e);
                line = buffer.push_nat(heap, line, n);
                line = buffer.push(heap, line, byte_of(10));
                line = buffer.append(heap, line, "S ");
                let doc = schema.json_schema(heap, sc, root);
                borrow doc as &db in {
                    line = buffer.append(heap, line, buffer.bytes(db));
                }
                buffer.drop(heap, doc);
                line = buffer.push(heap, line, byte_of(10));
                var k = 0;
                while k < schema.errors_stored(e) {
                    line = buffer.append(heap, line, "E ");
                    line = buffer.append(heap, line, schema.code_name(schema.error_code(e, k)));
                    line = buffer.push(heap, line, byte_of(32));
                    let p = schema.pointer(heap, sc, body, t, e, k);
                    borrow p as &pb in {
                        line = buffer.append(heap, line, buffer.bytes(pb));
                    }
                    buffer.drop(heap, p);
                    line = buffer.push(heap, line, byte_of(10));
                    k = k + 1;
                }
            }
        }
    }
    borrow line as &lb in {
        io.write_all(io, buffer.bytes(lb));
    }
    buffer.drop(heap, line);
    unbox_slice(heap, errs);
    unbox_slice(heap, slots);
    unbox_slice(heap, tape);
    return 0;
}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--lex-sys", default=os.environ.get("LEX_SYS", "lex-sys"))
    args = ap.parse_args()

    r = random.Random(args.seed)
    gen = Gen(r)
    ref = Ref()
    cases = []
    for index in range(args.cases):
        s = gen.schema()
        doc = valid_value(r, s)
        if r.random() < 0.6:
            doc = corrupt(r, s, doc)
        text = json.dumps(doc, ensure_ascii=r.random() < 0.7, separators=(",", ":"))
        parsed = json.loads(text)
        cases.append((s, text, ref.errors(json_schema(s), parsed)))

    src = PRELUDE + "\n".join(case_source(i, s, t) for i, (s, t, _) in enumerate(cases))
    src += "\nfn main(world: World) -> [] int {\n    let Split { io, ffi, fs, heap, args } = split(world);\n"
    src += "    release(ffi); release(fs); release(args);\n    borrow mut heap as &!h in {\n        borrow mut io as &!i in {\n"
    src += "".join("            case_%d(h, i);\n" % i for i in range(len(cases)))
    src += "        }\n    }\n    release(io);\n    release(heap);\n    return 0;\n}\n"

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "driver.ls")
        with open(path, "w") as f:
            f.write(src)
        run = subprocess.run([args.lex_sys, "run", path, SRC, "--std"], capture_output=True)
    if run.returncode != 0:
        sys.stderr.write(run.stderr.decode(errors="replace"))
        sys.stderr.write("the generated program did not run (exit %d)\n" % run.returncode)
        return 2

    got = {}
    generated = {}
    cur = None
    for line in run.stdout.decode("utf-8").split("\n"):
        if line.startswith("C "):
            _, idx, n = line.split(" ")
            cur = int(idx)
            got[cur] = [int(n), set()]
        elif line.startswith("S "):
            generated[cur] = line[2:]
        elif line.startswith("E "):
            _, code, pointer = line.split(" ", 2)
            got[cur][1].add((pointer, code))

    bad = 0
    interesting = {"valid": 0, "invalid": 0}
    for index, (s, text, (count, errs)) in enumerate(cases):
        interesting["invalid" if count else "valid"] += 1
        lex_count, lex_errs = got.get(index, [None, None])
        # The schema the library *generates* must be the one the generator meant,
        # and must give the reference the same verdict the library's own
        # validator gave: one declaration, two uses (`docs/design.md` §1).
        built = json_schema(s)
        made = json.loads(generated[index]) if index in generated else None
        from_made = ref.errors(made, json.loads(text)) if made is not None else None
        if made != built or from_made != (count, errs):
            bad += 1
            if bad <= 5:
                print("GENERATED SCHEMA DISAGREES case %d\n  built:     %s\n  generated: %s\n  doc: %s"
                      % (index, json.dumps(built), generated.get(index), text))
        if lex_count != count or lex_errs != errs:
            bad += 1
            if bad <= 5:
                print("DISAGREE case %d\n  document: %s\n  schema:   %s\n  reference: %d %s\n  lex-sys:   %s %s"
                      % (index, text, json.dumps(json_schema(s)), count, sorted(errs), lex_count,
                         sorted(lex_errs) if lex_errs is not None else None))
    print("%d cases (%d valid, %d invalid): %s" % (
        len(cases), interesting["valid"], interesting["invalid"],
        "all agree" if not bad else "%d DISAGREE" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
