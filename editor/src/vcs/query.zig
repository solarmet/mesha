//! A query a person writes after a program's command, as vcs-git's log (`git log …`) and
//! vcs-p4's history (`p4 changes …`) take one: split into arguments as a POSIX shell splits a
//! command line, nothing expanded and no shell run, each argument written after
//! `process.argument_separator` for a `runner.Job`'s `argv`. Knows no program: each panel
//! places its own options around what this writes, and refuses what it must.

const std = @import("std");
const mesha = @import("mesha");
const process = mesha.process;
const testing = std.testing;

const separator = process.argument_separator;

/// What `write` fails with: the writer's failure; a quote opened and not closed
/// (`UnterminatedQuote`); or an argument that cannot be passed as one (`UnpassableArgument`):
/// empty (`''`), or holding a NUL or `process.argument_separator`.
pub const Error = std.Io.Writer.Error || error{ UnterminatedQuote, UnpassableArgument };

/// Splits `query`, the text a person wrote after a program's command (`git log `, `p4 changes `),
/// into arguments as a POSIX shell splits a command line, and writes each after a separator;
/// returns how many. Spaces, tabs and line breaks separate; text in single quotes is kept as it
/// is; text in double quotes keeps its spaces, and in it `\"` is `"` and `\\` is `\`, every
/// other backslash kept; outside quotes a backslash keeps the character after it (a last one is
/// kept itself); quoted and unquoted parts that touch are one argument
/// (`--grep="two words"`). Nothing is expanded: `$HOME`, `~`, `*.zig` and backquotes are their
/// characters. Fails with `UnterminatedQuote` or `UnpassableArgument` before writing anything.
pub fn write(writer: *std.Io.Writer, query: []const u8) Error!u32 {
    // Checked whole first, so a bad query writes nothing.
    _ = try count(query);
    return split(writer, query);
}

/// How many arguments `query` splits into (`write`), or why it cannot be split: what a
/// panel checks before it runs a query, to tell why it does not.
pub fn count(query: []const u8) error{ UnterminatedQuote, UnpassableArgument }!u32 {
    var discarding = std.Io.Writer.Discarding.init(&.{});
    return split(&discarding.writer, query) catch |err| switch (err) {
        error.UnterminatedQuote, error.UnpassableArgument => |failed| failed,
        // A discarding writer takes everything.
        error.WriteFailed => unreachable,
    };
}

fn split(writer: *std.Io.Writer, query: []const u8) Error!u32 {
    const Quoting = enum { none, single, double };
    var written: u32 = 0;
    var quoting: Quoting = .none;
    // Whether an argument has begun: a quote begins one, even one that stays empty.
    var in_argument = false;
    var argument_bytes: usize = 0;
    var index: usize = 0;
    while (index < query.len) : (index += 1) {
        const byte = query[index];
        switch (quoting) {
            .single => {
                if (byte == '\'') {
                    quoting = .none;
                    continue;
                }
                try writeByte(writer, byte, &argument_bytes);
            },
            .double => {
                if (byte == '"') {
                    quoting = .none;
                    continue;
                }
                const escapes = byte == '\\' and index + 1 < query.len and (query[index + 1] == '"' or query[index + 1] == '\\');
                if (escapes) index += 1;
                try writeByte(writer, query[index], &argument_bytes);
            },
            .none => {
                const space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
                if (space) {
                    if (in_argument) try endArgument(&written, &in_argument, argument_bytes);
                    continue;
                }
                if (!in_argument) {
                    try writer.writeByte(separator);
                    in_argument = true;
                    argument_bytes = 0;
                }
                switch (byte) {
                    '\'' => quoting = .single,
                    '"' => quoting = .double,
                    '\\' => {
                        if (index + 1 < query.len) index += 1;
                        try writeByte(writer, query[index], &argument_bytes);
                    },
                    else => try writeByte(writer, byte, &argument_bytes),
                }
            },
        }
    }
    if (quoting != .none) return error.UnterminatedQuote;
    if (in_argument) try endArgument(&written, &in_argument, argument_bytes);
    return written;
}

