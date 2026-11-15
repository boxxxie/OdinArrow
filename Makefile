SRC   := src
TESTS := tests
BIN   := bin

# Apache Arrow C++ paths — prefer system pkg-config, fall back to bundled PyArrow.
HAS_PKG_ARROW := $(shell pkg-config --exists arrow arrow-compute 2>/dev/null && echo 1 || echo 0)
ifeq ($(HAS_PKG_ARROW),1)
ARROW_IDIR       := $(shell pkg-config --variable=includedir arrow 2>/dev/null)
ARROW_LDIR       := $(shell pkg-config --variable=libdir arrow 2>/dev/null)
ARROW_CPP_FLAGS  := -std=c++20 -O3 $(shell pkg-config --cflags arrow arrow-compute)
ARROW_LINK_FLAGS := $(shell pkg-config --libs arrow arrow-compute) -Wl,-rpath,$(ARROW_LDIR)
PARQUET_LINK_FLAGS := $(shell pkg-config --libs arrow parquet) -Wl,-rpath,$(ARROW_LDIR)
else
ARROW_IDIR := $(shell python3 -c "import pyarrow; print(pyarrow.get_include())" 2>/dev/null)
ARROW_LDIR := $(shell python3 -c "import pyarrow; print(pyarrow.get_library_dirs()[0])" 2>/dev/null)
ARROW_VER  ?= $(shell python3 -c "import pyarrow, glob, os; d = pyarrow.get_library_dirs()[0]; m = sorted(glob.glob(os.path.join(d, 'libarrow.so.*'))); print(os.path.basename(m[0]).split('libarrow.so.')[1] if m else '2400')" 2>/dev/null)
ARROW_COMPUTE_LIB := $(shell python3 -c "import pyarrow, glob, os; d = pyarrow.get_library_dirs()[0]; m = sorted(glob.glob(os.path.join(d, 'libarrow_compute.so.*'))); print('-l:' + os.path.basename(m[0]) if m else '')" 2>/dev/null)

ARROW_CPP_FLAGS  := -std=c++20 -O3 -I$(ARROW_IDIR)
ARROW_LINK_FLAGS := -L$(ARROW_LDIR) \
    $(ARROW_COMPUTE_LIB) \
    -l:libarrow.so.$(ARROW_VER) \
    -Wl,-rpath,$(ARROW_LDIR)

PARQUET_LINK_FLAGS := -L$(ARROW_LDIR) \
    -l:libparquet.so.$(ARROW_VER) \
    -l:libarrow.so.$(ARROW_VER) \
    -Wl,-rpath,$(ARROW_LDIR)
endif

TEST_DATA ?= test_data.parquet
ODIN_CHECK_FLAGS := -vet -strict-style -disallow-do -warnings-as-errors

.PHONY: all check test test-cpp bench-odin bench-python bench bench-compare \
        build-arrow-capi bench-arrow-cpp \
        build-parquet-capi parquet-odin parquet-ffi bench-parquet \
        csv-to-parquet-odin csv-to-parquet-ffi clean

all: test

$(BIN):
	mkdir -p $(BIN)

lib:
	mkdir -p lib

# ── Odin static checks & tests (no C++ dependency) ────────────────────────────

check:
	odin check $(SRC) -no-entry-point $(ODIN_CHECK_FLAGS)
	odin check examples/quickstart $(ODIN_CHECK_FLAGS)
	odin check benchmarks/odin_c $(ODIN_CHECK_FLAGS)
	odin check programs/parquet_to_csv_odin $(ODIN_CHECK_FLAGS)
	odin check programs/parquet_to_csv_ffi $(ODIN_CHECK_FLAGS)
	odin check programs/csv_to_parquet_odin $(ODIN_CHECK_FLAGS)
	odin check programs/csv_to_parquet_ffi $(ODIN_CHECK_FLAGS)

test: $(BIN)
	odin test $(TESTS) -out:$(BIN)/test_runner $(ODIN_CHECK_FLAGS)

# ── Arrow C++ shared library (for Odin FFI) ───────────────────────────────────

