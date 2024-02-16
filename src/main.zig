const std = @import("std");

fn debug_noop(_: []const u8, _: anytype) void {}
const debug_log = debug_noop;

fn pointer_align(ptr: [*]u8, ptr_align: u8) usize {

    // 0 0 0 0 0 0 0 0
    // 0 0 0 0 0 0 0 0
    // 0 0 0 0 0 0 0 0

    // 0 0 0 0 0 0 0 1
    // 0 0 0 0 0 0 0 1 (align 1)

    // 0 0 0 0 0 0 0 0 // and with 1 0 then remove 1 0
    // 0 0 0 0 0 0 1 0 // (align 2)

    // 0 0 0 0 0 0 1 0
    // 0 0 0 0 0 0 1 0

    // 0 1 0 1 0 0 1 0
    // 0 0 0 0 0 1 0 0

    // 0 1 0 1 0 1 1 0
    // 0 0 0 0 0 1 0 0
    const ONES: usize = std.math.maxInt(usize);
    //const new_offset = ((ONES << @truncate(ptr_align - 1)) & s.offset) + ~(ONES << @truncate(ptr_align));
    //const new_offset = ((ONES << @truncate(ptr_align)) | s.offset) - (ONES << @truncate(ptr_align));
    //const new_offset = (s.offset - ~(ONES << @truncate(ptr_align))) | (ONES << @truncate(ptr_align));
    //const new_offset = s.offset + (~(ONES << @truncate(ptr_align)) & s.offset);
    //const new_offset = (s.offset + (@as(usize, 1) << @as(u3, @truncate(ptr_align)) -| 1)) & (ONES << @truncate(ptr_align)); // does not handle 0 align
    //const align_jump = ((@as(usize, 1) << @as(u3, @truncate(ptr_align + 1))) >> 1);
    //const align_jump = @as(usize, 1) << @as(u3, @truncate(ptr_align));
    //const mask = ONES << @truncate(ptr_align);
    //const new_offset: usize = (@intFromPtr(s.offset) & mask) | align_jump;
    //const align_jump = @intFromPtr(s.offset) & mask;
    const mask = ONES << @truncate(ptr_align);
    const align_jump = @as(usize, 1) << @truncate(ptr_align);
    const new_ptr = (@intFromPtr(ptr) & mask) + align_jump;

    std.debug.assert(new_ptr >= @intFromPtr(ptr));
    return new_ptr;
}

const LinAlloc = struct {
    buf: []u8,
    offset: [*]u8,

    fn alloc(so: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        const s: *LinAlloc = @alignCast(@ptrCast(so));
        const new_offset = pointer_align(s.offset, ptr_align);
        const end = new_offset + len;
        //debug_log("ptr_align: {d}\nsize: {d}\nold_offset: {any}\nnew_offset: u8@{x}\njump: {d}\nmask: {b}\nend: u8@{x}\n\n", .{ ptr_align, len, s.offset, new_offset, align_jump, mask, end });
        if (end > @intFromPtr(s.buf.ptr) + s.buf.len) {
            return null;
        }
        s.offset = @ptrFromInt(new_offset + len);
        return @ptrFromInt(new_offset);
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }
};

fn getLeftNode(i: usize) usize {
    return i * 2 + 1;
}

fn getRightNode(i: usize) usize {
    return i * 2 + 2;
}

fn getLeftZone(zone: []u8) []u8 {
    return zone[0 .. zone.len / 2];
}

fn getRightZone(zone: []u8) []u8 {
    return zone[zone.len / 2 ..];
}

