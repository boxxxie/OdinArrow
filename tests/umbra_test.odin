package skadi_tests

import "core:mem"
import "core:slice"
import "core:testing"
import oa "../skadi"

@(test)
test_umbra_inline_and_long :: proc(t: ^testing.T) {
	b := oa.umbra_builder_make()
	defer oa.umbra_builder_destroy(&b)
	vals := []string{
		"",                       // empty
		"hi",                     // short inline
		"twelve_bytes",           // exactly 12 (inline boundary)
		"this is a long string",  // > 12 (uses prefix + data buffer)
		"αβγ",                    // multibyte, short
	}
	for v in vals { oa.umbra_append(&b, v) }
	a := oa.umbra_builder_finish(&b)
	defer oa.umbra_free(&a)

	testing.expect_value(t, a.length, len(vals))
	for v, i in vals {
		testing.expect_value(t, oa.umbra_get(&a, i), v)
		testing.expect_value(t, oa.umbra_length(&a, i), len(v))
	}
}

@(test)
test_umbra_compare_and_count :: proc(t: ^testing.T) {
	b := oa.umbra_builder_make()
	defer oa.umbra_builder_destroy(&b)
	vals := []string{"banana", "apple", "apricot", "banana", "cherry"}
	for v in vals { oa.umbra_append(&b, v) }
	a := oa.umbra_builder_finish(&b)
	defer oa.umbra_free(&a)

	// compare returns sign of lexicographic order
	testing.expect(t, oa.umbra_compare(&a, 1, 0) < 0)  // apple < banana
	testing.expect(t, oa.umbra_compare(&a, 1, 2) < 0)  // apple < apricot (prefix tie on "app")
	testing.expect(t, oa.umbra_compare(&a, 0, 3) == 0) // banana == banana
	testing.expect(t, oa.umbra_compare(&a, 4, 0) > 0)  // cherry > banana

	testing.expect_value(t, oa.umbra_count_eq(&a, "banana"), 2)
	testing.expect_value(t, oa.umbra_count_eq(&a, "apple"), 1)
	testing.expect_value(t, oa.umbra_count_eq(&a, "missing"), 0)
}

// Sort a deterministic pseudo-random set of long strings and verify the result
// is fully sorted and matches a reference sort of the same strings.
@(test)
test_umbra_sort :: proc(t: ^testing.T) {
	N :: 500
	raw := make([]string, N)
	defer { for s in raw { delete(s) }; delete(raw) }
	b := oa.umbra_builder_make()
	defer oa.umbra_builder_destroy(&b)
	for i in 0..<N {
		// 16-char strings (all "long") with varied prefixes
		buf := make([]u8, 16)
		x := u32(i*2654435761) // knuth hash for spread
		for k in 0..<16 { buf[k] = u8('a' + (x >> uint(k)) % 26) }
		raw[i] = string(buf)
		oa.umbra_append(&b, raw[i])
	}
	a := oa.umbra_builder_finish(&b)
	defer oa.umbra_free(&a)

	idx := oa.umbra_sort_indices(&a)
	defer oa.array_free(&idx)
	testing.expect_value(t, idx.length, N)

	// result is non-decreasing
	for k in 1..<N {
		prev := oa.umbra_get(&a, int(oa.array_get(&idx, k-1, i64)))
		cur  := oa.umbra_get(&a, int(oa.array_get(&idx, k,   i64)))
		testing.expect(t, prev <= cur, "umbra sort not ordered")
	}

	// matches a reference sort of the same strings
	ref := make([]string, N); defer delete(ref)
	copy(ref, raw)
	slice.sort(ref)
	for k in 0..<N {
		got := oa.umbra_get(&a, int(oa.array_get(&idx, k, i64)))
		testing.expect_value(t, got, ref[k])
	}
}

@(test)
test_umbra_long_tie_break_offsets_and_mixed_lengths :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	vals := []string{
		"same12prefix_12345678_alphe",
		"same12prefix",                  // 12B inline boundary
		"same12prefix_12345678_alpha",   // >12B, 8B tail + 1B diff
		"same_short\x00long_suffix",     // >12B sharing 4B prefix "same" with short strings
		"same12prefix\x00a",             // >12B with embedded NUL at tail
		"same",                          // 4B inline
		"same12prefix_1234",             // 17B (4B + 1B tail)
		"same12prefix_12345678_alpha",   // duplicate long string
		"same_short",                    // 10B inline prefix of "same_short\x00long_suffix"
		"same12prefix_1235",             // 17B differing in 4B tail
		"same\x00",                      // 5B inline with trailing NUL
		"same12prefix_12345678_9999",    // 26B differing after 8B tail
		"same12prefix!",                 // 13B >12B
		"same12prefix_123",              // 16B exact 4B tail
		"same12prefix\x00",              // 13B embedded NUL at index 12
		"same\xff\xff\xff\xff\xff\xff\xff\xff\xff", // high-byte >12B string (signed vs unsigned byte test)
		"same12prefix",                  // duplicate 12B inline
		"same12prefixA",                 // 13B differing at byte 12
		"same12prefixB",                 // 13B differing at byte 12
		"same12",                        // 6B inline
		"",                              // empty string
		"pref_001_beta_suffix_1234",
		"pref_001_alpha_suffix_xyz",
		"pref_001_alpha_suffix_xya",
		"pref_000_aaaa_long_tail",
	}

	ub := oa.umbra_builder_make(len(vals))
	defer oa.umbra_builder_destroy(&ub)
	sb := oa.string_builder_make(len(vals))
	defer oa.string_builder_destroy(&sb)
	for v in vals {
		oa.umbra_append(&ub, v)
		oa.string_builder_append(&sb, v)
	}
	ua := oa.umbra_builder_finish(&ub)
	defer oa.umbra_free(&ua)
	sa, s_err := oa.string_builder_finish(&sb)
	testing.expect_value(t, s_err, nil)
	defer oa.array_free(&sa)

	// Pairwise umbra_compare parity (covers i == j, equal offsets/values, <=12 vs >12, 4/8/12/16+ prefix ties)
	for i in 0..<len(vals) {
		for j in 0..<len(vals) {
			got := oa.umbra_compare(&ua, i, j)
			if vals[i] < vals[j] {
				testing.expect(t, got < 0, "expected < 0 in umbra_compare")
			} else if vals[i] > vals[j] {
				testing.expect(t, got > 0, "expected > 0 in umbra_compare")
			} else {
				testing.expect_value(t, got, 0)
			}
		}
	}

	uidx := oa.umbra_sort_indices(&ua)
	defer oa.array_free(&uidx)
	sidx, si_err := oa.compute_sort_indices(&sa)
	testing.expect_value(t, si_err, nil)
	defer oa.array_free(&sidx)

	testing.expect_value(t, uidx.length, len(vals))
	testing.expect_value(t, sidx.length, len(vals))
	for k in 0..<len(vals) {
		ui := oa.array_get(&uidx, k, i64)
		si := oa.array_get(&sidx, k, i64)
		testing.expect_value(t, ui, si)
	}
}
