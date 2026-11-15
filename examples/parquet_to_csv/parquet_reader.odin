package parquet_to_csv

import "core:os"
import oa "../../skadi"

// Physical types
PTYPE_BOOLEAN    :: i32(0)
PTYPE_INT32      :: i32(1)
PTYPE_INT64      :: i32(2)
PTYPE_FLOAT      :: i32(4)
PTYPE_DOUBLE     :: i32(5)
PTYPE_BYTE_ARRAY :: i32(6)

// Page types
PPAGE_DATA :: i32(0)
PPAGE_DICT :: i32(2)

// Repetition types
REP_REQUIRED :: i32(0)
REP_OPTIONAL :: i32(1)

Column_Chunk_Meta :: struct {
	name:          string,
	ptype:         i32,
	num_values:    i64,
	uncomp_size:   i64, // total_uncompressed_size from ColumnMetaData field 6
	data_offset:   i64,
	dict_offset:   i64,
	has_dict:      bool,
	max_def_level: i32, // 0=REQUIRED, 1=OPTIONAL
	// Extra row-group page offsets and value counts (row groups 1..N).
	// Populated by parse_footer_struct for multi-row-group files.
	extra_rg_data_offsets: []i64,
	extra_rg_num_values:   []i64,
	extra_rg_dict_offsets: []i64,
	extra_rg_has_dict:     []bool,
}

Page_Header :: struct {
	page_type:  i32,
	uncomp:     i32,
	comp:       i32,
	num_values: i32,
	encoding:   i32,
}

read_i32_le :: #force_inline proc "contextless" (data: []u8, pos: int) -> i32 {
	return i32(data[pos]) | i32(data[pos+1])<<8 | i32(data[pos+2])<<16 | i32(data[pos+3])<<24
}

// ── footer parsing ────────────────────────────────────────────────────────────

// parse_footer_struct parses the raw FileMetaData Thrift bytes (no magic check).
parse_footer_struct :: proc(data: []u8) -> (num_rows: i64, metas: []Column_Chunk_Meta, ok: bool) {
	t := thrift_make(data)

	col_names:  [dynamic]string; defer delete(col_names)
	col_ptypes: [dynamic]i32;    defer delete(col_ptypes)
	col_dls:    [dynamic]i32;    defer delete(col_dls)
	rg_metas:   [dynamic]Column_Chunk_Meta; defer delete(rg_metas)

	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(&t, &prev)
		if stop || t.err { break }
		switch fid {
		case 1: thrift_read_i32(&t)
		case 2:
			_, cnt := thrift_read_list_header(&t)
			for i in 0..<cnt {
				if t.err { break }
				parse_schema_element(&t, i == 0, &col_names, &col_ptypes, &col_dls)
			}
		case 3: num_rows = thrift_read_i64(&t)
		case 4:
			_, rg_cnt := thrift_read_list_header(&t)
			for _ in 0..<rg_cnt {
				if t.err { break }
				parse_row_group(&t, &rg_metas)
			}
		case: thrift_skip(&t, ftype)
		}
		if t.err { break }
	}
	if t.err { return }

	n_cols := len(col_names)
	if n_cols > 0 && len(rg_metas) % n_cols != 0 { return }
	n_rg   := len(rg_metas) / n_cols if n_cols > 0 else 0
	if len(col_ptypes) < n_cols || len(col_dls) < n_cols || len(rg_metas) < n_rg * n_cols { return }
	result := make([]Column_Chunk_Meta, n_cols)
	for col in 0..<n_cols {
		if col < len(rg_metas) {
			result[col] = rg_metas[col]   // first row group
		}
		// Clone the name: col_names[col] is a view into footer_buf which is
		// freed by the caller after parse_footer_struct returns.
		name_bytes := make([]u8, len(col_names[col]))
		copy(name_bytes, col_names[col])
		result[col].name          = string(name_bytes)
		result[col].ptype         = col_ptypes[col]
		result[col].max_def_level = col_dls[col]
		if n_rg > 1 {
			extra := n_rg - 1
			offs := make([]i64, extra)
			vals := make([]i64, extra)
			dict_offs := make([]i64, extra)
			has_dicts := make([]bool, extra)
			for rg in 1..<n_rg {
				rg_idx := rg * n_cols + col
				offs[rg-1]      = rg_metas[rg_idx].data_offset
				vals[rg-1]      = rg_metas[rg_idx].num_values
				dict_offs[rg-1] = rg_metas[rg_idx].dict_offset
				has_dicts[rg-1] = rg_metas[rg_idx].has_dict
			}
			result[col].extra_rg_data_offsets = offs
			result[col].extra_rg_num_values   = vals
			result[col].extra_rg_dict_offsets = dict_offs
			result[col].extra_rg_has_dict     = has_dicts
		}
	}
	metas = result
	ok = true
	return
}

