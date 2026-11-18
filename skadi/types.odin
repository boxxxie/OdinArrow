/*
Package `skadi` implements the Apache Arrow columnar in-memory format, compute
kernels, companion compressed encodings, and Arrow IPC (Feather v2) serialization
in Odin.

Core components:
- **Columnar memory**: 64-byte aligned `Buffer`, packed validity `Bitmap`,
  zero-copy `array_slice`, and single-threaded `Buffer_Pool` recycling.
- **Type system & containers**: 16 flat `DataType` variants, `Array`,
  `Primitive_Builder`, variable-length string/binary builders, `Schema`,
  `Record_Batch` (with refcounted `mmap` backing), and `Table` / `Chunked_Array`.
- **Compute, selection & fusion**: Target-scoped AVX2/SIMD reductions,
  selectivity-hybrid `compute_filter`, prefetched `compute_take`, packed `u32`
  LSD radix `compute_sort_indices`, lazy `Selection` vectors with L1d `u16`
  morsels, single-pass `*_where` fused aggregates, and persistent thread-pool
  `*_parallel` kernels.
- **Companion encodings**: `Umbra_Array` (16-byte German strings), `RLE_Array(T)`
  (run-end encoding), and `Dict_Array(T)` / `Str_Dict_Array` (dictionary encoding).
- **Arrow IPC**: Self-contained FlatBuffers encoder/decoder, vectored `writev`
  writes, and `mmap` zero-copy file/stream reads compatible with PyArrow and
  Apache Arrow C++.
*/
package skadi

// --- Type tags -----------------------------------------------------------
// Empty structs — the tagged union discriminant IS the type identity.
// Types with parameters (Timestamp, FixedSizeList, etc.) will grow fields.

Null_Type         :: struct{}
Bool_Type         :: struct{}
Int8_Type         :: struct{}
Int16_Type        :: struct{}
Int32_Type        :: struct{}
Int64_Type        :: struct{}
UInt8_Type        :: struct{}
UInt16_Type       :: struct{}
UInt32_Type       :: struct{}
UInt64_Type       :: struct{}
Float32_Type      :: struct{}
Float64_Type      :: struct{}
Decimal64_Type    :: struct { precision: i32, scale: i32 } // 8-byte little-endian i64
Decimal128_Type   :: struct { precision: i32, scale: i32 } // 16-byte little-endian i128
String_Type       :: struct{} // UTF-8, i32 offsets
Large_String_Type :: struct{} // UTF-8, i64 offsets
Binary_Type       :: struct{} // raw bytes, i32 offsets
Large_Binary_Type :: struct{} // raw bytes, i64 offsets

DataType :: union {
	Null_Type,
	Bool_Type,
	Int8_Type, Int16_Type, Int32_Type, Int64_Type,
	UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type,
	Float32_Type, Float64_Type,
	Decimal64_Type, Decimal128_Type,
	String_Type, Large_String_Type,
	Binary_Type, Large_Binary_Type,
}

// --- Metadata helpers (exhaustive switches required by the compiler) ------

// Fixed byte width per element; -1 for variable-length; 0 for Null/Bool.
type_byte_width :: proc(dt: DataType) -> int {
	switch _ in dt {
	case Null_Type:                           return 0
	case Bool_Type:                           return 0
	case Int8_Type:                           return 1
	case Int16_Type:                          return 2
	case Int32_Type:                          return 4
	case Int64_Type:                          return 8
	case UInt8_Type:                          return 1
	case UInt16_Type:                         return 2
	case UInt32_Type:                         return 4
	case UInt64_Type:                         return 8
	case Float32_Type:                        return 4
	case Float64_Type:                        return 8
	case Decimal64_Type:                      return 8
	case Decimal128_Type:                     return 16
	case String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:      return -1
	}
	return 0
}

type_is_bit_packed :: proc(dt: DataType) -> bool {
	_, ok := dt.(Bool_Type)
	return ok
}

type_is_variable_length :: proc(dt: DataType) -> bool {
	switch _ in dt {
	case String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		return true
	case Null_Type, Bool_Type,
	     Int8_Type, Int16_Type, Int32_Type, Int64_Type,
	     UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type,
	     Float32_Type, Float64_Type,
	     Decimal64_Type, Decimal128_Type:
		return false
	}
	return false
}

type_is_integer :: proc(dt: DataType) -> bool {
	switch _ in dt {
	case Int8_Type, Int16_Type, Int32_Type, Int64_Type,
	     UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type:
		return true
	case Null_Type, Bool_Type, Float32_Type, Float64_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		return false
	}
	return false
}

type_is_decimal :: proc(dt: DataType) -> bool {
	switch _ in dt {
	case Decimal64_Type, Decimal128_Type:
		return true
	case Null_Type, Bool_Type,
	     Int8_Type, Int16_Type, Int32_Type, Int64_Type,
	     UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type,
	     Float32_Type, Float64_Type,
	     String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		return false
	}
	return false
}

type_is_signed :: proc(dt: DataType) -> bool {
	switch _ in dt {
	case Int8_Type, Int16_Type, Int32_Type, Int64_Type,
	     Decimal64_Type, Decimal128_Type:
		return true
	case Null_Type, Bool_Type,
	     UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type,
	     Float32_Type, Float64_Type,
	     String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		return false
	}
	return false
}

type_is_floating :: proc(dt: DataType) -> bool {
	switch _ in dt {
	case Float32_Type, Float64_Type:
		return true
	case Null_Type, Bool_Type,
	     Int8_Type, Int16_Type, Int32_Type, Int64_Type,
	     UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		return false
	}
	return false
}

type_name :: proc(dt: DataType) -> string {
	switch _ in dt {
	case Null_Type:         return "null"
	case Bool_Type:         return "bool"
	case Int8_Type:         return "int8"
	case Int16_Type:        return "int16"
	case Int32_Type:        return "int32"
	case Int64_Type:        return "int64"
	case UInt8_Type:        return "uint8"
	case UInt16_Type:       return "uint16"
	case UInt32_Type:       return "uint32"
	case UInt64_Type:       return "uint64"
	case Float32_Type:      return "float32"
	case Float64_Type:      return "float64"
	case Decimal64_Type:    return "decimal64"
	case Decimal128_Type:   return "decimal128"
	case String_Type:       return "string"
	case Large_String_Type: return "large_string"
	case Binary_Type:       return "binary"
	case Large_Binary_Type: return "large_binary"
	}
	return "unknown"
}
