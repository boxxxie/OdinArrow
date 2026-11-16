package skadi

import "base:intrinsics"
import "base:runtime"
import "core:mem"

// Umbra / "German-style" strings: each element is a fixed 16-byte slot
//
//   { length: u32, data: [12]u8 }
//
// - length <= 12: the bytes live inline in `data` (the rest zero-padded). No
//   separate data buffer, no offset indirection, no pointer chase.
// - length  > 12: data[0:4] is a 4-byte prefix and data[4:12] is an i64 offset
//   into a side `data` buffer holding the full bytes.
//
// The payoff is comparison: the first 4 bytes (the prefix, zero-padded) sit in
// the slot, so the vast majority of string comparisons resolve in registers
// without ever touching the data buffer. For random-access comparison work like
// sorting — where Arrow's `[offsets][bytes]` layout takes a cache miss into the
// data buffer on every compare — this is a large win.
//
// This breaks the Arrow Utf8 layout by design; it is a separate type, and would
// be transcoded at an Arrow/IPC boundary.

Umbra_String :: struct {
	length: u32,
	data:   [12]u8,
}
#assert(size_of(Umbra_String) == 16)

Umbra_Array :: struct {
	slots:     []Umbra_String,
	data:      []u8, // backing bytes for strings longer than 12
	length:    int,
	allocator: mem.Allocator,
}

// ── builder ─────────────────────────────────────────────────────────────────

Umbra_Builder :: struct {
	slots:  [dynamic]Umbra_String,
	data:   [dynamic]u8,
	length: int,
}

umbra_builder_make :: proc(initial_cap := 64, allocator := context.allocator) -> Umbra_Builder {
	return Umbra_Builder{
		slots = make([dynamic]Umbra_String, 0, initial_cap, allocator),
		data  = make([dynamic]u8, 0, initial_cap * 8, allocator),
	}
}

umbra_append :: proc(b: ^Umbra_Builder, s: string) {
	assert(len(s) <= int(max(u32)), "Umbra_Builder: string length exceeds u32 limit")
	us: Umbra_String
	us.length = u32(len(s))
	if len(s) <= 12 {
		copy(us.data[:], transmute([]u8)s)              // inline; tail stays zero
	} else {
		copy(us.data[0:4], transmute([]u8)s[:4])        // prefix
		_put_i64le(us.data[4:12], i64(len(b.data)))     // offset into the side buffer
		append(&b.data, ..transmute([]u8)s)
	}
	append(&b.slots, us)
	b.length += 1
}

umbra_builder_finish :: proc(b: ^Umbra_Builder, allocator := context.allocator) -> Umbra_Array {
	slots := make([]Umbra_String, len(b.slots), allocator)
	data  := make([]u8, len(b.data), allocator)
	copy(slots, b.slots[:])
	copy(data, b.data[:])
	return Umbra_Array{ slots = slots, data = data, length = b.length, allocator = allocator }
}

umbra_builder_destroy :: proc(b: ^Umbra_Builder) {
	delete(b.slots)
	delete(b.data)
	b^ = {}
}

umbra_free :: proc(a: ^Umbra_Array) {
	delete(a.slots, a.allocator)
	delete(a.data, a.allocator)
	a^ = {}
}

// ── accessors ───────────────────────────────────────────────────────────────

// Zero-copy view of element i. Valid while the array is alive.
umbra_get :: proc(a: ^Umbra_Array, i: int) -> string {
	s := &a.slots[i]
	if s.length <= 12 {
		return string(s.data[:s.length])
	}
	off := _get_i64le(s.data[4:12])
	return string(a.data[off : off + i64(s.length)])
}

umbra_length :: #force_inline proc(a: ^Umbra_Array, i: int) -> int { return int(a.slots[i].length) }

// ── comparison-heavy kernels ────────────────────────────────────────────────

