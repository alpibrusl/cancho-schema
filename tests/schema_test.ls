import std.buffer;
import std.bytes;
import std.json;
import std.test;
import schema;

// What validation says about `body`, as the problem document it would answer
// with (or `ok`): compact, deterministic, and exercises the error list, the
// pointers and the messages together.
fn verdict[&h, &s, &b](heap: &!h Heap, sc: &s schema.Schema, root: int, body: &b [byte], room: int) -> [heap] buffer.Buffer {
    let tape = box_slice(heap, json.tape_len(body), 0);
    let slots = box_slice(heap, schema.slot_count(sc) + 1, 0);
    let errs = box_slice(heap, schema.errors_len(room), 0);
    var out = buffer.empty(heap, 64);
    borrow mut tape as &!tw in {
        let t = contents(tw);
        let nodes = json.parse(body, t);
        test.assert(nodes > 0);
        borrow mut slots as &!sw in {
            borrow mut errs as &!ew in {
                let e = contents(ew);
                let n = schema.validate(sc, root, body, t, contents(sw), e);
                if n == 0 {
                    out = buffer.append(heap, out, "ok");
                } else {
                    buffer.drop(heap, out);
                    out = schema.problem(heap, sc, body, t, e, 422, "Unprocessable Content");
                }
            }
        }
    }
    unbox_slice(heap, errs);
    unbox_slice(heap, slots);
    unbox_slice(heap, tape);
    return out;
}

fn says[&h, &s, &b, &w](heap: &!h Heap, sc: &s schema.Schema, root: int, body: &b [byte], room: int, want: &w [byte]) -> [heap] int {
    let got = verdict(heap, sc, root, body, room);
    borrow got as &g in {
        test.assert(bytes.equal(buffer.bytes(g), want));
    }
    buffer.drop(heap, got);
    return 0;
}

// {"name": string 1..8, "age"?: int 0..150, "tags"?: [string] up to 2 items}
fn user[&h](heap: &!h Heap) -> [heap] (schema.Schema, int) {
    var s = schema.empty(heap);
    let (s1, name) = schema.new_string(heap, s, 1, 8);
    let (s2, age) = schema.new_int(heap, s1, 0, 150);
    let (s3, tag) = schema.new_string(heap, s2, 0, schema.int_max());
    let (s4, tags) = schema.new_array(heap, s3, tag, 0, 2);
    let (s5, obj) = schema.new_object(heap, s4, true);
    s = schema.add_field(heap, s5, obj, "name", name, true);
    s = schema.add_field(heap, s, obj, "age", age, false);
    s = schema.add_field(heap, s, obj, "tags", tags, false);
    return (s, obj);
}

fn test_a_valid_body_is_ok[&h](heap: &!h Heap) -> [heap] int {
    let (s, obj) = user(heap);
    borrow s as &sr in {
        says(heap, sr, obj, "{\"name\":\"ada\"}", 4, "ok");
        says(heap, sr, obj, "{\"name\":\"ada\",\"age\":36,\"tags\":[\"a\",\"b\"]}", 4, "ok");
        // Key order does not matter.
        says(heap, sr, obj, "{\"tags\":[],\"age\":0,\"name\":\"x\"}", 4, "ok");
        test.assert_eq(schema.slot_count(sr), 3);
    }
    schema.drop(heap, s);
    return 0;
}

