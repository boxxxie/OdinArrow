package skadi

// General operator fusion via compile-time specialisation.
//
// A query engine fuses a pipeline by *generating* a single loop that evaluates
// the predicate and every aggregate per row — no intermediate mask array, no
// filtered array, one pass over memory. Odin has no runtime JIT, but its
// monomorphisation is the compile-time equivalent: one generic driver,
// parameterised on the value type and the comparison operator (comptime `$OP`),
// is specialised by the compiler into a tight fused kernel for each combination.
//
// `compute_agg_where_compare` is the worked example: it computes sum, count,
// min and max of `values` for the rows where `pred <op> scalar`, in a single
// pass, producing all four aggregates at once. The unfused equivalent is a
// compare (materialise a mask) followed by a separate pass per aggregate.

Aggregates :: struct {
	sum:     f64,
	count:   int,
	min_val: f64,
	max_val: f64,
	valid:   bool, // any row matched
}

// SELECT sum,count,min,max FROM values WHERE pred <op> scalar — fused, one pass.
// `values` and `pred` must share the same numeric type.
compute_agg_where_compare :: proc(values, pred: ^Array, op: Compare_Op, scalar: f64) -> Aggregates {
	assert(values.length == pred.length, "compute_agg_where_compare: length mismatch")
	assert(values.type == pred.type, "compute_agg_where_compare: type mismatch")
	switch _ in values.type {
	case Int8_Type:    return _agg_where_int_f64(values, pred, op, scalar, i8)
	case Int16_Type:   return _agg_where_int_f64(values, pred, op, scalar, i16)
	case Int32_Type:   return _agg_where_int_f64(values, pred, op, scalar, i32)
	case Int64_Type:   return _agg_where_int_f64(values, pred, op, scalar, i64)
	case UInt8_Type:   return _agg_where_int_f64(values, pred, op, scalar, u8)
	case UInt16_Type:  return _agg_where_int_f64(values, pred, op, scalar, u16)
	case UInt32_Type:  return _agg_where_int_f64(values, pred, op, scalar, u32)
	case UInt64_Type:  return _agg_where_int_f64(values, pred, op, scalar, u64)
	case Float32_Type: return _agg_where_float_f64(values, pred, op, scalar, f32)
	case Float64_Type: return _agg_where_float_f64(values, pred, op, scalar, f64)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_agg_where_compare: type does not support aggregation")
	}
	return {}
}

compute_agg_where_compare_i64 :: proc(values, pred: ^Array, op: Compare_Op, scalar: i64) -> Aggregates {
	assert(values.length == pred.length, "compute_agg_where_compare_i64: length mismatch")
	assert(values.type == pred.type, "compute_agg_where_compare_i64: type mismatch")
	switch _ in values.type {
	case Int8_Type:    return _agg_where_int_i64(values, pred, op, scalar, i8)
	case Int16_Type:   return _agg_where_int_i64(values, pred, op, scalar, i16)
	case Int32_Type:   return _agg_where_int_i64(values, pred, op, scalar, i32)
	case Int64_Type:   return _agg_where_int_i64(values, pred, op, scalar, i64)
	case UInt8_Type:   return _agg_where_int_i64(values, pred, op, scalar, u8)
	case UInt16_Type:  return _agg_where_int_i64(values, pred, op, scalar, u16)
	case UInt32_Type:  return _agg_where_int_i64(values, pred, op, scalar, u32)
	case UInt64_Type:  return _agg_where_int_i64(values, pred, op, scalar, u64)
	case Float32_Type: return _agg_where_float_i64(values, pred, op, scalar, f32)
	case Float64_Type: return _agg_where_float_i64(values, pred, op, scalar, f64)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_agg_where_compare_i64: type does not support ordering")
	}
	return {}
}

@(private="file")
_agg_all_valid_pred :: proc(values, pred: ^Array, $T: typeid) -> Aggregates {
	n := values.length
	vdata := cast([^]T)values.buffers[1].data
	voff := values.offset
	v_nulls := values.buffers[0].data != nil
	p_nulls := pred.buffers[0].data != nil
	a: Aggregates
	lo, hi: T
	seen := false
	for i in 0..<n {
		if p_nulls && !array_is_valid(pred, i) { continue }
		if v_nulls && !array_is_valid(values, i) { continue }
		v := vdata[voff + i]
		a.sum += f64(v)
		a.count += 1
		if seen {
			if v < lo { lo = v }
			if v > hi { hi = v }
		} else {
			lo = v
			hi = v
			seen = true
		}
	}
	if seen { a.min_val = f64(lo); a.max_val = f64(hi); a.valid = true }
	return a
}

@(private="file")
_agg_where_int_f64 :: proc(values, pred: ^Array, op: Compare_Op, scalar: f64, $T: typeid) -> Aggregates {
	mode, cmp_op, thresh := _int_vs_f64_plan(scalar, op, T)
	if mode == .All_False { return {} }
	if mode == .All_True  { return _agg_all_valid_pred(values, pred, T) }
	return _agg_where_native_dispatch(values, pred, cmp_op, thresh, T)
}

@(private="file")
_agg_where_int_i64 :: proc(values, pred: ^Array, op: Compare_Op, scalar: i64, $T: typeid) -> Aggregates {
	mode, thresh := _int_vs_i64_plan(scalar, op, T)
	if mode == .All_False { return {} }
	if mode == .All_True  { return _agg_all_valid_pred(values, pred, T) }
	return _agg_where_native_dispatch(values, pred, op, thresh, T)
}