_umbra_u64be :: #force_inline proc "contextless" (p: ^u8) -> u64 {
	raw := intrinsics.unaligned_load(cast(^u64)p)
	when ODIN_ENDIAN == .Little {
		return intrinsics.byte_swap(raw)
	} else {
		return raw
	}
}

_umbra_u32be :: #force_inline proc "contextless" (p: ^u8) -> u32 {
	raw := intrinsics.unaligned_load(cast(^u32)p)
	when ODIN_ENDIAN == .Little {
		return intrinsics.byte_swap(raw)
	} else {
		return raw
	}
}

// First 4 bytes as a big-endian u32 so a numeric compare equals a lexicographic
// compare of the (zero-padded) prefix.
umbra_prefix :: #force_inline proc "contextless" (s: ^Umbra_String) -> u32 {
	return _umbra_u32be(&s.data[0])
}
_umbra_prefix :: umbra_prefix

// Bytes 4..11 as a big-endian u64 for register-only tie-breaking of inline strings.
_umbra_tail64 :: #force_inline proc "contextless" (s: ^Umbra_String) -> u64 {
	return _umbra_u64be(&s.data[4])
}

// Compare elements i and j assuming their 4-byte prefixes already match.
umbra_compare_tie :: #force_inline proc(a: ^Umbra_Array, i, j: int) -> int {
	if i == j { return 0 }
	si := &a.slots[i]
	sj := &a.slots[j]
	if si.length <= 12 && sj.length <= 12 {
		wi := _umbra_tail64(si)
		wj := _umbra_tail64(sj)
		if wi != wj { return -1 if wi < wj else 1 }
		if si.length != sj.length { return -1 if si.length < sj.length else 1 }
		return 0
	}
	if si.length > 12 && sj.length > 12 {
		off_i := int(_get_i64le(si.data[4:12]))
		off_j := int(_get_i64le(sj.data[4:12]))
		if off_i == off_j {
			if si.length == sj.length { return 0 }
			return -1 if si.length < sj.length else 1
		}
		base := raw_data(a.data)
		pi := base[off_i:]
		pj := base[off_j:]
		wi := _umbra_u64be(&pi[4])
		wj := _umbra_u64be(&pj[4])
		if wi != wj { return -1 if wi < wj else 1 }

		min_len := int(min(si.length, sj.length))
		pos := 12
		for ; pos + 8 <= min_len; pos += 8 {
			ui := _umbra_u64be(&pi[pos])
			uj := _umbra_u64be(&pj[pos])
			if ui != uj { return -1 if ui < uj else 1 }
		}
		if pos + 4 <= min_len {
			ui := _umbra_u32be(&pi[pos])
			uj := _umbra_u32be(&pj[pos])
			if ui != uj { return -1 if ui < uj else 1 }
			pos += 4
		}
		for ; pos < min_len; pos += 1 {
			if pi[pos] != pj[pos] {
				return -1 if pi[pos] < pj[pos] else 1
			}
		}
		if si.length == sj.length { return 0 }
		return -1 if si.length < sj.length else 1
	}

	base := raw_data(a.data)
	pi: [^]u8 = cast([^]u8)&si.data[0] if si.length <= 12 else base[int(_get_i64le(si.data[4:12])):]
	pj: [^]u8 = cast([^]u8)&sj.data[0] if sj.length <= 12 else base[int(_get_i64le(sj.data[4:12])):]
	min_len := int(min(si.length, sj.length))
	for pos := 4; pos < min_len; pos += 1 {
		if pi[pos] != pj[pos] {
			return -1 if pi[pos] < pj[pos] else 1
		}
	}
	return -1 if si.length < sj.length else 1
}

// Lexicographic compare of elements i and j: -1, 0, or 1. The prefix resolves
// most pairs without touching the data buffer; equal prefixes check the inline
// tail in registers for short strings or fall back to full byte compare.
umbra_compare :: proc(a: ^Umbra_Array, i, j: int) -> int {
	pi := _umbra_prefix(&a.slots[i])
	pj := _umbra_prefix(&a.slots[j])
	if pi != pj { return -1 if pi < pj else 1 }
	return _umbra_compare_tie(a, i, j)
}

