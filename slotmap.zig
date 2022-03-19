const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub fn Dense(comptime T: type) type {
    return DenseCustomSlot(T, u16, u16);
}

pub fn DenseCustomSlot(comptime T: type, comptime slot_index_type: type, comptime slot_salt_type: type) type {
    // Both slot index and salt must be unsigned
    const index_info = @typeInfo(slot_index_type);
    assert(index_info.Int.signedness == .unsigned);

    const salt_info = @typeInfo(slot_salt_type);
    assert(salt_info.Int.signedness == .unsigned);

    return struct {
        const Self = @This();
        const SlotList = std.ArrayList(Slot);
        const TList = std.ArrayList(T);
        const IndexList = std.ArrayList(usize);

        slots: SlotList,
        data: TList,
        erase: IndexList,

        next_free: slot_index_type,
        len: usize,

        pub const Slot = SlotType(slot_index_type, slot_salt_type);

        pub fn init(allocator: std.mem.Allocator) Self {
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
            return self.slots.items.len;
        }

        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            std.debug.assert(new_capacity < std.math.maxInt(slot_index_type));

            if (self.slots.items.len < new_capacity) {
                var previous_last = self.slots.items.len;

                try self.slots.resize(new_capacity);
                try self.data.resize(new_capacity);
                try self.erase.resize(new_capacity);

                // add new items to the freelist
                for (self.slots.items[previous_last..self.slots.items.len]) |*slot, index| {
                    slot.index = @intCast(slot_index_type, index + previous_last) + 1;
                    slot.salt = 1;
                }
            }
        }

        pub fn clear(self: *Self) void {
            self.next_free = 0;
            self.len = 0;
            for (self.slots.items[self.next_free..self.slots.items.len]) |*slot, index| {
                slot.index = @intCast(slot_index_type, index + 1);
                slot.salt = slot.salt +% 1;
                if (slot.salt == 0) {
                    slot.salt = 1;
                }
            }
        }

        pub fn insert(self: *Self, v: T) !Slot {
            try self.ensureCapacity(self.len + 1);

            var index_of_redirect = self.next_free;
            var redirect = &self.slots.items[index_of_redirect];
            self.next_free = redirect.index; // redirect.index points to the next free slot

            redirect.index = @intCast(slot_index_type, self.len);
            self.data.items[redirect.index] = v;
            self.erase.items[redirect.index] = index_of_redirect;

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

            var redirect = &self.slots.items[slot.index];
            if (slot.salt != redirect.salt) {
                return error.NOT_FOUND;
            }
            var free_index = redirect.index;

            self.len -= 1;

            if (self.len > 0) {
                var free_data = &self.data.items[free_index];
                var free_erase = &self.erase.items[free_index];
                var last_data = &self.data.items[self.len];
                var last_erase = &self.erase.items[self.len];

                free_data.* = last_data.*;
                free_erase.* = last_erase.*;
                self.slots.items[free_erase.*].index = free_index;
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

            const redirect = &self.slots.items[slot.index];
            if (slot.salt == redirect.salt) {
                return &self.data.items[redirect.index];
            } else {
                return error.NOT_FOUND;
            }
        }

        pub fn get(self: *Self, slot: Slot) !T {
            return (try self.getPtr(slot)).*;
        }

        pub fn toSlice(self: *Self) []T {
            return self.data.items[0..self.len];
        }

        pub fn toSliceConst(self: *Self) []const T {
            return self.data.items[0..self.len];
        }
    };
}

fn SlotType(comptime slot_index_type: type, comptime slot_salt_type: type) type {
    return struct {
        const Self = @This();

        index: slot_index_type = 0,
        salt: slot_salt_type = 0,

        fn is_valid(slot: Self) bool {
            return slot.salt != 0;
        }

        fn is_equal(a: Self, b: Self) bool {
            return a.index == b.index and a.salt == b.salt;
        }
    };
}

test "slots" {
    const Slotmap = Dense(i32);
    const invalid = Slotmap.Slot{};
    const valid1 = Slotmap.Slot{ .index = 0, .salt = 1 };
    const valid2 = Slotmap.Slot{ .index = 0, .salt = 1 };

    assert(!invalid.is_valid());
    assert(valid1.is_valid());
    assert(valid2.is_valid());
    assert(!valid1.is_equal(invalid));
    assert(valid1.is_equal(valid2));
}

test "basic inserts and growing" {
    var map = Dense(i32).init(std.testing.allocator);
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

    map.deinit();
}

test "removal" {
    var map = Dense(i32).init(std.testing.allocator);
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

    map.deinit();
}

test "mixed insert and removal" {
    var map = Dense(i32).init(std.testing.allocator);
    try map.ensureCapacity(4);

    var iterations: usize = 10;
    while (iterations > 0) {
        iterations -= 1;

        _ = try map.insert(10);
        var slot1 = try map.insert(11);
        var slot2 = try map.insert(12);
        _ = try map.insert(13);
        assert(map.len == 4);

        var slot4 = try map.insert(14);
        assert(map.len == 5);

        try map.remove(slot1);
        try map.remove(slot4);

        var slot5 = try map.insert(15);
        _ = try map.insert(16);
        _ = try map.insert(17);
        _ = try map.insert(18);

        try map.remove(slot5);
        try map.remove(slot2);

        _ = try map.insert(19);
        _ = try map.insert(20);

        assert(map.len == 7);
        map.clear();
    }

    map.deinit();
}

test "slices" {
    const MapType = Dense(i32);
    var map = MapType.init(std.testing.allocator);
    try map.ensureCapacity(10);

    var slots = [_]MapType.Slot{
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

    for (map.toSliceConst()) |value| {
        assert(value == 0xBEEF);
    }

    for (slots) |slot, i| {
        if (@mod(i, 2) == 1) {
            try map.remove(slot);
        }
    }

    for (slots) |*slot| {
        slot.* = try map.insert(0x1337);
    }

    assert(map.len == 11);

    for (map.toSliceConst()) |value| {
        assert(value == 0x1337);
    }

    map.deinit();
}

test "stresstest" {
    const allocator = std.testing.allocator;

    const MapType = Dense(i32);
    var map = MapType.init(allocator);
    var slots = std.ArrayList(MapType.Slot).init(allocator);
    defer slots.deinit();
    var rng = std.rand.DefaultPrng.init(0);
    var random = rng.random();

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
            var index = @mod(random.int(usize), slots.items.len);
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

        i = slots.items.len;
        while (i > 0) {
            var index = @mod(random.int(usize), slots.items.len);
            var slot = slots.swapRemove(index);
            try map.remove(slot);
            i -= 1;
        }
    }

    map.deinit();
}