fn test_every_code_has_its_pointer_and_message[&h](heap: &!h Heap) -> [heap] int {
    let (s, obj) = user(heap);
    borrow s as &sr in {
        says(heap, sr, obj, "[]", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}");
        says(heap, sr, obj, "{}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/name\",\"code\":\"required\",\"detail\":\"is required\"}]}");
        says(heap, sr, obj, "{\"name\":\"ada\",\"nick\":1}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/nick\",\"code\":\"unknown\",\"detail\":\"is not a known field\"}]}");
        says(heap, sr, obj, "{\"name\":\"ada\",\"age\":-1}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/age\",\"code\":\"minimum\",\"detail\":\"is below the minimum\"}]}");
        says(heap, sr, obj, "{\"name\":\"ada\",\"age\":151}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/age\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"}]}");
        says(heap, sr, obj, "{\"name\":\"\"}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/name\",\"code\":\"min_length\",\"detail\":\"is too short\"}]}");
        says(heap, sr, obj, "{\"name\":\"abcdefghi\"}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/name\",\"code\":\"max_length\",\"detail\":\"is too long\"}]}");
        says(heap, sr, obj, "{\"name\":\"ada\",\"tags\":[\"a\",\"b\",\"c\"]}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/tags\",\"code\":\"max_items\",\"detail\":\"has too many items\"}]}");
        // The pointer reaches into an array.
        says(heap, sr, obj, "{\"name\":\"ada\",\"tags\":[\"a\",1]}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/tags/1\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

// Every error, not the first.
fn test_errors_accumulate_and_overflow_is_counted_not_stored[&h](heap: &!h Heap) -> [heap] int {
    let (s, obj) = user(heap);
    borrow s as &sr in {
        let body = "{\"age\":500,\"tags\":[7]}";
        // The order is the schema's (name, age, tags), so `required` first.
        let ordered = "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":3,\"errors\":[{\"pointer\":\"/name\",\"code\":\"required\",\"detail\":\"is required\"},{\"pointer\":\"/age\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"},{\"pointer\":\"/tags/0\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}";
        says(heap, sr, obj, body, 8, ordered);
        // Room for two: the third is counted (`count`:3) and not listed.
        says(heap, sr, obj, body, 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":3,\"errors\":[{\"pointer\":\"/name\",\"code\":\"required\",\"detail\":\"is required\"},{\"pointer\":\"/age\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

fn test_a_slot_holds_the_tape_node_of_the_field[&h](heap: &!h Heap) -> [heap] int {
    let (s, obj) = user(heap);
    let body = "{\"name\":\"ada\",\"age\":36}";
    let tape = box_slice(heap, json.tape_len(body), 0);
    let slots = box_slice(heap, 3, 0);
    let errs = box_slice(heap, schema.errors_len(4), 0);
    borrow mut tape as &!tw in {
        let t = contents(tw);
        json.parse(body, t);
        borrow mut slots as &!sw in {
            borrow mut errs as &!ew in {
                borrow s as &sr in {
                    test.assert_eq(schema.validate(sr, obj, body, t, contents(sw), contents(ew)), 0);
                }
                let sl = contents(sw);
                // name is the first value, age the second; tags is absent.
                test.assert(json.string_equals(body, t, sl[0], "ada"));
                test.assert_eq(json.to_int(body, t, sl[1]), 36);
                test.assert_eq(sl[2], 0 - 1);
            }
        }
    }
    unbox_slice(heap, errs);
    unbox_slice(heap, slots);
    unbox_slice(heap, tape);
    schema.drop(heap, s);
    return 0;
}

fn test_integers_are_not_coerced_and_do_not_wrap[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, n) = schema.new_int(heap, s, schema.int_min(), schema.int_max());
    s = s1;
    borrow s as &sr in {
        says(heap, sr, n, "7", 2, "ok");
        says(heap, sr, n, "-9223372036854775808", 2, "ok");
        says(heap, sr, n, "9223372036854775807", 2, "ok");
        // Not an integer: a string, a float -- `1.0` included -- a boolean.
        says(heap, sr, n, "\"7\"", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}");
        says(heap, sr, n, "true", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}");
        // Whole numbers written as floats are integers, as in JSON Schema: a client
        // that serializes a float sends `150.0`.
        says(heap, sr, n, "1.0", 2, "ok");
        says(heap, sr, n, "-0.0", 2, "ok");
        says(heap, sr, n, "1.5e2", 2, "ok");
        says(heap, sr, n, "1E3", 2, "ok");
        says(heap, sr, n, "9.007199254740993e15", 2, "ok");
        // ... and a fraction is not.
        says(heap, sr, n, "1.5", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}");
        says(heap, sr, n, "1e-1", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}");
        // Whole, and beyond an `int`: `range`, whichever way it is written.
        says(heap, sr, n, "1e30", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"range\",\"detail\":\"is outside the range of an integer\"}]}");
        says(heap, sr, n, "-1e30", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"range\",\"detail\":\"is outside the range of an integer\"}]}");
        // Too big for an int: its own error, not a wrap.
        says(heap, sr, n, "9223372036854775808", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"range\",\"detail\":\"is outside the range of an integer\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

fn test_null_only_where_it_was_allowed[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, a) = schema.new_string(heap, s, 0, 4);
    let (s2, b) = schema.new_string(heap, s1, 0, 4);
    s = schema.make_nullable(s2, b);
    let (s3, obj) = schema.new_object(heap, s, true);
    s = schema.add_field(heap, s3, obj, "a", a, true);
    s = schema.add_field(heap, s, obj, "b", b, true);
    borrow s as &sr in {
        says(heap, sr, obj, "{\"a\":\"x\",\"b\":null}", 4, "ok");
        says(heap, sr, obj, "{\"a\":null,\"b\":null}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/a\",\"code\":\"type\",\"detail\":\"has the wrong type\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

fn test_choices_compare_decoded_text[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, colour) = schema.new_string(heap, s, 0, schema.int_max());
    s = schema.add_choice(heap, s1, colour, "red");
    s = schema.add_choice(heap, s, colour, "green");
    s = schema.add_choice(heap, s, colour, "blue");
    borrow s as &sr in {
        says(heap, sr, colour, "\"red\"", 2, "ok");
        says(heap, sr, colour, "\"blue\"", 2, "ok");
        // An escaped spelling of a member is the member.
        says(heap, sr, colour, "\"\\u0072ed\"", 2, "ok");
        says(heap, sr, colour, "\"pink\"", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"choice\",\"detail\":\"is not one of the allowed values\"}]}");
        says(heap, sr, colour, "\"Red\"", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"choice\",\"detail\":\"is not one of the allowed values\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

// The first of a duplicate key wins, as `json.get` reads it, so the validator
// and the reader agree on which value a field has.
fn test_the_first_duplicate_key_is_the_one_validated[&h](heap: &!h Heap) -> [heap] int {
    let (s, obj) = user(heap);
    borrow s as &sr in {
        says(heap, sr, obj, "{\"name\":\"ada\",\"age\":1,\"age\":999}", 4, "ok");
        says(heap, sr, obj, "{\"name\":\"ada\",\"age\":999,\"age\":1}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/age\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

fn test_a_lenient_object_ignores_unknown_keys[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, n) = schema.new_int(heap, s, 0, 9);
    let (s2, obj) = schema.new_object(heap, s1, false);
    s = schema.add_field(heap, s2, obj, "n", n, true);
    borrow s as &sr in {
        says(heap, sr, obj, "{\"n\":1,\"extra\":[1,2,{\"deep\":true}]}", 4, "ok");
    }
    schema.drop(heap, s);
    return 0;
}

// A key with `/` or `~` in it is escaped in the pointer (RFC 6901 §3), and a
// key that was written with an escape is decoded first.
fn test_pointers_escape_their_segments[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, n) = schema.new_int(heap, s, 0, 9);
    let (s2, obj) = schema.new_object(heap, s1, true);
    s = schema.add_field(heap, s2, obj, "a/b", n, true);
    s = schema.add_field(heap, s, obj, "c~d", n, true);
    borrow s as &sr in {
        says(heap, sr, obj, "{\"a/b\":99,\"c~d\":1}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/a~1b\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"}]}");
        says(heap, sr, obj, "{\"a/b\":1,\"c~d\":99}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/c~0d\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"}]}");
        // The same key spelled with an escape (`\u002f` is `/`) is the same key.
        says(heap, sr, obj, "{\"a\\u002fb\":99,\"c~d\":1}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/a~1b\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"}]}");
        // A missing field is named in the pointer, escaped like any other segment.
        says(heap, sr, obj, "{\"a/b\":1}", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"/c~0d\",\"code\":\"required\",\"detail\":\"is required\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

fn test_arrays_of_objects_point_at_the_element[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, n) = schema.new_int(heap, s, 0, 9);
    let (s2, item) = schema.new_object(heap, s1, true);
    s = schema.add_field(heap, s2, item, "n", n, true);
    let (s3, list) = schema.new_array(heap, s, item, 1, 5);
    s = s3;
    borrow s as &sr in {
        says(heap, sr, list, "[{\"n\":1},{\"n\":2}]", 4, "ok");
        says(heap, sr, list, "[]", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"min_items\",\"detail\":\"has too few items\"}]}");
        says(heap, sr, list, "[{\"n\":1},{\"n\":20},{}]", 4, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":2,\"errors\":[{\"pointer\":\"/1/n\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"},{\"pointer\":\"/2/n\",\"code\":\"required\",\"detail\":\"is required\"}]}");
    }
    schema.drop(heap, s);
    return 0;
}

// Fields reached through an array are not recorded: one field, many values.
fn test_fields_under_an_array_leave_their_slots_unset[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, n) = schema.new_int(heap, s, 0, 9);
    let (s2, item) = schema.new_object(heap, s1, true);
    s = schema.add_field(heap, s2, item, "n", n, true);
    let (s3, list) = schema.new_array(heap, s, item, 0, 5);
    s = s3;
    let body = "[{\"n\":1},{\"n\":2}]";
    let tape = box_slice(heap, json.tape_len(body), 0);
    let slots = box_slice(heap, 1, 5);
    let errs = box_slice(heap, schema.errors_len(2), 0);
    borrow mut tape as &!tw in {
        let t = contents(tw);
        json.parse(body, t);
        borrow mut slots as &!sw in {
            borrow mut errs as &!ew in {
                borrow s as &sr in {
                    test.assert_eq(schema.validate(sr, list, body, t, contents(sw), contents(ew)), 0);
                }
                // `validate` clears the slots first (they were 5), and nothing wrote one.
                test.assert_eq(contents(sw)[0], 0 - 1);
            }
        }
    }
    unbox_slice(heap, errs);
    unbox_slice(heap, slots);
    unbox_slice(heap, tape);
    schema.drop(heap, s);
    return 0;
}

// A hostile body cannot make the error list large: five thousand wrong elements
// are five thousand errors counted, four stored.
fn test_a_body_with_thousands_of_errors_is_counted_not_stored[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, n) = schema.new_int(heap, s, 0, 9);
    let (s2, list) = schema.new_array(heap, s1, n, 0, schema.int_max());
    s = s2;
    var body = buffer.append(heap, buffer.empty(heap, 16), "[");
    var i = 0;
    while i < 5000 {
        if i > 0 {
            body = buffer.push(heap, body, byte_of(44));
        }
        body = buffer.append(heap, body, "99");
        i = i + 1;
    }
    body = buffer.push(heap, body, byte_of(93));
    borrow body as &bb in {
        let src = buffer.bytes(bb);
        let tape = box_slice(heap, json.tape_len(src), 0);
        let slots = box_slice(heap, 1, 0);
        let errs = box_slice(heap, schema.errors_len(4), 0);
        borrow mut tape as &!tw in {
            let t = contents(tw);
            test.assert(json.parse(src, t) > 0);
            borrow mut slots as &!sw in {
                borrow mut errs as &!ew in {
                    borrow s as &sr in {
                        let e = contents(ew);
                        test.assert_eq(schema.validate(sr, list, src, t, contents(sw), e), 5000);
                        test.assert_eq(schema.error_count(e), 5000);
                        test.assert_eq(schema.errors_stored(e), 4);
                    }
                }
            }
        }
        unbox_slice(heap, errs);
        unbox_slice(heap, slots);
        unbox_slice(heap, tape);
    }
    buffer.drop(heap, body);
    schema.drop(heap, s);
    return 0;
}

fn schema_text[&h, &s](heap: &!h Heap, sc: &s schema.Schema, root: int, want: &static [byte]) -> [heap] int {
    let got = schema.json_schema(heap, sc, root);
    borrow got as &g in {
        test.assert(bytes.equal(buffer.bytes(g), want));
    }
    buffer.drop(heap, got);
    return 0;
}

fn test_json_schema_for_an_object[&h](heap: &!h Heap) -> [heap] int {
    let (s, obj) = user(heap);
    borrow s as &sr in {
        schema_text(heap, sr, obj, "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8,\"x-length-unit\":\"bytes\"},\"age\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":150},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"maxItems\":2}},\"required\":[\"name\"],\"additionalProperties\":false}");
    }
    schema.drop(heap, s);
    return 0;
}

fn test_json_schema_for_the_small_kinds[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, any) = schema.new_any(heap, s);
    let (s2, flag) = schema.new_bool(heap, s1);
    let (s3, num) = schema.new_number(heap, s2);
    let (s4, n) = schema.new_int(heap, s3, 0, schema.int_max());
    s = schema.make_nullable(s4, n);
    let (s5, colour) = schema.new_string(heap, s, 0, schema.int_max());
    s = schema.add_choice(heap, s5, colour, "red");
    s = schema.add_choice(heap, s, colour, "green");
    s = schema.make_nullable(s, colour);
    let (s6, plain) = schema.new_string(heap, s, 0, schema.int_max());
    let (s7, lenient) = schema.new_object(heap, s6, false);
    s = s7;
    borrow s as &sr in {
        schema_text(heap, sr, any, "{}");
        schema_text(heap, sr, flag, "{\"type\":\"boolean\"}");
        schema_text(heap, sr, num, "{\"type\":\"number\"}");
        schema_text(heap, sr, n, "{\"type\":[\"integer\",\"null\"],\"minimum\":0}");
        // `enum` constrains every type, so a nullable choice lists `null`.
        schema_text(heap, sr, colour, "{\"type\":[\"string\",\"null\"],\"enum\":[\"red\",\"green\",null]}");
        schema_text(heap, sr, plain, "{\"type\":\"string\"}");
        schema_text(heap, sr, lenient, "{\"type\":\"object\",\"properties\":{}}");
    }
    schema.drop(heap, s);
    return 0;
}

// Names and members are escaped, not spliced in.
fn test_json_schema_escapes_what_it_was_given[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, str) = schema.new_string(heap, s, 0, schema.int_max());
    s = schema.add_choice(heap, s1, str, "a\"b\\c");
    let (s2, obj) = schema.new_object(heap, s, true);
    s = schema.add_field(heap, s2, obj, "k\"ey", str, true);
    borrow s as &sr in {
        schema_text(heap, sr, obj, "{\"type\":\"object\",\"properties\":{\"k\\\"ey\":{\"type\":\"string\",\"enum\":[\"a\\\"b\\\\c\"]}},\"required\":[\"k\\\"ey\"],\"additionalProperties\":false}");
    }
    schema.drop(heap, s);
    return 0;
}

// A float-spelled integer meets the bounds like any other, and `to_int` reads it.
fn test_a_whole_float_is_checked_against_the_bounds_and_read_as_an_integer[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, age) = schema.new_int(heap, s, 0, 150);
    s = s1;
    borrow s as &sr in {
        says(heap, sr, age, "150.0", 2, "ok");
        says(heap, sr, age, "0.0", 2, "ok");
        says(heap, sr, age, "151.0", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"maximum\",\"detail\":\"is above the maximum\"}]}");
        says(heap, sr, age, "-1.0", 2, "{\"type\":\"about:blank\",\"title\":\"Unprocessable Content\",\"status\":422,\"count\":1,\"errors\":[{\"pointer\":\"\",\"code\":\"minimum\",\"detail\":\"is below the minimum\"}]}");
    }
    schema.drop(heap, s);
    let body = "[150.0, 36, 1e2, 7.5, \"x\"]";
    let tape = box_slice(heap, json.tape_len(body), 0);
    borrow mut tape as &!tw in {
        let t = contents(tw);
        json.parse(body, t);
        test.assert_eq(schema.to_int(body, t, json.at(t, 0, 0)), 150);
        test.assert_eq(schema.to_int(body, t, json.at(t, 0, 1)), 36);
        test.assert_eq(schema.to_int(body, t, json.at(t, 0, 2)), 100);
        // Not an integer: 0, which `validate` would have refused first.
        test.assert_eq(schema.to_int(body, t, json.at(t, 0, 3)), 0);
        test.assert_eq(schema.to_int(body, t, json.at(t, 0, 4)), 0);
    }
    unbox_slice(heap, tape);
    return 0;
}
