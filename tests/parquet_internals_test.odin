package skadi_tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import oa "../skadi"
import c2p "../examples/csv_to_parquet"
import p2c "../examples/parquet_to_csv"

@(private="file")
g_pq_test_seq: u64

pq_temp_file :: proc(tag: string) -> string {
	seq := sync.atomic_add(&g_pq_test_seq, 1)
	td, _ := os.temp_dir(context.temp_allocator)
	return fmt.tprintf("%s/oa_pq_unit_%d_%d_%s.bin", td, os.get_pid(), seq, tag)
}

// Encodes `vals` (must be a multiple of 8) as a single Parquet bit-packed run.
encode_parquet_bitpacked :: proc(vals: []int, bit_width: int, allocator := context.allocator) -> []u8 {
	groups := len(vals) / 8
	hdr := u64(groups << 1) | 1
	out := make([dynamic]u8, 0, 4 + groups * bit_width, allocator)
	n := hdr
	for n >= 0x80 {
		append(&out, u8(n & 0x7F) | 0x80)
		n >>= 7
	}
	append(&out, u8(n))

	payload_start := len(out)
	resize(&out, payload_start + groups * bit_width)
	for v, idx in vals {
		for b in 0..<bit_width {
			if ((v >> uint(b)) & 1) == 1 {
				tbit := idx * bit_width + b
				out[payload_start + tbit / 8] |= u8(1 << uint(tbit % 8))
			}
		}
	}
	return out[:]
}

// Red-First: catches BOTH multi-group offset doubling (groups >= 2) AND bit_width >= 10 truncation
@(test)
test_parquet_rle_bit_unpack_wide_dictionaries :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// 1. bit_width == 0 (single-entry dictionary): all zeros
	out0 := make([]int, 10, context.temp_allocator)
	for i in 0..<10 {
		out0[i] = 99
	}
	p2c.decode_rle_into(nil, 0, 10, out0)
	for v in out0 {
		testing.expect_value(t, v, 0)
	}

	// 2. Multi-group (16 values = 2 groups) at bit_width = 3, 10 (>512 dict), and 17 (>65k dict)
	widths := []int{3, 10, 17}
	for bw in widths {
		mask := (1 << uint(bw)) - 1
		want := make([]int, 16, context.temp_allocator)
		for i in 0..<16 {
			want[i] = ((i * 73_129) + (1 << uint(bw - 1)) + i) & mask
		}
		encoded := encode_parquet_bitpacked(want, bw, context.temp_allocator)
		got := p2c.decode_rle_indices(encoded, bw, 16)
		defer delete(got)

		testing.expect_value(t, len(got), 16)
		if len(got) == 16 {
			for i in 0..<16 {
				testing.expect_value(t, got[i], want[i])
			}
		}
	}
}

// Red-First: Thrift Compact Protocol MAP encodes varint count FIRST, and 0-size maps omit the kv-type byte
@(test)
test_thrift_skip_empty_and_non_empty_map :: proc(t: ^testing.T) {
	// Case A: Field 1 = empty MAP ([0x1B, 0x00]), Field 2 = I32 42 ([0x15, 0x54]), STOP ([0x00])
	empty_map_struct := []u8{0x1B, 0x00, 0x15, 0x54, 0x00}
	tr1 := p2c.thrift_make(empty_map_struct)
	prev1: i32 = 0

	fid1, ft1, stop1 := p2c.thrift_read_field(&tr1, &prev1)
	testing.expect(t, !stop1)
	testing.expect_value(t, fid1, i32(1))
	p2c.thrift_skip(&tr1, ft1)

	fid2, _, stop2 := p2c.thrift_read_field(&tr1, &prev1)
	testing.expect(t, !stop2)
	testing.expect_value(t, fid2, i32(2))
	testing.expect_value(t, p2c.thrift_read_i32(&tr1), i32(42))

	// Case B: Field 1 = 2-entry MAP<BINARY, I32>:
	//   0x1B (delta 1, MAP), 0x02 (count=2), 0x85 ((BINARY<<4)|I32),
	//   entry 0: len=1 'a' (0x01, 'a'), zigzag(10)=0x14
	//   entry 1: len=1 'b' (0x01, 'b'), zigzag(20)=0x28
	//   Field 2: 0x15 (delta 1, I32), zigzag(99)=198 -> varint [0xC6, 0x01], STOP 0x00
	non_empty_map := []u8{
		0x1B, 0x02, 0x85,
		0x01, 'a', 0x14,
		0x01, 'b', 0x28,
		0x15, 0xC6, 0x01,
		0x00,
	}
	tr2 := p2c.thrift_make(non_empty_map)
	prev2: i32 = 0

	mf1, mft1, mstop1 := p2c.thrift_read_field(&tr2, &prev2)
	testing.expect(t, !mstop1)
	testing.expect_value(t, mf1, i32(1))
	p2c.thrift_skip(&tr2, mft1)

	mf2, _, mstop2 := p2c.thrift_read_field(&tr2, &prev2)
	testing.expect(t, !mstop2)
	testing.expect_value(t, mf2, i32(2))
	testing.expect_value(t, p2c.thrift_read_i32(&tr2), i32(99))
}

