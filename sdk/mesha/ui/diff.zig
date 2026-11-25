//! A unified diff drawn as an outline: files, the hunks of each, and the lines of each hunk,
//! coloured as added, removed or context. It knows the unified-diff hunk (`@@ -a,b +c,d @@`
//! and lines beginning `+`, `-`, a space and `\`) and nothing of any version-control system:
//! a file's headers (git's `diff --git` and index lines, Perforce's `====` line) are the
//! caller's to read and to write back, and so is what a file is called and what is said of it.
//!
//! The caller splits what its program said into each file's part, takes the hunks of a part
//! with `parseHunks`, and builds the lines to draw with `lines`, giving each file a key its
//! folds are kept by:
//!
//!     const counted = diff.parseHunks(part, hunk_room);
//!     const file_keys = [_]u64{key_of_path};
//!     const files = [_]diff.File{.{ .label = path, .hunks = hunk_room[0..counted.kept] }};
//!     var built: diff.Lines = .{};
//!     try diff.lines(arena, &files, .{ .files = &file_keys }, diff.default_style, &built);
//!
//! `built.lines` are `outline.Line`s: the caller keeps the cursor and the folds over them and
//! draws them with `outline.record`, as it would any outline. Beside each line, `built.at`
//! says which file, hunk and hunk line it is, so a key on the cursor's line finds what it acts
//! on: `newLine` gives the new file's line to open, `patch` writes the bytes that apply one
//! hunk alone, and `stepHunk` moves the caller's cursor to the next hunk or the one before. Nothing here keeps anything between calls or touches a table; `lines` allocates
//! from the caller's allocator, and everything else allocates nothing.
const std = @import("std");
const outline = @import("outline.zig");
const ui = @import("ui.zig");

/// A hunk of a unified diff. Its slices are of the bytes `parseHunks` read, which the caller
/// keeps alive as long as it keeps the hunk.
pub const Hunk = struct {
    /// Its `@@ -a,b +c,d @@` line, with any text after it and its line break.
    header: []const u8,
    /// Every line after `header` up to the next hunk or the end of the part, byte for byte:
    /// carriage returns and `\ No newline at end of file` lines included, whatever the
    /// encoding.
    body: []const u8,
    /// Its first line in the old file; 0 for an added file's.
    old_start: u32,
    /// How many lines of the old file it covers.
    old_count: u32,
    /// Its first line in the new file; 0 for a deleted file's.
    new_start: u32,
    /// How many lines of the new file it covers.
    new_count: u32,
};

/// How many hunks `parseHunks` found, and how many of them fit in the slice it was given: the
/// first `kept`.
pub const Counted = struct {
    /// Hunks found in the part.
    seen: u32 = 0,
    /// Hunks written to the slice: the first `kept` of those found.
    kept: u32 = 0,
};

/// Splits `part`, one file's part of a unified diff, into `hunks`, without copying, as many as
/// fit, and says how many it found. Hunks begin at the part's first line that begins `@@ `;
/// what comes before it (a file's headers) is passed over. Each hunk runs to the next `@@ `
/// line or the end of the part. A count left out of a header is 1, and a header whose ranges
/// cannot be read gives 0s.
pub fn parseHunks(part: []const u8, hunks: []Hunk) Counted {
    var counted: Counted = .{};
    var position: usize = 0;
    // Past a file's headers, to its first hunk.
    while (position < part.len) {
        const line = lineAt(part, position);
        if (std.mem.startsWith(u8, line, "@@ ")) break;
        position += line.len;
    }
    while (position < part.len) {
        const header = lineAt(part, position);
        position += header.len;
        const body_start = position;
        while (position < part.len) {
            const line = lineAt(part, position);
            if (std.mem.startsWith(u8, line, "@@ ")) break;
            position += line.len;
        }
        counted.seen += 1;
        if (counted.kept >= hunks.len) continue;
        const ranges = readRanges(header);
        hunks[counted.kept] = .{
            .header = header,
            .body = part[body_start..position],
            .old_start = ranges.old.start,
            .old_count = ranges.old.count,
            .new_start = ranges.new.start,
            .new_count = ranges.new.count,
        };
        counted.kept += 1;
    }
    return counted;
}

