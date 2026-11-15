#include "arrow_capi.h"

#include <arrow/api.h>
#include <arrow/compute/api.h>
#include <arrow/io/api.h>
#include <arrow/ipc/api.h>

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <mutex>

// ── compute kernel registration ───────────────────────────────────────────────
//
// PyArrow bundles Arrow C++ with compute kernels split across multiple shared
// libraries.  When linking the standalone binary (not via Python), the kernel
// registration static-initializers inside libarrow_compute.so do not run
// automatically — only the 13 core vector kernels in libarrow.so are present.
//
// We call the internal registration functions once at library init time.
// These symbols are stable across Arrow 24.x (verified via nm).

namespace arrow { namespace compute { namespace internal {
    void RegisterScalarAggregateBasic(FunctionRegistry*);  // sum, count, min, max, …
    void RegisterScalarStringUtf8(FunctionRegistry*);       // utf8_length, utf8_upper, …
}}}

static void ensure_kernels_registered() {
    static std::once_flag once;
    std::call_once(once, []() {
        auto* reg = arrow::compute::GetFunctionRegistry();
        arrow::compute::internal::RegisterScalarAggregateBasic(reg);
        arrow::compute::internal::RegisterScalarStringUtf8(reg);
    });
}

// ── helpers ───────────────────────────────────────────────────────────────────

// Count null elements by scanning the packed-bit validity bitmap.
static int64_t count_nulls(const uint8_t* validity, int64_t n) {
    if (!validity) return 0;
    int64_t valid = 0;
    int64_t full  = n / 8;
    for (int64_t i = 0; i < full; ++i)
        valid += __builtin_popcount(validity[i]);
    if (int rem = n % 8; rem != 0) {
        uint8_t last = validity[full] & ((1u << rem) - 1);
        valid += __builtin_popcount(last);
    }
    return n - valid;
}

// Wrap a raw pointer in an Arrow Buffer without taking ownership.
static std::shared_ptr<arrow::Buffer> wrap(const void* ptr, int64_t bytes) {
    return std::make_shared<arrow::Buffer>(
        static_cast<const uint8_t*>(ptr), bytes);
}

// Build an ArrayData for a fixed-width primitive type.
// validity may be nullptr (all valid).
static std::shared_ptr<arrow::ArrayData> make_i32_data(
    const uint8_t* validity, const int32_t* data, int64_t n)
{
    int64_t null_count = count_nulls(validity, n);
    int64_t bm_bytes   = (n + 7) / 8;
    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(data, n * sizeof(int32_t)));
    return arrow::ArrayData::Make(arrow::int32(), n, std::move(bufs), null_count);
}

static std::shared_ptr<arrow::ArrayData> make_f64_data(
    const uint8_t* validity, const double* data, int64_t n)
{
    int64_t null_count = count_nulls(validity, n);
    int64_t bm_bytes   = (n + 7) / 8;
    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(data, n * sizeof(double)));
    return arrow::ArrayData::Make(arrow::float64(), n, std::move(bufs), null_count);
}

// ── sum ───────────────────────────────────────────────────────────────────────

ArrowScalar arrow_capi_sum_i32(const uint8_t* validity, const int32_t* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_i32_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::Sum(arr).ValueOrDie();
    auto s   = res.scalar_as<arrow::Int64Scalar>();
    return { static_cast<double>(s.value), n - ad->GetNullCount() };
}

ArrowScalar arrow_capi_sum_f64(const uint8_t* validity, const double* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_f64_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::Sum(arr).ValueOrDie();
    auto s   = res.scalar_as<arrow::DoubleScalar>();
    return { s.value, n - ad->GetNullCount() };
}

// ── min / max ─────────────────────────────────────────────────────────────────

ArrowScalar arrow_capi_min_i32(const uint8_t* validity, const int32_t* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_i32_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::MinMax(arr).ValueOrDie();
    auto mm  = res.scalar_as<arrow::StructScalar>();
    auto val = std::static_pointer_cast<arrow::Int32Scalar>(mm.field("min").ValueOrDie());
    return { static_cast<double>(val->value), n - ad->GetNullCount() };
}

