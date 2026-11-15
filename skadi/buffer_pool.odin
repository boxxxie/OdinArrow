package skadi

import "core:mem"

// Buffer_Pool is a free-list allocator that retains freed blocks (bucketed by
// size) and hands them back on the next allocation of the same size, instead of
// returning them to the OS. Reused blocks keep their pages resident, so a
// build → free → build loop avoids re-faulting fresh pages every time — the same
// reuse strategy Arrow's memory pool relies on to make repeated construction
// cheap.
//
// Use it by passing buffer_pool_allocator(&pool) as the builder's allocator.
//
// Not thread-safe: use one pool per thread (builders are single-threaded).
// All blocks are released by buffer_pool_destroy.

Buffer_Pool :: struct {
	backing:   mem.Allocator,
	free_list: map[_Pool_Key][dynamic]rawptr, // (size, align) -> stack of free user pointers
	bases:     [dynamic]rawptr,              // every backing base pointer (for destroy)
	hits:      u64,                          // blocks served from free_list or in-place resize
	misses:    u64,                          // fresh blocks allocated from backing allocator
}

@(private="file")
_Pool_Key :: struct {
	size:  int,
	align: int,
}

@(private="file")
_Pool_Header :: struct {
	size:  int,    // bucket capacity in bytes
	align: int,    // bucket alignment in bytes
	base:  rawptr, // backing allocation start
}

@(private="file")
_POOL_HDR :: size_of(_Pool_Header)

@(private="file")
_next_power_of_two :: proc "contextless" (x: int) -> int {
	if x <= 1 { return 1 }
	max_pow := 1 << uint(8 * size_of(int) - 2)
	if x > max_pow { return x }
	v := x - 1
	v |= v >> 1
	v |= v >> 2
	v |= v >> 4
	v |= v >> 8
	v |= v >> 16
	when size_of(int) == 8 {
		v |= v >> 32
	}
	return v + 1
}

buffer_pool_init :: proc(pool: ^Buffer_Pool, backing := context.allocator) {
	pool.backing = backing
	// Bookkeeping always lives in the backing allocator, never context.allocator:
	// callers commonly set context.allocator to this very pool, and routing the
	// pool's own metadata through itself is reentrant (use-after-free).
	pool.free_list = make(map[_Pool_Key][dynamic]rawptr, 16, backing)
	pool.bases     = make([dynamic]rawptr, 0, 0, backing)
}

// Release every block the pool ever allocated, plus its bookkeeping.
buffer_pool_destroy :: proc(pool: ^Buffer_Pool) {
	for base in pool.bases {
		mem.free(base, pool.backing)
	}
	delete(pool.bases)
	for _, stack in pool.free_list {
		delete(stack)
	}
	delete(pool.free_list)
	pool^ = {}
}

buffer_pool_allocator :: proc(pool: ^Buffer_Pool) -> mem.Allocator {
	return mem.Allocator{procedure = _buffer_pool_proc, data = pool}
}

@(private="file")
_buffer_pool_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int, old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	pool := cast(^Buffer_Pool)allocator_data

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		ptr, err := _pool_get(pool, size, alignment)
		if err != .None { return nil, err }
		if size == 0 { return nil, .None }
		if mode == .Alloc { mem.zero(ptr, size) }
		return (cast([^]byte)ptr)[:size], .None

	case .Free:
		if old_memory != nil { _pool_put(pool, old_memory) }
		return nil, .None

	case .Free_All:
		// A pool keeps memory owned for reuse; nothing is returned to the OS
		// until buffer_pool_destroy. Treat Free_All as a no-op.
		return nil, .None

	case .Resize, .Resize_Non_Zeroed:
		ptr, err := _pool_resize(pool, old_memory, old_size, size, alignment, mode == .Resize)
		if err != .None { return nil, err }
		if size == 0 { return nil, .None }
		return (cast([^]byte)ptr)[:size], .None

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, .None

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .None
}

@(private="file")
LARGE_BUCKET_THRESHOLD :: 4 * 1024 * 1024 // 4 MB
@(private="file")
LARGE_BUCKET_STEP      :: 256 * 1024      // 256 KB

