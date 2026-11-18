package skadi

import "core:c"
import "core:mem"
import lz4 "vendor:compress/lz4"

LZ4F_VERSION :: c.uint(100)

@(private = "file")
_ :: lz4.VERSION_NUMBER

when ODIN_OS == .Windows {
	@(default_calling_convention = "c")
	foreign {
		LZ4F_isError                    :: proc(code: c.size_t) -> c.uint ---
		LZ4F_compressFrameBound         :: proc(srcSize: c.size_t, preferencesPtr: rawptr) -> c.size_t ---
		LZ4F_compressFrame              :: proc(dstBuffer: rawptr, dstCapacity: c.size_t, srcBuffer: rawptr, srcSize: c.size_t, preferencesPtr: rawptr) -> c.size_t ---
		LZ4F_createDecompressionContext :: proc(dctxPtr: ^rawptr, version: c.uint) -> c.size_t ---
		LZ4F_freeDecompressionContext   :: proc(dctx: rawptr) -> c.size_t ---
		LZ4F_resetDecompressionContext  :: proc(dctx: rawptr) ---
		LZ4F_decompress                 :: proc(dctx: rawptr, dstBuffer: rawptr, dstSizePtr: ^c.size_t, srcBuffer: rawptr, srcSizePtr: ^c.size_t, dOptPtr: rawptr) -> c.size_t ---
	}
} else {
	foreign import lz4f_lib "system:lz4"
	@(default_calling_convention = "c")
	foreign lz4f_lib {
		LZ4F_isError                    :: proc(code: c.size_t) -> c.uint ---
		LZ4F_compressFrameBound         :: proc(srcSize: c.size_t, preferencesPtr: rawptr) -> c.size_t ---
		LZ4F_compressFrame              :: proc(dstBuffer: rawptr, dstCapacity: c.size_t, srcBuffer: rawptr, srcSize: c.size_t, preferencesPtr: rawptr) -> c.size_t ---
		LZ4F_createDecompressionContext :: proc(dctxPtr: ^rawptr, version: c.uint) -> c.size_t ---
		LZ4F_freeDecompressionContext   :: proc(dctx: rawptr) -> c.size_t ---
		LZ4F_resetDecompressionContext  :: proc(dctx: rawptr) ---
		LZ4F_decompress                 :: proc(dctx: rawptr, dstBuffer: rawptr, dstSizePtr: ^c.size_t, srcBuffer: rawptr, srcSizePtr: ^c.size_t, dOptPtr: rawptr) -> c.size_t ---
	}
}

// Encodes one non-empty Arrow IPC body buffer using the Arrow BodyCompression
// framing: [uncompressed_len:i64le][lz4_frame_bytes], falling back to
// [uncompressed_len=-1:i64le][raw_bytes] whenever LZ4 frame encoding does not
// shrink the buffer.
_ipc_lz4_compress_buffer :: proc(
	src:       [^]u8,
	raw_len:   i64,
	allocator: mem.Allocator,
) -> (backing: []u8, out_len: i64, ok: bool) {
	if raw_len <= 0 || src == nil {
		return nil, 0, true
	}
	if u64(raw_len) > u64(max(int) - 64) {
		return nil, 0, false
	}

	bound := LZ4F_compressFrameBound(c.size_t(raw_len), nil)
	if LZ4F_isError(bound) != 0 || bound > c.size_t(max(int) - 8) {
		return nil, 0, false
	}

	cap_bytes := max(8 + int(bound), 8 + int(raw_len))
	buf, alloc_err := mem.alloc_bytes_non_zeroed(cap_bytes, 8, allocator)
	if alloc_err != nil {
		return nil, 0, false
	}

	written := LZ4F_compressFrame(
		raw_data(buf[8:]),
		bound,
		rawptr(src),
		c.size_t(raw_len),
		nil,
	)
	if LZ4F_isError(written) == 0 && i64(8 + int(written)) < raw_len {
		_le_i64(buf[:8], raw_len)
		return buf, i64(8 + int(written)), true
	}

	// Incompressible or tiny buffer: store raw payload with -1 sentinel.
	_le_i64(buf[:8], -1)
	mem.copy(raw_data(buf[8:]), rawptr(src), int(raw_len))
	return buf, 8 + raw_len, true
}

// Decodes one Arrow IPC body buffer compressed with LZ4_FRAME.
// Always returns a 64-byte-aligned owned Buffer (or zero-value Buffer for empty
// 0-byte payloads) so downstream SIMD kernels observe ARROW_ALIGNMENT guarantees.
_ipc_lz4_decompress_buffer :: proc(
	dctx:      rawptr,
	body:      []u8,
	off:       int,
	length:    int,
	allocator: mem.Allocator,
) -> (buf: Buffer, ok: bool) {
	if length == 0 {
		return {}, true
	}
	if length < 8 || !_fits(body, off, length) {
		return {}, false
	}

	uncomp_len_i64 := _rd_i64(body, off)
	payload        := body[off + 8 : off + length]
	comp_len       := len(payload)

	if uncomp_len_i64 == -1 {
		if comp_len == 0 {
			return {}, true
		}
		b, err := buffer_make(comp_len, allocator)
		if err != nil {
			return {}, false
		}
		mem.copy(rawptr(b.data), raw_data(payload), comp_len)
		return b, true
	}

	if uncomp_len_i64 < 0 || uncomp_len_i64 > i64(max(int) / 2) {
		return {}, false
	}
	// Anti-OOM fuzz guard: valid LZ4 streams cannot expand arbitrarily far
	// beyond the input size (~255:1 max theoretical block expansion).
	if uncomp_len_i64 > i64(comp_len) * 260 + 64 {
		return {}, false
	}
	if comp_len == 0 {
		return {}, false
	}

	uncomp_len := int(uncomp_len_i64)
	b: Buffer
	if uncomp_len > 0 {
		err: mem.Allocator_Error
		b, err = buffer_make(uncomp_len, allocator)
		if err != nil {
			return {}, false
		}
	}

	LZ4F_resetDecompressionContext(dctx)
	dummy: [1]u8
	src_pos := 0
	dst_pos := 0
	ret     := c.size_t(0)
	for {
		src_rem := c.size_t(comp_len - src_pos)
		dst_cap := c.size_t(uncomp_len - dst_pos)
		src_ptr: rawptr = nil
		if src_pos < comp_len {
			src_ptr = rawptr(&payload[src_pos])
		}
		dst_ptr: rawptr = rawptr(&dummy[0])
		if uncomp_len > 0 && dst_pos < uncomp_len {
			dst_ptr = rawptr(b.data[dst_pos:])
		}
		ret = LZ4F_decompress(dctx, dst_ptr, &dst_cap, src_ptr, &src_rem, nil)
		if LZ4F_isError(ret) != 0 {
			buffer_free(&b)
			return {}, false
		}
		src_pos += int(src_rem)
		dst_pos += int(dst_cap)
		if ret == 0 {
			break
		}
		if src_pos >= comp_len || (src_rem == 0 && dst_cap == 0) {
			buffer_free(&b)
			return {}, false
		}
	}

	if dst_pos != uncomp_len || src_pos != comp_len {
		buffer_free(&b)
		return {}, false
	}
	return b, true
}