// OPTIONAL Parquet column with RLE definition levels [1, 0, 1, 0, 1] and values [10, 30, 50] via col_stream_to_i32_array
@(test)
test_parquet_optional_column_null_positions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := pq_temp_file("optional_i32")
	defer _ = os.remove(path)

	// Payload: [def_len=2 (i32 LE)][bit-packed 1 group of 8 @ bw=1: 0b0001_0101 = 0x15][i32 10, 30, 50]
	page_payload := []u8{
		2, 0, 0, 0, 0x03, 0x15,
		10, 0, 0, 0,
		30, 0, 0, 0,
		50, 0, 0, 0,
	}

	hdr_tw := c2p.tw_make()
	defer c2p.tw_destroy(&hdr_tw)
	{
		prev: i32 = 0
		c2p.tw_field_i32(&hdr_tw, 1, p2c.PPAGE_DATA, &prev)
		c2p.tw_field_i32(&hdr_tw, 2, i32(len(page_payload)), &prev)
		c2p.tw_field_i32(&hdr_tw, 3, i32(len(page_payload)), &prev)
		c2p.tw_field(&hdr_tw, 5, c2p.TW_STRUCT, &prev)
		{
			p2: i32 = 0
			c2p.tw_field_i32(&hdr_tw, 1, 5, &p2) // 5 logical rows (3 valid + 2 null)
			c2p.tw_field_i32(&hdr_tw, 2, 0, &p2) // PLAIN
			c2p.tw_field_i32(&hdr_tw, 3, 3, &p2) // RLE def levels
			c2p.tw_field_i32(&hdr_tw, 4, 3, &p2) // RLE rep levels
			c2p.tw_stop(&hdr_tw)
		}
		c2p.tw_stop(&hdr_tw)
	}
	hdr_bytes := c2p.tw_bytes(&hdr_tw)
	col_total := i64(len(hdr_bytes) + len(page_payload))

	ft_tw := c2p.tw_make()
	defer c2p.tw_destroy(&ft_tw)
	{
		prev: i32 = 0
		c2p.tw_field_i32(&ft_tw, 1, 2, &prev)
		c2p.tw_field_list_begin(&ft_tw, 2, c2p.TW_STRUCT, 2, &prev)
		{
			pr: i32 = 0
			c2p.tw_field_string(&ft_tw, 4, "schema", &pr)
			c2p.tw_field_i32(&ft_tw, 5, 1, &pr)
			c2p.tw_stop(&ft_tw)
		}
		{
			pl: i32 = 0
			c2p.tw_field_i32(&ft_tw, 1, p2c.PTYPE_INT32, &pl)
			c2p.tw_field_i32(&ft_tw, 3, p2c.REP_OPTIONAL, &pl)
			c2p.tw_field_string(&ft_tw, 4, "opt_v", &pl)
			c2p.tw_stop(&ft_tw)
		}
		c2p.tw_field_i64(&ft_tw, 3, 5, &prev)
		c2p.tw_field_list_begin(&ft_tw, 4, c2p.TW_STRUCT, 1, &prev)
		{
			prg: i32 = 0
			c2p.tw_field_list_begin(&ft_tw, 1, c2p.TW_STRUCT, 1, &prg)
			{
				pcc: i32 = 0
				c2p.tw_field_i64(&ft_tw, 2, 4, &pcc)
				c2p.tw_field(&ft_tw, 3, c2p.TW_STRUCT, &pcc)
				{
					pcm: i32 = 0
					c2p.tw_field_i32(&ft_tw, 1, p2c.PTYPE_INT32, &pcm)
					c2p.tw_field_list_begin(&ft_tw, 2, c2p.TW_I32, 1, &pcm)
					c2p.tw_i32(&ft_tw, 0)
					c2p.tw_field_list_begin(&ft_tw, 3, c2p.TW_BINARY, 1, &pcm)
					c2p.tw_varint(&ft_tw, 5)
					append(&ft_tw.buf, 'o', 'p', 't', '_', 'v')
					c2p.tw_field_i32(&ft_tw, 4, 0, &pcm)
					c2p.tw_field_i64(&ft_tw, 5, 5, &pcm)
					c2p.tw_field_i64(&ft_tw, 6, col_total, &pcm)
					c2p.tw_field_i64(&ft_tw, 7, col_total, &pcm)
					c2p.tw_field_i64(&ft_tw, 9, 4, &pcm)
					c2p.tw_stop(&ft_tw)
				}
				c2p.tw_stop(&ft_tw)
			}
			c2p.tw_field_i64(&ft_tw, 2, col_total, &prg)
			c2p.tw_field_i64(&ft_tw, 3, 5, &prg)
			c2p.tw_stop(&ft_tw)
		}
		c2p.tw_stop(&ft_tw)
	}
	ft_bytes := c2p.tw_bytes(&ft_tw)
	flen := i32(len(ft_bytes))

	file_buf := make([dynamic]u8, 0, 12 + int(col_total) + len(ft_bytes), context.temp_allocator)
	append(&file_buf, 'P', 'A', 'R', '1')
	append(&file_buf, ..hdr_bytes)
	append(&file_buf, ..page_payload)
	append(&file_buf, ..ft_bytes)
	append(&file_buf, u8(flen), u8(flen >> 8), u8(flen >> 16), u8(flen >> 24))
	append(&file_buf, 'P', 'A', 'R', '1')
	testing.expect_value(t, os.write_entire_file(path, file_buf[:]), nil)

	num_rows, metas, ok := p2c.parse_footer(file_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, num_rows, i64(5))
	defer {
		for &m in metas {
			delete(transmute([]u8)m.name)
			delete(m.extra_rg_data_offsets)
			delete(m.extra_rg_num_values)
		}
		delete(metas)
	}
	testing.expect_value(t, len(metas), 1)
	if !ok || len(metas) == 0 {
		return
	}

	cs, cs_ok := p2c.col_stream_init(path, metas[0])
	testing.expect(t, cs_ok)
	if !cs_ok {
		return
	}
	defer p2c.col_stream_destroy(&cs)

	arr := p2c.col_stream_to_i32_array(&cs, 5)
	defer oa.array_free(&arr)

	testing.expect_value(t, arr.length, 5)
	if arr.length != 5 {
		return
	}
	testing.expect_value(t, oa.array_get(&arr, 0, i32), i32(10))
	testing.expect(t, oa.array_is_null(&arr, 1), "row 1 must be null")
	testing.expect_value(t, oa.array_get(&arr, 2, i32), i32(30))
	testing.expect(t, oa.array_is_null(&arr, 3), "row 3 must be null")
	testing.expect_value(t, oa.array_get(&arr, 4, i32), i32(50))
}

