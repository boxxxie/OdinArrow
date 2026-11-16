package skadi

import "base:intrinsics"
import "core:mem"
import "core:sync"

// ── parallel compute kernels ──────────────────────────────────────────────────
//
// Multi-threaded variants of the compute kernels using dynamic morsel stealing
// over the persistent thread pool. Arrays are immutable, so workers share the
// underlying buffers without synchronisation.
//
// Arrays shorter than PARALLEL_MIN_LENGTH fall back to the serial kernel —
// thread wakeup/barrier overhead swamps the work below that size.

PARALLEL_MIN_LENGTH :: 262_144
MAX_MORSELS         :: 256

// 0 → one thread per physical core; scales thread count down for narrow/small
// payloads using runtime L3 budget (`hardware_config_get().parallel_min_bytes`).
parallel_resolve_threads :: proc(requested: int, length: int, bytes_per_row := 8) -> int {
	return _resolve_threads(requested, length, bytes_per_row)
}

// Compute cache-resident aligned morsel row count and morsel count for `bytes_per_row`.
parallel_compute_morsels :: proc(length, nt: int, bytes_per_row := 8) -> (chunk, n_morsels: int) {
	return _compute_morsels(length, nt, bytes_per_row)
}

// 0 → one thread per physical core.
_resolve_threads :: proc(requested: int, length: int, bytes_per_row := 8) -> int {
	hw       := hardware_config_get()
	n        := requested if requested > 0 else max(hw.physical_cores, 1)
	bpr      := max(bytes_per_row, 1)
	min_rows := min(max(hw.parallel_min_bytes / bpr, 1024), PARALLEL_MIN_LENGTH)
	if length < min_rows { return 1 }
	// Never spawn threads that would get less than a quarter of a minimum chunk
	max_useful := max(length / max(min_rows / 4, 1024), 1)
	return clamp(n, 1, max_useful)
}

// Compute byte-aligned (multiple of 64 rows for SIMD + 64-bit bitmap word alignment)
// morsel size targeting `hardware_config_get().morsel_target_bytes / bytes_per_row`.
_compute_morsels :: proc(length, nt: int, bytes_per_row := 8) -> (chunk, n_morsels: int) {
	if length <= 0 { return 64, 0 }
	hw          := hardware_config_get()
	bpr         := max(bytes_per_row, 1)
	target_rows := max(hw.morsel_target_bytes / bpr, 64)
	target_rows  = (target_rows + 63) &~ 63
	// Ensure enough morsels for work stealing across nt threads when length permits.
	if nt > 1 && length >= nt * 256 && (length / target_rows) < nt * 4 {
		target_rows = max(((length + nt * 4 - 1) / (nt * 4) + 63) &~ 63, 64)
	}
	if (length + target_rows - 1) / target_rows > MAX_MORSELS {
		target_rows = ((length + MAX_MORSELS - 1) / MAX_MORSELS + 63) &~ 63
	}
	chunk     = max(target_rows, 8)
	n_morsels = clamp((length + chunk - 1) / chunk, 1, MAX_MORSELS)
	return
}

// ── sum ───────────────────────────────────────────────────────────────────────

_Sum_Task :: struct {
	slice: Array,
	sum:   f64,
	valid: int,
}

compute_sum_parallel :: proc(arr: ^Array, num_threads := 0) -> (sum: f64, valid_count: int) {
	bpr := max(type_byte_width(arr.type), 1)
	nt  := _resolve_threads(num_threads, arr.length, bpr)
	if nt <= 1 {
		return compute_sum(arr)
	}

	chunk, n_morsels := _compute_morsels(arr.length, nt, bpr)
	tasks_buf: [MAX_MORSELS]_Sum_Task
	tasks := tasks_buf[:n_morsels]

	for i in 0..<n_morsels {
		from := i * chunk
		to   := min(from + chunk, arr.length)
		tasks[i].slice = array_slice(arr^, from, to)
	}
	_pool_run(nt, _sum_job, raw_data(tasks), n_morsels)
	for i in 0..<n_morsels {
		sum         += tasks[i].sum
		valid_count += tasks[i].valid
	}
	return
}

_sum_job :: proc(ctx: rawptr, idx: int) {
	t := &(cast([^]_Sum_Task)ctx)[idx]
	t.sum, t.valid = compute_sum(&t.slice)
}

