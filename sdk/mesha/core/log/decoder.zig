//! Reading the log back: walking a log file's records, picking the metadata out of one,
//! and printing one as text.
//!
//! `FileRecords` walks the bytes of a `.meshalog` file (`format.zig`) and gives each record's
//! payload. A payload is a zone (`zones.RingRecord.of` reads it) or a log record
//! (`record.zig`), which `metadataOf` reads as metadata, `messageOf` as a short line for a
//! person, and `RecordPrinter` as a line of ZON for the console and `meshalog-print`. The
//! log's writer thread uses the same functions on live records. All of it is pure reading of
//! bytes the caller owns: no log state, usable from tools.
const std = @import("std");

const record = @import("record.zig");
const format = @import("format.zig");

/// The records of a log file, in the order they were written. A record whose checksum does
/// not match is given as not `valid`, for a reader that reports it; a record cut short by
/// the end of the file ends the walk.
pub const FileRecords = struct {
    /// The whole file's bytes, borrowed: they must outlive the walk and every payload it gives.
    data: []const u8,
    /// The byte offset the next search for a record starts from.
    position: usize,

    /// One record of the file.
    pub const Item = struct {
        /// Where the record's header begins in the file.
        offset: usize,
        /// The record's bytes, after its header: a slice of the file's.
        payload: []const u8,
        /// Whether the payload's checksum matches the header's. A payload that does not is
        /// damaged and should not be decoded.
        valid: bool,
    };

    /// A walk of `data`, the bytes of a whole log file, from its first record.
    /// `error.InvalidLogFile` when it is shorter than a file header or does not begin with
    /// `format.file_magic`. The version byte is not checked. Allocates nothing.
    pub fn init(data: []const u8) error{InvalidLogFile}!FileRecords {
        const header_len = @sizeOf(format.FileHeader);
        if (data.len < header_len or !std.mem.eql(u8, data[0..4], &format.file_magic)) return error.InvalidLogFile;
        return .{ .data = data, .position = header_len };
    }

    /// The next record, or null at the end of the file. Bytes between records that are not a
    /// record header are skipped.
    pub fn next(records: *FileRecords) ?Item {
        const data = records.data;
        // A header is found by its magic, so damage costs only the records it covers.
        const relative = std.mem.indexOf(u8, data[records.position..], &format.record_magic) orelse return null;
        const offset = records.position + relative;
        const lengths_start = offset + format.record_magic.len;
        if (lengths_start + 8 > data.len) return null;
        const length = std.mem.readInt(u32, data[lengths_start..][0..4], .little);
        const expected_crc = std.mem.readInt(u32, data[lengths_start + 4 ..][0..4], .little);
        const payload_start = lengths_start + 8;
        if (length > data.len - payload_start) return null;
        const payload = data[payload_start..][0..length];
        records.position = payload_start + length;
        return .{ .offset = offset, .payload = payload, .valid = format.crc32(payload) == expected_crc };
    }
};

test "a file's records are walked in order, a damaged one marked" {
    const testing = std.testing;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const file_header: format.FileHeader = .{};
    try file.appendSlice(testing.allocator, std.mem.asBytes(&file_header));
    for ([_][]const u8{ "first", "second", "third" }) |payload| {
        const header: format.RecordHeader = .{ .length = @intCast(payload.len), .crc32 = format.crc32(payload) };
        try file.appendSlice(testing.allocator, std.mem.asBytes(&header));
        try file.appendSlice(testing.allocator, payload);
    }
    // Damage the second record's payload.
    const damaged = std.mem.indexOf(u8, file.items, "second").?;
    file.items[damaged] = 'S';

    var records = try FileRecords.init(file.items);
    const first = records.next().?;
    try testing.expectEqualStrings("first", first.payload);
    try testing.expect(first.valid);
    try testing.expect(!records.next().?.valid);
    try testing.expectEqualStrings("third", records.next().?.payload);
    try testing.expect(records.next() == null);
    try testing.expectError(error.InvalidLogFile, FileRecords.init("not a log"));
}

fn writeString(w: *std.Io.Writer, value: []const u8) !void {
    try w.print("\"{f}\"", .{std.zig.fmtString(value)});
}

