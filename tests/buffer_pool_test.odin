package skadi_tests

import "core:mem"
import "core:testing"
import oa "../skadi"

// A build → free → build cycle through a Buffer_Pool should reuse the same
// underlying block (warm pages), and the values must still be correct.
@(test)
test_buffer_pool_reuse :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	// First build.
	b1 := oa.builder_make(i32, 1000, alloc)
	for i in 0..<1000 { oa.builder_append(&b1, i32(i)) }
	a1, _ := oa.builder_finish(&b1, alloc)
	ptr1 := a1.buffers[1].data
	testing.expect_value(t, oa.array_get(&a1, 999, i32), i32(999))

	// Return it to the pool.
	oa.array_free(&a1)
	oa.builder_destroy(&b1)

	// Second build of the same size should reuse the same data block.
	b2 := oa.builder_make(i32, 1000, alloc)
	for i in 0..<1000 { oa.builder_append(&b2, i32(2 * i)) }
	a2, _ := oa.builder_finish(&b2, alloc)
	ptr2 := a2.buffers[1].data
	defer { oa.array_free(&a2); oa.builder_destroy(&b2) }

	testing.expect(t, ptr1 == ptr2, "pool should hand back the recycled block")
	testing.expect_value(t, oa.array_get(&a2, 0, i32), i32(0))
	testing.expect_value(t, oa.array_get(&a2, 999, i32), i32(1998))
}

// Nulls must round-trip correctly even though reused blocks are not pre-zeroed
// (the validity bitmap is allocated through the zeroing .Alloc path).
@(test)
test_buffer_pool_nulls :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	// Pre-warm and dirty a same-sized bitmap block, then free it.
	warm := oa.builder_make(i32, 64, alloc)
	for _ in 0..<64 { oa.builder_append_null(&warm) }   // forces a full validity bitmap
	wa, _ := oa.builder_finish(&warm, alloc)
	oa.array_free(&wa); oa.builder_destroy(&warm)

	// New builder of the same shape: every other element null.
	b := oa.builder_make(i32, 64, alloc)
	for i in 0..<64 {
		if i % 2 == 0 { oa.builder_append(&b, i32(i)) }
		else          { oa.builder_append_null(&b) }
	}
	a, _ := oa.builder_finish(&b, alloc)
	defer { oa.array_free(&a); oa.builder_destroy(&b) }

	testing.expect_value(t, a.null_count, 32)
	testing.expect(t, !oa.array_is_null(&a, 0))
	testing.expect(t, oa.array_is_null(&a, 1))
	testing.expect_value(t, oa.array_get(&a, 4, i32), i32(4))
}

// Regression: a pool used AS context.allocator must not route its own
// bookkeeping (free-list stacks, base list) back through itself — that is
// reentrant and corrupts the heap. Exercise many sizes and free/alloc cycles so
// the free-list map and per-size stacks grow while the pool is the context
// allocator; a use-after-free here would crash or trip the leak tracker.
@(test)
test_buffer_pool_as_context_allocator :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)

	context.allocator = oa.buffer_pool_allocator(&pool)

	// Many distinct sizes create many free-list buckets; repeating the loop
	// reuses freed blocks and grows the per-size stacks — all via the pool.
	for round in 0..<3 {
		arrs: [16]oa.Array
		for s in 0..<16 {
			n := (s + 1) * 50
			b := oa.builder_make(i32, n)
			for i in 0..<n { oa.builder_append(&b, i32(i + round)) }
			arrs[s], _ = oa.builder_finish(&b)
			oa.builder_destroy(&b)
		}
		for s in 0..<16 {
			testing.expect_value(t, arrs[s].length, (s + 1) * 50)
			testing.expect_value(t, oa.array_get(&arrs[s], 0, i32), i32(round))
			oa.array_free(&arrs[s])
		}
	}
}

// String builders work through the pool too (data, offsets, and validity all
// come from the pool).
@(test)
test_buffer_pool_strings :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	b := oa.string_builder_make(8, alloc)
	words := []string{"alpha", "beta", "gamma"}
	for w in words { oa.string_builder_append(&b, w) }
	a, _ := oa.string_builder_finish(&b, alloc)
	defer { oa.array_free(&a); oa.string_builder_destroy(&b) }

	testing.expect_value(t, a.length, 3)
	testing.expect_value(t, oa.array_get_string(&a, 0), "alpha")
	testing.expect_value(t, oa.array_get_string(&a, 2), "gamma")
}