// Count elements equal to `needle`. Rejects on length, then prefix, before any
// data-buffer access.
umbra_count_eq :: proc(a: ^Umbra_Array, needle: string) -> int {
	nlen := u32(len(needle))
	npfx: u32
	{
		tmp: Umbra_String
		copy(tmp.data[0:4], transmute([]u8)needle[:min(len(needle), 4)])
		npfx = _umbra_prefix(&tmp)
	}
	count := 0
	for i in 0..<a.length {
		s := &a.slots[i]
		if s.length != nlen { continue }
		if _umbra_prefix(s) != npfx { continue }
		if umbra_get(a, i) == needle { count += 1 }
	}
	return count
}

_umbra_compare_tie :: umbra_compare_tie

@(private="file")
_Umbra_Radix_Entry :: struct {
	key: u32,
	idx: i32,
}

@(private="file")
_merge_sort_umbra_run :: proc(a: ^Umbra_Array, run, tmp: []_Umbra_Radix_Entry) {
	m := len(run)
	if m <= 16 {
		for i in 1..<m {
			cur := run[i]
			k := i
			for k > 0 && _umbra_compare_tie(a, int(run[k - 1].idx), int(cur.idx)) > 0 {
				run[k] = run[k - 1]
				k -= 1
			}
			run[k] = cur
		}
		return
	}
	for start := 0; start < m; start += 16 {
		end := min(start + 16, m)
		for i := start + 1; i < end; i += 1 {
			cur := run[i]
			k := i
			for k > start && _umbra_compare_tie(a, int(run[k - 1].idx), int(cur.idx)) > 0 {
				run[k] = run[k - 1]
				k -= 1
			}
			run[k] = cur
		}
	}
	width := 16
	for width < m {
		i := 0
		for i < m {
			lo  := i
			mid := min(i + width, m)
			hi  := min(i + 2 * width, m)
			x, y, dst := lo, mid, lo
			for x < mid && y < hi {
				if _umbra_compare_tie(a, int(run[x].idx), int(run[y].idx)) <= 0 {
					tmp[dst] = run[x]; x += 1
				} else {
					tmp[dst] = run[y]; y += 1
				}
				dst += 1
			}
			for x < mid { tmp[dst] = run[x]; x += 1; dst += 1 }
			for y < hi  { tmp[dst] = run[y]; y += 1; dst += 1 }
			i += 2 * width
		}
		copy(run, tmp[:m])
		width *= 2
	}
}