lib/libarrow_capi.so: benchmarks/cpp/arrow_capi.cpp benchmarks/cpp/arrow_capi.h | lib
	g++ $(ARROW_CPP_FLAGS) -shared -fPIC \
	    benchmarks/cpp/arrow_capi.cpp \
	    $(ARROW_LINK_FLAGS) \
	    -Wl,-rpath,'$$ORIGIN' \
	    -o $@

build-arrow-capi: lib/libarrow_capi.so

# ── Odin tests that link Arrow C++ ───────────────────────────────────────────

test-cpp: lib/libarrow_capi.so $(BIN)
	odin test tests_cpp/ -out:$(BIN)/test_runner_cpp $(ODIN_CHECK_FLAGS) \
	    -extra-linker-flags="-Wl,-rpath,$(realpath lib) -Wl,-rpath,$(ARROW_LDIR)"

# ── Standalone Arrow C++ benchmark binary ─────────────────────────────────────

bin/bench_arrow_cpp: benchmarks/cpp/bench_arrow_main.cpp \
                     benchmarks/cpp/arrow_capi.cpp \
                     benchmarks/cpp/arrow_capi.h | $(BIN)
	g++ $(ARROW_CPP_FLAGS) \
	    benchmarks/cpp/bench_arrow_main.cpp \
	    benchmarks/cpp/arrow_capi.cpp \
	    $(ARROW_LINK_FLAGS) \
	    -o $@

bench-arrow-cpp: bin/bench_arrow_cpp
	bin/bench_arrow_cpp

# ── Python benchmarks ─────────────────────────────────────────────────────────

bench-odin: $(BIN)
	odin run benchmarks/odin -out:$(BIN)/bench_runner -o:speed

bench-python:
	python3 benchmarks/python/bench_array.py
	python3 benchmarks/python/bench_compute.py

bench: bench-odin bench-python

# ── Full 3-way comparison ─────────────────────────────────────────────────────

bench-compare: bin/bench_arrow_cpp $(BIN)
	bash benchmarks/compare.sh

# ── Parquet → CSV: Arrow C++ FFI shared library ───────────────────────────────

lib/libparquet_capi.so: benchmarks/cpp/parquet_capi.cpp benchmarks/cpp/parquet_capi.h | lib
	g++ $(ARROW_CPP_FLAGS) -shared -fPIC \
	    benchmarks/cpp/parquet_capi.cpp \
	    $(PARQUET_LINK_FLAGS) \
	    -Wl,-rpath,'$$ORIGIN' \
	    -o $@

build-parquet-capi: lib/libparquet_capi.so

# ── Parquet → CSV programs ────────────────────────────────────────────────────

bin/parquet_to_csv_odin: programs/parquet_to_csv_odin/*.odin | $(BIN)
	odin build programs/parquet_to_csv_odin -out:$@ -o:speed

bin/parquet_to_csv_ffi: programs/parquet_to_csv_ffi/main.odin lib/libparquet_capi.so | $(BIN)
	odin build programs/parquet_to_csv_ffi -out:$@ -o:speed \
	    -extra-linker-flags="-Wl,-rpath,$(realpath lib) -Wl,-rpath,$(ARROW_LDIR)"

parquet-odin: bin/parquet_to_csv_odin

parquet-ffi: bin/parquet_to_csv_ffi

# ── CSV → Parquet programs ────────────────────────────────────────────────────

bin/csv_to_parquet_odin: programs/csv_to_parquet_odin/*.odin | $(BIN)
	odin build programs/csv_to_parquet_odin -out:$@ -o:speed

bin/csv_to_parquet_ffi: programs/csv_to_parquet_ffi/main.odin lib/libparquet_capi.so | $(BIN)
	odin build programs/csv_to_parquet_ffi -out:$@ -o:speed \
	    -extra-linker-flags="-Wl,-rpath,$(realpath lib) -Wl,-rpath,$(ARROW_LDIR)"

csv-to-parquet-odin: bin/csv_to_parquet_odin

csv-to-parquet-ffi: bin/csv_to_parquet_ffi

# ── Parquet benchmark ─────────────────────────────────────────────────────────

bench-parquet: bin/parquet_to_csv_odin bin/parquet_to_csv_ffi
	bash benchmarks/parquet_bench.sh $(TEST_DATA)

clean:
	rm -rf $(BIN) lib