/// Hey buddy, I think you got the wrong door.
fn BuddyAllocator(chunk_size: usize) type {
    return struct {
        nodes: []usize,
        mem: []u8,
        const unused = std.math.maxInt(usize);
        const used = unused - 1;

        pub fn init(nodes: []usize, mem: []u8) @This() {
            const max_supported_len = chunk_size * ((nodes.len + 1) / 2);
            if (max_supported_len >= mem.len) {
                @panic("not enough nodes allocated to the BuddyAllocator");
            }
            nodes[0] = unused;
            return .{
                .nodes = nodes,
                .mem = mem,
            };
        }

        fn update_using_trace(a: *@This(), trace: []usize) void {
            for (trace, 0..) |m, t| {
                debug_log("tracing: {d}\n", .{m});
                const left_value = a.nodes[getLeftNode(m)];
                const right_value = a.nodes[getRightNode(m)];
                var biggest: usize = undefined;
                if (left_value == used and right_value == used) {
                    biggest = 0;
                } else {
                    biggest = @max(left_value, right_value);
                    if (biggest == unused) {
                        biggest = a.mem.len >> @truncate(trace.len - t);
                    }
                }
                a.nodes[m] = biggest;
            }
        }

        fn alloc(ba: *anyopaque, type_len: usize, ptr_align: u8, _: usize) ?[*]u8 {
            const a: *@This() = @alignCast(@ptrCast(ba));
            const requested_size = type_len + (@as(usize, 1) << @truncate(ptr_align));
            debug_log("attempting to alloc: {d} with allign: {d}\n", .{ requested_size, ptr_align });

            var trace: [48]usize = undefined;
            var j: usize = trace.len;

            var i: usize = 0;
            var zone = a.mem;
            var failed = false;
            while (i < a.nodes.len) {
                j -= 1;
                trace[j] = i;

                const node = a.nodes[i];
                debug_log("zone {d} is being considered with value {d}\n", .{ i, node });
                if (node == used) {
                    failed = true;
                    break;
                }

                // Either by having available size = max available size for this layer.
                // Or by just being set as unsued...
                const is_unused = node == zone.len or node == unused;

                if (is_unused and requested_size > zone.len / 2) {
                    // If we go deeper then we won't ever find anything big enough
                    // to contain this type. We know it is safe to use this
                    // as we have already checked against the region being used.
                    a.nodes[i] = used;
                    debug_log("zone was force allocated\n", .{});
                    break;
                }

                if (i * 2 + 1 >= a.nodes.len) {
                    // This is the last row of our pyramid.
                    if (zone.len >= requested_size) {
                        // And the data fits within one single cell/node.
                        a.nodes[i] = used;
                    } else {
                        // No point in continuing.
                        failed = true;
                    }
                    break;
                }

                if (node == unused) {
                    debug_log("zone converted from unused: {d}\n", .{i});
                    a.nodes[getRightNode(i)] = unused;
                    a.nodes[getLeftNode(i)] = unused;
                    i = getLeftNode(i);
                    zone = getLeftZone(zone);
                } else if (node >= requested_size) {
                    var left_size = a.nodes[getLeftNode(i)];
                    if (left_size == unused) {
                        left_size = zone.len / 2;
                    }

                    var right_size = a.nodes[getRightNode(i)];
                    if (right_size == unused) {
                        right_size = zone.len / 2;
                    }

                    debug_log("zone {d}: {d} left_size: {d} right_size: {d}\n", .{ i, zone.len, left_size, right_size });

                    if (right_size != used and right_size >= requested_size and (right_size < left_size or left_size == 0 or left_size == used or left_size < requested_size)) {
                        i = getRightNode(i);
                        zone = getRightZone(zone);
                    } else {
                        i = getLeftNode(i);
                        zone = getLeftZone(zone);
                    }
                } else {
                    failed = true;
                    break;
                }
            }

            a.update_using_trace(trace[j + 1 ..]);

            if (failed) {
                return null;
            }

            debug_log("[NOTICE] zone was used: {d}\n", .{i});
            return @ptrFromInt(pointer_align(zone.ptr, ptr_align));
        }

        fn print_buddy(b: @This(), indent: usize, n: usize) void {
            if (n >= b.nodes.len) {
                return;
            }
            for (0..indent) |_| {
                debug_log("  ", .{});
            }
            if (b.nodes[n] == unused) {
                debug_log("{d}: unused\n", .{n});
            } else if (b.nodes[n] == used) {
                debug_log("{d}: used\n", .{n});
            } else {
                debug_log("{d}: {d}\n", .{ n, b.nodes[n] });
                b.print_buddy(indent + 1, getLeftNode(n));
                b.print_buddy(indent + 1, getRightNode(n));
            }
        }

        fn free(ba: *anyopaque, buf: []u8, _: u8, _: usize) void {
            const a: *@This() = @alignCast(@ptrCast(ba));

            var zone = a.mem;
            var trace: [48]usize = undefined;
            var i: usize = 0;
            var j: usize = trace.len;
            while (i < a.nodes.len) {
                if (a.nodes[i] == used) {
                    a.nodes[i] = unused;
                    break;
                }
                j -= 1;
                trace[j] = i;

                const right = getRightZone(zone);
                if (@intFromPtr(buf.ptr) < @intFromPtr(right.ptr)) {
                    zone = getLeftZone(zone);
                    i = getLeftNode(i);
                } else {
                    zone = right;
                    i = getRightNode(i);
                }
            }

            a.update_using_trace(trace[j..]);
        }

        fn resize(s: *anyopaque, buf: []u8, ptr_align: u8, new_len: usize, _: usize) bool {
            _ = new_len;
            _ = ptr_align;
            _ = buf;
            _ = s;
            // Come on, let's go!
            // TODO: One could allow resizing by checing the "buddies"...
            // But I am too lazy. Meaning this isn't a true BuddyAllocator yet, rather it is some
            // kind of heap based allocator.
            return false;
        }
    };
}

