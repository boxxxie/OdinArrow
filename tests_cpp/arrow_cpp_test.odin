// Tests that link against Apache Arrow C++ via libarrow_capi.so.
//
// Purpose: verify that our Odin Array buffer layout is binary-compatible with
// Apache Arrow's C++ layout — i.e., we can hand raw buffer pointers to Arrow
// C++ and get identical results to our own compute kernels.
//
// Build with: make test-cpp
// (requires lib/libarrow_capi.so — built by make build-arrow-capi)

package skadi_tests_cpp

import "core:testing"
import oa "../skadi"

// ── FFI declarations ──────────────────────────────────────────────────────────

when ODIN_OS == .Linux {
    foreign import libarrow_capi "../lib/libarrow_capi.so"
}

Arrow_Scalar :: struct {
    value:       f64,
    valid_count: i64,
}

@(default_calling_convention = "c")
foreign libarrow_capi {
    arrow_capi_sum_i32  :: proc(validity: [^]u8, data: [^]i32, n: i64) -> Arrow_Scalar ---
    arrow_capi_sum_f64  :: proc(validity: [^]u8, data: [^]f64, n: i64) -> Arrow_Scalar ---
    arrow_capi_min_i32  :: proc(validity: [^]u8, data: [^]i32, n: i64) -> Arrow_Scalar ---
    arrow_capi_max_i32  :: proc(validity: [^]u8, data: [^]i32, n: i64) -> Arrow_Scalar ---
    arrow_capi_filter_i32 :: proc(
        src_validity: [^]u8, src_data: [^]i32,
        mask_validity: [^]u8, mask_bits: [^]u8,
        n: i64,
    ) -> i64 ---
    arrow_capi_filter_i32_materialize :: proc(
        src_validity: [^]u8, src_data: [^]i32,
        mask_validity: [^]u8, mask_bits: [^]u8,
        n: i64,
        out_values: [^]i32,
        out_valid: [^]u8,
        out_cap: i64,
    ) -> i64 ---
    arrow_capi_string_scan :: proc(
        validity: [^]u8,
        offsets:  [^]i32,
        utf8_data: [^]u8,
        n: i64,
    ) -> i64 ---
}

// ── helpers ───────────────────────────────────────────────────────────────────

approx_eq_cpp :: proc(a, b, eps: f64) -> bool {
    d := a - b
    return d >= -eps && d <= eps
}

build_i32 :: proc(vals: []i32) -> oa.Array {
    b := oa.builder_make(i32, len(vals))
    defer oa.builder_destroy(&b)
    for v in vals { oa.builder_append(&b, v) }
    arr, _ := oa.builder_finish(&b)
    return arr
}

build_i32_with_nulls :: proc(vals: []i32, null_mask: []bool) -> oa.Array {
    b := oa.builder_make(i32, len(vals))
    defer oa.builder_destroy(&b)
    for is_null, i in null_mask {
        if is_null { oa.builder_append_null(&b) }
        else       { oa.builder_append(&b, vals[i]) }
    }
    arr, _ := oa.builder_finish(&b)
    return arr
}

// ── sum i32 ───────────────────────────────────────────────────────────────────

@(test)
test_arrow_cpp_sum_i32_matches :: proc(t: ^testing.T) {
    arr := build_i32([]i32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10})
    defer oa.array_free(&arr)

    our_sum, our_n := oa.compute_sum(&arr)

    cpp := arrow_capi_sum_i32(
        arr.buffers[0].data,
        cast([^]i32)arr.buffers[1].data,
        i64(arr.length))

    testing.expect(t, approx_eq_cpp(our_sum, cpp.value, 1e-9), "sum must match")
    testing.expect_value(t, i64(our_n), cpp.valid_count)
}

@(test)
test_arrow_cpp_sum_i32_with_nulls :: proc(t: ^testing.T) {
    vals      := []i32{10, 20, 30, 40, 50}
    null_mask := []bool{false, true, false, true, false}
    arr := build_i32_with_nulls(vals, null_mask)
    defer oa.array_free(&arr)

    our_sum, our_n := oa.compute_sum(&arr)

    cpp := arrow_capi_sum_i32(
        arr.buffers[0].data,
        cast([^]i32)arr.buffers[1].data,
        i64(arr.length))

    testing.expect(t, approx_eq_cpp(our_sum, cpp.value, 1e-9))
    testing.expect_value(t, i64(our_n), cpp.valid_count)
}

// ── sum f64 ───────────────────────────────────────────────────────────────────