// ── min / max ─────────────────────────────────────────────────────────────────

_MinMax_Task :: struct {
	slice:   Array,
	val:     f64,
	valid:   int,
	is_max:  bool,
}

_min_max_parallel :: proc(arr: ^Array, is_max: bool, num_threads: int) -> (val: f64, valid_count: int) {
	bpr := max(type_byte_width(arr.type), 1)
	nt  := _resolve_threads(num_threads, arr.length, bpr)
	if nt <= 1 {
		if is_max {
			return compute_max(arr)
		}
		return compute_min(arr)
	}

	chunk, n_morsels := _compute_morsels(arr.length, nt, bpr)
	tasks_buf: [MAX_MORSELS]_MinMax_Task
	tasks := tasks_buf[:n_morsels]

	for i in 0..<n_morsels {
		from := i * chunk
		to   := min(from + chunk, arr.length)
		tasks[i].slice  = array_slice(arr^, from, to)
		tasks[i].is_max = is_max
	}
	_pool_run(nt, _min_max_job, raw_data(tasks), n_morsels)
	for i in 0..<n_morsels {
		if tasks[i].valid > 0 {
			if valid_count == 0 {
				val = tasks[i].val
			} else if is_max {
				val = max(val, tasks[i].val)
			} else {
				val = min(val, tasks[i].val)
			}
			valid_count += tasks[i].valid
		}
	}
	return
}

_min_max_job :: proc(ctx: rawptr, idx: int) {
	t := &(cast([^]_MinMax_Task)ctx)[idx]
	if t.is_max {
		t.val, t.valid = compute_max(&t.slice)
	} else {
		t.val, t.valid = compute_min(&t.slice)
	}
}

compute_min_parallel :: proc(arr: ^Array, num_threads := 0) -> (min_val: f64, valid_count: int) {
	return _min_max_parallel(arr, false, num_threads)
}

compute_max_parallel :: proc(arr: ^Array, num_threads := 0) -> (max_val: f64, valid_count: int) {
	return _min_max_parallel(arr, true, num_threads)
}

compute_mean_parallel :: proc(arr: ^Array, num_threads := 0) -> (mean: f64, valid_count: int) {
	sum: f64
	sum, valid_count = compute_sum_parallel(arr, num_threads)
	if valid_count > 0 {
		mean = sum / f64(valid_count)
	}
	return
}

// ── min_max parallel ──────────────────────────────────────────────────────────

_MM_Task :: struct {
	slice: Array,
	lo:    f64,
	hi:    f64,
	valid: int,
}

compute_min_max_parallel :: proc(arr: ^Array, num_threads := 0) -> (min_val: f64, max_val: f64, valid_count: int) {
	bpr := max(type_byte_width(arr.type), 1)
	nt  := _resolve_threads(num_threads, arr.length, bpr)
	if nt <= 1 {
		return compute_min_max(arr)
	}

	chunk, n_morsels := _compute_morsels(arr.length, nt, bpr)
	tasks_buf: [MAX_MORSELS]_MM_Task
	tasks := tasks_buf[:n_morsels]

	for i in 0..<n_morsels {
		from := i * chunk
		to   := min(from + chunk, arr.length)
		tasks[i].slice = array_slice(arr^, from, to)
	}
	_pool_run(nt, _mm_job, raw_data(tasks), n_morsels)

	for i in 0..<n_morsels {
		if tasks[i].valid > 0 {
			if valid_count == 0 {
				min_val = tasks[i].lo
				max_val = tasks[i].hi
			} else {
				if tasks[i].lo < min_val { min_val = tasks[i].lo }
				if tasks[i].hi > max_val { max_val = tasks[i].hi }
			}
			valid_count += tasks[i].valid
		}
	}
	return
}

_mm_job :: proc(ctx: rawptr, idx: int) {
	t := &(cast([^]_MM_Task)ctx)[idx]
	t.lo, t.hi, t.valid = compute_min_max(&t.slice)
}

// ── filter (two-phase direct-scatter) ─────────────────────────────────────────

_Filter_Morsel :: struct {
	from:       int,
	to:         int,
	out_count:  int,
	null_count: int,
	out_start:  int,
	out_bytes:  int,
	byte_start: int,
}

