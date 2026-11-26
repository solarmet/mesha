//! The plugin image boundary, as types see it. The host and each plugin are separate images,
//! each with its own copy of the engine's code, and may be built by different compiler
//! backends. They share memory: every type reachable from a pointer the host hands a plugin, or
//! from a value one image writes into a table cell or a message payload for the other to read,
//! must lay out alike in both images, and every function pointer stored there is called by
//! code of the other image whenever that image reaches it. Zig's own calling convention is not
//! the same across backends, so such a pointer must be `callconv(.c)`, and interfaces holding
//! Zig function pointers (`std.mem.Allocator`, `std.Io`) must not be stored there: hold the
//! concrete owner and build the interface where it is used.
//!
//! `crossings` lists the stored interfaces and Zig function pointers reachable from a set of
//! root types; `fingerprint` hashes their layouts, so a loader can refuse a plugin built
//! another way (a different optimize mode changes the size of hash maps and bare unions).
const std = @import("std");

/// A type the host hands a plugin, under the name its paths begin with.
/// `name` is for people: it starts each path `crossings` reports and is not hashed by
/// `fingerprint`. `T` is the type itself. Comptime only.
pub const Root = struct { name: []const u8, T: type };

/// One type reached from the roots, with the path by which it was first reached.
const Node = struct {
    T: type,
    path: []const u8,
};

/// An edge from a type to a type it holds or points at.
const Edge = struct {
    T: type,
    /// Appended to the parent's path.
    label: []const u8,
    /// Bit offset in the parent; zero for pointees and children of optionals.
    bit_offset: usize,
};

/// What an edge leads to: a type the walk goes on into, or a stop that crosses the boundary.
const Target = enum { walk, interface, zig_fn_pointer, opaque_leaf };

fn targetOf(comptime T: type) Target {
    if (T == std.mem.Allocator or T == std.Io) return .interface;
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const inner = targetOf(optional.child);
            return if (inner == .zig_fn_pointer) .zig_fn_pointer else .walk;
        },
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |function| {
                const c_call = function.calling_convention.eql(std.builtin.CallingConvention.c);
                return if (c_call) .opaque_leaf else .zig_fn_pointer;
            },
            .@"opaque" => return .opaque_leaf,
            else => return .walk,
        },
        else => return .walk,
    }
}

/// The types a value of `T` holds or points at, in declaration order.
fn edgesOf(comptime T: type) []const Edge {
    var edges: []const Edge = &.{};
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            for (info.fields) |field| {
                if (field.is_comptime) continue;
                edges = edges ++ .{Edge{ .T = field.type, .label = "." ++ field.name, .bit_offset = @bitOffsetOf(T, field.name) }};
            }
        },
        .@"union" => |info| {
            if (info.tag_type) |Tag| edges = edges ++ .{Edge{ .T = Tag, .label = ".(tag)", .bit_offset = 0 }};
            for (info.fields) |field| {
                edges = edges ++ .{Edge{ .T = field.type, .label = "." ++ field.name, .bit_offset = 0 }};
            }
        },
        .optional => |info| edges = edges ++ .{Edge{ .T = info.child, .label = ".?", .bit_offset = 0 }},
        .error_union => |info| edges = edges ++ .{Edge{ .T = info.payload, .label = ".!", .bit_offset = 0 }},
        .array => |info| edges = edges ++ .{Edge{ .T = info.child, .label = "[]", .bit_offset = 0 }},
        .pointer => |info| edges = edges ++ .{Edge{ .T = info.child, .label = ".*", .bit_offset = 0 }},
        else => {},
    }
    return edges;
}

fn indexOf(comptime nodes: []const Node, comptime T: type) ?usize {
    for (nodes, 0..) |node, index| {
        if (node.T == T) return index;
    }
    return null;
}

/// Every type reachable from `roots`, breadth first: the same order in every image.
fn reachable(comptime roots: []const Root) []const Node {
    var nodes: []const Node = &.{};
    for (roots) |root| {
        if (indexOf(nodes, root.T) == null) nodes = nodes ++ .{Node{ .T = root.T, .path = root.name }};
    }
    var next: usize = 0;
    while (next < nodes.len) : (next += 1) {
        const node = nodes[next];
        for (edgesOf(node.T)) |edge| {
            if (targetOf(edge.T) != .walk) continue;
            if (indexOf(nodes, edge.T) != null) continue;
            nodes = nodes ++ .{Node{ .T = edge.T, .path = node.path ++ edge.label }};
        }
    }
    return nodes;
}

const eval_quota = 50_000_000;

/// Paths to the stored interfaces and Zig function pointers reachable from `roots`: each
/// field holding one, by the path its holder was first reached by, as in
/// `Memory.global_source` (in a path, `.?` is an optional's payload, `.*` a pointee and `[]` an
/// array's item). A `std.mem.Allocator` or `std.Io` field is reported and not
/// walked into; `callconv(.c)` function pointers and pointers to opaque types are not
/// reported. Evaluated at comptime: the slice is static and costs nothing at run time.
pub fn crossings(comptime roots: []const Root) []const []const u8 {
    const result = comptime found: {
        @setEvalBranchQuota(eval_quota);
        const nodes = reachable(roots);
        var found: []const []const u8 = &.{};
        for (nodes) |node| {
            for (edgesOf(node.T)) |edge| {
                switch (targetOf(edge.T)) {
                    .interface, .zig_fn_pointer => found = found ++ .{node.path ++ edge.label},
                    .walk, .opaque_leaf => {},
                }
            }
        }
        break :found found[0..found.len].*;
    };
    return &result;
}