// parse_footer reads from a full in-memory file slice (legacy path).
parse_footer :: proc(data: []u8) -> (num_rows: i64, metas: []Column_Chunk_Meta, ok: bool) {
	n := len(data)
	if n < 12 { return }
	if string(data[:4]) != "PAR1" || string(data[n-4:]) != "PAR1" { return }
	footer_len := int(read_i32_le(data, n-8))
	if footer_len >= n-8 { return }
	return parse_footer_struct(data[n-8-footer_len : n-8])
}

// parse_footer_from_file reads only the footer bytes from an open file handle.
parse_footer_from_file :: proc(file: ^os.File) -> (num_rows: i64, metas: []Column_Chunk_Meta, ok: bool) {
	file_size, size_err := os.file_size(file)
	if size_err != nil || file_size < 12 { return }

	head: [4]u8
	os.seek(file, 0, .Start)
	n_head, _ := os.read(file, head[:])
	if n_head < 4 || string(head[:]) != "PAR1" { return }

	tail: [8]u8
	os.seek(file, file_size - 8, .Start)
	n_tail, _ := os.read(file, tail[:])
	if n_tail < 8 || string(tail[4:]) != "PAR1" { return }

	footer_len := int(read_i32_le(tail[:], 0))
	if footer_len <= 0 || i64(footer_len) >= file_size - 8 { return }

	footer_buf := make([]u8, footer_len)
	defer delete(footer_buf)
	os.seek(file, file_size - 8 - i64(footer_len), .Start)
	n_footer, _ := os.read(file, footer_buf)
	if n_footer < footer_len { return }

	return parse_footer_struct(footer_buf)
}

parse_schema_element :: proc(t: ^Thrift, is_root: bool,
	names: ^[dynamic]string, ptypes: ^[dynamic]i32, dls: ^[dynamic]i32) {

	ptype:    i32 = -1
	rep_type: i32 = 0
	name:     string

	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop || t.err { break }
		switch fid {
		case 1: ptype    = thrift_read_i32(t)
		case 3: rep_type = thrift_read_i32(t)
		case 4: name     = string(thrift_read_binary(t))
		case:   thrift_skip(t, ftype)
		}
		if t.err { break }
	}
	if t.err { return }
	if !is_root && ptype >= 0 {
		dl := i32(0)
		if rep_type == REP_OPTIONAL { dl = 1 }
		append(names, name)
		append(ptypes, ptype)
		append(dls, dl)
	}
}

parse_row_group :: proc(t: ^Thrift, metas: ^[dynamic]Column_Chunk_Meta) {
	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop || t.err { break }
		switch fid {
		case 1:
			_, cnt := thrift_read_list_header(t)
			for _ in 0..<cnt {
				if t.err { break }
				m := parse_column_chunk(t)
				if t.err { break }
				append(metas, m)
			}
		case: thrift_skip(t, ftype)
		}
		if t.err { break }
	}
}

parse_column_chunk :: proc(t: ^Thrift) -> Column_Chunk_Meta {
	meta: Column_Chunk_Meta
	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop || t.err { break }
		switch fid {
		case 3: parse_column_metadata(t, &meta)
		case:   thrift_skip(t, ftype)
		}
		if t.err { break }
	}
	return meta
}

parse_column_metadata :: proc(t: ^Thrift, meta: ^Column_Chunk_Meta) {
	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop || t.err { break }
		switch fid {
		case 5:  meta.num_values  = thrift_read_i64(t)
		case 6:  meta.uncomp_size = thrift_read_i64(t)
		case 9:  meta.data_offset = thrift_read_i64(t)
		case 11:
			meta.dict_offset = thrift_read_i64(t)
			meta.has_dict    = true
		case: thrift_skip(t, ftype)
		}
		if t.err { break }
	}
}

// ── page header ───────────────────────────────────────────────────────────────