// Stable ascending sort; returns an Int64 index array (feeds compute_take-style
// gathers). Uses 4-pass LSD radix sort over the 4-byte prefix and only
// merge-sorts unsorted equal-prefix runs.
umbra_sort_indices :: proc(a: ^Umbra_Array, allocator := context.allocator) -> Array {
	n := a.length
	assert(n <= int(max(i32)), "umbra_sort_indices: length exceeds i32 radix index limit")
	buf, buf_err := buffer_make_uninit(n * size_of(i64), allocator)
	assert(buf_err == .None, "umbra_sort_indices: allocation failed")
	out := cast([^]i64)buf.data
	if n <= 1 {
		if n == 1 { out[0] = 0 }
		return Array{ type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, buf, {}} }
	}

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	src := make([]_Umbra_Radix_Entry, n, context.temp_allocator)
	dst := make([]_Umbra_Radix_Entry, n, context.temp_allocator)

	hist: [4][256]int
	slots := a.slots
	for i in 0..<n {
		k := _umbra_prefix(&slots[i])
		src[i] = _Umbra_Radix_Entry{ key = k, idx = i32(i) }
		hist[0][k & 0xFF] += 1
		hist[1][(k >> 8) & 0xFF] += 1
		hist[2][(k >> 16) & 0xFF] += 1
		hist[3][(k >> 24) & 0xFF] += 1
	}

	first_key := src[0].key
	for pass in u32(0)..<4 {
		shift := pass * 8
		if hist[pass][(first_key >> shift) & 0xFF] == n { continue }
		offsets: [256]int
		acc := 0
		for bucket in 0..<256 {
			offsets[bucket] = acc
			acc += hist[pass][bucket]
		}
		for i in 0..<n {
			e := src[i]
			bkt := (e.key >> shift) & 0xFF
			pos := offsets[bkt]
			offsets[bkt] = pos + 1
			dst[pos] = e
		}
		src, dst = dst, src
	}

	lo := 0
	for lo < n {
		k := src[lo].key
		hi := lo + 1
		for hi < n && src[hi].key == k { hi += 1 }
		if hi - lo > 1 {
			sorted := true
			for r := lo; r + 1 < hi; r += 1 {
				if _umbra_compare_tie(a, int(src[r].idx), int(src[r + 1].idx)) > 0 {
					sorted = false
					break
				}
			}
			if !sorted {
				_merge_sort_umbra_run(a, src[lo:hi], dst[:hi - lo])
			}
		}
		lo = hi
	}

	for i in 0..<n {
		out[i] = i64(src[i].idx)
	}
	return Array{ type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, buf, {}} }
}

@(private="file")
_umbra_le_u64 :: #force_inline proc(a: ^Umbra_Array, ea, eb: u64) -> bool {
	ka := u32(ea >> 32)
	kb := u32(eb >> 32)
	if ka != kb {
		return ka < kb
	}
	ia := int(u32(ea))
	ib := int(u32(eb))
	cmp := umbra_compare_tie(a, ia, ib)
	if cmp != 0 {
		return cmp < 0
	}
	return ia <= ib
}

@(private="file")
_umbra_tie_le_u64 :: #force_inline proc(a: ^Umbra_Array, ea, eb: u64) -> bool {
	ia := int(u32(ea))
	ib := int(u32(eb))
	cmp := umbra_compare_tie(a, ia, ib)
	if cmp != 0 {
		return cmp < 0
	}
	return ia <= ib
}

@(private="file")
_merge_sort_umbra_run_u64 :: proc(a: ^Umbra_Array, run, tmp: []u64) {
	m := len(run)
	if m <= 1 { return }
	if m <= 16 {
		for i in 1..<m {
			v := run[i]
			j := i - 1
			for j >= 0 && !_umbra_tie_le_u64(a, run[j], v) {
				run[j + 1] = run[j]
				j -= 1
			}
			run[j + 1] = v
		}
		return
	}
	for start := 0; start < m; start += 16 {
		end := min(start + 16, m)
		for i := start + 1; i < end; i += 1 {
			v := run[i]
			j := i - 1
			for j >= start && !_umbra_tie_le_u64(a, run[j], v) {
				run[j + 1] = run[j]
				j -= 1
			}
			run[j + 1] = v
		}
	}
	src := run
	dst := tmp
	width := 16
	for width < m {
		i := 0
		for i < m {
			lo  := i
			mid := min(i + width, m)
			hi  := min(i + 2 * width, m)
			l, r, k := lo, mid, lo
			for l < mid && r < hi {
				if _umbra_tie_le_u64(a, src[l], src[r]) {
					dst[k] = src[l]
					l += 1
				} else {
					dst[k] = src[r]
					r += 1
				}
				k += 1
			}
			for l < mid {
				dst[k] = src[l]
				l += 1
				k += 1
			}
			for r < hi {
				dst[k] = src[r]
				r += 1
				k += 1
			}
			i += 2 * width
		}
		src, dst = dst, src
		width *= 2
	}
	if raw_data(src) != raw_data(run) {
		copy(run, src[:m])
	}
}