_Filter_Parallel_Ctx :: struct {
	arr:         ^Array,
	mask:        ^Array,
	dst_data:    [^]u8,
	dst_off:     [^]i32,
	dst_bm:      [^]u8,
	total_nulls: int,
	morsels:     []_Filter_Morsel,
}

// Parallel filter via two-phase direct scatter into single exact output buffers:
//   Phase 1: workers count surviving elements (and nulls / varlen bytes) per morsel.
//   Prefix sum + allocate output buffer(s) once on the main thread.
//   Phase 2: workers scatter surviving values directly into their disjoint slice.
compute_filter_parallel :: proc(arr, mask: ^Array, num_threads := 0, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	assert(arr.length == mask.length, "filter mask length must match array length")
	_, is_bool := mask.type.(Bool_Type)
	assert(is_bool, "filter mask must be boolean")
	bpr := max(type_byte_width(arr.type) * 2, 2)
	nt  := _resolve_threads(num_threads, arr.length, bpr)
	is_varlen := false
	#partial switch _ in arr.type {
	case Large_String_Type, Large_Binary_Type, Null_Type, Bool_Type:
		return compute_filter(arr, mask, allocator)
	case String_Type, Binary_Type:
		is_varlen = true
	}
	if nt <= 1 || (arr.offset & 7 != 0) || (mask.offset & 7 != 0) {
		return compute_filter(arr, mask, allocator)
	}

	chunk, n_morsels := _compute_morsels(arr.length, nt, bpr)
	morsels_buf: [MAX_MORSELS]_Filter_Morsel
	morsels := morsels_buf[:n_morsels]
	for i in 0..<n_morsels {
		morsels[i] = _Filter_Morsel{
			from = i * chunk,
			to   = min((i + 1) * chunk, arr.length),
		}
	}

	fctx := _Filter_Parallel_Ctx{
		arr     = arr,
		mask    = mask,
		morsels = morsels,
	}

	if is_varlen {
		_pool_run(nt, _filter_varlen_count_job, &fctx, n_morsels)

		total_len   := 0
		total_nulls := 0
		total_bytes := 0
		for &m in morsels {
			m.out_start  = total_len
			m.byte_start = total_bytes
			total_len   += m.out_count
			total_nulls += m.null_count
			if m.out_bytes > int(max(i32)) - total_bytes {
				panic("compute_filter_parallel: data exceeds i32 offset limit")
			}
			total_bytes += m.out_bytes
		}

		bitmap_buf, off_buf, data_buf := _varlen_alloc_buffers(total_len, total_bytes, total_nulls, allocator) or_return
		dst_off := cast([^]i32)off_buf.data
		dst_off[0] = 0

		if total_len > 0 {
			fctx.dst_data    = data_buf.data
			fctx.dst_off     = dst_off
			fctx.dst_bm      = bitmap_buf.data
			fctx.total_nulls = total_nulls
			_pool_run(nt, _filter_varlen_scatter_job, &fctx, n_morsels)
		}

		result = Array{
			type       = arr.type,
			length     = total_len,
			null_count = total_nulls,
			buffers    = {bitmap_buf, off_buf, data_buf},
		}
		return
	}

	_pool_run(nt, _filter_count_job, &fctx, n_morsels)

	total_len   := 0
	total_nulls := 0
	for &m in morsels {
		m.out_start  = total_len
		total_len   += m.out_count
		total_nulls += m.null_count
	}

	width := type_byte_width(arr.type)
	data_buf := buffer_make_uninit(total_len * width, allocator) or_return
	bitmap_buf: Buffer
	if total_nulls > 0 {
		bm, bm_err := buffer_make(bitmap_byte_count(total_len), allocator)
		if bm_err != nil {
			buffer_free(&data_buf)
			return {}, bm_err
		}
		bitmap_buf = bm
	}

	if total_len > 0 {
		fctx.dst_data    = data_buf.data
		fctx.dst_bm      = bitmap_buf.data
		fctx.total_nulls = total_nulls

		scatter_job: proc(ctx: rawptr, idx: int)
		#partial switch _ in arr.type {
		case Int8_Type:    scatter_job = _filter_scatter_job(i8)
		case Int16_Type:   scatter_job = _filter_scatter_job(i16)
		case Int32_Type:   scatter_job = _filter_scatter_job(i32)
		case Int64_Type:   scatter_job = _filter_scatter_job(i64)
		case UInt8_Type:   scatter_job = _filter_scatter_job(u8)
		case UInt16_Type:  scatter_job = _filter_scatter_job(u16)
		case UInt32_Type:  scatter_job = _filter_scatter_job(u32)
		case UInt64_Type:  scatter_job = _filter_scatter_job(u64)
		case Float32_Type: scatter_job = _filter_scatter_job(f32)
		case Float64_Type: scatter_job = _filter_scatter_job(f64)
		}
		_pool_run(nt, scatter_job, &fctx, n_morsels)
	}

	result = Array{
		type       = arr.type,
		length     = total_len,
		null_count = total_nulls,
		buffers    = {bitmap_buf, data_buf, {}},
	}
	return
}