parse_page_header :: proc(data: []u8, pos: ^int) -> (ph: Page_Header, ok: bool) {
	t := thrift_make(data[pos^:])
	prev: i32
	has_type   := false
	has_uncomp := false
	has_comp   := false
	for {
		fid, ftype, stop := thrift_read_field(&t, &prev)
		if t.err { return ph, false }
		if stop { break }
		if ftype == THRIFT_STOP || ftype > 12 { return ph, false }
		switch fid {
		case 1:
			ph.page_type = thrift_read_i32(&t)
			has_type = true
		case 2:
			ph.uncomp    = thrift_read_i32(&t)
			has_uncomp   = true
		case 3:
			ph.comp      = thrift_read_i32(&t)
			has_comp     = true
		case 4: thrift_read_i32(&t)
		case 5:
			p2: i32
			for {
				fid2, ftype2, stop2 := thrift_read_field(&t, &p2)
				if t.err { return ph, false }
				if stop2 { break }
				if ftype2 == THRIFT_STOP || ftype2 > 12 { return ph, false }
				switch fid2 {
				case 1: ph.num_values = thrift_read_i32(&t)
				case 2: ph.encoding   = thrift_read_i32(&t)
				case:   thrift_skip(&t, ftype2)
				}
				if t.err { return ph, false }
			}
		case 7:
			p2: i32
			for {
				fid2, ftype2, stop2 := thrift_read_field(&t, &p2)
				if t.err { return ph, false }
				if stop2 { break }
				if ftype2 == THRIFT_STOP || ftype2 > 12 { return ph, false }
				switch fid2 {
				case 1: ph.num_values = thrift_read_i32(&t)
				case 2: ph.encoding   = thrift_read_i32(&t)
				case:   thrift_skip(&t, ftype2)
				}
				if t.err { return ph, false }
			}
		case: thrift_skip(&t, ftype)
		}
		if t.err { return ph, false }
	}
	if !has_type || !has_uncomp || !has_comp || ph.uncomp < 0 || ph.comp < 0 {
		return ph, false
	}
	if ph.page_type != PPAGE_DICT && ph.num_values > 0 && (ph.uncomp == 0 || ph.comp == 0) {
		return ph, false
	}
	pos^ += t.pos
	ok = true
	return
}

// ── varint for RLE ───────────────────────────────────────────────────────────

rle_read_varint :: proc "contextless" (data: []u8, pos: ^int) -> u64 {
	result: u64
	shift:  uint
	for pos^ < len(data) && shift < 64 {
		b := data[pos^]; pos^ += 1
		result |= u64(b & 0x7F) << shift
		shift += 7
		if b & 0x80 == 0 { break }
	}
	return result
}

// decode_rle_into decodes RLE/bit-packed values into a pre-allocated slice.
decode_rle_into :: proc(data: []u8, bit_width: int, num_values: int, out: []int) {
	if num_values <= 0 { return }
	if bit_width <= 0 {
		for i in 0..<num_values { out[i] = 0 }
		return
	}
	pos := 0
	idx := 0
	mask := u64(~u64(0)) if bit_width >= 64 else ((u64(1) << uint(bit_width)) - 1)
	for idx < num_values && pos < len(data) {
		hdr := rle_read_varint(data, &pos)
		if hdr & 1 == 0 {
			run_count := int(hdr >> 1)
			if run_count <= 0 { break }
			val_bytes := (bit_width + 7) / 8
			if pos + val_bytes > len(data) { break }
			val := 0
			for b in 0..<val_bytes {
				val |= int(data[pos]) << uint(b * 8)
				pos += 1
			}
			val = int(u64(val) & mask)
			n := min(run_count, num_values - idx)
			for _ in 0..<n { out[idx] = val; idx += 1 }
		} else {
			groups := int(hdr >> 1)
			if groups <= 0 { break }
			run_start := pos
			total_vals := groups * 8
			for v_i in 0..<total_vals {
				if idx >= num_values { break }
				bit_pos := v_i * bit_width
				byte_off := run_start + bit_pos / 8
				bit_off  := uint(bit_pos % 8)
				accum: u64 = 0
				for b_i in 0..<8 {
					if byte_off + b_i < len(data) {
						accum |= u64(data[byte_off + b_i]) << uint(b_i * 8)
					}
				}
				val := int((accum >> bit_off) & mask)
				out[idx] = val
				idx += 1
			}
			pos += groups * bit_width
		}
	}
	for idx < num_values {
		out[idx] = 0
		idx += 1
	}
}