ArrowScalar arrow_capi_max_i32(const uint8_t* validity, const int32_t* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_i32_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::MinMax(arr).ValueOrDie();
    auto mm  = res.scalar_as<arrow::StructScalar>();
    auto val = std::static_pointer_cast<arrow::Int32Scalar>(mm.field("max").ValueOrDie());
    return { static_cast<double>(val->value), n - ad->GetNullCount() };
}

// ── filter ────────────────────────────────────────────────────────────────────

static std::shared_ptr<arrow::Int32Array> run_filter_i32(
    const uint8_t* src_validity,
    const int32_t* src_data,
    const uint8_t* mask_validity,
    const uint8_t* mask_bits,
    int64_t        n)
{
    auto src_ad  = make_i32_data(src_validity, src_data, n);
    auto src_arr = arrow::MakeArray(src_ad);

    int64_t mask_null = count_nulls(mask_validity, n);
    int64_t bm_bytes  = (n + 7) / 8;
    std::vector<std::shared_ptr<arrow::Buffer>> mask_bufs;
    mask_bufs.push_back(mask_validity ? wrap(mask_validity, bm_bytes) : nullptr);
    mask_bufs.push_back(wrap(mask_bits, bm_bytes));
    auto mask_ad  = arrow::ArrayData::Make(arrow::boolean(), n, std::move(mask_bufs), mask_null);
    auto mask_arr = arrow::MakeArray(mask_ad);

    auto result = arrow::compute::Filter(src_arr, mask_arr).ValueOrDie();
    return std::static_pointer_cast<arrow::Int32Array>(result.make_array());
}

int64_t arrow_capi_filter_i32(
    const uint8_t* src_validity,
    const int32_t* src_data,
    const uint8_t* mask_validity,
    const uint8_t* mask_bits,
    int64_t n)
{
    return run_filter_i32(src_validity, src_data, mask_validity, mask_bits, n)->length();
}

int64_t arrow_capi_filter_i32_materialize(
    const uint8_t* src_validity,
    const int32_t* src_data,
    const uint8_t* mask_validity,
    const uint8_t* mask_bits,
    int64_t        n,
    int32_t*       out_values,
    uint8_t*       out_valid,
    int64_t        out_cap)
{
    auto out_arr = run_filter_i32(src_validity, src_data, mask_validity, mask_bits, n);
    int64_t out_len = out_arr->length();
    int64_t copy_n  = out_len < out_cap ? out_len : out_cap;
    for (int64_t i = 0; i < copy_n; ++i) {
        bool valid = out_arr->IsValid(i);
        out_valid[i]  = valid ? 1 : 0;
        out_values[i] = valid ? out_arr->Value(i) : 0;
    }
    return out_len;
}

// ── string scan ───────────────────────────────────────────────────────────────

int64_t arrow_capi_string_scan(
    const uint8_t* validity,
    const int32_t* offsets,
    const uint8_t* utf8_data,
    int64_t n)
{
    ensure_kernels_registered();
    int64_t null_count  = count_nulls(validity, n);
    int64_t bm_bytes    = (n + 7) / 8;
    int64_t off_bytes   = (n + 1) * static_cast<int64_t>(sizeof(int32_t));
    int64_t data_bytes  = offsets[n];  // last offset = total byte count

    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(offsets,   off_bytes));
    bufs.push_back(wrap(utf8_data, data_bytes));
    auto ad  = arrow::ArrayData::Make(arrow::utf8(), n, std::move(bufs), null_count);
    auto arr = arrow::MakeArray(ad);

    auto lengths = arrow::compute::CallFunction("utf8_length", {arr}).ValueOrDie();
    auto total   = arrow::compute::Sum(lengths).ValueOrDie();
    return total.scalar_as<arrow::Int64Scalar>().value;
}