/// The line that begins at `position`, its line break included; the rest of `bytes` when it
/// has none.
fn lineAt(bytes: []const u8, position: usize) []const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, position, '\n');
    if (end) |newline| return bytes[position .. newline + 1];
    return bytes[position..];
}

/// Where a hunk is in a file: its first line and how many it covers.
const Range = struct { start: u32 = 0, count: u32 = 0 };

/// A hunk's ranges in the old file and the new.
const Ranges = struct { old: Range = .{}, new: Range = .{} };

/// Reads `@@ -a[,b] +c[,d] @@` from a hunk's header; 0s where it cannot.
fn readRanges(header: []const u8) Ranges {
    var fields = std.mem.splitScalar(u8, header, ' ');
    _ = fields.next();
    const old_range = fields.next() orelse return .{};
    const new_range = fields.next() orelse return .{};
    if (old_range.len < 2 or new_range.len < 2) return .{};
    const old = parseRange(old_range[1..]);
    const new = parseRange(new_range[1..]);
    return .{ .old = old, .new = new };
}

/// `a` or `a,b` as a range; a count left out is 1.
fn parseRange(text: []const u8) Range {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return .{ .start = parseNumber(text), .count = 1 };
    const start = parseNumber(text[0..comma]);
    const count = parseNumber(text[comma + 1 ..]);
    return .{ .start = start, .count = count };
}

fn parseNumber(text: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 10) catch 0;
}

/// A file as `lines` shows it. Its slices are the caller's, alive as long as the lines built
/// from it are.
pub const File = struct {
    /// What the file is called, as the caller made it: a path, or a rename as `old -> new`.
    /// Made displayable where it is not UTF-8.
    label: []const u8,
    /// What is said of it under its line, dimmed, before its hunks: "Binary file", "mode
    /// changed"; empty for nothing.
    note: []const u8 = "",
    /// Its hunks, in order.
    hunks: []const Hunk = &.{},
};

/// `At.hunk` and `At.line` of a line that is no hunk's, or no hunk line.
pub const none = std.math.maxInt(u32);

/// What a line `lines` built is: its file's index in the files given, its hunk's index among
/// the file's hunks, and its place among the hunk's body's lines, from 0. A file's line and its
/// note's have `hunk` and `line` `none`; a hunk's line has `line` `none`.
pub const At = struct {
    /// The index of the line's file in `lines`' `files`.
    file: u32,
    /// The index of its hunk in the file's `hunks`, or `none`.
    hunk: u32 = none,
    /// Its place among the hunk's body's lines, from 0, or `none`.
    line: u32 = none,
};

/// What a line of a diff is, as `Kinds` gives its `outline.Line.kind` by default.
pub const Kind = enum(u8) {
    /// A file's line: its label.
    file,
    /// What is said of a file, under it.
    note,
    /// A hunk's `@@` line.
    hunk,
    /// A line of a hunk: added, removed, context or `\ No newline at end of file`.
    line,
};

/// The `outline.Line.kind` each part of a diff is given, which the outline never reads: `Kind`'s
/// values unless the caller gives its own. A caller needs it when the diff's lines sit in an
/// outline of its own whose kernels switch on its own kind enum, so the lines `lines` builds
/// carry that enum's values beside the caller's other lines.
pub const Kinds = struct {
    /// A file's own line, when `lines` makes it (`FileLines.made`).
    file: u8 = @intFromEnum(Kind.file),
    /// What a file shows in place of hunks: a binary file, a mode changed.
    note: u8 = @intFromEnum(Kind.note),
    /// A hunk's `@@` line.
    hunk: u8 = @intFromEnum(Kind.hunk),
    /// A line of a hunk's body.
    line: u8 = @intFromEnum(Kind.line),
};

/// Whether `lines` makes each file's own line.
pub const FileLines = enum {
    /// A line of its label, at `Keys.depth`, with its note and hunks under it.
    made,
    /// None: the caller puts the file's line in its own outline, at `Keys.depth`, and the note
    /// and hunks go under it.
    left_to_caller,
};