// _rle_can_decode verifies without allocating that `data` can yield at least
// `num_values` RLE/bit-packed values at `bit_width`.
_rle_can_decode :: proc "contextless" (data: []u8, bit_width: int, num_values: int) -> bool {
	if num_values <= 0 { return true }
	if bit_width <= 0 { return true }
	pos := 0
	idx := 0
	val_bytes := (bit_width + 7) / 8
	for idx < num_values && pos < len(data) {
		hdr := rle_read_varint(data, &pos)
		if hdr & 1 == 0 {
			run_count := int(hdr >> 1)
			if run_count <= 0 || val_bytes > len(data) - pos {
				return false
			}
			pos += val_bytes
			idx += min(run_count, num_values - idx)
		} else {
			groups := int(hdr >> 1)
			if groups <= 0 || groups > (len(data) - pos) / bit_width {
				return false
			}
			pos += groups * bit_width
			total_vals := groups * 8
			idx += min(total_vals, num_values - idx)
		}
	}
	return idx >= num_values
}

// decode_rle_indices allocates and decodes (kept for callers that own the slice).
decode_rle_indices :: proc(data: []u8, bit_width: int, num_values: int) -> []int {
	result := make([]int, num_values)
	decode_rle_into(data, bit_width, num_values, result)
	return result
}

skip_def_levels :: proc "contextless" (data: []u8, pos: ^int, max_def_level: i32) {
	if max_def_level == 0 { return }
	def_len := int(read_i32_le(data, pos^))
	pos^ += 4 + def_len
}

// ── Col_Stream: streaming page-by-page column reader ─────────────────────────
//
// Each Col_Stream owns its own file descriptor so concurrent column reads
// don't interfere via shared file-pointer state.

Col_Stream :: struct {
	file:                  ^os.File,
	file_size:             i64,
	ptype:                 i32,
	max_def:               i32,
	has_dict:              bool,
	page_is_dict:          bool,
	total_rows:            int,   // total across ALL row groups
	rows_done:             int,   // total rows consumed across all row groups
	// Row-group advancement
	rg_total:              int,   // rows in current row group
	rg_rows_done:          int,   // rows consumed from current row group
	extra_rg_offsets:      []i64, // data_offset for row groups 1..N
	extra_rg_values:       []i64, // num_values  for row groups 1..N
	extra_rg_dict_offsets: []i64, // dict_offset for row groups 1..N
	extra_rg_has_dict:     []bool,// has_dict    for row groups 1..N
	extra_rg_idx:          int,
	// Dictionary (reloaded per row group if PPAGE_DICT encountered)
	dict_strs:             []string,   // for string dict (zero-copy from dict_buf)
	dict_i32s:             []i32,      // for INT32 dict
	dict_buf:              []u8,       // backing storage for dict string bytes
	// Definition levels for nullable columns (max_def > 0)
	def_buf:               []int,      // 1 = valid, 0 = null
	def_pos:               int,
	// Page cursor
	page_off:              i64,        // file offset of next page header
	page_buf:              []u8,       // reusable data buffer
	// Current page decoder state
	page_rows_left:        int,
	plain_data:            []u8,       // view into page_buf (PLAIN values)
	plain_pos:             int,
	rle_idx_buf:           []int,      // decoded indices for current dict page
	rle_idx_pos:           int,
}