// ── sliced types (i64 / u64 / f32 / bool / binary) ────────────────────────────

static int64_t count_nulls_slice(const uint8_t* validity, int64_t offset, int64_t n) {
    if (!validity) return 0;
    int64_t nulls = 0;
    for (int64_t i = 0; i < n; ++i) {
        int64_t bit = offset + i;
        if (((validity[bit >> 3] >> (bit & 7)) & 1u) == 0) {
            ++nulls;
        }
    }
    return nulls;
}

template <typename T>
static std::shared_ptr<arrow::ArrayData> make_primitive_slice_data(
    const std::shared_ptr<arrow::DataType>& dtype,
    const uint8_t* validity,
    const T* data,
    int64_t offset,
    int64_t n)
{
    int64_t total      = offset + n;
    int64_t null_count = count_nulls_slice(validity, offset, n);
    int64_t bm_bytes   = (total + 7) / 8;
    static const uint8_t kEmpty = 0;
    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(data ? static_cast<const void*>(data) : &kEmpty,
                        total * static_cast<int64_t>(sizeof(T))));
    return arrow::ArrayData::Make(dtype, n, std::move(bufs), null_count, offset);
}

static double scalar_to_double(const std::shared_ptr<arrow::Scalar>& s) {
    switch (s->type->id()) {
    case arrow::Type::INT64:  return static_cast<double>(std::static_pointer_cast<arrow::Int64Scalar>(s)->value);
    case arrow::Type::UINT64: return static_cast<double>(std::static_pointer_cast<arrow::UInt64Scalar>(s)->value);
    case arrow::Type::FLOAT:  return static_cast<double>(std::static_pointer_cast<arrow::FloatScalar>(s)->value);
    case arrow::Type::DOUBLE: return std::static_pointer_cast<arrow::DoubleScalar>(s)->value;
    case arrow::Type::INT32:  return static_cast<double>(std::static_pointer_cast<arrow::Int32Scalar>(s)->value);
    case arrow::Type::UINT32: return static_cast<double>(std::static_pointer_cast<arrow::UInt32Scalar>(s)->value);
    default: assert(false && "unexpected scalar type"); return 0.0;
    }
}

template <typename T>
static ArrowScalar eval_sum_slice(
    const std::shared_ptr<arrow::DataType>& dtype,
    const uint8_t* validity, const T* data, int64_t offset, int64_t n)
{
    ensure_kernels_registered();
    std::shared_ptr<arrow::ArrayData> ad = make_primitive_slice_data(dtype, validity, data, offset, n);
    std::shared_ptr<arrow::Array> arr    = arrow::MakeArray(ad);
    int64_t vc = n - ad->GetNullCount();
    if (vc == 0) return { 0.0, 0 };
    arrow::Datum res = arrow::compute::Sum(arr).ValueOrDie();
    return { scalar_to_double(res.scalar()), vc };
}

template <typename T>
static ArrowScalar eval_mean_slice(
    const std::shared_ptr<arrow::DataType>& dtype,
    const uint8_t* validity, const T* data, int64_t offset, int64_t n)
{
    ensure_kernels_registered();
    std::shared_ptr<arrow::ArrayData> ad = make_primitive_slice_data(dtype, validity, data, offset, n);
    std::shared_ptr<arrow::Array> arr    = arrow::MakeArray(ad);
    int64_t vc = n - ad->GetNullCount();
    if (vc == 0) return { 0.0, 0 };
    arrow::Datum res = arrow::compute::Mean(arr).ValueOrDie();
    return { scalar_to_double(res.scalar()), vc };
}

