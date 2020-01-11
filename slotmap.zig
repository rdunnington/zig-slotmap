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

        next_free: u16,
        len: usize,

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .slots = SlotList.init(allocator),
                .data = TList.init(allocator),
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

                // add new items to the freelist
                for (self.slots.toSlice()[previous_last..self.slots.len]) |*slot, index| {
                    slot.index = @intCast(u16, index + previous_last) + 1;
                    slot.salt = 0;
                }
            }
        }

        pub fn clear(self: *Self) void {
            self.next_free = 0;
            self.len = 0;
            for (self.slots.toSlice()[self.next_free..self.slots.len]) |*slot, index| {
                slot.index = @intCast(u16, index + 1);
                slot.salt = slot.salt +% 1;
            }
        }

        pub fn insert(self: *Self, v: T) !Slot {
            try self.ensureCapacity(self.len + 1);

            var redirect_index = self.next_free;
            var redirect = self.slots.ptrAt(redirect_index);
            self.next_free = redirect.index; // redirect.index points to the next free slot

            redirect.index = redirect_index;
            redirect.salt = redirect.salt +% 1;
            var data = self.data.ptrAt(redirect_index);
            data.* = v;

            self.len += 1;

            return redirect.*;
        }

        pub fn remove(self: *Self, slot: Slot) !void {
            if (!slot.is_valid()) {
                return error.INVALID_PARAMETER;
            }

            var redirect = self.slots.ptrAt(slot.index);
            if (slot.salt == redirect.salt) {
                self.len -= 1;
                redirect.index = self.next_free;
                self.next_free = slot.index;
            } else {
                return error.NOT_FOUND;
            }
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

        pub fn log(self: *Self) void {
            std.debug.warn("Slotmap({}) with {} items:\n", .{ @typeName(T), self.len });
            std.debug.warn("\tnext_free: {}\n", .{self.next_free});
            for (self.toSlice()) |item| {
                std.debug.warn("\t{}\n", .{item});
            }
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

    {
        var slot0 = try map.insert(10);
        var slot1 = try map.insert(11);
        var slot2 = try map.insert(12);
        var slot3 = try map.insert(13);
        assert(map.len == 4);
        assert(map.capacity() == 4);

        var slot4 = try map.insert(14);
        assert(map.len == 5);
        assert(map.capacity() == 5);

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
    }

    map.clear();

    {
        var slot0 = try map.insert(10);
        var slot1 = try map.insert(11);
        var slot2 = try map.insert(12);
        var slot3 = try map.insert(13);
        assert(map.len == 4);
        assert(map.capacity() == 7);

        var slot4 = try map.insert(14);
        assert(map.len == 5);
        assert(map.capacity() == 7);

        try map.remove(slot1);
        try map.remove(slot4);

        var slot5 = try map.insert(15);
        var slot6 = try map.insert(16);
        var slot7 = try map.insert(17);
        var slot8 = try map.insert(18);

        assert(map.capacity() == 7);

        try map.remove(slot5);
        try map.remove(slot2);

        var slot9 = try map.insert(19);
        var slot10 = try map.insert(20);

        assert(map.len == 7);
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
            try slots.append((try map.insert(value)));
            i -= 1;
        }

        i = 5000;
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