_filter_count_job :: proc(ctx: rawptr, idx: int) {
	fctx      := cast(^_Filter_Parallel_Ctx)ctx
	m         := &fctx.morsels[idx]
	n_elems   := m.to - m.from
	src_bm    := fctx.arr.buffers[0].data
	mask_bm   := fctx.mask.buffers[0].data
	mask_bits := fctx.mask.buffers[1].data
	m_byte0   := (fctx.mask.offset + m.from) >> 3
	a_byte0   := (fctx.arr.offset  + m.from) >> 3

	if src_bm == nil && mask_bm == nil {
		m.out_count  = bitmap_popcount(&mask_bits[m_byte0], n_elems)
		m.null_count = 0
		return
	}

	n_bytes   := (n_elems + 7) >> 3
	out_count := 0
	valid_out := 0
	for bi in 0..<n_bytes {
		pass := mask_bits[m_byte0 + bi]
		if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
		if bi == n_bytes - 1 {
			rem := uint(n_elems) & 7
			if rem != 0 { pass &= u8((1 << rem) - 1) }
		}
		out_count += int(intrinsics.count_ones(pass))
		if src_bm != nil {
			valid_out += int(intrinsics.count_ones(pass & src_bm[a_byte0 + bi]))
		}
	}
	m.out_count  = out_count
	m.null_count = (out_count - valid_out) if src_bm != nil else 0
}

_filter_varlen_count_job :: proc(ctx: rawptr, idx: int) {
	fctx      := cast(^_Filter_Parallel_Ctx)ctx
	m         := &fctx.morsels[idx]
	n_elems   := m.to - m.from
	n_bytes   := (n_elems + 7) >> 3
	src_bm    := fctx.arr.buffers[0].data
	src_off   := cast([^]i32)fctx.arr.buffers[1].data
	mask_bm   := fctx.mask.buffers[0].data
	mask_bits := fctx.mask.buffers[1].data
	m_byte0   := (fctx.mask.offset + m.from) >> 3
	src_base  := fctx.arr.offset + m.from
	a_byte0   := src_base >> 3

	out_count := 0
	valid_out := 0
	out_bytes := 0
	for bi in 0..<n_bytes {
		pass := mask_bits[m_byte0 + bi]
		if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
		if bi == n_bytes - 1 {
			rem := uint(n_elems) & 7
			if rem != 0 { pass &= u8((1 << rem) - 1) }
		}
		if pass == 0 { continue }
		cnt := int(intrinsics.count_ones(pass))
		out_count += cnt
		in_base := src_base + (bi << 3)
		if src_bm == nil {
			positions := _BYTE_INDICES_LUT[pass]
			for k in 0..<cnt {
				a_idx := in_base + int(positions[k])
				out_bytes += int(src_off[a_idx + 1] - src_off[a_idx])
			}
		} else {
			valid_pass := pass & src_bm[a_byte0 + bi]
			v_cnt := int(intrinsics.count_ones(valid_pass))
			valid_out += v_cnt
			v_pos := _BYTE_INDICES_LUT[valid_pass]
			for k in 0..<v_cnt {
				a_idx := in_base + int(v_pos[k])
				out_bytes += int(src_off[a_idx + 1] - src_off[a_idx])
			}
		}
	}
	m.out_count  = out_count
	m.null_count = (out_count - valid_out) if src_bm != nil else 0
	m.out_bytes  = out_bytes
}

