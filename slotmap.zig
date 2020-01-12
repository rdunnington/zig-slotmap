const std = @import("std");
const assert = std.debug.assert;

pub const Slot = struct {
    index: u16 = 0,
    salt: u16 = 0,

    fn is_valid(slot: Slot) bool {
        return slot.salt != 0;
    }

    fn is_equal(a: Slot, b: Slot) bool {
        return a.index == b.index and a.salt == b.salt;
    }
};

pub fn Slotmap(comptime T: type) type {
    return struct {
        const Self = @This();
        const SlotList = std.ArrayList(Slot);
        const TList = std.ArrayList(T);
        const IndexList = std.ArrayList(usize);

        slots: SlotList,
        data: TList,
        erase: IndexList,

        next_free: u16,
        len: usize,

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .slots = SlotList.init(allocator),
                .data = TList.init(allocator),
                .erase = IndexList.init(allocator),
                .next_free = 0,
                .len = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit();
            self.data.deinit();
            self.erase.deinit();
        }

        pub fn capacity(self: *Self) usize {
            return self.slots.len;
        }

        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            std.debug.assert(new_capacity < std.math.maxInt(u16));

            if (self.slots.len < new_capacity) {
                var previous_last = self.slots.len;

                try self.slots.resize(new_capacity);
                try self.data.resize(new_capacity);
                try self.erase.resize(new_capacity);

                // add new items to the freelist
                for (self.slots.toSlice()[previous_last..self.slots.len]) |*slot, index| {
                    slot.index = @intCast(u16, index + previous_last) + 1;
                    slot.salt = 1;
                }
            }
        }

        pub fn clear(self: *Self) void {
            self.next_free = 0;
            self.len = 0;
            for (self.slots.toSlice()[self.next_free..self.slots.len]) |*slot, index| {
                slot.index = @intCast(u16, index + 1);
                slot.salt = slot.salt +% 1;
                if (slot.salt == 0) {
                    slot.salt = 1;
                }
            }
        }

        pub fn insert(self: *Self, v: T) !Slot {
            try self.ensureCapacity(self.len + 1);

            var index_of_redirect = self.next_free;
            var redirect = self.slots.ptrAt(index_of_redirect);
            self.next_free = redirect.index; // redirect.index points to the next free slot

            redirect.index = @intCast(u16, self.len);
            self.data.set(redirect.index, v);
            self.erase.set(redirect.index, index_of_redirect);

            self.len += 1;

            return Slot{
                .index = index_of_redirect,
                .salt = redirect.salt,
            };
        }

        pub fn remove(self: *Self, slot: Slot) !void {
            if (!slot.is_valid()) {
                return error.INVALID_PARAMETER;
            }

            var redirect = self.slots.ptrAt(slot.index);
            if (slot.salt != redirect.salt) {
                std.debug.warn("{} {} {}\n", .{ slot, redirect, self });
                return error.NOT_FOUND;
            }
            var free_index = redirect.index;

            self.len -= 1;

            if (self.len > 0) {
                var free_data = self.data.ptrAt(free_index);
                var free_erase = self.erase.ptrAt(free_index);
                var last_data = self.data.ptrAt(self.len);
                var last_erase = self.erase.ptrAt(self.len);

                free_data.* = last_data.*;
                free_erase.* = last_erase.*;
                self.slots.ptrAt(free_erase.*).index = free_index;
            }

            // Update the redirect after "self.slots.ptrAt(free_erase.*).index" was updated because
            // if it happened to point to this redirect we want to avoid breaking the freelist
            redirect.salt +%= 1;
            if (redirect.salt == 0) {
                redirect.salt = 1;
            }
            redirect.index = self.next_free;

            self.next_free = slot.index;
        }

        pub fn getPtr(self: *Self, slot: Slot) !*T {
            if (!slot.is_valid()) {
                return error.INVALID_PARAMETER;
            }

            const redirect = self.slots.ptrAt(slot.index);
            if (slot.salt == redirect.salt) {
                return self.data.ptrAt(redirect.index);
            } else {
                return error.NOT_FOUND;
            }
        }

        pub fn get(self: *Self, slot: Slot) !T {
            return (try self.getPtr(slot)).*;
        }

        pub fn toSlice(self: *Self) []T {
            return self.data.toSlice()[0..self.len];
        }

        pub fn toSliceConst(self: *Self) []const T {
            return self.data.toSlice()[0..self.len];
        }
    };
}

test "slots" {
    const invalid = Slot{};
    const valid1 = Slot{ .index = 0, .salt = 1 };
    const valid2 = Slot{ .index = 0, .salt = 1 };

    assert(!invalid.is_valid());
    assert(valid1.is_valid());
    assert(valid2.is_valid());
    assert(!valid1.is_equal(invalid));
    assert(valid1.is_equal(valid2));
}

