# Odin Style Guide for Skadi

## 1. Syntax & Strict Compiler Compliance
- **Block Statements**: Always use brace blocks `{ ... }` for control flow (`if`, `for`, `switch`). Never use `if ... do ...` or `for ... do ...` (`-disallow-do` compliant).
- **No Type Shadowing**: Never shadow built-in types (e.g. `byte`, `rune`, `rawptr`, `string`). Use distinct names (e.g. `raw_byte`, `b_val`, `vbyte`).
- **Formatting**: Format all code with `odinfmt -w`.
- **Compiler Flags**: All code must pass `odin check . -vet-strict-style -disallow-do` with zero warnings.

## 2. Memory Management & Allocator Hygiene
- **Explicit Allocators**: Always provide an explicit allocator parameter defaulting to `context.allocator` on public API procedures: `allocator := context.allocator`.
- **Zero-Copy Invariants**: Slicing an array or buffer must never allocate new storage. Slice views must explicitly set `allocator.procedure = nil` to disallow invalid resizing.
- **Alignment Guarantees**: Arrow buffers must be 64-byte aligned (`ARROW_ALIGNMENT = 64`). When using custom allocators or `Buffer_Pool`, ensure effective alignment satisfies `max(alignment, ARROW_ALIGNMENT)`.
- **Temp Allocator Scoping**: In compute or sort kernels that allocate scratch arrays using `context.temp_allocator`, always guard allocations with:
  ```odin
  runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
  ```
- **Error Propagation**: Never discard `mem.Allocator_Error` or allocation failures in public constructors or builder growth functions. Return `(..., mem.Allocator_Error)` or propagate errors cleanly.
- **Require Results**: Annotate all resource constructors and allocating procedures with `@(require_results)`.

## 3. SIMD & Intrinsics Safety
- **Unaligned Loads**: Sliced arrays, IPC mmap buffers, and non-zero offset arrays are not guaranteed to be 32-byte or 64-byte aligned. Never cast raw pointers directly to `[^]#simd[K]T` without either:
  1. Peeling scalar elements until `uintptr(ptr) & (align_of(V)-1) == 0`.
  2. Or using `intrinsics.unaligned_load(&vp[i])`.
- **Streaming Stores**: Before using `intrinsics.non_temporal_store`, always verify destination alignment satisfies vector alignment.

## 4. Testing Conventions
- **Memory Tracking**: Unit tests should verify allocations and bad frees using `mem.Tracking_Allocator`:
  ```odin
  track: mem.Tracking_Allocator
  mem.tracking_allocator_init(&track, context.allocator)
  defer mem.tracking_allocator_destroy(&track)
  context.allocator = mem.tracking_allocator(&track)
  ```
- **Failure Attribution**: All custom assertion and test helper procedures must accept `loc := #caller_location` so failures report the caller's line number in the test file rather than inside the helper.
- **Isolation**: Never use hardcoded paths in `/tmp` that could collide across concurrent runs. Use unique identifiers or in-memory streams.
