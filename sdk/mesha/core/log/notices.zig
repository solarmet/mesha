//! What the log has to tell a person: its warnings and errors, each as a line of text. The
//! log's writer thread adds them as it writes their records; the frame's thread takes them
//! and shows them (the text editor keeps them in `*Messages*`).
//!
//! The lines wait in storage made once, so adding one allocates nothing. Lines that find it
//! full are counted and dropped: the log's file still has their records.

const std = @import("std");

/// The lines waiting to be told. One thread adds (the log's writer) and another takes (the
/// frame's); a mutex orders them.
pub const Notices = struct {
    /// What the mutex locks through.
    io: std.Io,
    /// Held while lines are added or taken.
    lock: std.Io.Mutex = .init,
    /// The lines waiting, each ended by a line feed, in `storage[0..used]`.
    storage: []u8,
    /// The bytes of `storage` that hold waiting lines.
    used: usize = 0,
    /// Lines dropped since the last `take`, which says so.
    dropped: u32 = 0,
    /// The lowest level told, as the log's `Level` integer.
    min_level: u8,
    /// Wakes the frame's thread to take a line added while it sleeps. Set once by the host.
    wake: std.atomic.Value(?*const fn () void) = .init(null),

    /// The bytes of lines that may wait at once; lines beyond are dropped and counted.
    pub const storage_bytes = 64 * 1024;
    /// The longest text of a line the log's writer gives `add`; a longer record's text is cut
    /// short there.
    pub const max_line_bytes = 1024;

    /// Notices that tell records at `min_level` (a `Level` integer) and above, with storage of
    /// `storage_bytes` from `allocator`. `min_level` is kept for the log's writer to filter by;
    /// `add` itself takes every line. Fails with `error.OutOfMemory`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, min_level: u8) !Notices {
        return .{ .io = io, .storage = try allocator.alloc(u8, storage_bytes), .min_level = min_level };
    }

    /// Frees the storage; `allocator` is the one given to `init`. No thread may still add or take.
    pub fn deinit(notices: *Notices, allocator: std.mem.Allocator) void {
        allocator.free(notices.storage);
    }

    /// Adds the line `scope: text`, copying both, and calls `wake` when one is set. A line
    /// that does not fit the storage is dropped and counted. Called by the log's writer thread.
    pub fn add(notices: *Notices, scope: []const u8, text: []const u8) void {
        {
            notices.lock.lockUncancelable(notices.io);
            defer notices.lock.unlock(notices.io);
            const separator = ": ";
            const needed = scope.len + separator.len + text.len + 1;
            if (needed > notices.storage.len - notices.used) {
                notices.dropped +|= 1;
                return;
            }
            var writer: std.Io.Writer = .fixed(notices.storage[notices.used..]);
            writer.writeAll(scope) catch unreachable;
            writer.writeAll(separator) catch unreachable;
            writer.writeAll(text) catch unreachable;
            writer.writeByte('\n') catch unreachable;
            notices.used += needed;
        }
        if (notices.wake.load(.acquire)) |wake| wake();
    }

    /// Moves the waiting lines into `out`, as many whole ones as fit, oldest first, and
    /// returns them as a slice of `out`; lines that did not fit wait for the next call. A line
    /// saying how many were dropped comes first when any were; when `out` cannot hold even
    /// that, nothing is taken. Called by the frame's thread.
    pub fn take(notices: *Notices, out: []u8) []u8 {
        notices.lock.lockUncancelable(notices.io);
        defer notices.lock.unlock(notices.io);
        var written: usize = 0;
        if (notices.dropped != 0) {
            const said = std.fmt.bufPrint(out, "log: {d} messages dropped\n", .{notices.dropped}) catch return out[0..0];
            written = said.len;
            notices.dropped = 0;
        }
        const waiting = notices.storage[0..notices.used];
        const room = out.len - written;
        const fitting = if (waiting.len <= room) waiting.len else if (std.mem.lastIndexOfScalar(u8, waiting[0..room], '\n')) |end| end + 1 else 0;
        @memcpy(out[written..][0..fitting], waiting[0..fitting]);
        std.mem.copyForwards(u8, notices.storage[0 .. waiting.len - fitting], waiting[fitting..]);
        notices.used = waiting.len - fitting;
        return out[0 .. written + fitting];
    }
};

test "notices are taken whole, oldest first, and the dropped are counted" {
    var notices = try Notices.init(std.testing.allocator, std.testing.io, 0);
    defer notices.deinit(std.testing.allocator);
    notices.add("plugins", "plugin_init_failed plugin=user");
    notices.add("watch", "watch_ended code=1");

    var small: [40]u8 = undefined;
    try std.testing.expectEqualStrings("plugins: plugin_init_failed plugin=user\n", notices.take(&small));
    var rest: [64]u8 = undefined;
    try std.testing.expectEqualStrings("watch: watch_ended code=1\n", notices.take(&rest));
    try std.testing.expectEqualStrings("", notices.take(&rest));

    const long: [Notices.storage_bytes]u8 = @splat('x');
    notices.add("big", &long);
    try std.testing.expectEqualStrings("log: 1 messages dropped\n", notices.take(&rest));
}