// Red-First: opening an empty 0-byte CSV file must fail cleanly without leaking cs.buf
@(test)
test_csv_empty_file_no_leak :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := pq_temp_file("empty_csv")
	defer _ = os.remove(path)

	testing.expect_value(t, os.write_entire_file(path, nil), nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer check_no_leaks(t, &track)
	{
		old_alloc := context.allocator
		defer context.allocator = old_alloc
		context.allocator = mem.tracking_allocator(&track)
		cs, ok := c2p.csv_stream_open(path, 4096)
		if ok {
			c2p.csv_stream_destroy(&cs)
		}
		testing.expect(t, !ok, "0-byte CSV has no header and must return ok=false")
	}
}

@(private="file")
pq_append_zigzag_i64 :: proc(dst: ^[dynamic]u8, v: i64) {
	u := u64((v << 1) ~ (v >> 63))
	for {
		b := u8(u & 0x7F)
		u >>= 7
		if u != 0 {
			append(dst, b | 0x80)
		} else {
			append(dst, b)
			break
		}
	}
}

@(test)
test_parquet_corrupt_dict_page_cleanup_no_leak :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pq_path := pq_temp_file("corrupt_dict")
	csv_path := pq_temp_file("corrupt_dict_out")
	defer {
		_ = os.remove(pq_path)
		_ = os.remove(csv_path)
	}

	buf := make([dynamic]u8, 0, 512, context.temp_allocator)
	append(&buf, "PAR1")

	// RG 0: dictionary [100, 200] + RLE indices [0, 1]
	rg0_dict_off := i64(len(buf))
	append(&buf, 0x15, 0x04, 0x15, 0x10, 0x15, 0x10, 0x4C, 0x15, 0x04, 0x15, 0x00, 0x00, 0x00)
	append(&buf, 100, 0, 0, 0, 200, 0, 0, 0)

	rg0_data_off := i64(len(buf))
	append(&buf, 0x15, 0x00, 0x15, 0x06, 0x15, 0x06, 0x2C, 0x15, 0x04, 0x15, 0x04, 0x15, 0x06, 0x15, 0x06, 0x00, 0x00)
	append(&buf, 1, 0x03, 0x02)
	rg0_sz := i64(len(buf)) - rg0_dict_off

	// RG 1: PLAIN [300, 400] with no dictionary page
	rg1_data_off := i64(len(buf))
	append(&buf, 0x15, 0x00, 0x15, 0x10, 0x15, 0x10, 0x2C, 0x15, 0x04, 0x15, 0x00, 0x15, 0x06, 0x15, 0x06, 0x00, 0x00)
	append(&buf, 44, 1, 0, 0, 144, 1, 0, 0)
	rg1_sz := i64(len(buf)) - rg1_data_off

	footer_start := len(buf)
	// FileMetaData: version=1, schema=[root("r", 1 child), REQUIRED INT32 "x"], num_rows=4, 2 row groups
	append(&buf, 0x15, 0x02, 0x19, 0x2C)
	append(&buf, 0x48, 0x01, 'r', 0x15, 0x02, 0x00)
	append(&buf, 0x15, 0x02, 0x25, 0x00, 0x18, 0x01, 'x', 0x00)
	append(&buf, 0x16, 0x08, 0x19, 0x2C)

	// RowGroup 0 metadata (has dictionary_page_offset)
	append(&buf, 0x19, 0x1C, 0x26, 0x00, 0x1C)
	append(&buf, 0x15, 0x02, 0x19, 0x15, 0x04, 0x19, 0x18, 0x01, 'x', 0x15, 0x00, 0x16, 0x04)
	append(&buf, 0x16); pq_append_zigzag_i64(&buf, rg0_sz)
	append(&buf, 0x16); pq_append_zigzag_i64(&buf, rg0_sz)
	append(&buf, 0x26); pq_append_zigzag_i64(&buf, rg0_data_off)
	append(&buf, 0x26); pq_append_zigzag_i64(&buf, rg0_dict_off)
	append(&buf, 0x00, 0x00)
	append(&buf, 0x16); pq_append_zigzag_i64(&buf, rg0_sz)
	append(&buf, 0x16, 0x04, 0x00)

	// RowGroup 1 metadata (PLAIN, no dictionary_page_offset)
	append(&buf, 0x19, 0x1C, 0x26, 0x00, 0x1C)
	append(&buf, 0x15, 0x02, 0x19, 0x15, 0x00, 0x19, 0x18, 0x01, 'x', 0x15, 0x00, 0x16, 0x04)
	append(&buf, 0x16); pq_append_zigzag_i64(&buf, rg1_sz)
	append(&buf, 0x16); pq_append_zigzag_i64(&buf, rg1_sz)
	append(&buf, 0x26); pq_append_zigzag_i64(&buf, rg1_data_off)
	append(&buf, 0x00, 0x00)
	append(&buf, 0x16); pq_append_zigzag_i64(&buf, rg1_sz)
	append(&buf, 0x16, 0x04, 0x00)

	append(&buf, 0x00) // STOP FileMetaData
	flen := u32(len(buf) - footer_start)
	append(&buf, u8(flen), u8(flen >> 8), u8(flen >> 16), u8(flen >> 24))
	append(&buf, "PAR1")

	// Corrupt RG 0 dictionary header so parse_page_header fails inside col_stream_init
	for i in int(rg0_dict_off) ..< int(rg0_data_off) {
		buf[i] = 0x80
	}
	testing.expect_value(t, os.write_entire_file(pq_path, buf[:]), nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer check_no_leaks(t, &track)
	{
		old_alloc := context.allocator
		defer context.allocator = old_alloc
		context.allocator = mem.tracking_allocator(&track)
		_, _, bad_err := p2c.parquet_to_csv_stream(pq_path, csv_path, 64 * 1024 * 1024, chunk_rows_override = 2)
		_, is_init_err := bad_err.(p2c.Parquet_To_CSV_Stream_Init_Error)
		testing.expect(t, is_init_err, "corrupt dictionary page header must return Stream_Init_Error")
	}
}