fn writeFloat(w: *std.Io.Writer, value: f64) !void {
    if (std.math.isNan(value)) return w.writeAll("nan");
    if (std.math.isInf(value)) return w.writeAll(if (value < 0) "-inf" else "inf");
    try w.print("{e}", .{value});
}

const level_names = [_][]const u8{ "trace", "debug", "info", "warn", "err", "fatal" };

test "producer records print parseable ZON with escaped strings and nested values" {
    const testing = std.testing;
    var printer = RecordPrinter.init(testing.allocator);
    defer printer.deinit();
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    const metadata = record.encode(1, 2, 2, 0, "cmd", .{ .cmd = "tag_name", .id = @as(u8, 7), .name = "scope with spaces" });
    try printer.printRecord(metadata.slice(), &output.writer);
    const encoded = record.encode(1, 3, 2, 7, "event\"\nname", .{
        .text = "text\n\t\"\\",
        .missing = @as(?u32, null),
        .values = [_]f64{ 1, -2.5, std.math.inf(f64), std.math.nan(f64) },
        .nested = .{ .ok = true },
    });
    try printer.printRecord(encoded.slice(), &output.writer);
    const Result = struct {
        level: []const u8,
        tag: []const u8,
        key: []const u8,
        value: struct { text: []const u8, missing: ?u32, values: [4]f64, nested: struct { ok: bool } },
    };
    const terminated = try testing.allocator.dupeZ(u8, output.written());
    defer testing.allocator.free(terminated);
    const parsed = try std.zon.parse.fromSliceAlloc(Result, testing.allocator, terminated, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);
    try testing.expectEqualStrings("scope with spaces", parsed.tag);
    try testing.expectEqualStrings("event\"\nname", parsed.key);
    try testing.expectEqualStrings("text\n\t\"\\", parsed.value.text);
    try testing.expect(parsed.value.missing == null and parsed.value.nested.ok);
    try testing.expect(std.math.isInf(parsed.value.values[2]) and std.math.isNan(parsed.value.values[3]));
}

test "terminal metadata recognizes all historical tag name spellings" {
    for ([_][]const u8{ "tag_name", ":tag-name", ".tag-name" }) |command| {
        var printer = RecordPrinter.init(std.testing.allocator);
        defer printer.deinit();
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        const metadata = record.encode(1, 2, 2, 0, "cmd", .{ .cmd = command, .id = @as(u8, 7), .name = "old scope" });
        try printer.printRecord(metadata.slice(), &output.writer);
        try std.testing.expectEqualStrings("old scope", printer.tags.get(7).?);
        try std.testing.expectEqual(@as(usize, 0), output.written().len);
    }
}

/// A metadata record's command and the fields that name something.
pub const Metadata = struct {
    /// What the record says.
    command: record.MetadataCommand,
    /// A scope's tag, a thread's id, or a zone's name hash; 0 when the record gives none.
    id: u64 = 0,
    /// The name given: a scope's, a thread's or a zone's. Empty for a clock anchor.
    name: []const u8 = "",
    /// A thread's lane, which `thread_name` records carry.
    lane: ?u16 = null,
    /// A zone's scope tag, which `zone_name` records carry.
    scope: u32 = 0,
};

/// The metadata a record carries, or null for any other record: a zone, a log record, or
/// bytes that do not decode. `name` borrows `payload`. Allocates nothing.
pub fn metadataOf(payload: []const u8) ?Metadata {
    var d: Decoder = .{ .data = payload };
    const header = d.readByte() catch return null;
    if (header != 0x96) return null;
    for (0..2) |_| _ = d.readUint() catch return null;
    _ = d.readUint() catch return null;
    const tag = d.readUint() catch return null;
    const key = d.readStrRaw() catch return null;
    if (tag != 0 or !std.mem.eql(u8, key, "cmd")) return null;
    const map_header = d.readByte() catch return null;
    const count: usize = switch (map_header) {
        0x80...0x8f => map_header & 0x0f,
        0xde => d.readU16() catch return null,
        else => return null,
    };
    var command: ?record.MetadataCommand = null;
    var metadata: Metadata = .{ .command = .tag_name };
    for (0..count) |_| {
        const field = d.readStrRaw() catch return null;
        if (std.mem.eql(u8, field, "cmd")) {
            const text = d.readStrRaw() catch return null;
            command = record.metadataCommand(text);
        } else if (std.mem.eql(u8, field, "id")) {
            metadata.id = d.readUint() catch return null;
        } else if (std.mem.eql(u8, field, "name")) {
            metadata.name = d.readStrRaw() catch return null;
        } else if (std.mem.eql(u8, field, "scope")) {
            const scope_tag = d.readUint() catch return null;
            metadata.scope = std.math.cast(u32, scope_tag) orelse return null;
        } else if (std.mem.eql(u8, field, "lane")) {
            const lane = d.readUint() catch return null;
            metadata.lane = std.math.cast(u16, lane);
        } else {
            d.skipValue() catch return null;
        }
    }
    metadata.command = command orelse return null;
    return metadata;
}