/// How the lines `lines` builds are named in the caller's outline and where they nest in it.
/// The slices are the caller's, borrowed for the call.
pub const Keys = struct {
    /// Each file's key, parallel to `lines`' `files`: never 0, unique among the keys of the
    /// caller's outline, and the same for the same file each time it is built, so its fold and
    /// its hunks' survive a refresh. It is the file's line's key; its note's, its hunks' and
    /// their lines' are made from it (a hunk's from it and the hunk's four numbers, a hunk
    /// line's from its hunk's and its place).
    files: []const u64,
    /// The kinds the lines are given.
    kinds: Kinds = .{},
    /// How deep a file's line nests; its note and its hunks are one deeper, their lines two.
    depth: u8 = 0,
    /// Whether the files' own lines are made.
    file_lines: FileLines = .made,
};

/// What `lines` builds: the outline's lines and, beside each at the same index, what it is.
/// Both lists are in the allocator `lines` was given, and grow as it appends. That allocator
/// must be one the caller frees all at once, an arena (a frame's or a kernel's scratch): the
/// displayable copies of the texts are made in it and not tracked one by one, so nothing frees
/// them but the arena. A line's text is a slice of a `File`'s or a hunk's bytes, or such a copy,
/// alive while both are.
pub const Lines = struct {
    /// The lines, in order: each file's, its note's, then each hunk's and its lines.
    lines: std.ArrayList(outline.Line) = .empty,
    /// What each line of `lines` is.
    at: std.ArrayList(At) = .empty,
};

/// The colours `lines` gives a diff's lines. The caller's, usually from its theme;
/// `default_style` for a plugin without one.
pub const Style = struct {
    /// A file's label.
    file: ui.Color,
    /// A file's note.
    note: ui.Color,
    /// A hunk's `@@` line.
    hunk_header: ui.Color,
    /// A line beginning `+`.
    added: ui.Color,
    /// A line beginning `-`.
    removed: ui.Color,
    /// A line beginning with a space, or an empty one.
    context: ui.Color,
    /// A `\ No newline at end of file` line, dimmed.
    no_newline: ui.Color,
};

/// A style that reads on a dark background.
pub const default_style = Style{
    .file = ui.rgb(240, 240, 240),
    .note = ui.rgb(190, 190, 190),
    .hunk_header = ui.rgb(120, 195, 255),
    .added = ui.rgb(110, 200, 130),
    .removed = ui.rgb(255, 84, 112),
    .context = ui.rgb(240, 240, 240),
    .no_newline = ui.rgb(190, 190, 190),
};

/// Appends to `out` the lines of `files`: for each, its line (unless `keys.file_lines` leaves it
/// to the caller), its note when it has one, and each hunk's `@@` line, open to its lines; and
/// beside each line what it is. A file's line and its note are in the text font, a hunk's lines
/// in the code font; every text is made displayable (`ui.displayText`), a line's break and the
/// carriage return before it not shown. `allocator` is an arena the caller frees all at once
/// (`Lines`), as the displayable copies are not tracked. A file's line can be folded when it has a note or a
/// hunk, and a hunk's always. `keys.files` holds a key for each of `files`. On an error `out`
/// holds the lines appended before it, `lines` and `at` of one length.
pub fn lines(allocator: std.mem.Allocator, files: []const File, keys: Keys, style: Style, out: *Lines) !void {
    std.debug.assert(keys.files.len == files.len);
    const inner_depth = keys.depth +| 1;
    for (files, keys.files, 0..) |file, file_key, file_index| {
        const file_number: u32 = @intCast(file_index);
        if (keys.file_lines == .made) {
            const label = try ui.displayText(allocator, file.label);
            const has_lines = file.note.len != 0 or file.hunks.len != 0;
            const file_line: outline.Line = .{ .depth = keys.depth, .kind = keys.kinds.file, .key = file_key, .text = label, .colour = style.file, .expandable = has_lines };
            try append(allocator, out, file_line, .{ .file = file_number });
        }
        if (file.note.len != 0) {
            const note = try ui.displayText(allocator, file.note);
            const note_key = noteKey(file_key);
            const note_line: outline.Line = .{ .depth = inner_depth, .kind = keys.kinds.note, .key = note_key, .text = note, .colour = style.note };
            try append(allocator, out, note_line, .{ .file = file_number });
        }
        for (file.hunks, 0..) |hunk, hunk_index| {
            const at: At = .{ .file = file_number, .hunk = @intCast(hunk_index) };
            const hunk_key = hunkKey(file_key, hunk);
            try hunkLines(allocator, hunk, hunk_key, inner_depth, at, keys.kinds, style, out);
        }
    }
}