test "basic inserts and growing" {
    var map = Slotmap(i32).init(std.debug.global_allocator);
    assert(map.len == 0);

    try map.ensureCapacity(4);
    assert(map.len == 0);

    var slot0 = try map.insert(10);
    var slot1 = try map.insert(11);
    var slot2 = try map.insert(12);
    var slot3 = try map.insert(13);

    assert(slot0.is_valid());
    assert(slot1.is_valid());
    assert(slot2.is_valid());
    assert(slot3.is_valid());

    assert(!slot0.is_equal(slot1));
    assert(!slot0.is_equal(slot2));
    assert(!slot0.is_equal(slot3));
    assert(!slot2.is_equal(slot3));

    assert(map.len == 4);

    assert((try map.get(slot0)) == 10);
    assert((try map.get(slot1)) == 11);
    assert((try map.get(slot2)) == 12);
    assert((try map.get(slot3)) == 13);

    var slot4 = try map.insert(14);
    assert(map.len == 5);
    assert(map.capacity() == 5);

    assert((try map.get(slot0)) == 10);
    assert((try map.get(slot1)) == 11);
    assert((try map.get(slot2)) == 12);
    assert((try map.get(slot3)) == 13);
    assert((try map.get(slot4)) == 14);

    try map.ensureCapacity(1);
    try map.ensureCapacity(6);
    try map.ensureCapacity(8);
    try map.ensureCapacity(16);

    assert(map.len == 5);
    assert(map.capacity() == 16);
    var slot5 = try map.insert(15);

    assert((try map.get(slot0)) == 10);
    assert((try map.get(slot1)) == 11);
    assert((try map.get(slot2)) == 12);
    assert((try map.get(slot3)) == 13);
    assert((try map.get(slot4)) == 14);
    assert((try map.get(slot5)) == 15);
}

test "removal" {
    var map = Slotmap(i32).init(std.debug.global_allocator);
    try map.ensureCapacity(6);

    var slot0 = try map.insert(10);
    var slot1 = try map.insert(11);
    var slot2 = try map.insert(12);
    var slot3 = try map.insert(13);
    assert(map.len == 4);
    assert(map.capacity() == 6);

    try map.remove(slot3);
    assert(map.len == 3);

    try map.remove(slot0);
    assert(map.len == 2);

    try map.remove(slot1);
    try map.remove(slot2);
    assert(map.len == 0);
    assert(map.capacity() == 6);
}

test "mixed insert and removal" {
    var map = Slotmap(i32).init(std.debug.global_allocator);
    try map.ensureCapacity(4);

    var iterations: usize = 10;
    while (iterations > 0) {
        iterations -= 1;

        var slot0 = try map.insert(10);
        var slot1 = try map.insert(11);
        var slot2 = try map.insert(12);
        var slot3 = try map.insert(13);
        assert(map.len == 4);

        var slot4 = try map.insert(14);
        assert(map.len == 5);

        try map.remove(slot1);
        try map.remove(slot4);

        var slot5 = try map.insert(15);
        var slot6 = try map.insert(16);
        var slot7 = try map.insert(17);
        var slot8 = try map.insert(18);

        try map.remove(slot5);
        try map.remove(slot2);

        var slot9 = try map.insert(19);
        var slot10 = try map.insert(20);

        assert(map.len == 7);
        map.clear();
    }
}

test "slices" {
    var map = Slotmap(i32).init(std.debug.global_allocator);
    try map.ensureCapacity(10);

    var slots = [_]Slot{
        try map.insert(0xDEAD1),
        try map.insert(0xDEAD2),
        try map.insert(0xDEAD3),
        try map.insert(0xDEAD4),
        try map.insert(0xDEAD5),
        try map.insert(0xDEAD6),
        try map.insert(0xDEAD7),
        try map.insert(0xDEAD8),
        try map.insert(0xDEAD9),
        try map.insert(0xDEAD10),
        try map.insert(0xDEAD11),
    };

    assert(map.len == 11);

    for (slots) |slot, i| {
        if (@mod(i, 2) == 0) {
            try map.remove(slot);
        } else {
            var value = try map.getPtr(slot);
            value.* = 0xBEEF;
        }
    }

    assert(map.len == 5);

    for (map.toSliceConst()) |value, i| {
        assert(value == 0xBEEF);
    }

    for (slots) |slot, i| {
        if (@mod(i, 2) == 1) {
            try map.remove(slot);
        }
    }

    for (slots) |*slot, i| {
        slot.* = try map.insert(0x1337);
    }

    assert(map.len == 11);

    for (map.toSliceConst()) |value, i| {
        assert(value == 0x1337);
    }
}

test "stresstest" {
    var buffer: [1024 * 1024 * 4]u8 = undefined;
    const allocator = &std.heap.FixedBufferAllocator.init(&buffer).allocator;

    var map = Slotmap(i32).init(allocator);
    var slots = std.ArrayList(Slot).init(allocator);
    var rng = std.rand.DefaultPrng.init(0);

    var iterations: i32 = 100;
    while (iterations > 0) {
        iterations -= 1;

        var i: usize = 20000;
        while (i > 0) {
            var value = @intCast(i32, i) - 500;
            var slot = try map.insert(value);
            try slots.append(slot);
            i -= 1;
        }

        i = 15000;
        while (i > 0) {
            var index = @mod(rng.random.int(usize), slots.len);
            var slot = slots.swapRemove(index);
            try map.remove(slot);
            i -= 1;
        }

        i = 7500;
        while (i > 0) {
            var value = @intCast(i32, i) - 500;
            try slots.append((try map.insert(value)));
            i -= 1;
        }

        i = slots.len;
        while (i > 0) {
            var index = @mod(rng.random.int(usize), slots.len);
            var slot = slots.swapRemove(index);
            try map.remove(slot);
            i -= 1;
        }
    }
}
