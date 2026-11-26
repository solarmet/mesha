//! A gap buffer: a sequence kept in one allocation with a hole where the next edit is
//! expected. Inserting and removing at the gap costs only the items written; an edit
//! elsewhere first moves the gap there, which costs the items between. Reading never
//! moves the gap: the sequence is read as the two slices on either side of it.
//!
//! The buffer owns nothing but its storage, which the caller's allocator provides. On a
//! page allocator, growth remaps the pages instead of copying them.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A gap buffer of `T`, which is copied with `memcpy` and so must need no destructor. Positions
/// and indices count items of the sequence, the gap left out: 0 is before the first item and
/// `len()` after the last. A default value (`.{}`) is an empty buffer with no storage. Not
/// thread-safe. Pass the same allocator to every call that takes one.
pub fn GapBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// How much room a growing buffer leaves for the edits after it: a quarter of
        /// its length, within these bounds.
        pub const Growth = struct {
            /// The least room left, in items.
            min_gap: usize = 4096,
            /// The most room left, in items.
            max_gap: usize = 64 * 1024 * 1024,
        };

        /// The one allocation: items before the gap sit at its start, items after the gap at
        /// its end, and the slots between are the gap, whose contents are undefined.
        storage: []T = &.{},
        /// The index in `storage` of the gap's first slot, and the count of items before the gap.
        gap_start: usize = 0,
        /// The index in `storage` just past the gap's last slot; equal to `gap_start` when the gap
        /// is empty.
        gap_end: usize = 0,
        /// How growth sizes the gap. Set it when the buffer is declared; `deinit` keeps it.
        growth: Growth = .{},

        /// Frees the storage and leaves an empty buffer with the same `growth`, which may be used
        /// again. `allocator` is the one the buffer grew with.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            const growth = self.growth;
            allocator.free(self.storage);
            self.* = .{ .growth = growth };
        }

        /// The number of items in the sequence.
        pub fn len(self: *const Self) usize {
            const gap_len = self.gap_end - self.gap_start;
            return self.storage.len - gap_len;
        }

        /// How many more items fit before an insert must allocate.
        pub fn gapLen(self: *const Self) usize {
            return self.gap_end - self.gap_start;
        }

        /// The items before the gap: the sequence's first `gap_start` items. Valid until the next
        /// call that moves the gap or grows the buffer (any insert, `remove`, `moveGap`,
        /// `ensureGap`, `clear`, `deinit`).
        pub fn before(self: *const Self) []const T {
            return self.storage[0..self.gap_start];
        }

        /// The items after the gap: the rest of the sequence, following `before()`. Valid as
        /// long as `before()` is.
        pub fn after(self: *const Self) []const T {
            return self.storage[self.gap_end..];
        }

        /// The item at `index` of the sequence, which must be below `len()`.
        pub fn at(self: *const Self, index: usize) T {
            if (index < self.gap_start) return self.storage[index];
            const gap_len = self.gap_end - self.gap_start;
            return self.storage[index + gap_len];
        }

        /// Copies the `out.len` items starting at `start` into `out`, across the gap where
        /// they span it. The range must lie within the sequence. Does not move the gap.
        pub fn copyRange(self: *const Self, start: usize, out: []T) void {
            const end = start + out.len;
            std.debug.assert(end <= self.len());
            const from_before_end = @min(end, self.gap_start);
            var written: usize = 0;
            if (start < from_before_end) {
                written = from_before_end - start;
                @memcpy(out[0..written], self.storage[start..from_before_end]);
            }
            if (written < out.len) {
                const gap_len = self.gap_end - self.gap_start;
                const source_start = start + written + gap_len;
                const remaining = out.len - written;
                @memcpy(out[written..], self.storage[source_start..][0..remaining]);
            }
        }

        /// Puts the gap at `position` (at most `len()`), moving the items between its old place
        /// and its new one. Never allocates. Slices from `before` and `after` are stale after.
        pub fn moveGap(self: *Self, position: usize) void {
            std.debug.assert(position <= self.len());
            if (position < self.gap_start) {
                const moved = self.gap_start - position;
                const destination = self.storage[self.gap_end - moved .. self.gap_end];
                const source = self.storage[position..self.gap_start];
                std.mem.copyBackwards(T, destination, source);
                self.gap_start = position;
                self.gap_end -= moved;
            } else if (position > self.gap_start) {
                const moved = position - self.gap_start;
                const destination = self.storage[self.gap_start..][0..moved];
                const source = self.storage[self.gap_end..][0..moved];
                std.mem.copyForwards(T, destination, source);
                self.gap_start = position;
                self.gap_end += moved;
            }
        }

        /// Makes room for `needed` more items without moving the gap, growing the storage by
        /// `growth`'s spare room beyond that when the gap is too small. Nothing changes when
        /// it fails. Slices from `before` and `after` are stale after a growth.
        pub fn ensureGap(self: *Self, allocator: Allocator, needed: usize) Allocator.Error!void {
            const gap_len = self.gap_end - self.gap_start;
            if (gap_len >= needed) return;

            const item_count = self.len();
            const spare = std.math.clamp(item_count / 4, self.growth.min_gap, self.growth.max_gap);
            const wanted = std.math.add(usize, item_count, needed) catch return error.OutOfMemory;
            const new_capacity = std.math.add(usize, wanted, spare) catch return error.OutOfMemory;

            const tail_len = self.storage.len - self.gap_end;
            const old_tail_start = self.gap_end;
            const grown = try allocator.realloc(self.storage, new_capacity);
            const new_tail_start = new_capacity - tail_len;
            const destination = grown[new_tail_start..];
            const source = grown[old_tail_start..][0..tail_len];
            std.mem.copyBackwards(T, destination, source);
            self.storage = grown;
            self.gap_end = new_tail_start;
        }

        /// Opens `count` items at `position` (at most `len()`) for the caller to fill before
        /// the buffer is next read: they count as items at once and hold undefined values. The
        /// slice returned is valid until the next call that moves the gap or grows the buffer.
        /// Nothing changes when allocation fails.
        pub fn insertUninitialized(self: *Self, allocator: Allocator, position: usize, count: usize) Allocator.Error![]T {
            try self.ensureGap(allocator, count);
            self.moveGap(position);
            const opened = self.storage[self.gap_start..][0..count];
            self.gap_start += count;
            return opened;
        }

        /// Inserts a copy of `items` before the item at `position` (at most `len()`), leaving the
        /// gap just after them. `items` must not be a slice of this buffer. Nothing changes when
        /// allocation fails.
        pub fn insert(self: *Self, allocator: Allocator, position: usize, items: []const T) Allocator.Error!void {
            const opened = try self.insertUninitialized(allocator, position, items.len);
            @memcpy(opened, items);
        }

        /// Inserts a copy of `items` at `position` into room `ensureGap` already made, so it
        /// cannot fail: the gap must hold `items.len`.
        pub fn insertAssumeCapacity(self: *Self, position: usize, items: []const T) void {
            std.debug.assert(self.gapLen() >= items.len);
            self.moveGap(position);
            @memcpy(self.storage[self.gap_start..][0..items.len], items);
            self.gap_start += items.len;
        }

        /// Removes the `count` items starting at `position`, which must all exist, leaving the gap
        /// where they were. Never allocates or frees: the room joins the gap.
        pub fn remove(self: *Self, position: usize, count: usize) void {
            std.debug.assert(position + count <= self.len());
            self.moveGap(position);
            self.gap_end += count;
        }

        /// Empties the sequence and keeps the storage, all of it gap.
        pub fn clear(self: *Self) void {
            self.gap_start = 0;
            self.gap_end = self.storage.len;
        }
    };
}