@(test)
test_arrow_cpp_sum_f64_matches :: proc(t: ^testing.T) {
    b := oa.builder_make(f64, 5)
    defer oa.builder_destroy(&b)
    f64_vals := []f64{1.5, 2.5, 3.0, 4.0, 5.0}
    for v in f64_vals { oa.builder_append(&b, v) }
    arr, _ := oa.builder_finish(&b)
    defer oa.array_free(&arr)

    our_sum, _ := oa.compute_sum(&arr)
    cpp := arrow_capi_sum_f64(
        arr.buffers[0].data,
        cast([^]f64)arr.buffers[1].data,
        i64(arr.length))

    testing.expect(t, approx_eq_cpp(our_sum, cpp.value, 1e-9))
}

// ── min / max ─────────────────────────────────────────────────────────────────

@(test)
test_arrow_cpp_min_max_matches :: proc(t: ^testing.T) {
    arr := build_i32([]i32{7, 2, 9, 1, 5, 8, 3})
    defer oa.array_free(&arr)

    our_min, _ := oa.compute_min(&arr)
    our_max, _ := oa.compute_max(&arr)

    cpp_min := arrow_capi_min_i32(arr.buffers[0].data, cast([^]i32)arr.buffers[1].data, i64(arr.length))
    cpp_max := arrow_capi_max_i32(arr.buffers[0].data, cast([^]i32)arr.buffers[1].data, i64(arr.length))

    testing.expect(t, approx_eq_cpp(our_min, cpp_min.value, 1e-9), "min must match")
    testing.expect(t, approx_eq_cpp(our_max, cpp_max.value, 1e-9), "max must match")
}

@(test)
test_arrow_cpp_min_max_with_nulls :: proc(t: ^testing.T) {
    vals      := []i32{99, 1, 7, 50}
    null_mask := []bool{false, false, false, false}
    null_mask[0] = true // 99 is null → min should be 1
    arr := build_i32_with_nulls(vals, null_mask)
    defer oa.array_free(&arr)

    our_min, _ := oa.compute_min(&arr)
    cpp_min    := arrow_capi_min_i32(arr.buffers[0].data, cast([^]i32)arr.buffers[1].data, i64(arr.length))

    testing.expect(t, approx_eq_cpp(our_min, cpp_min.value, 1e-9), "min with null must match")
}

// ── filter ────────────────────────────────────────────────────────────────────

verify_filter_i32_parity :: proc(t: ^testing.T, src, mask: ^oa.Array, loc := #caller_location) {
    our_result, ferr := oa.compute_filter(src, mask)
    testing.expect_value(t, ferr, nil, loc = loc)
    defer oa.array_free(&our_result)

    cap := src.length
    cpp_vals  := make([]i32, max(cap, 1))
    cpp_valid := make([]u8,  max(cap, 1))
    defer delete(cpp_vals)
    defer delete(cpp_valid)

    cpp_count := arrow_capi_filter_i32_materialize(
        src.buffers[0].data,
        cast([^]i32)src.buffers[1].data,
        mask.buffers[0].data,
        mask.buffers[1].data,
        i64(src.length),
        raw_data(cpp_vals),
        raw_data(cpp_valid),
        i64(len(cpp_vals)))

    testing.expect_value(t, i64(our_result.length), cpp_count, loc = loc)
    if i64(our_result.length) != cpp_count {
        return
    }
    cpp_nulls := 0
    for i in 0 ..< our_result.length {
        want_valid := cpp_valid[i] != 0
        got_valid  := oa.array_is_valid(&our_result, i)
        if got_valid != want_valid {
            testing.expectf(t, false, "filter validity mismatch at %d: got=%v want=%v", i, got_valid, want_valid, loc = loc)
            return
        }
        if !want_valid {
            cpp_nulls += 1
        } else {
            got_v := oa.array_get(&our_result, i, i32)
            if got_v != cpp_vals[i] {
                testing.expectf(t, false, "filter value mismatch at %d: got=%d want=%d", i, got_v, cpp_vals[i], loc = loc)
                return
            }
        }
    }
    testing.expect_value(t, oa.array_null_count(&our_result), cpp_nulls, loc = loc)
}