/// A hash of the layout of every type reachable from `roots`: sizes, alignments, field names
/// and offsets, and which type each field holds. Type names are left out, as an anonymous
/// type's may differ between compilations. Two images whose values differ must not share the
/// roots' memory; equal values do not prove the calling conventions match, which `crossings`
/// is for. Evaluated at comptime. `plugin.abi_fingerprint` is this over what the host hands a
/// plugin.
pub fn fingerprint(comptime roots: []const Root) u64 {
    return comptime hash: {
        @setEvalBranchQuota(eval_quota);
        const nodes = reachable(roots);
        var hasher = std.hash.Fnv1a_64.init();
        for (nodes) |node| {
            const kind: []const u8 = @tagName(@typeInfo(node.T));
            hasher.update(kind);
            const sized = switch (@typeInfo(node.T)) {
                .@"opaque", .@"fn", .noreturn => false,
                else => true,
            };
            if (sized) {
                hasher.update(std.mem.asBytes(&@as(u64, @sizeOf(node.T))));
                hasher.update(std.mem.asBytes(&@as(u64, @alignOf(node.T))));
            }
            for (edgesOf(node.T)) |edge| {
                hasher.update(edge.label);
                hasher.update(std.mem.asBytes(&@as(u64, edge.bit_offset)));
                const target: u64 = switch (targetOf(edge.T)) {
                    .walk => indexOf(nodes, edge.T).?,
                    .interface => 1 << 62,
                    .zig_fn_pointer, .opaque_leaf => 1 << 63,
                };
                hasher.update(std.mem.asBytes(&target));
            }
        }
        break :hash hasher.final();
    };
}

/// Crossings the boundary keeps: every path beginning with `prefix`, safe for `reason`.
/// `reason` is for people and is not checked.
pub const Kept = struct { prefix: []const u8, reason: []const u8 };

/// Fails with `error.BoundaryCrossingsChanged` on a crossing of `found` (what `crossings`
/// returned) that is neither kept nor pending, and on a kept prefix or pending path that
/// matches no crossing, so both lists shrink as crossings go. A pending path must equal a
/// crossing exactly. Prints each mismatch to stderr. For tests.
pub fn expectAllowed(found: []const []const u8, kept: []const Kept, pending: []const []const u8) !void {
    var mismatches: usize = 0;
    for (found) |path| {
        const allowed = keptPrefixOf(path, kept) != null or containsPath(pending, path);
        if (allowed) continue;
        std.debug.print("boundary crossing neither kept nor pending: {s}\n", .{path});
        mismatches += 1;
    }
    for (kept) |entry| {
        if (anyStartsWith(found, entry.prefix)) continue;
        std.debug.print("kept boundary prefix matches no crossing: {s}\n", .{entry.prefix});
        mismatches += 1;
    }
    for (pending) |path| {
        if (containsPath(found, path)) continue;
        std.debug.print("pending boundary crossing is gone, remove it from the list: {s}\n", .{path});
        mismatches += 1;
    }
    if (mismatches != 0) return error.BoundaryCrossingsChanged;
}

fn keptPrefixOf(path: []const u8, kept: []const Kept) ?Kept {
    for (kept) |entry| {
        if (std.mem.startsWith(u8, path, entry.prefix)) return entry;
    }
    return null;
}

fn containsPath(paths: []const []const u8, wanted: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, wanted)) return true;
    }
    return false;
}

fn anyStartsWith(paths: []const []const u8, prefix: []const u8) bool {
    for (paths) |path| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

test "crossings name stored interfaces and Zig function pointers, not C ones" {
    const Leaf = struct {
        allocator: std.mem.Allocator,
        c_callback: *const fn (*anyopaque) callconv(.c) void,
        zig_callback: ?*const fn (*anyopaque) void,
    };
    const Holder = struct {
        count: u32,
        leaf: *Leaf,
        leaves: []const Leaf,
    };
    const found = crossings(&.{.{ .name = "Root", .T = Holder }});
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("Root.leaf.*.allocator", found[0]);
    try std.testing.expectEqualStrings("Root.leaf.*.zig_callback", found[1]);
}

test "fingerprint follows layout, not names" {
    const A = struct { x: u32, y: u64 };
    const B = struct { x: u32, y: u64 };
    const C = extern struct { x: u32, y: u32 };
    const a = fingerprint(&.{.{ .name = "a", .T = A }});
    const b = fingerprint(&.{.{ .name = "b", .T = B }});
    const c = fingerprint(&.{.{ .name = "c", .T = C }});
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "fingerprint follows what a root points at, through optionals and slices" {
    const Narrow = struct { x: u32 };
    const Wide = struct { x: u32, y: u64 };
    const PointsAtNarrow = struct { found: ?*const Narrow, items: []const Narrow };
    const PointsAtWide = struct { found: ?*const Wide, items: []const Narrow };
    const SlicesWide = struct { found: ?*const Narrow, items: []const Wide };
    const narrow = fingerprint(&.{.{ .name = "answer", .T = PointsAtNarrow }});
    const wide = fingerprint(&.{.{ .name = "answer", .T = PointsAtWide }});
    const sliced = fingerprint(&.{.{ .name = "answer", .T = SlicesWide }});
    try std.testing.expect(narrow != wide);
    try std.testing.expect(narrow != sliced);
}