template <typename T>
static ArrowScalar eval_minmax_slice(
    const std::shared_ptr<arrow::DataType>& dtype,
    const uint8_t* validity, const T* data, int64_t offset, int64_t n,
    const char* field_name)
{
    ensure_kernels_registered();
    std::shared_ptr<arrow::ArrayData> ad = make_primitive_slice_data(dtype, validity, data, offset, n);
    std::shared_ptr<arrow::Array> arr    = arrow::MakeArray(ad);
    int64_t vc = n - ad->GetNullCount();
    if (vc == 0) return { 0.0, 0 };
    arrow::Datum res = arrow::compute::MinMax(arr).ValueOrDie();
    const auto& mm   = res.scalar_as<arrow::StructScalar>();
    auto val         = mm.field(field_name).ValueOrDie();
    return { scalar_to_double(val), vc };
}

ArrowScalar arrow_capi_sum_i64_slice(const uint8_t* validity, const int64_t* data, int64_t offset, int64_t n) {
    return eval_sum_slice(arrow::int64(), validity, data, offset, n);
}

ArrowScalar arrow_capi_min_i64_slice(const uint8_t* validity, const int64_t* data, int64_t offset, int64_t n) {
    return eval_minmax_slice(arrow::int64(), validity, data, offset, n, "min");
}

ArrowScalar arrow_capi_max_i64_slice(const uint8_t* validity, const int64_t* data, int64_t offset, int64_t n) {
    return eval_minmax_slice(arrow::int64(), validity, data, offset, n, "max");
}

ArrowScalar arrow_capi_sum_u64_slice(const uint8_t* validity, const uint64_t* data, int64_t offset, int64_t n) {
    return eval_sum_slice(arrow::uint64(), validity, data, offset, n);
}

ArrowScalar arrow_capi_min_u64_slice(const uint8_t* validity, const uint64_t* data, int64_t offset, int64_t n) {
    return eval_minmax_slice(arrow::uint64(), validity, data, offset, n, "min");
}

ArrowScalar arrow_capi_max_u64_slice(const uint8_t* validity, const uint64_t* data, int64_t offset, int64_t n) {
    return eval_minmax_slice(arrow::uint64(), validity, data, offset, n, "max");
}

ArrowScalar arrow_capi_sum_f32_slice(const uint8_t* validity, const float* data, int64_t offset, int64_t n) {
    return eval_sum_slice(arrow::float32(), validity, data, offset, n);
}

ArrowScalar arrow_capi_mean_f32_slice(const uint8_t* validity, const float* data, int64_t offset, int64_t n) {
    return eval_mean_slice(arrow::float32(), validity, data, offset, n);
}

int arrow_capi_bool_stats_slice(
    const uint8_t* validity,
    const uint8_t* bits,
    int64_t offset,
    int64_t n,
    int64_t* out_true_count,
    int64_t* out_null_count)
{
    int64_t total      = offset + n;
    int64_t null_count = count_nulls_slice(validity, offset, n);
    int64_t bm_bytes   = (total + 7) / 8;
    static const uint8_t kEmpty = 0;
    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(bits ? static_cast<const void*>(bits) : &kEmpty, bm_bytes));

    auto ad  = arrow::ArrayData::Make(arrow::boolean(), n, std::move(bufs), null_count, offset);
    auto arr = std::make_shared<arrow::BooleanArray>(ad);
    if (!arr->ValidateFull().ok()) return 0;

    if (out_true_count) *out_true_count = arr->true_count();
    if (out_null_count) *out_null_count = arr->null_count();
    return 1;
}