@(test)
test_rle_decode_malformed_zero_run_and_truncated :: proc(t: ^testing.T) {
	out := make([]int, 6, context.temp_allocator)
	defer free_all(context.temp_allocator)

	// 1. hdr == 0x00 (run_count == 0) must terminate immediately and zero-fill out
	for &v in out { v = 99 }
	p2c.decode_rle_into([]u8{0x00, 0x05}, 8, 6, out)
	for v in out { testing.expect_value(t, v, 0) }

	// 2. hdr == 0x01 (groups == 0) must terminate immediately and zero-fill out
	for &v in out { v = 99 }
	p2c.decode_rle_into([]u8{0x01, 0xFF}, 8, 6, out)
	for v in out { testing.expect_value(t, v, 0) }

	// 3. Truncated RLE run (hdr = 5 values, bw = 8, missing value byte) must not panic and must clear stale values
	for &v in out { v = 99 }
	p2c.decode_rle_into([]u8{0x0A}, 8, 6, out)
	for v in out { testing.expect_value(t, v, 0) }
}

@(test)
test_thrift_and_page_header_reject_truncated_and_allow_empty_dict :: proc(t: ^testing.T) {
	// 1. Page header truncated mid-way through field 5 (DataPageHeader) must return ok = false
	tw := c2p.tw_make()
	defer c2p.tw_destroy(&tw)
	prev: i32 = 0
	c2p.tw_field_i32(&tw, 1, p2c.PPAGE_DATA, &prev)
	c2p.tw_field_i32(&tw, 2, 16, &prev)
	c2p.tw_field_i32(&tw, 3, 16, &prev)
	c2p.tw_field(&tw, 5, c2p.TW_STRUCT, &prev)
	p2: i32 = 0
	c2p.tw_field_i32(&tw, 1, 4, &p2)
	// Intentionally omit inner THRIFT_STOP and outer THRIFT_STOP
	pos := 0
	_, ok_trunc := p2c.parse_page_header(c2p.tw_bytes(&tw), &pos)
	testing.expect(t, !ok_trunc, "truncated DataPageHeader must fail parse_page_header")

	// 2. Empty dictionary page (PPAGE_DICT, uncomp=0, comp=0, num_values=0) must be accepted
	tw_dict := c2p.tw_make()
	defer c2p.tw_destroy(&tw_dict)
	pd: i32 = 0
	c2p.tw_field_i32(&tw_dict, 1, p2c.PPAGE_DICT, &pd)
	c2p.tw_field_i32(&tw_dict, 2, 0, &pd)
	c2p.tw_field_i32(&tw_dict, 3, 0, &pd)
	c2p.tw_field(&tw_dict, 7, c2p.TW_STRUCT, &pd)
	{
		p7: i32 = 0
		c2p.tw_field_i32(&tw_dict, 1, 0, &p7)
		c2p.tw_field_i32(&tw_dict, 2, 2, &p7)
		c2p.tw_stop(&tw_dict)
	}
	c2p.tw_stop(&tw_dict)
	dpos := 0
	ph_dict, ok_dict := p2c.parse_page_header(c2p.tw_bytes(&tw_dict), &dpos)
	testing.expect(t, ok_dict, "empty dictionary page header must be accepted")
	testing.expect_value(t, ph_dict.page_type, p2c.PPAGE_DICT)
	testing.expect_value(t, ph_dict.comp, i32(0))
}

@(test)
test_csv_newline_only_header_rejected_no_leak :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for content, tag in ([]string{"\n", "\r\n"}) {
		path := pq_temp_file(tag == 0 ? "nl_lf" : "nl_crlf")
		defer _ = os.remove(path)
		testing.expect_value(t, os.write_entire_file(path, transmute([]u8)content), nil)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer check_no_leaks(t, &track)
		{
			old_alloc := context.allocator
			defer context.allocator = old_alloc
			context.allocator = mem.tracking_allocator(&track)
			cs, ok := c2p.csv_stream_open(path, 4096)
			if ok {
				c2p.csv_stream_destroy(&cs)
			}
			testing.expect(t, !ok, "newline-only CSV must return ok=false")
		}
	}
}