// Sort a bucket of packed (u64(prefix32) << 32) | u64(orig_idx) Umbra entries directly into out_i64.
// rem_shift specifies remaining low prefix bits (default 24 after 1-byte MSB partitioning).
umbra_sort_range_into :: proc(a: ^Umbra_Array, entries, scratch: []u64, out_i64: []i64, rem_shift: u32 = 24) {
	m := len(entries)
	if m == 0 { return }
	assert(len(scratch) >= m && len(out_i64) >= m)

	if m == 1 {
		out_i64[0] = i64(u32(entries[0]))
		return
	}

	if m <= 32 {
		for i in 1..<m {
			v := entries[i]
			j := i - 1
			for j >= 0 && !_umbra_le_u64(a, entries[j], v) {
				entries[j + 1] = entries[j]
				j -= 1
			}
			entries[j + 1] = v
		}
		for i in 0..<m {
			out_i64[i] = i64(u32(entries[i]))
		}
		return
	}

	src := entries
	dst := scratch
	if rem_shift > 0 {
		k0 := u32(src[0] >> 32)
		diff_k: u32 = 0
		for i in 1..<m {
			diff_k |= u32(src[i] >> 32) ~ k0
		}
		if diff_k != 0 {
			hist: [256]u32
			offs: [256]u32
			for shift: u32 = 0; shift < rem_shift && shift < 32; shift += 8 {
				if ((diff_k >> shift) & 0xFF) == 0 { continue }

				hist = {}
				key_shift := u32(32) + shift
				for i in 0..<m {
					b := (src[i] >> key_shift) & 0xFF
					hist[b] += 1
				}
				first_b := (src[0] >> key_shift) & 0xFF
				if int(hist[first_b]) == m { continue }

				acc: u32 = 0
				for b in 0..<256 {
					offs[b] = acc
					acc += hist[b]
				}
				for i in 0..<m {
					v := src[i]
					b := (v >> key_shift) & 0xFF
					pos := offs[b]
					offs[b] = pos + 1
					dst[pos] = v
				}
				src, dst = dst, src
			}
		}
	}

	i := 0
	for i < m {
		rk := u32(src[i] >> 32)
		idx0 := int(u32(src[i]))
		len0 := a.slots[idx0].length
		needs_tie := len0 > 4
		prev_idx := idx0
		monotonic_idx := true
		j := i + 1
		for j < m && u32(src[j] >> 32) == rk {
			idxj := int(u32(src[j]))
			if a.slots[idxj].length != len0 || len0 > 4 {
				needs_tie = true
			}
			if idxj < prev_idx {
				monotonic_idx = false
			}
			prev_idx = idxj
			j += 1
		}
		if j - i > 1 && (needs_tie || !monotonic_idx) {
			already_sorted := true
			for k := i + 1; k < j; k += 1 {
				if !_umbra_tie_le_u64(a, src[k - 1], src[k]) {
					already_sorted = false
					break
				}
			}
			if !already_sorted {
				_merge_sort_umbra_run_u64(a, src[i:j], dst[i:j])
			}
		}
		i = j
	}

	for k in 0..<m {
		out_i64[k] = i64(u32(src[k]))
	}
}

// ── little-endian i64 helpers (avoid unaligned i64 access into slot bytes) ───

_put_i64le :: #force_inline proc "contextless" (dst: []u8, v: i64) {
	when ODIN_ENDIAN == .Little {
		intrinsics.unaligned_store(cast(^i64)raw_data(dst), v)
	} else {
		intrinsics.unaligned_store(cast(^u64)raw_data(dst), intrinsics.byte_swap(u64(v)))
	}
}
_get_i64le :: #force_inline proc "contextless" (src: []u8) -> i64 {
	when ODIN_ENDIAN == .Little {
		return intrinsics.unaligned_load(cast(^i64)raw_data(src))
	} else {
		return i64(intrinsics.byte_swap(intrinsics.unaligned_load(cast(^u64)raw_data(src))))
	}
}