/// A hunk's `@@` line at `depth`, and its body's lines under it, each without its line break
/// and the carriage return before it, made displayable.
fn hunkLines(allocator: std.mem.Allocator, hunk: Hunk, key: u64, depth: u8, at: At, kinds: Kinds, style: Style, out: *Lines) !void {
    const header_text = std.mem.trimEnd(u8, hunk.header, "\r\n");
    const header = try ui.displayText(allocator, header_text);
    const header_line: outline.Line = .{ .depth = depth, .kind = kinds.hunk, .key = key, .text = header, .colour = style.hunk_header, .font = .code, .expandable = true };
    try append(allocator, out, header_line, at);
    var body = std.mem.splitScalar(u8, hunk.body, '\n');
    var index: u32 = 0;
    while (body.next()) |raw| {
        // The body ends with a line break: the empty piece after it is no line.
        if (raw.len == 0 and body.index == null) break;
        const text_bytes = std.mem.trimEnd(u8, raw, "\r");
        const text = try ui.displayText(allocator, text_bytes);
        const line: outline.Line = .{ .depth = depth +| 1, .kind = kinds.line, .key = lineKey(key, index), .text = text, .colour = colourOf(raw, style), .font = .code };
        try append(allocator, out, line, .{ .file = at.file, .hunk = at.hunk, .line = index });
        index += 1;
    }
}

/// Appends `line` and what it is to `out`, the two lists kept of one length.
fn append(allocator: std.mem.Allocator, out: *Lines, line: outline.Line, at: At) !void {
    try out.lines.ensureUnusedCapacity(allocator, 1);
    try out.at.ensureUnusedCapacity(allocator, 1);
    out.lines.appendAssumeCapacity(line);
    out.at.appendAssumeCapacity(at);
}

/// A hunk line's colour, by its first byte: added, removed, the no-newline mark, or context.
fn colourOf(raw: []const u8, style: Style) ui.Color {
    if (raw.len == 0) return style.context;
    return switch (raw[0]) {
        '+' => style.added,
        '-' => style.removed,
        '\\' => style.no_newline,
        else => style.context,
    };
}

/// A key made from `seed` and `bytes`, never 0.
fn keyFrom(seed: u64, bytes: []const u8) u64 {
    const key = std.hash.Wyhash.hash(seed, bytes);
    return if (key == 0) 1 else key;
}

/// The key of the note of the file whose key is `file_key`.
fn noteKey(file_key: u64) u64 {
    return keyFrom(file_key, "note");
}

/// The key of `hunk`'s `@@` line, of the file whose key is `file_key`: from it and the
/// hunk's four numbers, which stay as the diff is read again.
fn hunkKey(file_key: u64, hunk: Hunk) u64 {
    const ranges = [4]u32{ hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count };
    const range_bytes = std.mem.asBytes(&ranges);
    return keyFrom(file_key, range_bytes);
}

/// The key of the `index`th line of the hunk whose key is `hunk_key`.
fn lineKey(hunk_key: u64, index: u32) u64 {
    const index_bytes = std.mem.asBytes(&index);
    return keyFrom(hunk_key, index_bytes);
}

/// The line of the new file, from 1, that the `line`th line of `hunk`'s body is at: the
/// hunk's first, and one more for each context and added line before it. A removed line is at
/// the new file's line that follows where it was; a line past the body's end, at the line after
/// the hunk's last.
pub fn newLine(hunk: Hunk, line: u32) u32 {
    var line_number = hunk.new_start;
    var body = std.mem.splitScalar(u8, hunk.body, '\n');
    var position: u32 = 0;
    while (body.next()) |raw| : (position += 1) {
        if (position == line) break;
        if (raw.len == 0) continue;
        if (raw[0] == ' ' or raw[0] == '+') line_number += 1;
    }
    return line_number;
}

/// Which way `stepHunk` goes.
pub const Direction = enum { next, previous };