_col_stream_load_dict :: proc(cs: ^Col_Stream, ph: Page_Header, probe: []u8, hdr_pos: int, page_start_off: i64) -> bool {
	delete(cs.dict_buf)
	delete(cs.dict_i32s)
	delete(cs.dict_strs)
	cs.dict_buf = nil
	cs.dict_i32s = nil
	cs.dict_strs = nil

	dict_data_size := int(ph.comp)
	n_vals := int(ph.num_values)
	if dict_data_size < 0 || n_vals < 0 || n_vals > dict_data_size / 4 {
		return false
	}
	if page_start_off < 0 || hdr_pos < 0 {
		return false
	}
	if cs.file_size >= 0 {
		data_off := page_start_off + i64(hdr_pos)
		if data_off > cs.file_size || i64(dict_data_size) > cs.file_size - data_off {
			return false
		}
	}
	cs.dict_buf = make([]u8, dict_data_size)
	n_p := len(probe)
	already := min(max(n_p - hdr_pos, 0), dict_data_size)
	if already > 0 {
		copy(cs.dict_buf[:already], probe[hdr_pos : hdr_pos + already])
	}
	if already < dict_data_size {
		if _, seek_err := os.seek(cs.file, page_start_off + i64(hdr_pos) + i64(already), .Start); seek_err != nil {
			return false
		}
		read_off := already
		for read_off < dict_data_size {
			n_rd, rd_err := os.read(cs.file, cs.dict_buf[read_off:])
			if rd_err != nil || n_rd <= 0 {
				return false
			}
			read_off += n_rd
		}
	}

	if cs.ptype == PTYPE_INT32 {
		if n_vals > len(cs.dict_buf) / 4 {
			return false
		}
		cs.dict_i32s = make([]i32, n_vals)
		for i in 0 ..< n_vals {
			cs.dict_i32s[i] = read_i32_le(cs.dict_buf, i*4)
		}
	} else {
		if n_vals > len(cs.dict_buf) / 4 {
			return false
		}
		cs.dict_strs = make([]string, n_vals)
		pos := 0
		for i in 0 ..< n_vals {
			if pos + 4 > len(cs.dict_buf) {
				return false
			}
			slen := int(read_i32_le(cs.dict_buf, pos))
			pos += 4
			if slen < 0 || pos + slen > len(cs.dict_buf) {
				return false
			}
			cs.dict_strs[i] = string(cs.dict_buf[pos : pos + slen])
			pos += slen
		}
	}
	cs.has_dict = true
	return true
}

col_stream_init :: proc(path: string, meta: Column_Chunk_Meta) -> (cs: Col_Stream, ok: bool) {
	f, err := os.open(path)
	if err != nil { return }
	fsz, sz_err := os.file_size(f)
	if sz_err != nil || fsz < 0 {
		os.close(f)
		return
	}
	if meta.num_values < 0 {
		os.close(f)
		return
	}

	cs.file         = f
	cs.file_size    = fsz
	cs.ptype        = meta.ptype
	cs.max_def      = meta.max_def_level
	cs.has_dict     = meta.has_dict
	cs.rg_total     = int(meta.num_values)
	cs.rg_rows_done = 0
	// Accumulate total rows across all row groups.
	total := meta.num_values
	for v in meta.extra_rg_num_values {
		if v < 0 || v > max(i64) - total {
			os.close(f)
			cs = {}
			return
		}
		total += v
	}
	cs.total_rows = int(total)
	// Copy extra row-group data so the stream owns its own lifetime.
	if len(meta.extra_rg_data_offsets) > 0 {
		cs.extra_rg_offsets = make([]i64, len(meta.extra_rg_data_offsets))
		copy(cs.extra_rg_offsets, meta.extra_rg_data_offsets)
		cs.extra_rg_values = make([]i64, len(meta.extra_rg_num_values))
		copy(cs.extra_rg_values, meta.extra_rg_num_values)
	}
	if len(meta.extra_rg_dict_offsets) > 0 {
		cs.extra_rg_dict_offsets = make([]i64, len(meta.extra_rg_dict_offsets))
		copy(cs.extra_rg_dict_offsets, meta.extra_rg_dict_offsets)
		cs.extra_rg_has_dict = make([]bool, len(meta.extra_rg_has_dict))
		copy(cs.extra_rg_has_dict, meta.extra_rg_has_dict)
	}
	cs.page_buf = make([]u8, 1 << 20) // 1 MB starting size

	if meta.has_dict {
		probe: [512]u8
		if _, seek_err := os.seek(f, meta.dict_offset, .Start); seek_err != nil {
			col_stream_destroy(&cs)
			cs = {}
			return
		}
		n_p, _ := os.read(f, probe[:])
		if n_p < 4 {
			col_stream_destroy(&cs)
			cs = {}
			return
		}

		hdr_pos := 0
		ph, ph_ok := parse_page_header(probe[:n_p], &hdr_pos)
		if !ph_ok {
			col_stream_destroy(&cs)
			cs = {}
			return
		}
		if !_col_stream_load_dict(&cs, ph, probe[:n_p], hdr_pos, meta.dict_offset) {
			col_stream_destroy(&cs)
			cs = {}
			return
		}
	}

	cs.page_off = meta.data_offset
	ok = true
	return
}