// Bucketing policy: power-of-two up to 4 MB for fast small/medium reuse, then
// 256 KB step alignment above 4 MB so large payloads (e.g., 11 MB or 20 MB) do
// not round up 2x to the next power of two.
@(private="file")
_bucket_size :: proc "contextless" (size: int) -> int {
	clamped := max(size, ARROW_ALIGNMENT)
	if clamped <= LARGE_BUCKET_THRESHOLD {
		return _next_power_of_two(clamped)
	}
	return align_up(clamped, LARGE_BUCKET_STEP)
}

// Hand back a block of at least `size` bytes (reused if one is free), with the
// user pointer aligned to `effective_align` and bucketed by `(bucket_size, effective_align)`.
@(private="file")
_pool_get :: proc(pool: ^Buffer_Pool, size, alignment: int) -> (rawptr, mem.Allocator_Error) {
	if size == 0 { return nil, .None }
	effective_align := _next_power_of_two(max(alignment, align_of(_Pool_Header)))
	bucket_size := _bucket_size(size)
	key := _Pool_Key{size = bucket_size, align = effective_align}
	if stack, ok := pool.free_list[key]; ok && len(stack) > 0 {
		user := stack[len(stack) - 1]
		pop(&pool.free_list[key])
		pool.hits += 1
		return user, .None
	}
	total := _POOL_HDR + effective_align + bucket_size
	raw, err := mem.alloc_bytes_non_zeroed(total, effective_align, pool.backing)
	if err != .None || raw == nil { return nil, .Out_Of_Memory }
	base := raw_data(raw)
	au   := uintptr(effective_align)
	user := (uintptr(base) + uintptr(_POOL_HDR) + au - 1) & ~(au - 1)
	header := (^_Pool_Header)(rawptr(user - uintptr(_POOL_HDR)))
	header.size  = bucket_size
	header.align = effective_align
	header.base  = base
	append(&pool.bases, base)
	pool.misses += 1
	return rawptr(user), .None
}

@(private="file")
_pool_put :: proc(pool: ^Buffer_Pool, user: rawptr) {
	header := (^_Pool_Header)(rawptr(uintptr(user) - uintptr(_POOL_HDR)))
	key := _Pool_Key{size = header.size, align = header.align}
	s, ok := pool.free_list[key]
	if !ok {
		// New bucket — back its stack with the pool's backing allocator so
		// appends never reenter the pool via context.allocator.
		s = make([dynamic]rawptr, 0, 0, pool.backing)
	}
	append(&s, user)
	pool.free_list[key] = s
}

@(private="file")
_pool_resize :: proc(pool: ^Buffer_Pool, old_memory: rawptr, old_size, new_size, alignment: int, zeroed: bool) -> (rawptr, mem.Allocator_Error) {
	if old_memory == nil {
		p, err := _pool_get(pool, new_size, alignment)
		if err != .None { return nil, err }
		if zeroed && new_size > 0 { mem.zero(p, new_size) }
		return p, .None
	}
	if new_size == 0 {
		_pool_put(pool, old_memory)
		return nil, .None
	}
	header   := (^_Pool_Header)(rawptr(uintptr(old_memory) - uintptr(_POOL_HDR)))
	capacity := header.size
	req_align := uintptr(max(alignment, 1))
	if new_size <= capacity && uintptr(old_memory) % req_align == 0 {
		if zeroed && new_size > old_size {
			mem.zero(rawptr(uintptr(old_memory) + uintptr(old_size)), new_size - old_size)
		}
		pool.hits += 1
		return old_memory, .None
	}
	// Grow: take a bigger block, copy the live bytes, recycle the old one.
	p, err := _pool_get(pool, new_size, alignment)
	if err != .None { return nil, err }
	keep := min(old_size, new_size)
	if keep > 0 { mem.copy(p, old_memory, keep) }
	if zeroed && new_size > keep {
		mem.zero(rawptr(uintptr(p) + uintptr(keep)), new_size - keep)
	}
	_pool_put(pool, old_memory)
	return p, .None
}