/// The cursor moved to the `@@` line of the next shown hunk after the cursor's line, or of the
/// one before it, wherever the cursor is: on a file's line, a hunk's or one of a hunk's lines,
/// across files. A hunk's line is one of kind `hunk_kind` (the caller's `Kinds.hunk`), so a
/// diff's lines may sit among the caller's others. `shown` is what `outline.visible` gave of
/// `lines`; a cursor not settled against them is settled first. With no such hunk the cursor
/// stays where it is. The scroll is carried: `outline.scrollTo` follows the cursor.
pub fn stepHunk(all_lines: []const outline.Line, shown: []const u32, cursor: outline.Cursor, hunk_kind: u8, direction: Direction) outline.Cursor {
    const settled = outline.settle(all_lines, shown, cursor);
    if (shown.len == 0) return settled;
    var position = settled.index;
    while (true) {
        switch (direction) {
            .next => {
                if (position + 1 >= shown.len) return settled;
                position += 1;
            },
            .previous => {
                if (position == 0) return settled;
                position -= 1;
            },
        }
        const line = all_lines[shown[position]];
        if (line.kind == hunk_kind) return .{ .key = line.key, .index = position, .scroll = settled.scroll };
    }
}

/// Writes the patch that applies `hunk` alone: `file_header`, the caller's headers of the
/// hunk's file as its program wrote them, then the hunk's header and body as they were read,
/// byte for byte.
pub fn patch(writer: *std.Io.Writer, file_header: []const u8, hunk: Hunk) std.Io.Writer.Error!void {
    try writer.writeAll(file_header);
    try writer.writeAll(hunk.header);
    try writer.writeAll(hunk.body);
}

const testing = std.testing;

/// Three hunks of one file: the first plain, the second with CRLF lines, the third ending with
/// no line break at the file's end. A file's headers come before them.
const three_hunks_header = "--- a/notes.txt\n+++ b/notes.txt\n";
const first_hunk = "@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n";
const second_hunk = "@@ -10,4 +10,5 @@ ten\n line 10\r\n-line 11\r\n+line eleven\r\n+line 11.5\r\n line 12\r\n line 13\r\n";
const third_hunk = "@@ -20,2 +21,2 @@\n twenty\n-last\n\\ No newline at end of file\n+LAST\n\\ No newline at end of file\n";
const three_hunks = three_hunks_header ++ first_hunk ++ second_hunk ++ third_hunk;