pub fn main() !void {
    var heap = [_]u8{0} ** 1024;
    var lin_alloc = LinAlloc{ .buf = &heap, .offset = (&heap).ptr };
    const lin_alloc_vtable = std.mem.Allocator.VTable{
        .alloc = LinAlloc.alloc,
        .free = LinAlloc.free,
        .resize = LinAlloc.resize,
    };
    const ac = std.mem.Allocator{
        .ptr = &lin_alloc,
        .vtable = &lin_alloc_vtable,
    };
    _ = try ac.create(u8);
    _ = try ac.create(u64);
    _ = try ac.create(u64);
    _ = try ac.create(u64);
    _ = try ac.create(u16);
    _ = try ac.create(u128);

    var heap2: [1024]u8 = undefined;
    const BA = BuddyAllocator(8);
    var nodes: [15]usize = undefined;
    @memset(&nodes, 333);
    var buddy_alloc = BA.init(&nodes, &heap2);
    const buddy_alloc_vtable = std.mem.Allocator.VTable{
        .alloc = BA.alloc,
        .free = BA.free,
        .resize = BA.resize,
    };
    const ba = std.mem.Allocator{
        .ptr = &buddy_alloc,
        .vtable = &buddy_alloc_vtable,
    };

    buddy_alloc.print_buddy(0, 0);
    const v = try ba.create(u8);
    buddy_alloc.print_buddy(0, 0);
    ba.destroy(v);
    buddy_alloc.print_buddy(0, 0);

    // buddy_alloc.print_buddy(0, 0);
    // _ = try ba.create(u8);
    // buddy_alloc.print_buddy(0, 0);
    // _ = try ba.create(u64);
    // buddy_alloc.print_buddy(0, 0);
    // _ = try ba.create(u64);
    // buddy_alloc.print_buddy(0, 0);
    // _ = try ba.create(u64);
    // buddy_alloc.print_buddy(0, 0);
    // _ = try ba.create(u16);
    // buddy_alloc.print_buddy(0, 0);
    // _ = try ba.create(u128);
    // buddy_alloc.print_buddy(0, 0);
}

test "linear allocator test" {
    const heap = try std.heap.page_allocator.alloc(u8, 1024 * 1024 * 100);
    var lin_alloc = LinAlloc{ .buf = heap, .offset = heap.ptr };
    const lin_alloc_vtable = std.mem.Allocator.VTable{
        .alloc = LinAlloc.alloc,
        .free = LinAlloc.free,
        .resize = LinAlloc.resize,
    };
    const ac = std.mem.Allocator{
        .ptr = &lin_alloc,
        .vtable = &lin_alloc_vtable,
    };
    try std.heap.testAllocator(ac);
    try std.heap.testAllocatorAligned(ac);
    try std.heap.testAllocatorLargeAlignment(ac);
    try std.heap.testAllocatorAlignedShrink(ac);
}

test "buddy allocator test" {
    const heap = try std.heap.page_allocator.alloc(u8, 1024 * 1024 * 100);
    const BA = BuddyAllocator(1024);
    var nodes: [64000]usize = undefined;
    var buddy_alloc = BA.init(&nodes, heap);
    const buddy_alloc_vtable = std.mem.Allocator.VTable{
        .alloc = BA.alloc,
        .free = BA.free,
        .resize = BA.resize,
    };
    const ba = std.mem.Allocator{
        .ptr = &buddy_alloc,
        .vtable = &buddy_alloc_vtable,
    };

    // const slice = try ba.alloc(*i32, 100);
    // for (slice, 0..) |*item, i| {
    //     item.* = try ba.create(i32);
    //     item.*.* = @as(i32, @intCast(i));
    // }

    // buddy_alloc.print_buddy(0, 0);

    // _ = try ba.alloc(*i32, 2000);

    // buddy_alloc.print_buddy(0, 0);

    try std.heap.testAllocator(ba);
    try std.heap.testAllocatorAligned(ba);
    try std.heap.testAllocatorLargeAlignment(ba);
    try std.heap.testAllocatorAlignedShrink(ba);

    for (0..100) |_| {
        try std.heap.testAllocator(ba);
        try std.heap.testAllocatorAligned(ba);
        try std.heap.testAllocatorLargeAlignment(ba);
        try std.heap.testAllocatorAlignedShrink(ba);
    }
    // Without further interruption, let's celebrate
}