@(test)
test_parquet_rejects_unbounded_dict_and_page_num_values :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Case A: BYTE_ARRAY dictionary header with ph.comp = 4 and ph.num_values = max(i32)
	// must fail in _col_stream_load_dict without attempting a ~34 GB allocation.
	dict_path := pq_temp_file("unbounded_dict_nvals")
	defer _ = os.remove(dict_path)
	{
		hdr_tw := c2p.tw_make()
		defer c2p.tw_destroy(&hdr_tw)
		prev: i32 = 0
		c2p.tw_field_i32(&hdr_tw, 1, p2c.PPAGE_DICT, &prev)
		c2p.tw_field_i32(&hdr_tw, 2, 4, &prev)
		c2p.tw_field_i32(&hdr_tw, 3, 4, &prev)
		c2p.tw_field(&hdr_tw, 7, c2p.TW_STRUCT, &prev)
		{
			p7: i32 = 0
			c2p.tw_field_i32(&hdr_tw, 1, max(i32), &p7)
			c2p.tw_field_i32(&hdr_tw, 2, 0, &p7)
			c2p.tw_stop(&hdr_tw)
		}
		c2p.tw_stop(&hdr_tw)

		blob := make([dynamic]u8, 0, 64, context.temp_allocator)
		append(&blob, "PAR1")
		append(&blob, ..c2p.tw_bytes(&hdr_tw))
		append(&blob, 0, 0, 0, 0)
		testing.expect_value(t, os.write_entire_file(dict_path, blob[:]), nil)

		meta := p2c.Column_Chunk_Meta{
			ptype       = p2c.PTYPE_BYTE_ARRAY,
			num_values  = 1,
			dict_offset = 4,
			data_offset = 4,
			has_dict    = true,
		}

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer check_no_leaks(t, &track)
		{
			old_alloc := context.allocator
			defer context.allocator = old_alloc
			context.allocator = mem.tracking_allocator(&track)
			cs, ok := p2c.col_stream_init(dict_path, meta)
			if ok {
				p2c.col_stream_destroy(&cs)
			}
			testing.expect(t, !ok, "forged dict num_values exceeding dict_buf capacity must fail")
		}
	}

	// Case B: Data page with ph.num_values = max(i32) on an OPTIONAL column must fail
	// before allocating def_buf or rle_idx_buf.
	page_path := pq_temp_file("unbounded_page_nvals")
	defer _ = os.remove(page_path)
	{
		// Minimal valid 1-row RLE def levels [1] + 1 i32 value [7]
		payload := []u8{2, 0, 0, 0, 0x02, 0x01, 7, 0, 0, 0}
		hdr_tw := c2p.tw_make()
		defer c2p.tw_destroy(&hdr_tw)
		prev: i32 = 0
		c2p.tw_field_i32(&hdr_tw, 1, p2c.PPAGE_DATA, &prev)
		c2p.tw_field_i32(&hdr_tw, 2, i32(len(payload)), &prev)
		c2p.tw_field_i32(&hdr_tw, 3, i32(len(payload)), &prev)
		c2p.tw_field(&hdr_tw, 5, c2p.TW_STRUCT, &prev)
		{
			p5: i32 = 0
			c2p.tw_field_i32(&hdr_tw, 1, max(i32), &p5)
			c2p.tw_field_i32(&hdr_tw, 2, 0, &p5)
			c2p.tw_field_i32(&hdr_tw, 3, 3, &p5)
			c2p.tw_field_i32(&hdr_tw, 4, 3, &p5)
			c2p.tw_stop(&hdr_tw)
		}
		c2p.tw_stop(&hdr_tw)

		blob := make([dynamic]u8, 0, 64, context.temp_allocator)
		append(&blob, "PAR1")
		append(&blob, ..c2p.tw_bytes(&hdr_tw))
		append(&blob, ..payload)
		testing.expect_value(t, os.write_entire_file(page_path, blob[:]), nil)

		meta := p2c.Column_Chunk_Meta{
			ptype         = p2c.PTYPE_INT32,
			num_values    = 1,
			max_def_level = 1,
			data_offset   = 4,
		}

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer check_no_leaks(t, &track)
		{
			old_alloc := context.allocator
			defer context.allocator = old_alloc
			context.allocator = mem.tracking_allocator(&track)
			cs, ok := p2c.col_stream_init(page_path, meta)
			testing.expect(t, ok)
			if ok {
				defer p2c.col_stream_destroy(&cs)
				testing.expect(t, !p2c.col_stream_load_page(&cs), "forged page num_values must fail before allocation")
			}
		}
	}

	// Case C: Data page with ph.comp = max(i32) exceeding file size must fail before allocating page_buf.
	comp_path := pq_temp_file("unbounded_page_comp")
	defer _ = os.remove(comp_path)
	{
		hdr_tw := c2p.tw_make()
		defer c2p.tw_destroy(&hdr_tw)
		prev: i32 = 0
		c2p.tw_field_i32(&hdr_tw, 1, p2c.PPAGE_DATA, &prev)
		c2p.tw_field_i32(&hdr_tw, 2, max(i32), &prev)
		c2p.tw_field_i32(&hdr_tw, 3, max(i32), &prev)
		c2p.tw_field(&hdr_tw, 5, c2p.TW_STRUCT, &prev)
		{
			p5: i32 = 0
			c2p.tw_field_i32(&hdr_tw, 1, 1, &p5)
			c2p.tw_field_i32(&hdr_tw, 2, 0, &p5)
			c2p.tw_stop(&hdr_tw)
		}
		c2p.tw_stop(&hdr_tw)

		blob := make([dynamic]u8, 0, 64, context.temp_allocator)
		append(&blob, "PAR1")
		append(&blob, ..c2p.tw_bytes(&hdr_tw))
		append(&blob, 1, 0, 0, 0)
		testing.expect_value(t, os.write_entire_file(comp_path, blob[:]), nil)

		meta := p2c.Column_Chunk_Meta{
			ptype       = p2c.PTYPE_INT32,
			num_values  = 1,
			data_offset = 4,
		}

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer check_no_leaks(t, &track)
		{
			old_alloc := context.allocator
			defer context.allocator = old_alloc
			context.allocator = mem.tracking_allocator(&track)
			cs, ok := p2c.col_stream_init(comp_path, meta)
			testing.expect(t, ok)
			if ok {
				defer p2c.col_stream_destroy(&cs)
				testing.expect(t, !p2c.col_stream_load_page(&cs), "forged page comp exceeding file size must fail")
			}
		}
	}
}

@(test)
test_decode_rle_into_bit_widths_and_tails :: proc(t: ^testing.T) {
	// bit_width = 1: 10 values (group 0 fast path + group 1 tail fallback)
	bw1_data := [?]u8{5, 0b10110010, 0b00000011}
	bw1_out: [10]int
	p2c.decode_rle_into(bw1_data[:], 1, 10, bw1_out[:])
	want1 := [10]int{0, 1, 0, 0, 1, 1, 0, 1, 1, 1}
	testing.expect_value(t, bw1_out, want1)

	// bit_width = 5: 18 values (u64 fast path + tail)
	bw5_data := make([]u8, 1 + 3 * 5, context.temp_allocator)
	defer free_all(context.temp_allocator)
	bw5_data[0] = (3 << 1) | 1 // 3 groups = 24 slots
	for i in 0 ..< 18 {
		val := u64((i * 3 + 1) & 0x1F)
		bit_pos := i * 5
		for b in 0 ..< 5 {
			if (val >> uint(b)) & 1 != 0 {
				bw5_data[1 + (bit_pos + b) / 8] |= u8(1) << uint((bit_pos + b) % 8)
			}
		}
	}
	bw5_out: [18]int
	p2c.decode_rle_into(bw5_data, 5, 18, bw5_out[:])
	for i in 0 ..< 18 {
		testing.expect_value(t, bw5_out[i], (i * 3 + 1) & 0x1F)
	}

	// bit_width = 11: 18 values (u128 fast path + group 1/2 tail fallback)
	bw11_data := make([]u8, 1 + 3 * 11, context.temp_allocator)
	bw11_data[0] = (3 << 1) | 1
	for i in 0 ..< 18 {
		val := u64((i * 137 + 5) & 0x7FF)
		bit_pos := i * 11
		for b in 0 ..< 11 {
			if (val >> uint(b)) & 1 != 0 {
				bw11_data[1 + (bit_pos + b) / 8] |= u8(1) << uint((bit_pos + b) % 8)
			}
		}
	}
	bw11_out: [18]int
	p2c.decode_rle_into(bw11_data, 11, 18, bw11_out[:])
	for i in 0 ..< 18 {
		testing.expect_value(t, bw11_out[i], (i * 137 + 5) & 0x7FF)
	}
}