test "a part's hunks are read as slices of it, and the patch of one is its bytes exactly" {
    var hunks: [4]Hunk = undefined;
    const counted = parseHunks(three_hunks, &hunks);
    try testing.expectEqual(Counted{ .seen = 3, .kept = 3 }, counted);
    try testing.expectEqualStrings("@@ -10,4 +10,5 @@ ten\n", hunks[1].header);
    try testing.expectEqual(@as(u32, 10), hunks[1].old_start);
    try testing.expectEqual(@as(u32, 4), hunks[1].old_count);
    try testing.expectEqual(@as(u32, 10), hunks[1].new_start);
    try testing.expectEqual(@as(u32, 5), hunks[1].new_count);
    try testing.expectEqualStrings(first_hunk["@@ -1,3 +1,3 @@\n".len..], hunks[0].body);
    try testing.expectEqualStrings(third_hunk["@@ -20,2 +21,2 @@\n".len..], hunks[2].body);
    try testing.expect(hunks[1].header.ptr == three_hunks[three_hunks_header.len + first_hunk.len ..].ptr);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try patch(&writer, three_hunks_header, hunks[1]);
    try testing.expectEqualStrings(three_hunks_header ++ second_hunk, writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try patch(&writer, three_hunks_header, hunks[2]);
    try testing.expectEqualStrings(three_hunks_header ++ third_hunk, writer.buffered());

    // Room for one: the first is kept, all three are counted.
    var one: [1]Hunk = undefined;
    try testing.expectEqual(Counted{ .seen = 3, .kept = 1 }, parseHunks(three_hunks, &one));
    try testing.expectEqualStrings("@@ -1,3 +1,3 @@\n", one[0].header);
    // A header without counts covers one line.
    var single: [1]Hunk = undefined;
    _ = parseHunks("@@ -1 +0,0 @@\n-gone\n", &single);
    try testing.expectEqualStrings("-gone\n", single[0].body);
    try testing.expectEqual(Hunk{ .header = single[0].header, .body = single[0].body, .old_start = 1, .old_count = 1, .new_start = 0, .new_count = 0 }, single[0]);
}

test "a part that is not UTF-8 is kept, and its lines show U+FFFD without a carriage return" {
    const part = "@@ -1,2 +1,2 @@\n caf\xe9\r\n-old\n+new \xff\n\\ No newline at end of file\n";
    var hunks: [1]Hunk = undefined;
    _ = parseHunks(part, &hunks);
    try testing.expectEqualStrings(" caf\xe9\r\n-old\n+new \xff\n\\ No newline at end of file\n", hunks[0].body);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]File{.{ .label = "caf\xe9.txt", .hunks = &hunks }};
    const file_keys = [_]u64{7};
    var built: Lines = .{};
    try lines(arena, &files, .{ .files = &file_keys }, default_style, &built);

    const texts = [_][]const u8{ "caf\u{FFFD}.txt", "@@ -1,2 +1,2 @@", " caf\u{FFFD}", "-old", "+new \u{FFFD}", "\\ No newline at end of file" };
    const colours = [_]ui.Color{ default_style.file, default_style.hunk_header, default_style.context, default_style.removed, default_style.added, default_style.no_newline };
    const depths = [_]u8{ 0, 1, 2, 2, 2, 2 };
    const ats = [_]At{ .{ .file = 0 }, .{ .file = 0, .hunk = 0 }, .{ .file = 0, .hunk = 0, .line = 0 }, .{ .file = 0, .hunk = 0, .line = 1 }, .{ .file = 0, .hunk = 0, .line = 2 }, .{ .file = 0, .hunk = 0, .line = 3 } };
    try testing.expectEqual(texts.len, built.lines.items.len);
    try testing.expectEqual(texts.len, built.at.items.len);
    for (built.lines.items, built.at.items, 0..) |line, at, index| {
        try testing.expectEqualStrings(texts[index], line.text);
        try testing.expectEqual(colours[index], line.colour);
        try testing.expectEqual(depths[index], line.depth);
        try testing.expectEqual(ats[index], at);
        try testing.expect(line.key != 0);
    }
    try testing.expectEqual(@as(u64, 7), built.lines.items[0].key);
    try testing.expectEqual(outline.Font.text, built.lines.items[0].font);
    try testing.expectEqual(outline.Font.code, built.lines.items[1].font);
    try testing.expectEqual(outline.Font.code, built.lines.items[2].font);
    try testing.expect(built.lines.items[0].expandable);
    try testing.expect(built.lines.items[1].expandable);
    try testing.expect(!built.lines.items[2].expandable);
    try testing.expectEqual(@as(u8, @intFromEnum(Kind.hunk)), built.lines.items[1].kind);
    try testing.expectEqual(@as(u8, @intFromEnum(Kind.line)), built.lines.items[2].kind);

    // Built again from the same key, the lines have the same keys: folds are kept.
    var again: Lines = .{};
    try lines(arena, &files, .{ .files = &file_keys }, default_style, &again);
    for (built.lines.items, again.lines.items) |first, second| try testing.expectEqual(first.key, second.key);
}

test "newLine is the new file's line of an added, a context and a removed line" {
    // Lines 0 to 4 of the second hunk: context 10, removed, added 11, added 12, context 13.
    var hunks: [3]Hunk = undefined;
    _ = parseHunks(three_hunks, &hunks);
    const second = hunks[1];
    try testing.expectEqual(@as(u32, 10), newLine(second, 0));
    // The removed line is where the line after it is: the first added one.
    try testing.expectEqual(@as(u32, 11), newLine(second, 1));
    try testing.expectEqual(@as(u32, 12), newLine(second, 3));
    try testing.expectEqual(@as(u32, 13), newLine(second, 4));
}