test "metadata names a thread's lane" {
    const encoded = record.encode(1, 2, 2, 0, "cmd", .{ .cmd = "thread_name", .id = @as(u64, 99), .lane = @as(u16, 3), .name = "render" });
    const metadata = metadataOf(encoded.slice()).?;
    try std.testing.expectEqual(record.MetadataCommand.thread_name, metadata.command);
    try std.testing.expectEqual(@as(?u16, 3), metadata.lane);
    try std.testing.expectEqualStrings("render", metadata.name);
    const plain = record.encode(1, 2, 2, 5, "event", .{ .value = @as(u32, 1) });
    try std.testing.expect(metadataOf(plain.slice()) == null);
}

/// A log record as one line of text, for the profiler's messages and for notices.
pub const MessageLine = struct {
    /// The id of the thread that logged it.
    thread: u64,
    /// When it was logged, in monotonic nanoseconds (`log.now`).
    timestamp_ns: u64,
    /// The record's `log.Level`, as its integer; 0 when the record carries a number no `u8`
    /// holds.
    level: u8,
    /// The record's scope tag.
    tag: u32,
    /// The key and the value, borrowing the buffer given to `messageOf`.
    text: []const u8,
};

/// The record as one line, its key then its value written compactly into `buffer` and cut
/// short where the buffer ends: a struct's fields as `name=value`, strings bare. Null for a
/// record whose tag is 0 (metadata), a zone record, or one whose header does not decode; a
/// value that stops decoding part-way ends the line there. Allocates nothing.
pub fn messageOf(payload: []const u8, buffer: []u8) ?MessageLine {
    var d: Decoder = .{ .data = payload };
    const header = d.readByte() catch return null;
    if (header != 0x96) return null;
    const thread = d.readUint() catch return null;
    const timestamp = d.readUint() catch return null;
    const level = d.readUint() catch return null;
    const tag_value = d.readUint() catch return null;
    const tag = std.math.cast(u32, tag_value) orelse return null;
    const key = d.readStrRaw() catch return null;
    if (tag == 0) return null;
    var w: std.Io.Writer = .fixed(buffer);
    // A full buffer ends the line where it is.
    compactLine(&w, &d, key) catch {};
    return .{ .thread = thread, .timestamp_ns = timestamp, .level = std.math.cast(u8, level) orelse 0, .tag = tag, .text = w.buffered() };
}

fn compactLine(w: *std.Io.Writer, d: *Decoder, key: []const u8) !void {
    try w.writeAll(key);
    const peek = if (d.pos < d.data.len) d.data[d.pos] else return;
    // An empty struct or a void value says nothing more.
    if (peek == 0x80 or peek == 0xc0) return;
    try w.writeByte(' ');
    try d.printCompact(w, .top);
}