int arrow_capi_binary_stats_slice(
    const uint8_t* validity,
    const int32_t* offsets,
    const uint8_t* data,
    int64_t total_elems,
    int64_t data_bytes,
    int64_t offset,
    int64_t n,
    int64_t* out_valid_bytes,
    int64_t* out_null_count)
{
    int64_t bm_elems   = offset + n;
    int64_t eff_elems  = total_elems >= bm_elems ? total_elems : bm_elems;
    int64_t null_count = count_nulls_slice(validity, offset, n);
    int64_t bm_bytes   = (bm_elems + 7) / 8;
    int64_t off_bytes  = (eff_elems + 1) * static_cast<int64_t>(sizeof(int32_t));
    static const uint8_t kEmpty = 0;

    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(offsets, off_bytes));
    bufs.push_back(wrap(data ? static_cast<const void*>(data) : &kEmpty, data_bytes));

    auto ad  = arrow::ArrayData::Make(arrow::binary(), n, std::move(bufs), null_count, offset);
    auto arr = std::make_shared<arrow::BinaryArray>(ad);
    if (!arr->ValidateFull().ok()) return 0;

    int64_t total_valid = 0;
    for (int64_t i = 0; i < n; ++i) {
        if (arr->IsValid(i)) {
            total_valid += static_cast<int64_t>(arr->GetView(i).size());
        }
    }
    if (out_valid_bytes) *out_valid_bytes = total_valid;
    if (out_null_count)  *out_null_count  = arr->null_count();
    return 1;
}

// ── Arrow IPC file/stream parity ──────────────────────────────────────────────

int arrow_capi_ipc_write_sample(const char* path, int is_stream) {
    if (!path) return 0;

    auto schema = arrow::schema({
        arrow::field("id", arrow::int64()),
        arrow::field("uval", arrow::uint64()),
        arrow::field("score", arrow::float32()),
        arrow::field("flag", arrow::boolean()),
        arrow::field("payload", arrow::binary()),
        arrow::field("label", arrow::utf8()),
    });

    arrow::Int64Builder   b_id;
    arrow::UInt64Builder  b_uval;
    arrow::FloatBuilder   b_score;
    arrow::BooleanBuilder b_flag;
    arrow::BinaryBuilder  b_payload;
    arrow::StringBuilder  b_label;

    if (!b_id.Append(-5000000001LL).ok()) return 0;
    if (!b_id.AppendNull().ok()) return 0;
    if (!b_id.Append(0).ok()) return 0;
    if (!b_id.Append(9000000007LL).ok()) return 0;
    if (!b_id.Append(42).ok()) return 0;

    if (!b_uval.Append(5000000001ULL).ok()) return 0;
    if (!b_uval.Append(42ULL).ok()) return 0;
    if (!b_uval.AppendNull().ok()) return 0;
    if (!b_uval.Append(100ULL).ok()) return 0;
    if (!b_uval.Append(8000000009ULL).ok()) return 0;

    if (!b_score.Append(1.5f).ok()) return 0;
    if (!b_score.Append(-2.25f).ok()) return 0;
    if (!b_score.AppendNull().ok()) return 0;
    if (!b_score.Append(3.75f).ok()) return 0;
    if (!b_score.Append(0.0f).ok()) return 0;

    if (!b_flag.Append(true).ok()) return 0;
    if (!b_flag.AppendNull().ok()) return 0;
    if (!b_flag.Append(false).ok()) return 0;
    if (!b_flag.Append(true).ok()) return 0;
    if (!b_flag.Append(false).ok()) return 0;

    const uint8_t p0[] = { 0x00, 0xFF, 0x10 };
    const uint8_t p3[] = { 0xDE, 0xAD, 0xBE, 0xEF };
    const uint8_t p4[] = { 0x01 };
    if (!b_payload.Append(p0, 3).ok()) return 0;
    if (!b_payload.AppendNull().ok()) return 0;
    if (!b_payload.Append(p0, 0).ok()) return 0;
    if (!b_payload.Append(p3, 4).ok()) return 0;
    if (!b_payload.Append(p4, 1).ok()) return 0;

    if (!b_label.Append("alpha").ok()) return 0;
    if (!b_label.Append("").ok()) return 0;
    if (!b_label.AppendNull().ok()) return 0;
    if (!b_label.Append("delta").ok()) return 0;
    if (!b_label.Append("omega").ok()) return 0;

    std::shared_ptr<arrow::Array> c0, c1, c2, c3, c4, c5;
    if (!b_id.Finish(&c0).ok()) return 0;
    if (!b_uval.Finish(&c1).ok()) return 0;
    if (!b_score.Finish(&c2).ok()) return 0;
    if (!b_flag.Finish(&c3).ok()) return 0;
    if (!b_payload.Finish(&c4).ok()) return 0;
    if (!b_label.Finish(&c5).ok()) return 0;

    auto batch = arrow::RecordBatch::Make(schema, 5, {c0, c1, c2, c3, c4, c5});
    if (!batch->ValidateFull().ok()) return 0;

    auto out_res = arrow::io::FileOutputStream::Open(path);
    if (!out_res.ok()) return 0;
    auto sink = *out_res;

    auto writer_res = is_stream
        ? arrow::ipc::MakeStreamWriter(sink.get(), schema)
        : arrow::ipc::MakeFileWriter(sink.get(), schema);
    if (!writer_res.ok()) return 0;
    auto writer = *writer_res;

    if (!writer->WriteRecordBatch(*batch).ok()) return 0;
    if (!writer->Close().ok()) return 0;
    if (!sink->Close().ok()) return 0;
    return 1;
}