@(test)
test_csv_and_out_simd_16byte_boundaries :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	csv_in  := pq_temp_file("simd_bounds_in")
	pq_mid  := pq_temp_file("simd_bounds_mid")
	csv_out := pq_temp_file("simd_bounds_out")
	defer {
		_ = os.remove(csv_in)
		_ = os.remove(pq_mid)
		_ = os.remove(csv_out)
	}

	// Lengths 15, 16, 17, 31, 32, 33 with delimiters/quotes at lane 0, lane 15, and across refill.
	s15 := "abcdefghijklmno"
	s16 := "abcdefghijklmnop"
	s17 := "abcdefghijklmnopq"
	s31 := "0123456789abcdef0123456789abcde"
	s32 := "0123456789abcdef0123456789abcdef"
	s33 := "0123456789abcdef0123456789abcdefg"
	q16 := "0123456789abcde,z"   // comma at lane 15
	q17 := ",123456789abcdef01"  // comma at lane 0
	q32 := "0123456789abcdef0123456789abc\"ef" // quote inside 32-byte field

	content := fmt.tprintf(
		"c1,c2,c3\n%s,%s,%s\n%s,%s,%s\n\"%s\",\"%s\",\"%s\"\n",
		s15, s16, s17,
		s31, s32, s33,
		q16, q17, "0123456789abcdef0123456789abc\"\"ef",
	)
	_ = q32
	testing.expect_value(t, os.write_entire_file(csv_in, transmute([]u8)content), nil)

	// Small buf_size_override (16) forces CSV_Stream buffer refills mid-field.
	rows, _, c_err := c2p.csv_to_parquet_stream(csv_in, pq_mid, 64 * 1024 * 1024, buf_size_override = 16)
	testing.expect_value(t, c_err, nil)
	testing.expect_value(t, rows, 3)

	p_rows, _, p_err := p2c.parquet_to_csv_stream(pq_mid, csv_out, 64 * 1024 * 1024)
	testing.expect_value(t, p_err, nil)
	testing.expect_value(t, p_rows, i64(3))

	out_bytes, r_err := os.read_entire_file(csv_out, context.temp_allocator)
	testing.expect_value(t, r_err, nil)
	testing.expect_value(t, string(out_bytes), content)
}

free_pq_metas :: proc(metas: []p2c.Column_Chunk_Meta) {
	for &m in metas {
		delete(transmute([]u8)m.name)
		delete(m.extra_rg_data_offsets)
		delete(m.extra_rg_num_values)
		delete(m.extra_rg_dict_offsets)
		delete(m.extra_rg_has_dict)
	}
	delete(metas)
}

@(test)
test_parquet_parse_footer_corrupt_magic_and_truncated :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	csv_in  := pq_temp_file("bad_footer_in")
	pq_path := pq_temp_file("bad_footer_pq")
	bad_pq  := pq_temp_file("bad_footer_corrupt")
	csv_out := pq_temp_file("bad_footer_out")
	defer {
		_ = os.remove(csv_in)
		_ = os.remove(pq_path)
		_ = os.remove(bad_pq)
		_ = os.remove(csv_out)
	}

	testing.expect_value(t, os.write_entire_file(csv_in, transmute([]u8)string("a,b\n1,hello\n2,world\n")), nil)
	rows, _, c_err := c2p.csv_to_parquet_stream(csv_in, pq_path, 64 * 1024 * 1024)
	testing.expect_value(t, c_err, nil)
	testing.expect_value(t, rows, 2)

	orig, r_err := os.read_entire_file(pq_path, context.allocator)
	testing.expect_value(t, r_err, nil)
	defer delete(orig)

	// Baseline: valid footer parses cleanly
	num_rows, metas, base_ok := p2c.parse_footer(orig)
	testing.expect(t, base_ok, "valid Parquet file must parse cleanly")
	testing.expect_value(t, num_rows, i64(2))
	testing.expect_value(t, len(metas), 2)
	free_pq_metas(metas)

	n := len(orig)
	testing.expect(t, n > 12)

	// 1. Short slices (< 12 bytes)
	for cut in ([]int{0, 4, 8, 11}) {
		_, m_short, ok_short := p2c.parse_footer(orig[:cut])
		testing.expectf(t, !ok_short, "short slice of len %d must fail parse_footer", cut)
		if ok_short { free_pq_metas(m_short) }
	}

	buf := make([]u8, n, context.allocator)
	defer delete(buf)

	// 2. Corrupt leading and trailing PAR1 magic bytes
	for pos in ([]int{0, 3, n - 4, n - 1}) {
		copy(buf, orig)
		buf[pos] = 'X'
		_, m_magic, ok_magic := p2c.parse_footer(buf)
		testing.expectf(t, !ok_magic, "corrupted PAR1 magic at byte %d must fail", pos)
		if ok_magic { free_pq_metas(m_magic) }
	}

	// 3. Invalid footer_len values: 0, negative (-1), and n - 11 (overlaps leading PAR1)
	write_i32_le :: proc(dst: []u8, off: int, val: i32) {
		u := u32(val)
		dst[off + 0] = u8(u)
		dst[off + 1] = u8(u >> 8)
		dst[off + 2] = u8(u >> 16)
		dst[off + 3] = u8(u >> 24)
	}

	for bad_len in ([]i32{0, -1, i32(n - 11), i32(n)}) {
		copy(buf, orig)
		write_i32_le(buf, n - 8, bad_len)
		_, m_len, ok_len := p2c.parse_footer(buf)
		testing.expectf(t, !ok_len, "footer_len=%d must fail parse_footer", bad_len)
		if ok_len { free_pq_metas(m_len) }
	}

	// 4. Truncated Thrift footer metadata (first half of serialized FileMetaData repacked with PAR1 magic)
	orig_footer_len := i32(orig[n-8]) | (i32(orig[n-7]) << 8) | (i32(orig[n-6]) << 16) | (i32(orig[n-5]) << 24)
	orig_footer := orig[n - 8 - int(orig_footer_len) : n - 8]
	trunc_len := max(1, len(orig_footer) / 2)
	trunc_pq := make([]u8, 4 + trunc_len + 8, context.allocator)
	defer delete(trunc_pq)
	copy(trunc_pq[:4], transmute([]u8)string("PAR1"))
	copy(trunc_pq[4:4+trunc_len], orig_footer[:trunc_len])
	write_i32_le(trunc_pq, 4 + trunc_len, i32(trunc_len))
	copy(trunc_pq[4+trunc_len+4:], transmute([]u8)string("PAR1"))
	_, m_trunc, ok_trunc := p2c.parse_footer(trunc_pq)
	testing.expect(t, !ok_trunc, "truncated Thrift footer must fail parse_footer")
	if ok_trunc { free_pq_metas(m_trunc) }

	// 5. parquet_to_csv_stream surfaces Parquet_To_CSV_Bad_Footer_Error on overlapping footer_len
	copy(buf, orig)
	write_i32_le(buf, n - 8, i32(n - 11))
	testing.expect_value(t, os.write_entire_file(bad_pq, buf), nil)
	_, _, stream_err := p2c.parquet_to_csv_stream(bad_pq, csv_out, 64 * 1024 * 1024)
	_, is_bad_footer := stream_err.(p2c.Parquet_To_CSV_Bad_Footer_Error)
	testing.expect(t, is_bad_footer, "parquet_to_csv_stream must return Bad_Footer_Error on invalid footer_len")
}