_filter_varlen_scatter_job :: proc(ctx: rawptr, idx: int) {
	fctx := cast(^_Filter_Parallel_Ctx)ctx
	m    := &fctx.morsels[idx]
	if m.out_count == 0 { return }

	arr       := fctx.arr
	mask      := fctx.mask
	n_elems   := m.to - m.from
	n_bytes   := (n_elems + 7) >> 3
	src_bm    := arr.buffers[0].data
	src_off   := cast([^]i32)arr.buffers[1].data
	src_data  := arr.buffers[2].data
	mask_bm   := mask.buffers[0].data
	mask_bits := mask.buffers[1].data
	src_base  := arr.offset + m.from
	a_byte0   := src_base >> 3
	m_byte0   := (mask.offset + m.from) >> 3

	dst_off   := fctx.dst_off
	dst_data  := fctx.dst_data
	out_pos   := m.out_start
	write_pos := m.byte_start

	if fctx.total_nulls == 0 {
		for bi in 0..<n_bytes {
			pass := mask_bits[m_byte0 + bi]
			if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
			if bi == n_bytes - 1 {
				rem := uint(n_elems) & 7
				if rem != 0 { pass &= u8((1 << rem) - 1) }
			}
			if pass == 0 { continue }
			cnt       := int(intrinsics.count_ones(pass))
			positions := _BYTE_INDICES_LUT[pass]
			in_base   := src_base + (bi << 3)
			for k in 0..<cnt {
				a_idx   := in_base + int(positions[k])
				s_start := int(src_off[a_idx])
				s_end   := int(src_off[a_idx + 1])
				slen    := s_end - s_start
				if slen > 0 {
					mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&src_data[s_start]), slen)
					write_pos += slen
				}
				dst_off[out_pos + 1] = i32(write_pos)
				out_pos += 1
			}
		}
		return
	}

	dst_bm     := fctx.dst_bm
	first_byte := m.out_start >> 3
	last_byte  := (m.out_start + m.out_count - 1) >> 3
	cur_bidx   := first_byte
	cur_byte   := u8(0)

	for bi in 0..<n_bytes {
		pass := mask_bits[m_byte0 + bi]
		if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
		if bi == n_bytes - 1 {
			rem := uint(n_elems) & 7
			if rem != 0 { pass &= u8((1 << rem) - 1) }
		}
		if pass == 0 { continue }
		cnt       := int(intrinsics.count_ones(pass))
		positions := _BYTE_INDICES_LUT[pass]
		in_base   := src_base + (bi << 3)
		ab        := src_bm[a_byte0 + bi] if src_bm != nil else u8(0xFF)
		for k in 0..<cnt {
			bit := positions[k]
			if (ab >> bit) & 1 == 1 {
				a_idx   := in_base + int(bit)
				s_start := int(src_off[a_idx])
				s_end   := int(src_off[a_idx + 1])
				slen    := s_end - s_start
				if slen > 0 {
					mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&src_data[s_start]), slen)
					write_pos += slen
				}
				bidx := out_pos >> 3
				if bidx != cur_bidx {
					_flush_bm_byte(dst_bm, cur_bidx, first_byte, last_byte, cur_byte)
					cur_bidx = bidx
					cur_byte = 0
				}
				cur_byte |= 1 << u8(out_pos & 7)
			}
			dst_off[out_pos + 1] = i32(write_pos)
			out_pos += 1
		}
	}
	_flush_bm_byte(dst_bm, cur_bidx, first_byte, last_byte, cur_byte)
}

_flush_bm_byte :: #force_inline proc "contextless" (dst_bm: [^]u8, byte_idx, first_byte, last_byte: int, val: u8) {
	if val == 0 { return }
	if byte_idx == first_byte || byte_idx == last_byte {
		sync.atomic_or(&dst_bm[byte_idx], val)
	} else {
		dst_bm[byte_idx] = val
	}
}