@(test)
test_buffer_pool_alignment_bucketing :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	p8, err8 := mem.alloc(128, 1, alloc)
	testing.expect_value(t, err8, mem.Allocator_Error.None)
	mem.free(p8, alloc)

	p64, err64 := mem.alloc(128, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err64, mem.Allocator_Error.None)
	testing.expect(t, p64 != p8, "64-byte aligned alloc must not reuse 8-byte aligned bucket")
	testing.expect(t, uintptr(p64) % oa.ARROW_ALIGNMENT == 0, "64-byte block must be aligned")
	mem.free(p64, alloc)

	p128, err128 := mem.alloc(128, 128, alloc)
	testing.expect_value(t, err128, mem.Allocator_Error.None)
	testing.expect(t, p128 != p64, "128-byte aligned alloc must not reuse 64-byte aligned bucket")
	testing.expect(t, uintptr(p128) % 128 == 0, "128-byte block must be 128-byte aligned")
	mem.free(p128, alloc)

	p128_reused, err128_2 := mem.alloc(128, 128, alloc)
	testing.expect_value(t, err128_2, mem.Allocator_Error.None)
	testing.expect(t, p128_reused == p128, "second 128-byte alloc should reuse the 128-byte bucket")
	mem.free(p128_reused, alloc)
}

@(test)
test_buffer_pool_hit_miss_telemetry :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	p1, err1 := mem.alloc(100, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err1, mem.Allocator_Error.None)
	testing.expect_value(t, pool.misses, u64(1))
	testing.expect_value(t, pool.hits, u64(0))

	// Fits within bucket_size=128 -> in-place resize counts as a hit.
	p1_inplace, err2 := mem.resize(p1, 100, 120, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err2, mem.Allocator_Error.None)
	testing.expect(t, p1_inplace == p1)
	testing.expect_value(t, pool.hits, u64(1))
	testing.expect_value(t, pool.misses, u64(1))

	// Grow beyond bucket_size=128 -> miss for new 256B block; old 128B block goes to free_list.
	p1_grown, err3 := mem.resize(p1_inplace, 120, 200, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err3, mem.Allocator_Error.None)
	testing.expect_value(t, pool.misses, u64(2))
	testing.expect_value(t, pool.hits, u64(1))

	// Allocating 100B again should pop the recycled 128B block -> hit.
	p2, err4 := mem.alloc(100, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err4, mem.Allocator_Error.None)
	testing.expect(t, p2 == p1, "should reuse recycled 128B bucket block")
	testing.expect_value(t, pool.hits, u64(2))
	testing.expect_value(t, pool.misses, u64(2))

	mem.free(p1_grown, alloc)
	mem.free(p2, alloc)
}

@(test)
test_buffer_pool_large_256kb_bucketing :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	sz1 :: 4*1024*1024 + 1
	sz2 :: 4*1024*1024 + 200*1024 // same 256 KB-aligned bucket (4 MB + 256 KB)
	p1, err1 := mem.alloc(sz1, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err1, mem.Allocator_Error.None)
	mem.free(p1, alloc)

	p2, err2 := mem.alloc(sz2, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err2, mem.Allocator_Error.None)
	testing.expect(t, p2 == p1, "4MB+1 and 4MB+200KB should share the 256KB-aligned bucket")
	testing.expect_value(t, pool.hits, u64(1))
	testing.expect_value(t, pool.misses, u64(1))
	mem.free(p2, alloc)

	p3, err3 := mem.alloc(10_000_000, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err3, mem.Allocator_Error.None)
	mem.free(p3, alloc)

	p4, err4 := mem.alloc(10_050_000, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err4, mem.Allocator_Error.None)
	testing.expect(t, p4 == p3, "10M and 10.05M should reuse same 256KB bucket without jumping to 16MB")
	testing.expect_value(t, pool.hits, u64(2))
	mem.free(p4, alloc)
}

@(test)
test_buffer_pool_large_eviction_and_resize_bounds :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	// Allocate and free many distinct >4 MB sizes totaling well above the 128 MB cache cap.
	for i in 0..<24 {
		sz := 16 * 1024 * 1024 + i * 512 * 1024
		p, err := mem.alloc(sz, oa.ARROW_ALIGNMENT, alloc)
		testing.expect_value(t, err, mem.Allocator_Error.None)
		mem.free(p, alloc)
	}
	testing.expect(t, pool.free_large_bytes <= 128 * 1024 * 1024, "cached >4 MB free blocks must stay bounded")

	// Slack reuse: freeing a 12 MB block and requesting 11.2 MB reuses it without a backing miss.
	misses_before := pool.misses
	p_big, err_big := mem.alloc(12 * 1024 * 1024, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err_big, mem.Allocator_Error.None)
	mem.free(p_big, alloc)
	misses_after_big := pool.misses
	p_slack, err_slack := mem.alloc(11_200_000, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err_slack, mem.Allocator_Error.None)
	testing.expect(t, p_slack == p_big, "nearby smaller >4 MB alloc should reuse cached large block within slack")
	testing.expect_value(t, pool.misses, misses_after_big)
	_ = misses_before
	mem.free(p_slack, alloc)

	// Resize with overstated old_size must clamp cleanly to block capacity and never fault.
	p_small, err_small := mem.alloc(128, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err_small, mem.Allocator_Error.None)
	p_grown, err_grown := mem.resize(p_small, 10_000_000, 512, oa.ARROW_ALIGNMENT, alloc)
	testing.expect_value(t, err_grown, mem.Allocator_Error.None)
	mem.free(p_grown, alloc)
}