col_stream_destroy :: proc(cs: ^Col_Stream) {
	if cs.file != nil { os.close(cs.file) }
	delete(cs.page_buf)
	delete(cs.rle_idx_buf)
	delete(cs.dict_strs)
	delete(cs.dict_i32s)
	delete(cs.dict_buf)
	delete(cs.def_buf)
	delete(cs.extra_rg_offsets)
	delete(cs.extra_rg_values)
	delete(cs.extra_rg_dict_offsets)
	delete(cs.extra_rg_has_dict)
}

// col_stream_load_page reads and decodes the next data page from the file.
col_stream_load_page :: proc(cs: ^Col_Stream) -> bool {
	if cs.rows_done >= cs.total_rows { return false }
	// Advance to the next row group when the current one is fully consumed.
	rg_data_off: i64 = -1
	for cs.rg_rows_done >= cs.rg_total {
		if cs.extra_rg_idx >= len(cs.extra_rg_offsets) { return false }
		if cs.extra_rg_has_dict != nil && cs.extra_rg_has_dict[cs.extra_rg_idx] {
			cs.page_off = cs.extra_rg_dict_offsets[cs.extra_rg_idx]
			rg_data_off = cs.extra_rg_offsets[cs.extra_rg_idx]
			cs.has_dict = true
		} else {
			cs.page_off = cs.extra_rg_offsets[cs.extra_rg_idx]
			rg_data_off = -1
			cs.has_dict = false
		}
		cs.rg_total      = int(cs.extra_rg_values[cs.extra_rg_idx])
		cs.rg_rows_done  = 0
		cs.extra_rg_idx += 1
	}

	probe: [512]u8
	n_p: int
	hdr_pos: int
	ph: Page_Header
	for {
		if _, seek_err := os.seek(cs.file, cs.page_off, .Start); seek_err != nil { return false }
		n_p, _ = os.read(cs.file, probe[:])
		if n_p < 4 { return false }

		hdr_pos = 0
		ph_ok: bool
		ph, ph_ok = parse_page_header(probe[:n_p], &hdr_pos)
		if !ph_ok { return false }

		// Reload any dictionary page encountered and advance to the following data page
		if ph.page_type == PPAGE_DICT {
			if !_col_stream_load_dict(cs, ph, probe[:n_p], hdr_pos, cs.page_off) {
				return false
			}
			if rg_data_off >= 0 {
				cs.page_off = rg_data_off
				rg_data_off = -1
			} else {
				cs.page_off += i64(hdr_pos + int(ph.comp))
			}
			continue
		}
		break
	}

	total_data := int(ph.comp)
	if total_data < 0 || cs.page_off < 0 || hdr_pos < 0 {
		return false
	}
	if cs.file_size >= 0 {
		data_start := cs.page_off + i64(hdr_pos)
		if data_start > cs.file_size || i64(total_data) > cs.file_size - data_start {
			return false
		}
	}
	if len(cs.page_buf) < total_data {
		delete(cs.page_buf)
		cs.page_buf = make([]u8, total_data)
	}

	already := min(max(n_p - hdr_pos, 0), total_data)
	if already > 0 {
		copy(cs.page_buf[:already], probe[hdr_pos : hdr_pos + already])
	}
	if already < total_data {
		if _, seek_err := os.seek(cs.file, cs.page_off + i64(hdr_pos) + i64(already), .Start); seek_err != nil {
			return false
		}
		read_off := already
		for read_off < total_data {
			n_rd, rd_err := os.read(cs.file, cs.page_buf[read_off:total_data])
			if rd_err != nil || n_rd <= 0 { return false }
			read_off += n_rd
		}
	}

	cs.page_off += i64(hdr_pos + total_data)

	data := cs.page_buf[:total_data]
	pos  := 0
	n := int(ph.num_values)
	rem_rows := min(cs.total_rows - cs.rows_done, cs.rg_total - cs.rg_rows_done)
	if n <= 0 || n > rem_rows {
		return false
	}
	valid_count := n

	if cs.max_def > 0 {
		if pos + 4 > len(data) {
			return false
		}
		def_len := int(read_i32_le(data, pos))
		pos += 4
		if def_len <= 0 || pos + def_len > len(data) {
			return false
		}
		def_bw := 0
		for v := int(cs.max_def); v > 0; v >>= 1 {
			def_bw += 1
		}
		if !_rle_can_decode(data[pos : pos + def_len], def_bw, n) {
			return false
		}
		if len(cs.def_buf) < n {
			delete(cs.def_buf)
			cs.def_buf = make([]int, n)
		}
		decode_rle_into(data[pos : pos + def_len], def_bw, n, cs.def_buf[:n])
		pos += def_len
		cs.def_pos = 0

		valid_count = 0
		for i in 0..<n {
			if cs.def_buf[i] == int(cs.max_def) {
				valid_count += 1
			}
		}
	}

	cs.page_is_dict = (ph.encoding == 8 || ph.encoding == 2) && cs.has_dict
	if cs.page_is_dict {
		if valid_count > 0 {
			if pos >= len(data) {
				return false
			}
			bw := int(data[pos])
			pos += 1
			if bw < 0 || bw > 32 || !_rle_can_decode(data[pos:], bw, valid_count) {
				return false
			}
			if len(cs.rle_idx_buf) < valid_count {
				delete(cs.rle_idx_buf)
				cs.rle_idx_buf = make([]int, valid_count)
			}
			decode_rle_into(data[pos:], bw, valid_count, cs.rle_idx_buf[:valid_count])
		}
		cs.rle_idx_pos = 0
	} else {
		if valid_count > (len(data) - pos) / 4 {
			return false
		}
		cs.plain_data = data[pos:]
		cs.plain_pos  = 0
	}
	cs.page_rows_left = n
	return true
}