@(test)
test_parquet_rejects_unsupported_compression_codecs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	csv_in  := pq_temp_file("codec_in")
	pq_path := pq_temp_file("codec_pq")
	bad_pq  := pq_temp_file("codec_snappy_pq")
	csv_out := pq_temp_file("codec_out")
	defer {
		_ = os.remove(csv_in)
		_ = os.remove(pq_path)
		_ = os.remove(bad_pq)
		_ = os.remove(csv_out)
	}

	testing.expect_value(t, os.write_entire_file(csv_in, transmute([]u8)string("col_codec_marker\nval1\nval2\n")), nil)
	rows, _, c_err := c2p.csv_to_parquet_stream(csv_in, pq_path, 64 * 1024 * 1024)
	testing.expect_value(t, c_err, nil)
	testing.expect_value(t, rows, 2)

	orig, r_err := os.read_entire_file(pq_path, context.allocator)
	testing.expect_value(t, r_err, nil)
	defer delete(orig)

	_, metas, ok := p2c.parse_footer(orig)
	testing.expect(t, ok)
	testing.expect_value(t, len(metas), 1)
	defer free_pq_metas(metas)
	testing.expect_value(t, metas[0].codec, i32(0))

	// 1. col_stream_init rejects non-zero codecs (SNAPPY=1, ZSTD=6)
	for bad_codec in ([]i32{1, 6}) {
		bad_meta := metas[0]
		bad_meta.codec = bad_codec
		_, init_ok := p2c.col_stream_init(pq_path, bad_meta)
		testing.expectf(t, !init_ok, "col_stream_init must reject unsupported codec %d", bad_codec)
	}

	// 2. col_stream_load_page rejects non-zero stream codec even after init
	{
		cs, cs_ok := p2c.col_stream_init(pq_path, metas[0])
		testing.expect(t, cs_ok)
		defer p2c.col_stream_destroy(&cs)
		cs.codec = 2 // GZIP
		testing.expect(t, !p2c.col_stream_load_page(&cs), "col_stream_load_page must reject non-zero codec")
	}

	// 3. Patch Thrift ColumnMetaData field 4 (codec=0 -> 1/SNAPPY) in footer & test full pipeline rejection
	patched := make([]u8, len(orig), context.allocator)
	defer delete(patched)
	copy(patched, orig)

	marker := "col_codec_marker"
	n := len(patched)
	footer_len := int(patched[n-8]) | (int(patched[n-7]) << 8) | (int(patched[n-6]) << 16) | (int(patched[n-5]) << 24)
	footer_start := n - 8 - footer_len
	patch_pos := -1
	search: for i in footer_start ..< n - 8 - len(marker) - 2 {
		for j in 0 ..< len(marker) {
			if patched[i+j] != marker[j] { continue search }
		}
		// ColumnMetaData path_in_schema (field 3) is immediately followed by field 4 TW_I32 (0x15) and zigzag(0)=0x00.
		if patched[i+len(marker)] == 0x15 && patched[i+len(marker)+1] == 0x00 {
			patch_pos = i + len(marker) + 1
			break
		}
	}
	testing.expect(t, patch_pos >= 0, "expected ColumnMetaData codec field in Thrift footer")
	if patch_pos >= 0 {
		patched[patch_pos] = 0x02 // zigzag(1) -> codec = 1 (SNAPPY)
		_, p_metas, p_ok := p2c.parse_footer(patched)
		testing.expect(t, p_ok)
		testing.expect_value(t, p_metas[0].codec, i32(1))
		free_pq_metas(p_metas)

		testing.expect_value(t, os.write_entire_file(bad_pq, patched), nil)
		_, _, stream_err := p2c.parquet_to_csv_stream(bad_pq, csv_out, 64 * 1024 * 1024)
		_, is_init_err := stream_err.(p2c.Parquet_To_CSV_Stream_Init_Error)
		testing.expect(t, is_init_err, "parquet_to_csv_stream must reject non-uncompressed codec with Stream_Init_Error")
	}
}