test "edits at any position match a plain list" {
    const allocator = std.testing.allocator;
    var buffer: GapBuffer(u8) = .{ .growth = .{ .min_gap = 8, .max_gap = 64 } };
    defer buffer.deinit(allocator);
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(allocator);

    var prng: std.Random.DefaultPrng = .init(0x6170);
    const random = prng.random();
    var step: usize = 0;
    while (step < 2000) : (step += 1) {
        const inserting = model.items.len == 0 or random.uintLessThan(u8, 3) != 0;
        if (inserting) {
            var items: [12]u8 = undefined;
            const count = random.uintAtMost(usize, items.len);
            random.bytes(items[0..count]);
            const position = random.uintAtMost(usize, model.items.len);
            try buffer.insert(allocator, position, items[0..count]);
            try model.insertSlice(allocator, position, items[0..count]);
        } else {
            const position = random.uintLessThan(usize, model.items.len);
            const count = random.uintAtMost(usize, @min(9, model.items.len - position));
            buffer.remove(position, count);
            model.replaceRangeAssumeCapacity(position, count, &.{});
        }
        try std.testing.expectEqual(model.items.len, buffer.len());
    }

    const copied = try allocator.alloc(u8, model.items.len);
    defer allocator.free(copied);
    buffer.copyRange(0, copied);
    try std.testing.expectEqualSlices(u8, model.items, copied);
    for (model.items, 0..) |expected, index| {
        try std.testing.expectEqual(expected, buffer.at(index));
    }
}