// col_stream_to_string_array reads up to n string values into an OdinArrow Array.
// The caller owns the returned Array and must call oa.array_free when done.
col_stream_to_string_array :: proc(cs: ^Col_Stream, n: int) -> oa.Array {
	b := oa.string_builder_make(n)
	defer oa.string_builder_destroy(&b)
	count := 0
	for count < n && cs.rows_done < cs.total_rows {
		if cs.page_rows_left == 0 {
			if !col_stream_load_page(cs) { break }
		}
		is_null := false
		if cs.max_def > 0 {
			if cs.def_buf[cs.def_pos] < int(cs.max_def) {
				is_null = true
			}
			cs.def_pos += 1
		}

		if is_null {
			oa.string_builder_append_null(&b)
		} else if cs.page_is_dict {
			idx := cs.rle_idx_buf[cs.rle_idx_pos]
			cs.rle_idx_pos += 1
			if idx >= 0 && idx < len(cs.dict_strs) {
				oa.string_builder_append(&b, cs.dict_strs[idx])
			} else {
				oa.string_builder_append_null(&b)
			}
		} else {
			slen := int(read_i32_le(cs.plain_data, cs.plain_pos))
			cs.plain_pos += 4
			oa.string_builder_append(&b, string(cs.plain_data[cs.plain_pos : cs.plain_pos + slen]))
			cs.plain_pos += slen
		}
		cs.page_rows_left -= 1
		cs.rows_done      += 1
		cs.rg_rows_done   += 1
		count += 1
	}
	arr, _ := oa.string_builder_finish(&b)
	return arr
}

// col_stream_to_i32_array reads up to n INT32 values into an OdinArrow Array.
// The caller owns the returned Array and must call oa.array_free when done.
col_stream_to_i32_array :: proc(cs: ^Col_Stream, n: int) -> oa.Array {
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	count := 0
	for count < n && cs.rows_done < cs.total_rows {
		if cs.page_rows_left == 0 {
			if !col_stream_load_page(cs) { break }
		}
		is_null := false
		if cs.max_def > 0 {
			if cs.def_buf[cs.def_pos] < int(cs.max_def) {
				is_null = true
			}
			cs.def_pos += 1
		}

		if is_null {
			oa.builder_append_null(&b)
		} else if cs.page_is_dict {
			idx := cs.rle_idx_buf[cs.rle_idx_pos]
			cs.rle_idx_pos += 1
			if idx >= 0 && idx < len(cs.dict_i32s) {
				oa.builder_append(&b, cs.dict_i32s[idx])
			} else {
				oa.builder_append_null(&b)
			}
		} else {
			if cs.plain_pos + 4 > len(cs.plain_data) { break }
			oa.builder_append(&b, read_i32_le(cs.plain_data, cs.plain_pos))
			cs.plain_pos += 4
		}
		cs.page_rows_left -= 1
		cs.rows_done      += 1
		cs.rg_rows_done   += 1
		count += 1
	}
	arr, _ := oa.builder_finish(&b)
	return arr
}
