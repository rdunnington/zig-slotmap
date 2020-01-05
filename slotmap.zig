const std = @import("std");

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
                    slot.index = @intCast(u16, index) + 1;
                    slot.salt = 1;
                }
            }
        }

        pub fn clear(self: *Self) void {
            self.next_free = 0;
            for (self.slots.toSlice()[self.next_free..self.slots.len]) |*slot, index| {
                slot.index = index + 1;
                slot.salt = slot.salt +% 1;
            }
        }

        pub fn insert(self: *Self, v: T) !Slot {
            try self.ensureCapacity(self.len + 1);

            var freeindex = self.next_free;
            var redirect = self.slots.ptrAt(freeindex);
            self.next_free = redirect.index; // redirect.index points to the next free slot

            redirect.salt = redirect.salt +% 1;
            redirect.index = freeindex;
            var data = self.data.ptrAt(freeindex);
            var erase = self.erase.ptrAt(freeindex);
            data.* = v;
            erase.* = freeindex;

            self.len = self.len + 1;

            return redirect.*;
        }

        pub fn remove(self: *Self, slot: Slot) !void {
            if (!slot.is_valid()) {
                return error.INVALID_PARAMETER;
            }

            var redirect = self.slots.ptrAt(slot.index);
            if (slot.salt == redirect.salt) {
                self.data.swapRemove(redirect.index);
                self.erase.swapRemove(redirect.index);
                self.len = self.len - 1;

                if (self.len > 0) {
                    var erase_index = self.erase.at(redirect.index);
                    self.slots[erase_index].index = redirect.index;
                    self.erase[redirect.index] = redirect.index;
                }
                redirect.index = self.next_free;
                self.next_free = redirect.index;
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

test "basic inserts and growing" {
    const assert = std.debug.assert;

    var map = Slotmap(i32).init(std.debug.global_allocator);
    assert(map.len == 0);

    try map.ensureCapacity(4);
    assert(map.len == 0);

    var slot0 = try map.insert(10);
    var slot1 = try map.insert(11);
    var slot2 = try map.insert(12);
    var slot3 = try map.insert(13);
    assert(map.len == 4);

    assert((try map.get(slot0)) == 10);
    assert((try map.get(slot1)) == 11);
    assert((try map.get(slot2)) == 12);
    assert((try map.get(slot3)) == 13);

    map.log();

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
    map.log();
    try map.ensureCapacity(16);
    map.log();

    assert(map.len == 5);
    assert(map.capacity() == 16);
    var slot5 = try map.insert(15);

    map.log();

    assert((try map.get(slot0)) == 10);
    assert((try map.get(slot1)) == 11);
    assert((try map.get(slot2)) == 12);
    assert((try map.get(slot3)) == 13);
    assert((try map.get(slot4)) == 14);
    assert((try map.get(slot5)) == 15);
}