/// Writes `argument` as a query's text holds it, `write` reading it back as that one
/// argument: as it is when every byte is a letter, a digit or one of `_-+=.,/:@%^`, else in
/// single quotes, a quote in it written `'\\''`. What vcs-git's log menu writes its query with.
pub fn writeArgument(writer: *std.Io.Writer, argument: []const u8) std.Io.Writer.Error!void {
    const plain = argument.len != 0 and for (argument) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "_-+=.,/:@%^", byte) != null;
        if (!safe) break false;
    } else true;
    if (plain) return writer.writeAll(argument);
    try writer.writeByte('\'');
    for (argument) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
            continue;
        }
        try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}

/// Writes a byte of an argument of a query, which may hold no NUL and no separator.
fn writeByte(writer: *std.Io.Writer, byte: u8, argument_bytes: *usize) Error!void {
    if (byte == 0 or byte == separator) return error.UnpassableArgument;
    try writer.writeByte(byte);
    argument_bytes.* += 1;
}

/// Ends an argument of a query: an empty one (`''`) cannot be passed.
fn endArgument(written: *u32, in_argument: *bool, argument_bytes: usize) Error!void {
    if (argument_bytes == 0) return error.UnpassableArgument;
    written.* += 1;
    in_argument.* = false;
}

/// `query` split by `write`, its arguments one a line.
fn expectQuery(query: []const u8, expected: []const []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const arguments = try write(&writer, query);
    try testing.expectEqual(expected.len, arguments);
    var found = std.mem.tokenizeScalar(u8, writer.buffered(), separator);
    for (expected) |argument| try testing.expectEqualStrings(argument, found.next().?);
    try testing.expect(found.next() == null);
}

test "vcs git: a query is split as a shell splits it, and nothing is expanded" {
    try expectQuery("-n 256 HEAD", &.{ "-n", "256", "HEAD" });
    try expectQuery("  -n\t5  main\n-- src/ ", &.{ "-n", "5", "main", "--", "src/" });
    try expectQuery("--grep=\"two words\"", &.{"--grep=two words"});
    try expectQuery("'a b'\\ c", &.{"a b c"});
    try expectQuery("\"say \\\"hi\\\" \\\\ \\n\"", &.{"say \"hi\" \\ \\n"});
    try expectQuery("'it\\''s'", &.{"it\\s"});
    try expectQuery("$HOME ~ *.zig `id` 'a\"b'", &.{ "$HOME", "~", "*.zig", "`id`", "a\"b" });
    try expectQuery("a\\", &.{"a\\"});
    try expectQuery("--grep='it''s'", &.{"--grep=its"});
    // What the menu writes reads back as the arguments it wrote.
    var written: [128]u8 = undefined;
    var quoted = std.Io.Writer.fixed(&written);
    const arguments = [_][]const u8{ "--author=Kiran P", "it's", "--grep=$x *", "src/a.zig" };
    for (arguments, 0..) |argument, index| {
        if (index != 0) try quoted.writeByte(' ');
        try writeArgument(&quoted, argument);
    }
    try testing.expectEqualStrings("'--author=Kiran P' 'it'\\''s' '--grep=$x *' src/a.zig", quoted.buffered());
    try expectQuery(quoted.buffered(), &arguments);
    try expectQuery("", &.{});
    try expectQuery("   ", &.{});
    // An unterminated quote, an empty argument or a separator in one: nothing is written.
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.UnterminatedQuote, write(&writer, "--author='Ana"));
    try testing.expectError(error.UnterminatedQuote, write(&writer, "--grep=\"fix"));
    try testing.expectError(error.UnpassableArgument, write(&writer, "HEAD ''"));
    try testing.expectError(error.UnpassableArgument, write(&writer, "a\x1fb"));
    try testing.expectError(error.UnpassableArgument, write(&writer, "a\x00b"));
    try testing.expectError(error.UnpassableArgument, write(&writer, "\"\""));
    // In single quotes a backslash is itself: the second quote closes, the third opens.
    try testing.expectError(error.UnterminatedQuote, write(&writer, "'a\\'b'"));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try testing.expectEqual(@as(u32, 3), try count("-n 5 main"));
}