static bool accumulate_batch_stats(
    const std::shared_ptr<arrow::RecordBatch>& batch,
    int64_t* i64_sum,
    int64_t* bin_bytes)
{
    if (!batch || !batch->ValidateFull().ok()) return false;
    if (batch->num_columns() > 0 && batch->column(0)->type_id() == arrow::Type::INT64) {
        auto arr = std::static_pointer_cast<arrow::Int64Array>(batch->column(0));
        for (int64_t r = 0; r < arr->length(); ++r) {
            if (arr->IsValid(r)) *i64_sum += arr->Value(r);
        }
    }
    if (batch->num_columns() > 4 && batch->column(4)->type_id() == arrow::Type::BINARY) {
        auto arr = std::static_pointer_cast<arrow::BinaryArray>(batch->column(4));
        for (int64_t r = 0; r < arr->length(); ++r) {
            if (arr->IsValid(r)) *bin_bytes += static_cast<int64_t>(arr->GetView(r).size());
        }
    }
    return true;
}

int arrow_capi_ipc_verify_roundtrip(
    const char* path,
    int is_stream,
    int64_t expected_rows,
    int32_t expected_cols,
    int64_t* out_i64_sum,
    int64_t* out_bin_bytes)
{
    if (!path) return 0;
    auto file_res = arrow::io::ReadableFile::Open(path);
    if (!file_res.ok()) return 0;
    auto infile = *file_res;

    int64_t total_rows = 0;
    int64_t i64_sum    = 0;
    int64_t bin_bytes  = 0;

    if (is_stream) {
        auto r_res = arrow::ipc::RecordBatchStreamReader::Open(infile);
        if (!r_res.ok()) return 0;
        auto reader = *r_res;
        if (reader->schema()->num_fields() != expected_cols) return 0;
        while (true) {
            std::shared_ptr<arrow::RecordBatch> batch;
            if (!reader->ReadNext(&batch).ok()) return 0;
            if (!batch) break;
            if (!accumulate_batch_stats(batch, &i64_sum, &bin_bytes)) return 0;
            total_rows += batch->num_rows();
        }
    } else {
        auto r_res = arrow::ipc::RecordBatchFileReader::Open(infile);
        if (!r_res.ok()) return 0;
        auto reader = *r_res;
        if (reader->schema()->num_fields() != expected_cols) return 0;
        for (int i = 0; i < reader->num_record_batches(); ++i) {
            auto b_res = reader->ReadRecordBatch(i);
            if (!b_res.ok()) return 0;
            auto batch = *b_res;
            if (!accumulate_batch_stats(batch, &i64_sum, &bin_bytes)) return 0;
            total_rows += batch->num_rows();
        }
    }

    if (total_rows != expected_rows) return 0;
    if (out_i64_sum)   *out_i64_sum   = i64_sum;
    if (out_bin_bytes) *out_bin_bytes = bin_bytes;
    return 1;
}