@(test)
test_cli_csv_to_parquet_and_parquet_to_csv_flags_and_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// 1. Unit tests for csv_to_parquet.parse_cli_args
	{
		mb, inp, outp, ok := c2p.parse_cli_args([]string{"in.csv", "out.parquet"})
		testing.expect(t, ok)
		testing.expect_value(t, mb, 200)
		testing.expect_value(t, inp, "in.csv")
		testing.expect_value(t, outp, "out.parquet")

		mb2, inp2, outp2, ok2 := c2p.parse_cli_args([]string{"-m", "64", "a.csv", "b.parquet"})
		testing.expect(t, ok2)
		testing.expect_value(t, mb2, 64)
		testing.expect_value(t, inp2, "a.csv")
		testing.expect_value(t, outp2, "b.parquet")

		bad_cases := [][](string){
			[]string{},
			[]string{"only_one.csv"},
			[]string{"-m"},
			[]string{"a.csv", "b.parquet", "-m"},
			[]string{"-m", "0", "a.csv", "b.parquet"},
			[]string{"-m", "-5", "a.csv", "b.parquet"},
			[]string{"-m", "abc", "a.csv", "b.parquet"},
			[]string{"-x", "a.csv", "b.parquet"},
			[]string{"a.csv", "b.parquet", "extra"},
		}
		for args in bad_cases {
			_, _, _, bad_ok := c2p.parse_cli_args(args)
			testing.expectf(t, !bad_ok, "c2p.parse_cli_args must reject %v", args)
		}
	}

	// 2. Unit tests for parquet_to_csv.parse_cli_args
	{
		mb, inp, outp, ok := p2c.parse_cli_args([]string{"in.parquet"})
		testing.expect(t, ok)
		testing.expect_value(t, mb, 200)
		testing.expect_value(t, inp, "in.parquet")
		testing.expect_value(t, outp, "-")

		mb2, inp2, outp2, ok2 := p2c.parse_cli_args([]string{"in.parquet", "-", "-m", "128"})
		testing.expect(t, ok2)
		testing.expect_value(t, mb2, 128)
		testing.expect_value(t, inp2, "in.parquet")
		testing.expect_value(t, outp2, "-")

		bad_cases := [][](string){
			[]string{},
			[]string{"-", "out.csv"},
			[]string{"-m"},
			[]string{"-m", "0", "in.parquet"},
			[]string{"-m", "-1", "in.parquet"},
			[]string{"-m", "nope", "in.parquet"},
			[]string{"--bogus", "in.parquet"},
			[]string{"in.parquet", "out.csv", "extra"},
		}
		for args in bad_cases {
			_, _, _, bad_ok := p2c.parse_cli_args(args)
			testing.expectf(t, !bad_ok, "p2c.parse_cli_args must reject %v", args)
		}
	}

	// 3. Build temporary CLI executables and verify subprocess exit codes
	c2p_bin := pq_temp_file("cli_c2p_bin")
	p2c_bin := pq_temp_file("cli_p2c_bin")
	csv_in  := pq_temp_file("cli_in")
	pq_mid  := pq_temp_file("cli_mid")
	csv_out := pq_temp_file("cli_out")
	defer {
		_ = os.remove(c2p_bin)
		_ = os.remove(p2c_bin)
		_ = os.remove(csv_in)
		_ = os.remove(pq_mid)
		_ = os.remove(csv_out)
	}

	st_b1, _, _, err_b1 := os.process_exec(
		os.Process_Desc{command = []string{"odin", "build", "examples/csv_to_parquet", fmt.tprintf("-out:%s", c2p_bin)}},
		context.temp_allocator,
	)
	testing.expect_value(t, err_b1, nil)
	testing.expect_value(t, st_b1.exit_code, 0)

	st_b2, _, _, err_b2 := os.process_exec(
		os.Process_Desc{command = []string{"odin", "build", "examples/parquet_to_csv", fmt.tprintf("-out:%s", p2c_bin)}},
		context.temp_allocator,
	)
	testing.expect_value(t, err_b2, nil)
	testing.expect_value(t, st_b2.exit_code, 0)

	sample_csv := "k,v\nalpha,10\nbeta,20\n"
	testing.expect_value(t, os.write_entire_file(csv_in, transmute([]u8)sample_csv), nil)

	st_ok1, _, _, err_ok1 := os.process_exec(
		os.Process_Desc{command = []string{c2p_bin, "-m", "32", csv_in, pq_mid}},
		context.temp_allocator,
	)
	testing.expect_value(t, err_ok1, nil)
	testing.expect_value(t, st_ok1.exit_code, 0)

	st_ok2, _, _, err_ok2 := os.process_exec(
		os.Process_Desc{command = []string{p2c_bin, "-m", "32", pq_mid, csv_out}},
		context.temp_allocator,
	)
	testing.expect_value(t, err_ok2, nil)
	testing.expect_value(t, st_ok2.exit_code, 0)

	out_bytes, r_err := os.read_entire_file(csv_out, context.temp_allocator)
	testing.expect_value(t, r_err, nil)
	testing.expect_value(t, string(out_bytes), sample_csv)

	bad_cmds := [][](string){
		[]string{c2p_bin},
		[]string{c2p_bin, "-m", "0", csv_in, pq_mid},
		[]string{c2p_bin, "-m", "abc", csv_in, pq_mid},
		[]string{c2p_bin, csv_in, pq_mid, "-m"},
		[]string{c2p_bin, fmt.tprintf("%s_missing", csv_in), pq_mid},
		[]string{p2c_bin},
		[]string{p2c_bin, "-m", "0", pq_mid, csv_out},
		[]string{p2c_bin, "-m", "abc", pq_mid, csv_out},
		[]string{p2c_bin, pq_mid, csv_out, "-m"},
		[]string{p2c_bin, fmt.tprintf("%s_missing", pq_mid), csv_out},
	}
	for cmd in bad_cmds {
		st_bad, _, _, err_bad := os.process_exec(os.Process_Desc{command = cmd}, context.temp_allocator)
		testing.expect_value(t, err_bad, nil)
		testing.expectf(t, st_bad.exit_code != 0, "expected non-zero exit for %v, got %d", cmd, st_bad.exit_code)
	}
}