_filter_scatter_job :: proc($T: typeid) -> proc(ctx: rawptr, idx: int) {
	return proc(ctx: rawptr, idx: int) {
		fctx := cast(^_Filter_Parallel_Ctx)ctx
		m    := &fctx.morsels[idx]
		if m.out_count == 0 { return }

		arr       := fctx.arr
		mask      := fctx.mask
		n_elems   := m.to - m.from
		n_bytes   := (n_elems + 7) >> 3
		when T == u8 {
			src := arr.buffers[1].data
			dst := fctx.dst_data
		} else {
			src := cast([^]T)arr.buffers[1].data
			dst := cast([^]T)fctx.dst_data
		}
		src_bm    := arr.buffers[0].data
		mask_bm   := mask.buffers[0].data
		mask_bits := mask.buffers[1].data
		src_base  := arr.offset + m.from
		a_byte0   := src_base >> 3
		m_byte0   := (mask.offset + m.from) >> 3

		out_pos := m.out_start

		if fctx.total_nulls == 0 {
			for bi in 0..<n_bytes {
				pass := mask_bits[m_byte0 + bi]
				if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
				if bi == n_bytes - 1 {
					rem := uint(n_elems) & 7
					if rem != 0 { pass &= u8((1 << rem) - 1) }
				}
				if pass == 0 { continue }
				if pass == 0xFF {
					mem.copy_non_overlapping(rawptr(&dst[out_pos]), rawptr(&src[src_base + (bi << 3)]), 8 * size_of(T))
					out_pos += 8
					continue
				}
				cnt       := int(intrinsics.count_ones(pass))
				positions := _BYTE_INDICES_LUT[pass]
				in_base   := src_base + (bi << 3)
				for k in 0..<cnt {
					dst[out_pos + k] = src[in_base + int(positions[k])]
				}
				out_pos += cnt
			}
			return
		}

		dst_bm     := fctx.dst_bm
		first_byte := m.out_start >> 3
		last_byte  := (m.out_start + m.out_count - 1) >> 3
		cur_bidx   := first_byte
		cur_byte   := u8(0)

		for bi in 0..<n_bytes {
			pass := mask_bits[m_byte0 + bi]
			if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
			if bi == n_bytes - 1 {
				rem := uint(n_elems) & 7
				if rem != 0 { pass &= u8((1 << rem) - 1) }
			}
			if pass == 0 { continue }
			cnt       := int(intrinsics.count_ones(pass))
			positions := _BYTE_INDICES_LUT[pass]
			in_base   := src_base + (bi << 3)
			ab        := src_bm[a_byte0 + bi]
			for k in 0..<cnt {
				bit := positions[k]
				dst[out_pos] = src[in_base + int(bit)]
				bidx := out_pos >> 3
				if bidx != cur_bidx {
					_flush_bm_byte(dst_bm, cur_bidx, first_byte, last_byte, cur_byte)
					cur_bidx = bidx
					cur_byte = 0
				}
				if (ab >> bit) & 1 == 1 {
					cur_byte |= 1 << u8(out_pos & 7)
				}
				out_pos += 1
			}
		}
		_flush_bm_byte(dst_bm, cur_bidx, first_byte, last_byte, cur_byte)
	}
}

// ── take parallel ─────────────────────────────────────────────────────────────

_Take_Morsel :: struct {
	from: int,
	to:   int,
}

_Take_Parallel_Ctx :: struct {
	arr:      ^Array,
	indices:  ^Array,
	dst_data: [^]u8,
	morsels:  []_Take_Morsel,
}