test "a record as a message line: its key, then its fields compactly" {
    const encoded = record.encode(1, 42, 3, 7, "load_failed", .{ .path = "a b.zon", .count = @as(u32, 3), .ok = false, .nested = .{ .x = @as(f32, 0.5) } });
    var buffer: [128]u8 = undefined;
    const line = messageOf(encoded.slice(), &buffer).?;
    try std.testing.expectEqual(@as(u64, 42), line.timestamp_ns);
    try std.testing.expectEqual(@as(u8, 3), line.level);
    try std.testing.expectEqual(@as(u32, 7), line.tag);
    try std.testing.expectEqualStrings("load_failed path=a b.zon count=3 ok=false nested={x=0.5}", line.text);
    var short: [8]u8 = undefined;
    try std.testing.expectEqualStrings("load_fai", messageOf(encoded.slice(), &short).?.text);
    const bare = record.encode(1, 2, 2, 7, "started", .{});
    try std.testing.expectEqualStrings("started", messageOf(bare.slice(), &buffer).?.text);
    const metadata = record.encode(1, 2, 2, 0, "cmd", .{ .cmd = "tag_name", .id = @as(u8, 7), .name = "scope" });
    try std.testing.expect(messageOf(metadata.slice(), &buffer) == null);
}

/// Prints log records as text, a line each, naming each record's scope from the `tag_name`
/// metadata records it has been given so far: so give it a stream's records in order, the
/// metadata ones included. Not thread-safe.
pub const RecordPrinter = struct {
    /// Each scope tag's name, as the metadata records seen so far gave it. The names are owned
    /// by `allocator`.
    tags: std.AutoHashMap(u32, []const u8),
    /// Allocates the tag names and the map.
    allocator: std.mem.Allocator,

    /// A printer that knows no scope names yet. Allocates nothing until a name arrives.
    pub fn init(allocator: std.mem.Allocator) RecordPrinter {
        return .{
            .tags = std.AutoHashMap(u32, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    /// Frees the names and the map.
    pub fn deinit(self: *RecordPrinter) void {
        var it = self.tags.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.tags.deinit();
    }

    /// Writes the log record `payload` to `w` as one line of ZON,
    /// `.{ .level = "info", .tag = "scope", .key = "key", .value = ... }`, ending in a line feed;
    /// the tag is its number when no name is known for it. A metadata record prints nothing: a
    /// `tag_name` one is remembered. Fails with `error.InvalidFormat` or `error.UnexpectedEnd`
    /// on bytes that are not a log record, a zone record among them, with `error.OutOfMemory`
    /// keeping a name, or with the writer's error; part of a line may be written by then.
    pub fn printRecord(self: *RecordPrinter, payload: []const u8, w: *std.Io.Writer) !void {
        var d: Decoder = .{ .data = payload };
        try d.decodeRecord(w, self);
    }
};

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(d: *Decoder) !u8 {
        if (d.pos >= d.data.len) return error.UnexpectedEnd;
        defer d.pos += 1;
        return d.data[d.pos];
    }

    fn readU16(d: *Decoder) !u16 {
        if (d.pos + 2 > d.data.len) return error.UnexpectedEnd;
        const v = std.mem.readInt(u16, d.data[d.pos..][0..2], .big);
        d.pos += 2;
        return v;
    }

    fn readU32(d: *Decoder) !u32 {
        if (d.pos + 4 > d.data.len) return error.UnexpectedEnd;
        const v = std.mem.readInt(u32, d.data[d.pos..][0..4], .big);
        d.pos += 4;
        return v;
    }

    fn readU64(d: *Decoder) !u64 {
        if (d.pos + 8 > d.data.len) return error.UnexpectedEnd;
        const v = std.mem.readInt(u64, d.data[d.pos..][0..8], .big);
        d.pos += 8;
        return v;
    }

    fn readUint(d: *Decoder) !u64 {
        const b = try d.readByte();
        return switch (b) {
            0x00...0x7f => b,
            0xcc => try d.readByte(),
            0xcd => try d.readU16(),
            0xce => try d.readU32(),
            0xcf => try d.readU64(),
            else => error.InvalidFormat,
        };
    }

    fn readStrRaw(d: *Decoder) ![]const u8 {
        const b = try d.readByte();
        const len: usize = switch (b) {
            0xa0...0xbf => b & 0x1f,
            0xd9 => try d.readByte(),
            0xda => try d.readU16(),
            else => return error.InvalidFormat,
        };
        if (d.pos + len > d.data.len) return error.UnexpectedEnd;
        defer d.pos += len;
        return d.data[d.pos .. d.pos + len];
    }

    fn skipValue(d: *Decoder) !void {
        const b = try d.readByte();
        switch (b) {
            0x00...0x7f, 0xe0...0xff, 0xc0, 0xc2, 0xc3 => {},
            0xcc, 0xd0 => _ = try d.readByte(),
            0xcd, 0xd1 => _ = try d.readU16(),
            0xce, 0xd2, 0xca => _ = try d.readU32(),
            0xcf, 0xd3, 0xcb => _ = try d.readU64(),
            0xa0...0xbf => {
                const len = b & 0x1f;
                if (d.pos + len > d.data.len) return error.UnexpectedEnd;
                d.pos += len;
            },
            0xd9 => {
                const len = try d.readByte();
                if (d.pos + len > d.data.len) return error.UnexpectedEnd;
                d.pos += len;
            },
            0xda => {
                const len = try d.readU16();
                if (d.pos + len > d.data.len) return error.UnexpectedEnd;
                d.pos += len;
            },
            0x90...0x9f => for (0..b & 0x0f) |_| try d.skipValue(),
            0xdc => {
                const n = try d.readU16();
                for (0..n) |_| try d.skipValue();
            },
            0x80...0x8f => for (0..b & 0x0f) |_| {
                try d.skipValue();
                try d.skipValue();
            },
            0xde => {
                const n = try d.readU16();
                for (0..n) |_| {
                    try d.skipValue();
                    try d.skipValue();
                }
            },
            else => return error.InvalidFormat,
        }
    }

    fn parseTagNameCmd(d: *Decoder, printer: *RecordPrinter) !void {
        const b = try d.readByte();
        const count: usize = switch (b) {
            0x80...0x8f => b & 0x0f,
            0xde => try d.readU16(),
            else => return error.InvalidFormat,
        };

        var cmd: ?[]const u8 = null;
        var tag_id: ?u64 = null;
        var tag_name: ?[]const u8 = null;

        for (0..count) |_| {
            const k = try d.readStrRaw();
            if (std.mem.eql(u8, k, "cmd")) {
                cmd = try d.readStrRaw();
            } else if (std.mem.eql(u8, k, "id")) {
                tag_id = try d.readUint();
            } else if (std.mem.eql(u8, k, "name")) {
                tag_name = try d.readStrRaw();
            } else {
                try d.skipValue();
            }
        }

        if (cmd == null or record.metadataCommand(cmd.?) != .tag_name) return;

        if (tag_id) |id| {
            if (id > std.math.maxInt(u32)) return;
            if (tag_name) |name| {
                const owned = try printer.allocator.dupe(u8, name);
                errdefer printer.allocator.free(owned);
                const old = try printer.tags.fetchPut(@intCast(id), owned);
                if (old) |entry| printer.allocator.free(entry.value);
            }
        }
    }

    fn decodeRecord(d: *Decoder, w: *std.Io.Writer, printer: *RecordPrinter) !void {
        const hdr = try d.readByte();
        if (hdr != 0x96) return error.InvalidFormat;

        _ = try d.readUint();
        _ = try d.readUint();
        const level = try d.readUint();
        const tag_value = try d.readUint();
        if (tag_value > std.math.maxInt(u32)) return error.InvalidFormat;
        const tag: u32 = @intCast(tag_value);
        const key = try d.readStrRaw();

        if (tag == 0 and std.mem.eql(u8, key, "cmd")) {
            try d.parseTagNameCmd(printer);
            return;
        }

        {
            const level_name = if (level < level_names.len) level_names[@intCast(level)] else "?";
            try w.writeAll(".{ .level = ");
            try writeString(w, level_name);
            try w.writeAll(", .tag = ");
            if (printer.tags.get(tag)) |name| try writeString(w, name) else try w.print("{d}", .{tag});
            try w.writeAll(", .key = ");
            try writeString(w, key);
            try w.writeAll(", .value = ");
            try d.printValue(w);
            try w.writeAll(" }\n");
        }
    }

    fn printValue(d: *Decoder, w: *std.Io.Writer) anyerror!void {
        const b = try d.readByte();
        switch (b) {
            0x00...0x7f => try w.print("{}", .{b}),
            0xe0...0xff => try w.print("{}", .{@as(i8, @bitCast(b))}),
            0xc0 => try w.writeAll("null"),
            0xc2 => try w.writeAll("false"),
            0xc3 => try w.writeAll("true"),
            0xca => try writeFloat(w, @as(f32, @bitCast(try d.readU32()))),
            0xcb => try writeFloat(w, @as(f64, @bitCast(try d.readU64()))),
            0xcc => try w.print("{}", .{try d.readByte()}),
            0xcd => try w.print("{}", .{try d.readU16()}),
            0xce => try w.print("{}", .{try d.readU32()}),
            0xcf => try w.print("{}", .{try d.readU64()}),
            0xd0 => try w.print("{}", .{@as(i8, @bitCast(try d.readByte()))}),
            0xd1 => try w.print("{}", .{@as(i16, @bitCast(try d.readU16()))}),
            0xd2 => try w.print("{}", .{@as(i32, @bitCast(try d.readU32()))}),
            0xd3 => try w.print("{}", .{@as(i64, @bitCast(try d.readU64()))}),
            0xa0...0xbf => try d.printStr(w, b & 0x1f),
            0xd9 => try d.printStr(w, try d.readByte()),
            0xda => try d.printStr(w, try d.readU16()),
            0x90...0x9f => try d.printArray(w, b & 0x0f),
            0xdc => try d.printArray(w, try d.readU16()),
            0x80...0x8f => try d.printMap(w, b & 0x0f),
            0xde => try d.printMap(w, try d.readU16()),
            else => return error.InvalidFormat,
        }
    }

    const Nesting = enum { top, nested };

    /// A value for a reader rather than a parser: a struct's fields as `name=value`, spaced
    /// at the top and braced within, strings bare, floats as short as they print.
    fn printCompact(d: *Decoder, w: *std.Io.Writer, nesting: Nesting) anyerror!void {
        const b = try d.readByte();
        switch (b) {
            0xa0...0xbf => try w.writeAll(try d.readBytes(b & 0x1f)),
            0xd9 => try w.writeAll(try d.readBytes(try d.readByte())),
            0xda => try w.writeAll(try d.readBytes(try d.readU16())),
            0xca => try w.print("{d}", .{@as(f32, @bitCast(try d.readU32()))}),
            0xcb => try w.print("{d}", .{@as(f64, @bitCast(try d.readU64()))}),
            0x90...0x9f, 0xdc => {
                const count: usize = if (b == 0xdc) try d.readU16() else b & 0x0f;
                try w.writeByte('[');
                for (0..count) |index| {
                    if (index > 0) try w.writeAll(", ");
                    try d.printCompact(w, .nested);
                }
                try w.writeByte(']');
            },
            0x80...0x8f, 0xde => {
                const count: usize = if (b == 0xde) try d.readU16() else b & 0x0f;
                if (nesting == .nested) try w.writeByte('{');
                for (0..count) |index| {
                    if (index > 0) try w.writeAll(if (nesting == .top) " " else ", ");
                    try w.writeAll(try d.readStrRaw());
                    try w.writeByte('=');
                    try d.printCompact(w, .nested);
                }
                if (nesting == .nested) try w.writeByte('}');
            },
            else => {
                d.pos -= 1;
                try d.printValue(w);
            },
        }
    }

    fn readBytes(d: *Decoder, len: usize) ![]const u8 {
        if (d.pos + len > d.data.len) return error.UnexpectedEnd;
        defer d.pos += len;
        return d.data[d.pos .. d.pos + len];
    }

    fn printStr(d: *Decoder, w: *std.Io.Writer, len: usize) !void {
        if (d.pos + len > d.data.len) return error.UnexpectedEnd;
        try writeString(w, d.data[d.pos .. d.pos + len]);
        d.pos += len;
    }

    fn printArray(d: *Decoder, w: *std.Io.Writer, count: usize) !void {
        try w.writeAll(".{");
        for (0..count) |i| {
            if (i > 0) try w.writeAll(", ");
            try d.printValue(w);
        }
        try w.writeAll("}");
    }

    fn printMap(d: *Decoder, w: *std.Io.Writer, count: usize) !void {
        try w.writeAll(".{");
        for (0..count) |i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(".@");
            try writeString(w, try d.readStrRaw());
            try w.writeAll(" = ");
            try d.printValue(w);
        }
        try w.writeAll("}");
    }
};
