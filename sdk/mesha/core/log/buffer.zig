//! The ring each logging thread writes its records into, and the log's writer thread reads:
//! single-producer, single-consumer, with no lock and no allocation after `init`.
//!
//! A record is stored as a `u16` length and its bytes, never split across the ring's end:
//! where one does not fit before the end, the producer writes the skip marker there and the
//! record at the start. The log panics when a write finds the ring full (`log.zig`); the ring
//! itself only says so.
const std = @import("std");
const contract = @import("../contract.zig");
const format = @import("format.zig");

const skip_marker = format.skip_marker;

/// The largest payload a ring takes: its length header is a `u16`, and the skip marker is
/// the one length no record has.
pub const max_payload_bytes = std.math.maxInt(u16) - 1;

/// A ring of length-prefixed records for one producer thread and one consumer thread: the
/// thread that owns it writes, and the log's writer thread reads. Created on the heap by
/// `init`, since both threads hold its address.
pub const SpscRingBuffer = struct {
    /// The ring's bytes.
    buf: []align(64) u8,
    /// Where the producer writes next, as an offset into `buf`. Stored by the producer alone.
    write_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Where the consumer reads next, as an offset into `buf`. Stored by the consumer alone.
    read_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// A ring of `ring_bytes`, which must hold at least one largest record. The ring and the
    /// struct come from `allocator`; free both with `deinit`.
    pub fn init(allocator: std.mem.Allocator, ring_bytes: u32) !*SpscRingBuffer {
        const self = try allocator.create(SpscRingBuffer);
        errdefer allocator.destroy(self);
        const buf = try allocator.alignedAlloc(u8, .@"64", ring_bytes);
        self.* = .{ .buf = buf };
        return self;
    }

    /// Frees the ring and the struct itself; `allocator` is the one given to `init`. Neither
    /// thread may still use it.
    pub fn deinit(self: *SpscRingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        allocator.destroy(self);
    }

    /// The ring's size in bytes, headers included.
    pub fn capacity(self: *const SpscRingBuffer) u32 {
        return @intCast(self.buf.len);
    }

    /// Copies `payload` into the ring as one record and publishes it to the consumer. False,
    /// with nothing published, when the ring has no room for it or it is longer than
    /// `max_payload_bytes`. The producer thread's alone; never blocks.
    pub fn tryWrite(self: *SpscRingBuffer, payload: []const u8) bool {
        if (payload.len > max_payload_bytes) return false;
        const ring_bytes = self.capacity();
        const header_size = @sizeOf(u16);
        const total: u32 = header_size + @as(u32, @intCast(payload.len));

        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.acquire);
        contract.invariant(wp < ring_bytes and rp < ring_bytes, "log.ring.positions_in_range");

        const space_to_end: u32 = ring_bytes - wp;

        if (space_to_end >= total + @as(u32, @intCast(header_size))) {
            if (!self.hasSpace(wp, rp, total)) return false;
            self.writeHeader(wp, @intCast(payload.len));
            @memcpy(self.buf[wp + header_size .. wp + header_size + payload.len], payload);
            self.write_pos.store(wp + total, .release);
        } else {
            const skip_size: u32 = @intCast(header_size);
            contract.invariant(space_to_end >= skip_size, "log.ring.wrap_marker_fits");

            const total_needed = space_to_end + total;
            if (!self.hasSpace(wp, rp, total_needed)) return false;

            std.mem.writeInt(u16, self.buf[wp..][0..2], skip_marker, .little);

            if (!self.hasSpace(0, rp, total)) return false;
            self.writeHeader(0, @intCast(payload.len));
            @memcpy(self.buf[header_size .. header_size + payload.len], payload);
            self.write_pos.store(total, .release);
        }
        return true;
    }

    /// The oldest unread record's bytes, or null when the ring is empty. The slice points
    /// into the ring and stays valid until `consumeFront`. Calling it again without consuming
    /// returns the same record. The consumer thread's alone.
    pub fn readFront(self: *SpscRingBuffer) ?[]const u8 {
        const ring_bytes = self.capacity();
        var rp = self.read_pos.load(.monotonic);
        const wp = self.write_pos.load(.acquire);
        contract.invariant(rp < ring_bytes and wp < ring_bytes, "log.ring.positions_in_range");
        if (rp == wp) return null;

        const len = std.mem.readInt(u16, self.buf[rp..][0..2], .little);
        if (len == skip_marker) {
            self.read_pos.store(0, .release);
            rp = 0;
            const wp2 = self.write_pos.load(.acquire);
            if (rp == wp2) return null;
        }

        const actual_len = std.mem.readInt(u16, self.buf[rp..][0..2], .little);
        const payload_start = rp + @sizeOf(u16);
        return self.buf[payload_start .. payload_start + actual_len];
    }

    /// Releases the record `readFront` last returned, giving its room back to the producer. Call
    /// it once after each `readFront` that returned a record. The consumer thread's alone.
    pub fn consumeFront(self: *SpscRingBuffer) void {
        var rp = self.read_pos.load(.monotonic);
        contract.invariant(rp < self.capacity(), "log.ring.positions_in_range");

        const len = std.mem.readInt(u16, self.buf[rp..][0..2], .little);
        if (len == skip_marker) {
            rp = 0;
        }
        const actual_len = std.mem.readInt(u16, self.buf[rp..][0..2], .little);
        self.read_pos.store(rp + @sizeOf(u16) + actual_len, .release);
    }

    fn writeHeader(self: *SpscRingBuffer, pos: u32, len: u16) void {
        std.mem.writeInt(u16, self.buf[pos..][0..2], len, .little);
    }

    fn hasSpace(self: *SpscRingBuffer, wp: u32, rp: u32, needed: u32) bool {
        const ring_bytes = self.capacity();
        const used: u32 = if (wp >= rp) wp - rp else ring_bytes - rp + wp;
        return ring_bytes - used >= needed;
    }
};

test "ring rejects oversized records and wraps safely at the end boundary" {
    const allocator = std.testing.allocator;
    const capacity: u32 = 128 * 1024;
    const ring = try SpscRingBuffer.init(allocator, capacity);
    defer ring.deinit(allocator);

    const oversized = [_]u8{0} ** std.math.maxInt(u16);
    try std.testing.expect(!ring.tryWrite(&oversized));
    try std.testing.expect(ring.readFront() == null);

    const payload = [_]u8{ 0x41, 0x42 };
    const near_end = capacity - 6;
    ring.write_pos.store(near_end, .monotonic);
    ring.read_pos.store(near_end, .monotonic);
    try std.testing.expect(ring.tryWrite(&payload));
    try std.testing.expectEqualSlices(u8, &payload, ring.readFront().?);
    ring.consumeFront();

    try std.testing.expectEqual(@as(u32, capacity - 2), ring.write_pos.load(.monotonic));
    try std.testing.expect(ring.tryWrite(&payload));
    try std.testing.expectEqualSlices(u8, &payload, ring.readFront().?);
    ring.consumeFront();
    try std.testing.expect(ring.readFront() == null);
    try std.testing.expectEqual(ring.write_pos.load(.monotonic), ring.read_pos.load(.monotonic));
}