// Parallel fixed-width gather across morsels for null-free arrays and Int64/Int32 indices.
compute_take_parallel :: proc(arr, indices: ^Array, num_threads := 0, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	_, is_i64 := indices.type.(Int64_Type)
	_, is_i32 := indices.type.(Int32_Type)
	assert(is_i64 || is_i32, "compute_take_parallel: indices must be Int64_Type or Int32_Type")
	n        := indices.length
	idx_size := size_of(i64) if is_i64 else size_of(i32)
	bpr      := max(type_byte_width(arr.type) * 2 + idx_size, 10)
	nt       := _resolve_threads(num_threads, n, bpr)
	#partial switch _ in arr.type {
	case Bool_Type, String_Type, Binary_Type, Large_String_Type, Large_Binary_Type, Null_Type:
		return compute_take(arr, indices, allocator)
	}
	if nt <= 1 || arr.buffers[0].data != nil || indices.buffers[0].data != nil {
		return compute_take(arr, indices, allocator)
	}

	chunk, n_morsels := _compute_morsels(n, nt, bpr)
	morsels_buf: [MAX_MORSELS]_Take_Morsel
	morsels := morsels_buf[:n_morsels]
	for i in 0..<n_morsels {
		morsels[i] = _Take_Morsel{
			from = i * chunk,
			to   = min((i + 1) * chunk, n),
		}
	}

	width := type_byte_width(arr.type)
	data_buf := buffer_make_uninit(n * width, allocator) or_return
	tctx := _Take_Parallel_Ctx{
		arr      = arr,
		indices  = indices,
		dst_data = data_buf.data,
		morsels  = morsels,
	}

	take_job := _resolve_take_scatter_job(arr.type, i64) if is_i64 else _resolve_take_scatter_job(arr.type, i32)
	_pool_run(nt, take_job, &tctx, n_morsels)

	result = Array{
		type       = arr.type,
		length     = n,
		null_count = 0,
		buffers    = {{}, data_buf, {}},
	}
	return
}

_resolve_take_scatter_job :: proc(dt: DataType, $Idx: typeid) -> proc(ctx: rawptr, idx: int) {
	#partial switch _ in dt {
	case Int8_Type:    return _take_scatter_job(i8,  Idx)
	case Int16_Type:   return _take_scatter_job(i16, Idx)
	case Int32_Type:   return _take_scatter_job(i32, Idx)
	case Int64_Type:   return _take_scatter_job(i64, Idx)
	case UInt8_Type:   return _take_scatter_job(u8,  Idx)
	case UInt16_Type:  return _take_scatter_job(u16, Idx)
	case UInt32_Type:  return _take_scatter_job(u32, Idx)
	case UInt64_Type:  return _take_scatter_job(u64, Idx)
	case Float32_Type: return _take_scatter_job(f32, Idx)
	case Float64_Type: return _take_scatter_job(f64, Idx)
	}
	return nil
}

_take_scatter_job :: proc($T, $Idx: typeid) -> proc(ctx: rawptr, idx: int) {
	return proc(ctx: rawptr, idx: int) {
		tctx := cast(^_Take_Parallel_Ctx)ctx
		m    := &tctx.morsels[idx]
		when T == u8 {
			src := tctx.arr.buffers[1].data[tctx.arr.offset:]
			dst := tctx.dst_data
		} else {
			src := (cast([^]T)tctx.arr.buffers[1].data)[tctx.arr.offset:]
			dst := cast([^]T)tctx.dst_data
		}
		idxs := (cast([^]Idx)tctx.indices.buffers[1].data)[tctx.indices.offset:]
		to := m.to
		i  := m.from
		for ; i + _TAKE_PREFETCH_DIST + 8 <= to; i += 8 {
			#unroll for p in 0..<8 {
				intrinsics.prefetch_read_data(rawptr(&src[int(idxs[i + _TAKE_PREFETCH_DIST + p])]), _TAKE_PREFETCH_LOCALITY)
			}
			j0 := int(idxs[i])
			j1 := int(idxs[i + 1])
			j2 := int(idxs[i + 2])
			j3 := int(idxs[i + 3])
			j4 := int(idxs[i + 4])
			j5 := int(idxs[i + 5])
			j6 := int(idxs[i + 6])
			j7 := int(idxs[i + 7])
			arr_u := u64(tctx.arr.length)
			if u64(j0) >= arr_u || u64(j1) >= arr_u || u64(j2) >= arr_u || u64(j3) >= arr_u ||
			   u64(j4) >= arr_u || u64(j5) >= arr_u || u64(j6) >= arr_u || u64(j7) >= arr_u {
				panic("compute_take_parallel: index out of bounds")
			}
			dst[i]     = src[j0]
			dst[i + 1] = src[j1]
			dst[i + 2] = src[j2]
			dst[i + 3] = src[j3]
			dst[i + 4] = src[j4]
			dst[i + 5] = src[j5]
			dst[i + 6] = src[j6]
			dst[i + 7] = src[j7]
		}
		for ; i < to; i += 1 {
			j := int(idxs[i])
			if u64(j) >= u64(tctx.arr.length) {
				panic("compute_take_parallel: index out of bounds")
			}
			dst[i] = src[j]
		}
	}
}