test "a file with a note and no hunks gives the file and the note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]File{ .{ .label = "image.png", .note = "Binary file" }, .{ .label = "empty.txt" } };
    const file_keys = [_]u64{ 1, 2 };
    var built: Lines = .{};
    try lines(arena, &files, .{ .files = &file_keys, .depth = 1 }, default_style, &built);
    try testing.expectEqual(@as(usize, 3), built.lines.items.len);
    try testing.expectEqualStrings("image.png", built.lines.items[0].text);
    try testing.expectEqual(@as(u8, 1), built.lines.items[0].depth);
    try testing.expect(built.lines.items[0].expandable);
    try testing.expectEqualStrings("Binary file", built.lines.items[1].text);
    try testing.expectEqual(@as(u8, 2), built.lines.items[1].depth);
    try testing.expectEqual(default_style.note, built.lines.items[1].colour);
    try testing.expectEqual(@as(u8, @intFromEnum(Kind.note)), built.lines.items[1].kind);
    try testing.expectEqual(At{ .file = 0 }, built.at.items[1]);
    try testing.expectEqualStrings("empty.txt", built.lines.items[2].text);
    try testing.expect(!built.lines.items[2].expandable);
    try testing.expectEqual(At{ .file = 1 }, built.at.items[2]);

    // The caller draws the files' lines itself: only the note is built, under where it would be.
    var notes: Lines = .{};
    try lines(arena, files[0..1], .{ .files = file_keys[0..1], .depth = 1, .file_lines = .left_to_caller }, default_style, &notes);
    try testing.expectEqual(@as(usize, 1), notes.lines.items.len);
    try testing.expectEqualStrings("Binary file", notes.lines.items[0].text);
    try testing.expectEqual(@as(u8, 2), notes.lines.items[0].depth);
}

test "stepHunk goes to the next and the previous hunk's line across files, and stays past the last" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var hunks: [3]Hunk = undefined;
    _ = parseHunks(three_hunks, &hunks);
    const files = [_]File{ .{ .label = "notes.txt", .hunks = hunks[0..2] }, .{ .label = "other.txt", .hunks = hunks[2..3] } };
    const file_keys = [_]u64{ 1, 2 };
    var built: Lines = .{};
    try lines(arena, &files, .{ .files = &file_keys }, default_style, &built);
    const all = built.lines.items;
    var out: [64]u32 = undefined;
    const shown = outline.visible(all, &.{}, &out);
    const hunk_kind: u8 = @intFromEnum(Kind.hunk);

    // From notes.txt's line: its first hunk, then its second, then other.txt's one.
    var cursor = outline.settle(all, shown, .{ .key = 1 });
    const expected = [_][]const u8{ "@@ -1,3 +1,3 @@", "@@ -10,4 +10,5 @@ ten", "@@ -20,2 +21,2 @@" };
    for (expected) |text| {
        cursor = stepHunk(all, shown, cursor, hunk_kind, .next);
        try testing.expectEqualStrings(text, all[shown[cursor.index]].text);
        try testing.expectEqual(all[shown[cursor.index]].key, cursor.key);
    }
    // Past the last it stays.
    const last = stepHunk(all, shown, cursor, hunk_kind, .next);
    try testing.expectEqual(cursor, last);
    // From a line of the second hunk, back to its own `@@` line, then the first's.
    const in_second = for (all, 0..) |line, index| {
        if (std.mem.eql(u8, line.text, "+line 11.5")) break index;
    } else unreachable;
    cursor = outline.settle(all, shown, .{ .key = all[in_second].key });
    cursor = stepHunk(all, shown, cursor, hunk_kind, .previous);
    try testing.expectEqualStrings("@@ -10,4 +10,5 @@ ten", all[shown[cursor.index]].text);
    cursor = stepHunk(all, shown, cursor, hunk_kind, .previous);
    try testing.expectEqualStrings("@@ -1,3 +1,3 @@", all[shown[cursor.index]].text);
    // Before the first it stays; a folded hunk's lines are passed over as hidden.
    try testing.expectEqual(cursor, stepHunk(all, shown, cursor, hunk_kind, .previous));
    const folded = [_]u64{cursor.key};
    const fewer = outline.visible(all, &folded, &out);
    const after_fold = stepHunk(all, fewer, outline.settle(all, fewer, cursor), hunk_kind, .next);
    try testing.expectEqualStrings("@@ -10,4 +10,5 @@ ten", all[fewer[after_fold.index]].text);
}
