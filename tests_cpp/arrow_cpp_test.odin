// Tests that link against Apache Arrow C++ via libarrow_capi.so.
//
// Purpose: verify that our Odin Array buffer layout is binary-compatible with
// Apache Arrow's C++ layout — i.e., we can hand raw buffer pointers to Arrow
// C++ and get identical results to our own compute kernels.
//
// Build with: make test-cpp
// (requires lib/libarrow_capi.so — built by make build-arrow-capi)

package skadi_tests_cpp

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
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
    arrow_capi_sum_i64_slice  :: proc(validity: [^]u8, data: [^]i64, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_min_i64_slice  :: proc(validity: [^]u8, data: [^]i64, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_max_i64_slice  :: proc(validity: [^]u8, data: [^]i64, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_sum_u64_slice  :: proc(validity: [^]u8, data: [^]u64, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_min_u64_slice  :: proc(validity: [^]u8, data: [^]u64, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_max_u64_slice  :: proc(validity: [^]u8, data: [^]u64, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_sum_f32_slice  :: proc(validity: [^]u8, data: [^]f32, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_mean_f32_slice :: proc(validity: [^]u8, data: [^]f32, offset: i64, n: i64) -> Arrow_Scalar ---
    arrow_capi_bool_stats_slice :: proc(
        validity: [^]u8,
        bits: [^]u8,
        offset: i64,
        n: i64,
        out_true_count: ^i64,
        out_null_count: ^i64,
    ) -> c.int ---
    arrow_capi_binary_stats_slice :: proc(
        validity: [^]u8,
        offsets: [^]i32,
        data: [^]u8,
        total_elems: i64,
        data_bytes: i64,
        offset: i64,
        n: i64,
        out_valid_bytes: ^i64,
        out_null_count: ^i64,
    ) -> c.int ---
    arrow_capi_ipc_write_sample :: proc(path: cstring, is_stream: c.int) -> c.int ---
    arrow_capi_ipc_verify_roundtrip :: proc(
        path: cstring,
        is_stream: c.int,
        expected_rows: i64,
        expected_cols: i32,
        out_i64_sum: ^i64,
        out_bin_bytes: ^i64,
    ) -> c.int ---
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

// ── i64 / u64 / f32 / bool / binary sliced parity ─────────────────────────────

@(test)
test_arrow_cpp_i64_and_u64_slices_match :: proc(t: ^testing.T) {
    // 1. i64 non-null across offset=0, offset=8, and offset=3
    {
        vals := []i64{-5_000_000_000, -10, 0, 7, 4_000_000_003, 99, -123_456, 12, 34, 56, 78, -999}
        b := oa.builder_make(i64, len(vals))
        defer oa.builder_destroy(&b)
        for v in vals { oa.builder_append(&b, v) }
        full, err := oa.builder_finish(&b)
        testing.expect_value(t, err, nil)
        defer oa.array_free(&full)

        for off in ([]int{0, 8, 3}) {
            s := oa.array_slice(full, off, len(vals))
            our_sum, our_sn := oa.compute_sum(&s)
            our_min, our_mn := oa.compute_min(&s)
            our_max, our_xn := oa.compute_max(&s)

            cpp_sum := arrow_capi_sum_i64_slice(s.buffers[0].data, cast([^]i64)s.buffers[1].data, i64(s.offset), i64(s.length))
            cpp_min := arrow_capi_min_i64_slice(s.buffers[0].data, cast([^]i64)s.buffers[1].data, i64(s.offset), i64(s.length))
            cpp_max := arrow_capi_max_i64_slice(s.buffers[0].data, cast([^]i64)s.buffers[1].data, i64(s.offset), i64(s.length))

            testing.expect_value(t, i64(our_sn), cpp_sum.valid_count)
            testing.expect_value(t, i64(our_mn), cpp_min.valid_count)
            testing.expect_value(t, i64(our_xn), cpp_max.valid_count)
            testing.expect(t, approx_eq_cpp(our_sum, cpp_sum.value, 1e-3), "i64 non-null sum must match")
            testing.expect(t, approx_eq_cpp(our_min, cpp_min.value, 1e-3), "i64 non-null min must match")
            testing.expect(t, approx_eq_cpp(our_max, cpp_max.value, 1e-3), "i64 non-null max must match")
        }
    }

    // 2. i64 nullable across offset=0, offset=8, and offset=3
    {
        nb := oa.builder_make(i64, 13)
        defer oa.builder_destroy(&nb)
        for i in 0 ..< 13 {
            if i % 3 == 1 {
                oa.builder_append_null(&nb)
            } else {
                oa.builder_append(&nb, i64(i * 1_000_000_000 - 4_000_000_000))
            }
        }
        full, err := oa.builder_finish(&nb)
        testing.expect_value(t, err, nil)
        defer oa.array_free(&full)

        for off in ([]int{0, 8, 3}) {
            s := oa.array_slice(full, off, 12)
            our_sum, our_sn := oa.compute_sum(&s)
            our_min, our_mn := oa.compute_min(&s)
            our_max, our_xn := oa.compute_max(&s)

            cpp_sum := arrow_capi_sum_i64_slice(s.buffers[0].data, cast([^]i64)s.buffers[1].data, i64(s.offset), i64(s.length))
            cpp_min := arrow_capi_min_i64_slice(s.buffers[0].data, cast([^]i64)s.buffers[1].data, i64(s.offset), i64(s.length))
            cpp_max := arrow_capi_max_i64_slice(s.buffers[0].data, cast([^]i64)s.buffers[1].data, i64(s.offset), i64(s.length))

            testing.expect_value(t, i64(our_sn), cpp_sum.valid_count)
            testing.expect_value(t, i64(our_mn), cpp_min.valid_count)
            testing.expect_value(t, i64(our_xn), cpp_max.valid_count)
            testing.expect(t, approx_eq_cpp(our_sum, cpp_sum.value, 1e-3), "i64 nullable sum must match")
            testing.expect(t, approx_eq_cpp(our_min, cpp_min.value, 1e-3), "i64 nullable min must match")
            testing.expect(t, approx_eq_cpp(our_max, cpp_max.value, 1e-3), "i64 nullable max must match")
        }
    }

    // 3. u64 > max(u32) with nullable + offset=0, 8, 3
    {
        ub := oa.builder_make(u64, 12)
        defer oa.builder_destroy(&ub)
        for i in 0 ..< 12 {
            if i == 2 || i == 9 {
                oa.builder_append_null(&ub)
            } else {
                oa.builder_append(&ub, u64(5_000_000_000) + u64(i * 100_000))
            }
        }
        full, err := oa.builder_finish(&ub)
        testing.expect_value(t, err, nil)
        defer oa.array_free(&full)

        for off in ([]int{0, 8, 3}) {
            s := oa.array_slice(full, off, 12)
            our_sum, our_sn := oa.compute_sum(&s)
            our_min, our_mn := oa.compute_min(&s)
            our_max, our_xn := oa.compute_max(&s)

            cpp_sum := arrow_capi_sum_u64_slice(s.buffers[0].data, cast([^]u64)s.buffers[1].data, i64(s.offset), i64(s.length))
            cpp_min := arrow_capi_min_u64_slice(s.buffers[0].data, cast([^]u64)s.buffers[1].data, i64(s.offset), i64(s.length))
            cpp_max := arrow_capi_max_u64_slice(s.buffers[0].data, cast([^]u64)s.buffers[1].data, i64(s.offset), i64(s.length))

            testing.expect_value(t, i64(our_sn), cpp_sum.valid_count)
            testing.expect_value(t, i64(our_mn), cpp_min.valid_count)
            testing.expect_value(t, i64(our_xn), cpp_max.valid_count)
            testing.expect(t, approx_eq_cpp(our_sum, cpp_sum.value, 1.0), "u64 sum must match")
            testing.expect(t, approx_eq_cpp(our_min, cpp_min.value, 1.0), "u64 min must match")
            testing.expect(t, approx_eq_cpp(our_max, cpp_max.value, 1.0), "u64 max must match")
        }
    }
}

@(test)
test_arrow_cpp_f32_slices_match :: proc(t: ^testing.T) {
    // Non-null and nullable f32 across offset=0 and offset=5
    fb_nn := oa.builder_make(f32, 10)
    defer oa.builder_destroy(&fb_nn)
    fb_null := oa.builder_make(f32, 10)
    defer oa.builder_destroy(&fb_null)

    vals := []f32{1.5, -2.25, 0.0, 3.75, -8.5, 4.125, 0.5, -1.25, 10.0, 2.5}
    for v, i in vals {
        oa.builder_append(&fb_nn, v)
        if i == 1 || i == 6 || i == 8 {
            oa.builder_append_null(&fb_null)
        } else {
            oa.builder_append(&fb_null, v)
        }
    }

    arr_nn, err_nn := oa.builder_finish(&fb_nn)
    testing.expect_value(t, err_nn, nil)
    defer oa.array_free(&arr_nn)

    arr_null, err_null := oa.builder_finish(&fb_null)
    testing.expect_value(t, err_null, nil)
    defer oa.array_free(&arr_null)

    for full in ([]oa.Array{arr_nn, arr_null}) {
        for off in ([]int{0, 5}) {
            s := oa.array_slice(full, off, len(vals))
            our_sum, our_sn   := oa.compute_sum(&s)
            our_mean, our_mn  := oa.compute_mean(&s)

            cpp_sum  := arrow_capi_sum_f32_slice(s.buffers[0].data, cast([^]f32)s.buffers[1].data, i64(s.offset), i64(s.length))
            cpp_mean := arrow_capi_mean_f32_slice(s.buffers[0].data, cast([^]f32)s.buffers[1].data, i64(s.offset), i64(s.length))

            testing.expect_value(t, i64(our_sn), cpp_sum.valid_count)
            testing.expect_value(t, i64(our_mn), cpp_mean.valid_count)
            testing.expect(t, approx_eq_cpp(our_sum,  cpp_sum.value,  1e-4), "f32 sum must match")
            testing.expect(t, approx_eq_cpp(our_mean, cpp_mean.value, 1e-4), "f32 mean must match")
        }
    }
}

@(test)
test_arrow_cpp_bool_and_binary_slices_match :: proc(t: ^testing.T) {
    // 1. Bool_Type full and sliced (offset=3) validation + true/null count parity
    {
        bb := oa.builder_make(bool, 12)
        defer oa.builder_destroy(&bb)
        for i in 0 ..< 12 {
            if i == 2 || i == 5 || i == 10 {
                oa.builder_append_null(&bb)
            } else {
                oa.builder_append(&bb, i % 2 == 0)
            }
        }
        full, err := oa.builder_finish(&bb)
        testing.expect_value(t, err, nil)
        defer oa.array_free(&full)

        for rng in ([][2]int{{0, 12}, {3, 11}}) {
            s := oa.array_slice(full, rng[0], rng[1])
            our_trues := i64(0)
            for i in 0 ..< s.length {
                if v, ok := oa.array_try_get(&s, i, bool); ok && v {
                    our_trues += 1
                }
            }
            cpp_trues, cpp_nulls: i64
            valid := arrow_capi_bool_stats_slice(
                s.buffers[0].data,
                s.buffers[1].data,
                i64(s.offset),
                i64(s.length),
                &cpp_trues,
                &cpp_nulls,
            )
            testing.expect_value(t, valid, c.int(1))
            testing.expect_value(t, cpp_trues, our_trues)
            testing.expect_value(t, cpp_nulls, i64(oa.array_null_count(&s)))
        }
    }

    // 2. Binary_Type full and sliced (offset=3) validation + byte-length/null-count parity
    {
        bb := oa.binary_builder_make(7)
        defer oa.binary_builder_destroy(&bb)
        oa.binary_builder_append(&bb, []u8{0x01, 0x02})
        oa.binary_builder_append_null(&bb)
        oa.binary_builder_append(&bb, []u8{0x00, 0xFF, 0x10})
        oa.binary_builder_append(&bb, []u8{0xAA, 0xBB})
        oa.binary_builder_append(&bb, []u8{})
        oa.binary_builder_append_null(&bb)
        oa.binary_builder_append(&bb, []u8{0xDE, 0xAD, 0xBE, 0xEF})
        full, err := oa.binary_builder_finish(&bb)
        testing.expect_value(t, err, nil)
        defer oa.array_free(&full)

        total_elems := i64(full.buffers[1].size / size_of(i32) - 1)
        data_bytes  := i64(full.buffers[2].size)

        for rng in ([][2]int{{0, 7}, {3, 7}}) {
            s := oa.array_slice(full, rng[0], rng[1])
            our_bytes := i64(0)
            for i in 0 ..< s.length {
                if oa.array_is_valid(&s, i) {
                    our_bytes += i64(len(oa.array_get_binary(&s, i)))
                }
            }
            cpp_bytes, cpp_nulls: i64
            valid := arrow_capi_binary_stats_slice(
                s.buffers[0].data,
                cast([^]i32)s.buffers[1].data,
                s.buffers[2].data,
                total_elems,
                data_bytes,
                i64(s.offset),
                i64(s.length),
                &cpp_bytes,
                &cpp_nulls,
            )
            testing.expect_value(t, valid, c.int(1))
            testing.expect_value(t, cpp_bytes, our_bytes)
            testing.expect_value(t, cpp_nulls, i64(oa.array_null_count(&s)))
        }
    }
}

@(private="file")
g_cpp_ipc_seq: u64

cpp_temp_path :: proc(tag, ext: string) -> string {
    seq := sync.atomic_add(&g_cpp_ipc_seq, 1)
    return fmt.tprintf("%s/oa_cpp_%d_%d_%s.%s", os.temp_dir(context.temp_allocator), os.get_pid(), seq, tag, ext)
}

@(test)
test_arrow_cpp_ipc_file_and_stream_bidirectional_parity :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    odin_file_p   := cpp_temp_path("odin_file", "arrow")
    odin_stream_p := cpp_temp_path("odin_stream", "arrows")
    cpp_file_p    := cpp_temp_path("cpp_file", "arrow")
    cpp_stream_p  := cpp_temp_path("cpp_stream", "arrows")
    defer {
        _ = os.remove(odin_file_p)
        _ = os.remove(odin_stream_p)
        _ = os.remove(cpp_file_p)
        _ = os.remove(cpp_stream_p)
    }

    // 1. Direction A: Odin writes sliced (offset=2, 5 rows) 6-column Record_Batch -> Arrow C++ validates
    {
        sc_fields := []oa.Field{
            oa.field_make("id", oa.Int64_Type{}),
            oa.field_make("uval", oa.UInt64_Type{}),
            oa.field_make("score", oa.Float32_Type{}),
            oa.field_make("flag", oa.Bool_Type{}),
            oa.field_make("payload", oa.Binary_Type{}),
            oa.field_make("label", oa.String_Type{}),
        }
        sc, sc_err := oa.schema_make(sc_fields)
        testing.expect_value(t, sc_err, nil)
        defer oa.schema_free(&sc)

        bi := oa.builder_make(i64, 7);        defer oa.builder_destroy(&bi)
        bu := oa.builder_make(u64, 7);        defer oa.builder_destroy(&bu)
        bf := oa.builder_make(f32, 7);        defer oa.builder_destroy(&bf)
        bb := oa.builder_make(bool, 7);       defer oa.builder_destroy(&bb)
        bn := oa.binary_builder_make(7);      defer oa.binary_builder_destroy(&bn)
        bs := oa.string_builder_make(7);      defer oa.string_builder_destroy(&bs)

        // Two padding elements (sliced away with offset=2)
        for _ in 0 ..< 2 {
            oa.builder_append(&bi, i64(999))
            oa.builder_append(&bu, u64(999))
            oa.builder_append(&bf, f32(999.0))
            oa.builder_append(&bb, false)
            oa.binary_builder_append(&bn, []u8{0xEE})
            oa.string_builder_append(&bs, "pad")
        }

        // Five kept rows with nulls, empty values, high u64, and negative i64/f32
        oa.builder_append(&bi, i64(-5_000_000_001))
        oa.builder_append_null(&bi)
        oa.builder_append(&bi, i64(0))
        oa.builder_append(&bi, i64(9_000_000_007))
        oa.builder_append(&bi, i64(42))

        oa.builder_append(&bu, u64(5_000_000_001))
        oa.builder_append(&bu, u64(42))
        oa.builder_append_null(&bu)
        oa.builder_append(&bu, u64(100))
        oa.builder_append(&bu, u64(8_000_000_009))

        oa.builder_append(&bf, f32(1.5))
        oa.builder_append(&bf, f32(-2.25))
        oa.builder_append_null(&bf)
        oa.builder_append(&bf, f32(3.75))
        oa.builder_append(&bf, f32(0.0))

        oa.builder_append(&bb, true)
        oa.builder_append_null(&bb)
        oa.builder_append(&bb, false)
        oa.builder_append(&bb, true)
        oa.builder_append(&bb, false)

        oa.binary_builder_append(&bn, []u8{0x00, 0xFF, 0x10})
        oa.binary_builder_append_null(&bn)
        oa.binary_builder_append(&bn, []u8{})
        oa.binary_builder_append(&bn, []u8{0xDE, 0xAD, 0xBE, 0xEF})
        oa.binary_builder_append(&bn, []u8{0x01})

        oa.string_builder_append(&bs, "alpha")
        oa.string_builder_append(&bs, "")
        oa.string_builder_append_null(&bs)
        oa.string_builder_append(&bs, "delta")
        oa.string_builder_append(&bs, "omega")

        ai, e0 := oa.builder_finish(&bi);        testing.expect_value(t, e0, nil); defer oa.array_free(&ai)
        au, e1 := oa.builder_finish(&bu);        testing.expect_value(t, e1, nil); defer oa.array_free(&au)
        af, e2 := oa.builder_finish(&bf);        testing.expect_value(t, e2, nil); defer oa.array_free(&af)
        ab, e3 := oa.builder_finish(&bb);        testing.expect_value(t, e3, nil); defer oa.array_free(&ab)
        an, e4 := oa.binary_builder_finish(&bn); testing.expect_value(t, e4, nil); defer oa.array_free(&an)
        as, e5 := oa.string_builder_finish(&bs); testing.expect_value(t, e5, nil); defer oa.array_free(&as)

        cols := []oa.Array{
            oa.array_slice(ai, 2, 7),
            oa.array_slice(au, 2, 7),
            oa.array_slice(af, 2, 7),
            oa.array_slice(ab, 2, 7),
            oa.array_slice(an, 2, 7),
            oa.array_slice(as, 2, 7),
        }
        batch, rb_ok := oa.record_batch_make(&sc, cols)
        testing.expect(t, rb_ok)
        defer {
            // Note: columns inside batch are slice views whose buffers belong to ai..as; free only batch.columns slice.
            delete(batch.columns)
        }

        testing.expect(t, oa.ipc_write_file(odin_file_p, &sc, []oa.Record_Batch{batch}))
        testing.expect(t, oa.ipc_write_stream(odin_stream_p, &sc, []oa.Record_Batch{batch}))

        want_i64_sum  := i64(-5_000_000_001 + 0 + 9_000_000_007 + 42)
        want_bin_bytes := i64(3 + 0 + 4 + 1)

        got_sum_f, got_bytes_f: i64
        ok_f := arrow_capi_ipc_verify_roundtrip(
            strings.clone_to_cstring(odin_file_p, context.temp_allocator),
            0, 5, 6, &got_sum_f, &got_bytes_f,
        )
        testing.expect_value(t, ok_f, c.int(1))
        testing.expect_value(t, got_sum_f, want_i64_sum)
        testing.expect_value(t, got_bytes_f, want_bin_bytes)

        got_sum_s, got_bytes_s: i64
        ok_s := arrow_capi_ipc_verify_roundtrip(
            strings.clone_to_cstring(odin_stream_p, context.temp_allocator),
            1, 5, 6, &got_sum_s, &got_bytes_s,
        )
        testing.expect_value(t, ok_s, c.int(1))
        testing.expect_value(t, got_sum_s, want_i64_sum)
        testing.expect_value(t, got_bytes_s, want_bin_bytes)
    }

    // 2. Direction B: Arrow C++ writes IPC File & Stream -> Odin reads & verifies with leak tracking
    {
        testing.expect_value(
            t,
            arrow_capi_ipc_write_sample(strings.clone_to_cstring(cpp_file_p, context.temp_allocator), 0),
            c.int(1),
        )
        testing.expect_value(
            t,
            arrow_capi_ipc_write_sample(strings.clone_to_cstring(cpp_stream_p, context.temp_allocator), 1),
            c.int(1),
        )

        verify_odin_read :: proc(t: ^testing.T, sc: ^oa.Schema, batches: []oa.Record_Batch) {
            testing.expect(t, sc != nil)
            testing.expect_value(t, len(batches), 1)
            if sc == nil || len(batches) != 1 { return }

            testing.expect_value(t, len(sc.fields), 6)
            testing.expect_value(t, sc.fields[0].name, "id")
            testing.expect_value(t, sc.fields[4].name, "payload")
            b := &batches[0]
            testing.expect_value(t, b.length, 5)

            // Col 0: i64 [-5_000_000_001, null, 0, 9_000_000_007, 42]
            testing.expect_value(t, oa.array_null_count(&b.columns[0]), 1)
            testing.expect_value(t, oa.array_get(&b.columns[0], 0, i64), i64(-5_000_000_001))
            testing.expect(t, oa.array_is_null(&b.columns[0], 1))
            testing.expect_value(t, oa.array_get(&b.columns[0], 2, i64), i64(0))
            testing.expect_value(t, oa.array_get(&b.columns[0], 3, i64), i64(9_000_000_007))
            testing.expect_value(t, oa.array_get(&b.columns[0], 4, i64), i64(42))

            // Col 1: u64 [5_000_000_001, 42, null, 100, 8_000_000_009]
            testing.expect_value(t, oa.array_null_count(&b.columns[1]), 1)
            testing.expect_value(t, oa.array_get(&b.columns[1], 0, u64), u64(5_000_000_001))
            testing.expect_value(t, oa.array_get(&b.columns[1], 1, u64), u64(42))
            testing.expect(t, oa.array_is_null(&b.columns[1], 2))
            testing.expect_value(t, oa.array_get(&b.columns[1], 3, u64), u64(100))
            testing.expect_value(t, oa.array_get(&b.columns[1], 4, u64), u64(8_000_000_009))

            // Col 2: f32 [1.5, -2.25, null, 3.75, 0.0]
            testing.expect_value(t, oa.array_null_count(&b.columns[2]), 1)
            testing.expect_value(t, oa.array_get(&b.columns[2], 0, f32), f32(1.5))
            testing.expect_value(t, oa.array_get(&b.columns[2], 1, f32), f32(-2.25))
            testing.expect(t, oa.array_is_null(&b.columns[2], 2))
            testing.expect_value(t, oa.array_get(&b.columns[2], 3, f32), f32(3.75))
            testing.expect_value(t, oa.array_get(&b.columns[2], 4, f32), f32(0.0))

            // Col 3: bool [true, null, false, true, false]
            testing.expect_value(t, oa.array_null_count(&b.columns[3]), 1)
            testing.expect_value(t, oa.array_get(&b.columns[3], 0, bool), true)
            testing.expect(t, oa.array_is_null(&b.columns[3], 1))
            testing.expect_value(t, oa.array_get(&b.columns[3], 2, bool), false)
            testing.expect_value(t, oa.array_get(&b.columns[3], 3, bool), true)
            testing.expect_value(t, oa.array_get(&b.columns[3], 4, bool), false)

            // Col 4: binary [{0x00, 0xFF, 0x10}, null, {}, {0xDE, 0xAD, 0xBE, 0xEF}, {0x01}]
            testing.expect_value(t, oa.array_null_count(&b.columns[4]), 1)
            testing.expect(t, mem.compare(oa.array_get_binary(&b.columns[4], 0), []u8{0x00, 0xFF, 0x10}) == 0)
            testing.expect(t, oa.array_is_null(&b.columns[4], 1))
            testing.expect_value(t, len(oa.array_get_binary(&b.columns[4], 2)), 0)
            testing.expect(t, mem.compare(oa.array_get_binary(&b.columns[4], 3), []u8{0xDE, 0xAD, 0xBE, 0xEF}) == 0)
            testing.expect(t, mem.compare(oa.array_get_binary(&b.columns[4], 4), []u8{0x01}) == 0)

            // Col 5: string ["alpha", "", null, "delta", "omega"]
            testing.expect_value(t, oa.array_null_count(&b.columns[5]), 1)
            testing.expect_value(t, oa.array_get_string(&b.columns[5], 0), "alpha")
            testing.expect_value(t, oa.array_get_string(&b.columns[5], 1), "")
            testing.expect(t, oa.array_is_null(&b.columns[5], 2))
            testing.expect_value(t, oa.array_get_string(&b.columns[5], 3), "delta")
            testing.expect_value(t, oa.array_get_string(&b.columns[5], 4), "omega")
        }

        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        saved_alloc := context.allocator
        {
            context.allocator = mem.tracking_allocator(&track)
            defer context.allocator = saved_alloc

            sc_f, bs_f, ok_rf := oa.ipc_read_file(cpp_file_p)
            testing.expect(t, ok_rf)
            verify_odin_read(t, sc_f, bs_f)
            if sc_f != nil { oa.schema_free(sc_f); free(sc_f) }
            for bx in bs_f { bc := bx; oa.record_batch_free(&bc) }
            delete(bs_f)

            sc_s, bs_s, ok_rs := oa.ipc_read_stream(cpp_stream_p)
            testing.expect(t, ok_rs)
            verify_odin_read(t, sc_s, bs_s)
            if sc_s != nil { oa.schema_free(sc_s); free(sc_s) }
            for bx in bs_s { bc := bx; oa.record_batch_free(&bc) }
            delete(bs_s)
        }
        testing.expect_value(t, len(track.allocation_map), 0)
        testing.expect_value(t, len(track.bad_free_array), 0)
        mem.tracking_allocator_destroy(&track)
    }
}