@(private="file")
_agg_where_native_dispatch :: proc(values, pred: ^Array, op: Compare_Op, thresh: $T, $Val: typeid) -> Aggregates {
	switch op {
	case .Gt: return _agg_where_native_mono(values, pred, thresh, Val, .Gt)
	case .Ge: return _agg_where_native_mono(values, pred, thresh, Val, .Ge)
	case .Lt: return _agg_where_native_mono(values, pred, thresh, Val, .Lt)
	case .Le: return _agg_where_native_mono(values, pred, thresh, Val, .Le)
	case .Eq: return _agg_where_native_mono(values, pred, thresh, Val, .Eq)
	case .Ne: return _agg_where_native_mono(values, pred, thresh, Val, .Ne)
	}
	return {}
}

@(private="file")
_agg_where_native_mono :: proc(values, pred: ^Array, thresh: $T, $Val: typeid, $OP: Compare_Op) -> Aggregates {
	n := values.length
	vdata := cast([^]Val)values.buffers[1].data
	voff := values.offset
	pdata := cast([^]T)pred.buffers[1].data
	poff := pred.offset
	v_nulls := values.buffers[0].data != nil
	p_nulls := pred.buffers[0].data != nil

	a: Aggregates
	lo, hi: Val
	seen := false

	if !v_nulls && !p_nulls {
		for i in 0..<n {
			if _agg_cmp(pdata[poff + i], thresh, OP) {
				v := vdata[voff + i]
				a.sum += f64(v)
				a.count += 1
				if seen {
					if v < lo { lo = v }
					if v > hi { hi = v }
				} else {
					lo = v
					hi = v
					seen = true
				}
			}
		}
	} else {
		for i in 0..<n {
			if p_nulls && !array_is_valid(pred, i) { continue }
			if !_agg_cmp(pdata[poff + i], thresh, OP) { continue }
			if v_nulls && !array_is_valid(values, i) { continue }
			v := vdata[voff + i]
			a.sum += f64(v)
			a.count += 1
			if seen {
				if v < lo { lo = v }
				if v > hi { hi = v }
			} else {
				lo = v
				hi = v
				seen = true
			}
		}
	}

	if seen { a.min_val = f64(lo); a.max_val = f64(hi); a.valid = true }
	return a
}

@(private="file")
_agg_where_float_f64 :: proc(values, pred: ^Array, op: Compare_Op, scalar: f64, $T: typeid) -> Aggregates {
	switch op {
	case .Gt: return _agg_where_float_mono(values, pred, scalar, T, .Gt)
	case .Ge: return _agg_where_float_mono(values, pred, scalar, T, .Ge)
	case .Lt: return _agg_where_float_mono(values, pred, scalar, T, .Lt)
	case .Le: return _agg_where_float_mono(values, pred, scalar, T, .Le)
	case .Eq: return _agg_where_float_mono(values, pred, scalar, T, .Eq)
	case .Ne: return _agg_where_float_mono(values, pred, scalar, T, .Ne)
	}
	return {}
}

@(private="file")
_agg_where_float_i64 :: proc(values, pred: ^Array, op: Compare_Op, scalar: i64, $T: typeid) -> Aggregates {
	switch op {
	case .Gt: return _agg_where_float_mono(values, pred, scalar, T, .Gt)
	case .Ge: return _agg_where_float_mono(values, pred, scalar, T, .Ge)
	case .Lt: return _agg_where_float_mono(values, pred, scalar, T, .Lt)
	case .Le: return _agg_where_float_mono(values, pred, scalar, T, .Le)
	case .Eq: return _agg_where_float_mono(values, pred, scalar, T, .Eq)
	case .Ne: return _agg_where_float_mono(values, pred, scalar, T, .Ne)
	}
	return {}
}

@(private="file")
_agg_where_float_mono :: proc(values, pred: ^Array, scalar: $S, $T: typeid, $OP: Compare_Op) -> Aggregates {
	n := values.length
	vdata := cast([^]T)values.buffers[1].data
	voff := values.offset
	pdata := cast([^]T)pred.buffers[1].data
	poff := pred.offset
	v_nulls := values.buffers[0].data != nil
	p_nulls := pred.buffers[0].data != nil

	a: Aggregates
	lo, hi: T
	seen := false
	for i in 0..<n {
		if p_nulls && !array_is_valid(pred, i) { continue }
		when S == i64 {
			if !_cmp_f64_vs_i64(f64(pdata[poff + i]), OP, scalar) { continue }
		} else {
			if !_agg_cmp(f64(pdata[poff + i]), scalar, OP) { continue }
		}
		if v_nulls && !array_is_valid(values, i) { continue }
		v := vdata[voff + i]
		a.sum += f64(v)
		a.count += 1
		if seen {
			if v < lo { lo = v }
			if v > hi { hi = v }
		} else {
			lo = v
			hi = v
			seen = true
		}
	}
	if seen { a.min_val = f64(lo); a.max_val = f64(hi); a.valid = true }
	return a
}

@(private="file")
_agg_cmp :: #force_inline proc "contextless" (a, b: $T, $OP: Compare_Op) -> bool {
	when      OP == .Gt { return a >  b }
	else when OP == .Ge { return a >= b }
	else when OP == .Lt { return a <  b }
	else when OP == .Le { return a <= b }
	else when OP == .Eq { return a == b }
	else                { return a != b }
}
