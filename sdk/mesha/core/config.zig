//! A ZON document loaded whole and kept as a `Value` tree for its reader to walk: a thin
//! owner over `zon.parse`, with a variant that reads the text from a file.
//!
//! Load once on the thread that owns the atom registry (parsing interns names), read the
//! root with `Config.value`, and free it with `Config.deinit`. A file whose fields should be
//! read one by one, so that a bad one does not lose the rest, is read with
//! `zon.parseRootStruct` instead.
const std = @import("std");
const value_mod = @import("value.zig");
const Atom = @import("atom.zig").Atom;
const memory_mod = @import("memory.zig");
const zon_mod = @import("zon.zig");

/// Why a document did not load: the ZON reader's errors, described at `value.ParseError`.
pub const ConfigError = value_mod.ParseError;

/// A parsed ZON document and the memory that holds it.
pub const Config = struct {
    /// The allocator the document was parsed with, which backs `parsed`'s arena.
    allocator: std.mem.Allocator,
    /// The parsed tree and its arena.
    parsed: value_mod.ParseResult,

    /// Reads the file at `path`, relative to the working directory or absolute, and parses it
    /// as `load` does. The whole file is read into memory, with no size limit, and released
    /// once parsed. Fails with the file read's error or a `ConfigError`. Blocks on the read, so
    /// not for a kernel.
    pub fn loadFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, atoms: *Atom.Registry) (ConfigError || std.Io.Dir.ReadFileAllocError)!Config {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(source);
        return load(allocator, source, atoms);
    }

    /// Parses `source`, a whole ZON document, interning its atoms and field names into `atoms`.
    /// `source` is not kept. The caller frees the result with `deinit`.
    pub fn load(allocator: std.mem.Allocator, source: []const u8, atoms: *Atom.Registry) ConfigError!Config {
        const parsed = try zon_mod.parse(allocator, source, atoms, null);
        return .{
            .allocator = allocator,
            .parsed = parsed,
        };
    }

    /// The document's root. It and everything reached from it belong to the config and are
    /// invalid after `deinit`.
    pub fn value(config: *const Config) value_mod.Value {
        return config.parsed.value;
    }

    /// Frees the document. Values read from it must not be used after.
    pub fn deinit(config: *Config) void {
        config.parsed.deinit();
    }
};

const testing = std.testing;

const TestAtoms = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,

    fn init(self: *@This()) !void {
        self.memory.init(testing.allocator);
        try self.atoms.init(&self.memory);
    }

    fn deinit(self: *@This()) void {
        self.atoms.deinit();
        self.memory.deinit();
    }
};

test "Config.load exposes the parsed root map for App to navigate" {
    const source =
        \\.{
        \\    .scenes = .{
        \\        .test_scene = .{
        \\            .tables = .{
        \\                .things = .{
        \\                    .schema = .{
        \\                        .{ .name = "position", .type = .vec2f, .view = .vector },
        \\                        .{ .name = "active", .type = .tag, .view = .checkbox },
        \\                    },
        \\                    .rows = .{
        \\                        .{ .position = .{ .x = 1, .y = 2 }, .active = true },
        \\                        .{ .position = .{ .x = 3, .y = 4 } },
        \\                    },
        \\                },
        \\            },
        \\        },
        \\    },
        \\}
    ;

    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();
    var config = try Config.load(testing.allocator, source, &context.atoms);
    defer config.deinit();

    const root = try config.value().asMap();
    try testing.expect(root.get(value_mod.atom("scenes")) != null);
}

test "Config.load rejects malformed input" {
    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();
    try testing.expectError(error.InvalidZon, Config.load(testing.allocator, ".{", &context.atoms));
}

test "Config.loadFromPath round-trips a real file" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var context: TestAtoms = .{};
    try context.init();
    defer context.deinit();
    const tmp_path = "config_test.zon";
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    const source = ".{ .scenes = .{ .a = .{ .tables = .{ .t = .{ .schema = .{} } } } } }";
    {
        const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, source);
    }

    var config = try Config.loadFromPath(testing.allocator, io, tmp_path, &context.atoms);
    defer config.deinit();
    try testing.expect((try config.value().asMap()).get(value_mod.atom("scenes")) != null);
}
