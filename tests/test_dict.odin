package odinarrow_tests

import "core:testing"
import oa "../src"

mk_str_arr :: proc(vals: []string) -> oa.Array {
	b := oa.string_builder_make(len(vals))
	defer oa.string_builder_destroy(&b)
	for v in vals { oa.string_builder_append(&b, v) }
	arr, _ := oa.string_builder_finish(&b)
	return arr
}

@(test)
test_dict_encode_decode :: proc(t: ^testing.T) {
	vals := []string{"red", "green", "red", "blue", "green", "red"}
	src := mk_str_arr(vals)
	defer oa.array_free(&src)

	d := oa.str_dict_encode(&src)
	defer oa.str_dict_free(&d)

	testing.expect_value(t, d.length, len(vals))
	testing.expect_value(t, oa.n_dict(&d), 3)   // red, green, blue

	for v, i in vals {
		testing.expect_value(t, oa.str_dict_get(&d, i), v)
	}

	dec, _ := oa.str_dict_decode(&d)
	defer oa.array_free(&dec)
	testing.expect_value(t, dec.length, len(vals))
	for v, i in vals {
		testing.expect_value(t, oa.array_get_string(&dec, i), v)
	}
}

@(test)
test_dict_numeric :: proc(t: ^testing.T) {
	// logical: 5,2,5,9,2,5,9  → dict {5,2,9}, codes by first-seen
	vb := oa.builder_make(f64, 7)
	defer oa.builder_destroy(&vb)
	vals := []f64{5, 2, 5, 9, 2, 5, 9}
	for v in vals { oa.builder_append(&vb, v) }
	src, _ := oa.builder_finish(&vb)
	defer oa.array_free(&src)

	d := oa.dict_encode(&src, f64)
	defer oa.dict_free(&d)
	testing.expect_value(t, d.length, 7)
	testing.expect_value(t, oa.dict_size(&d), 3)

	for v, i in vals { testing.expect(t, approx_eq(oa.dict_get(&d, i), v, 1e-9)) }

	// sum / min_max via the encoded kernels
	testing.expect(t, approx_eq(oa.dict_sum(&d), 5+2+5+9+2+5+9, 1e-9))
	lo, hi, ok := oa.dict_min_max(&d)
	testing.expect(t, ok)
	testing.expect(t, approx_eq(lo, 2, 1e-9))
	testing.expect(t, approx_eq(hi, 9, 1e-9))

	// value_counts: 5×3, 2×2, 9×2
	counts := oa.dict_value_counts(&d)
	defer delete(counts)
	total := i64(0)
	for c in counts { total += c }
	testing.expect_value(t, total, i64(7))

	// decode round-trip
	dec, _ := oa.dict_decode(&d)
	defer oa.array_free(&dec)
	for v, i in vals { testing.expect(t, approx_eq(oa.array_get(&dec, i, f64), v, 1e-9)) }
}

@(test)
test_dict_try_get_with_nulls :: proc(t: ^testing.T) {
	// Str_Dict_Array with nulls
	sb := oa.string_builder_make(4)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append(&sb, "alpha")
	oa.string_builder_append_null(&sb)
	oa.string_builder_append(&sb, "beta")
	oa.string_builder_append_null(&sb)
	s_arr, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&s_arr)

	sd := oa.str_dict_encode(&s_arr)
	defer oa.str_dict_free(&sd)

	testing.expect(t, !oa.str_dict_is_null(&sd, 0))
	testing.expect(t, oa.str_dict_is_null(&sd, 1))
	v0, ok0 := oa.str_dict_try_get(&sd, 0)
	testing.expect(t, ok0)
	testing.expect_value(t, v0, "alpha")
	testing.expect_value(t, oa.str_dict_get(&sd, 0), "alpha")
	v1, ok1 := oa.str_dict_try_get(&sd, 1)
	testing.expect(t, !ok1)
	testing.expect_value(t, v1, "")
	v2, ok2 := oa.str_dict_try_get(&sd, 2)
	testing.expect(t, ok2)
	testing.expect_value(t, v2, "beta")

	// Dict_Array(i32) with nulls
	nb := oa.builder_make(i32, 4)
	defer oa.builder_destroy(&nb)
	oa.builder_append(&nb, 10)
	oa.builder_append_null(&nb)
	oa.builder_append(&nb, 20)
	oa.builder_append_null(&nb)
	n_arr, _ := oa.builder_finish(&nb)
	defer oa.array_free(&n_arr)

	nd := oa.dict_encode(&n_arr, i32)
	defer oa.dict_free(&nd)

	testing.expect(t, !oa.dict_is_null(&nd, 0))
	testing.expect(t, oa.dict_is_null(&nd, 1))
	nv0, nok0 := oa.dict_try_get(&nd, 0)
	testing.expect(t, nok0)
	testing.expect_value(t, nv0, i32(10))
	testing.expect_value(t, oa.dict_get(&nd, 0), i32(10))
	nv1, nok1 := oa.dict_try_get(&nd, 1)
	testing.expect(t, !nok1)
	testing.expect_value(t, nv1, i32(0))
	nv2, nok2 := oa.dict_try_get(&nd, 2)
	testing.expect(t, nok2)
	testing.expect_value(t, nv2, i32(20))
}