@(test)
test_arrow_cpp_filter_count_matches :: proc(t: ^testing.T) {
    // Non-null source and mask
    src := build_i32([]i32{10, 20, 30, 40, 50})
    defer oa.array_free(&src)

    bm := oa.builder_make(bool, 5)
    defer oa.builder_destroy(&bm)
    mask_vals := []bool{true, false, true, false, true}
    for v in mask_vals {
        oa.builder_append(&bm, v)
    }
    mask, merr := oa.builder_finish(&bm)
    testing.expect_value(t, merr, nil)
    defer oa.array_free(&mask)

    verify_filter_i32_parity(t, &src, &mask)

    // Nullable source + nullable mask (null mask entries excluded, source nulls preserved)
    src_null := build_i32_with_nulls(
        []i32{10, 0, 30, 40, 0},
        []bool{false, true, false, false, true},
    )
    defer oa.array_free(&src_null)

    bm2 := oa.builder_make(bool, 5)
    defer oa.builder_destroy(&bm2)
    oa.builder_append(&bm2, true)
    oa.builder_append(&bm2, true)
    oa.builder_append_null(&bm2)
    oa.builder_append(&bm2, false)
    oa.builder_append(&bm2, true)
    mask_null, merr2 := oa.builder_finish(&bm2)
    testing.expect_value(t, merr2, nil)
    defer oa.array_free(&mask_null)

    verify_filter_i32_parity(t, &src_null, &mask_null)
}

@(test)
test_arrow_cpp_filter_large :: proc(t: ^testing.T) {
    n :: 100_000
    b := oa.builder_make(i32, n)
    defer oa.builder_destroy(&b)
    for i in 0..<n { oa.builder_append(&b, i32(i)) }
    arr, err := oa.builder_finish(&b)
    testing.expect_value(t, err, nil)
    defer oa.array_free(&arr)

    mb := oa.builder_make(bool, n)
    defer oa.builder_destroy(&mb)
    for i in 0..<n { oa.builder_append(&mb, i % 2 == 0) }
    mask, merr := oa.builder_finish(&mb)
    testing.expect_value(t, merr, nil)
    defer oa.array_free(&mask)

    verify_filter_i32_parity(t, &arr, &mask)
}

// ── string scan ───────────────────────────────────────────────────────────────

@(test)
test_arrow_cpp_string_scan_matches :: proc(t: ^testing.T) {
    // Build a string array using our Odin String_Builder
    sb := oa.string_builder_make(5)
    defer oa.string_builder_destroy(&sb)
    words := []string{"hello", "world", "odin", "arrow", "test"}
    for w in words {
        oa.string_builder_append(&sb, w)
    }
    arr, _ := oa.string_builder_finish(&sb)
    defer oa.array_free(&arr)

    // Our Odin scan: sum of string lengths
    our_total := 0
    for i in 0..<arr.length {
        our_total += len(oa.array_get_string(&arr, i))
    }

    // Arrow C++ scan via FFI — buffers[1]=offsets, buffers[2]=utf8 bytes
    cpp_total := arrow_capi_string_scan(
        arr.buffers[0].data,
        cast([^]i32)arr.buffers[1].data,
        arr.buffers[2].data,
        i64(arr.length))

    testing.expect_value(t, i64(our_total), cpp_total)
}

@(test)
test_arrow_cpp_string_scan_with_nulls :: proc(t: ^testing.T) {
    sb := oa.string_builder_make(4)
    defer oa.string_builder_destroy(&sb)
    oa.string_builder_append(&sb, "abc")
    oa.string_builder_append_null(&sb)
    oa.string_builder_append(&sb, "de")
    oa.string_builder_append_null(&sb)
    arr, _ := oa.string_builder_finish(&sb)
    defer oa.array_free(&arr)

    our_total := 0
    for i in 0..<arr.length {
        if oa.array_is_valid(&arr, i) {
            our_total += len(oa.array_get_string(&arr, i))
        }
    }

    cpp_total := arrow_capi_string_scan(
        arr.buffers[0].data,
        cast([^]i32)arr.buffers[1].data,
        arr.buffers[2].data,
        i64(arr.length))

    testing.expect_value(t, i64(our_total), cpp_total)
}

// ── large correctness test ────────────────────────────────────────────────────

@(test)
test_arrow_cpp_sum_large :: proc(t: ^testing.T) {
    n :: 500_000
    b := oa.builder_make(i32, n)
    defer oa.builder_destroy(&b)
    for i in 0..<n { oa.builder_append(&b, i32(i)) }
    arr, _ := oa.builder_finish(&b)
    defer oa.array_free(&arr)

    our_sum, _ := oa.compute_sum(&arr)
    cpp := arrow_capi_sum_i32(arr.buffers[0].data, cast([^]i32)arr.buffers[1].data, i64(arr.length))

    // Both should equal n*(n-1)/2 = 124_999_750_000
    expected := f64(n) * f64(n - 1) / 2.0
    testing.expect(t, approx_eq_cpp(our_sum,   expected, 1.0), "Odin sum must match arithmetic series")
    testing.expect(t, approx_eq_cpp(cpp.value, expected, 1.0), "Arrow C++ sum must match arithmetic series")
    testing.expect(t, approx_eq_cpp(our_sum, cpp.value, 1.0),  "Odin and Arrow C++ sums must agree")
}
