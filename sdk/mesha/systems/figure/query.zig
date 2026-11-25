//! Queries: how a system asks the figure host a one-off question about a figure without calling
//! into it. A kernel appends a `QueryCommand` to `commands.figure_queries` (`appendQuery`), naming
//! the question and where the answer goes; the figure host answers every row in order each time
//! it synchronizes, after it applies the frame's commands and compiles what changed, so a query
//! sees the edits of the frame that asked. The answer arrives in the asker's inbox under the
//! reply's tag and with its user data: a `QueryAnswer` head, then what the question returns
//! (the hits, the solved channels or the clipboard bytes), which the readers on `QueryAnswer`
//! find.
//!
//! An inbox that refuses an answer keeps that row alone, which the host offers again at each
//! synchronization until `refusal_reply_attempts` offers are refused, then gives it up and logs
//! it; the rows behind it are answered meanwhile.
const std = @import("std");
const Atom = @import("../../core/atom.zig").Atom;
const Table = @import("../../core/table.zig");
const sequencer = @import("../../core/sequencer.zig");
const memory_mod = @import("../../core/memory.zig");
const figure = @import("../figure.zig");

/// `commands.figure_queries`, the table of `QueryCommand` rows the figure host answers.
pub const queries_table_name = "commands.figure_queries";
/// The table of queries: a row per question, its slices copied into the table's payloads, which
/// the host drains as it answers.
pub const Queries = sequencer.Commands(QueryCommand);

/// Which question a `Query` asks, and so what its answer carries. Its numbers never change, so an
/// answer reads the same in an image built apart from the host.
pub const QueryKind = enum(u8) {
    /// Carries the hits.
    hit_test = 0,
    /// Carries nothing after the head: the mapping is `QueryAnswer.paint`.
    paint_mapping = 1,
    /// Carries the solved channels; the rest of the solution is `QueryAnswer.solution`.
    solve_transient_pose = 2,
    /// Carries the clipboard bytes.
    encode_shape_clipboard = 3,
};

/// A question for the figure host. Its slices are borrowed until `appendQuery` returns, which
/// copies them into the table.
pub const Query = union(QueryKind) {
    /// The shapes of a posed figure under a point or touched by a rectangle, frontmost first, as
    /// the runtime's `hitTest` finds them.
    hit_test: struct {
        /// The definition and its pose.
        figure: figure.PosedFigure,
        /// Where to look and how far.
        query: figure.HitQuery,
    },
    /// Where a shape's paint lies in a pose (`figure.PaintMapping`), as the runtime's
    /// `paintMapping` finds it.
    paint_mapping: struct {
        /// The definition and its pose.
        figure: figure.PosedFigure,
        /// The shape's id.
        shape: u32,
        /// The paint's id, one of the shape's; null for none.
        paint: ?u32 = null,
        /// A point in the figure's space to carry back into the paint's space; null for none.
        point: ?figure.Vec2 = null,
    },
    /// How a chain of bones would turn to reach a point (`figure.TransientPoseQuery`), as the
    /// runtime's `solveTransientPose` solves it.
    solve_transient_pose: struct {
        /// The definition's store key.
        definition: Atom,
        /// The chain, its target and the pose to start from.
        query: figure.TransientPoseQuery,
    },
    /// The authored shapes `ids` of a definition baked in its working pose, as the figure file
    /// a paste reads (`figure.Payload.paste_shapes`), as the runtime's `encodeShapeClipboard`
    /// writes it.
    encode_shape_clipboard: struct {
        /// The definition's store key.
        definition: Atom,
        /// The shapes to copy, by id. A copy of none, or of none the definition has, is answered
        /// with `invalid_geometry`, as the runtime's `encodeShapeClipboard` refuses it.
        ids: []const u32,
    },
};

/// A row of `commands.figure_queries`: a question and where its answer goes.
pub const QueryCommand = struct {
    /// The question.
    query: Query,
    /// The asker's inbox, the tag the answer arrives under and the user data it comes back with,
    /// which is how an asker tells its answers apart. `no_inbox` asks for no answer: the host
    /// then computes nothing.
    reply: sequencer.ReplyTo,
};

/// The head of the payload of an answer to a `QueryCommand`, followed by what its `kind` carries:
/// the hits (`hits`), the solved channels (`channels`) or the clipboard bytes (`bytes`), or
/// nothing. A failed query carries nothing after its head, and its head's `paint` and `solution`
/// hold their defaults.
///
/// The head and what follows it lie in the inbox's arena, aligned for any value, until the inbox
/// is next found empty: a kernel copies what it keeps past its run. The readers take the
/// message as its inbox gives it: a payload shorter than a head, not aligned as an inbox aligns
/// it, or whose `kind` or `failure` byte names no value of theirs is not one.
pub const QueryAnswer = struct {
    /// The question's kind.
    kind: QueryKind,
    /// Why the question has no answer: `missing_definition` for a definition the host does not
    /// hold, `not_ready` for one with no compiled generation, or the question's own failure
    /// (`missing_pose`, `invalid_geometry`, ...). `none` when it was answered.
    failure: figure.Failure,
    /// The revision the answer is of: the compiled generation's that a hit test, a paint mapping
    /// or a solve read, the last one that compiled; the authored revision a clipboard copies. 0
    /// when `failure` is not `none`.
    revision: figure.Revision,
    /// A paint mapping's answer.
    paint: figure.PaintMapping = .{ .effective_revision = 0 },
    /// A solve's answer but its channels, which follow the head (`channels`).
    solution: Solution = .{},

    /// What a `figure.TransientPoseSolution` holds besides its channels.
    pub const Solution = struct {
        /// The bend the solve took.
        reference: figure.BendReference = .{},
        /// Where the chain's end came to, in the figure's space.
        endpoint: figure.Vec2 = .{ .x = 0, .y = 0 },
        /// How far the end came to from the target, in the figure's space.
        error_distance: f64 = 0,
    };

    comptime {
        // What follows the head starts aligned for the slices it carries, since the payload
        // starts aligned for any value.
        std.debug.assert(@sizeOf(QueryAnswer) % @alignOf(figure.Hit) == 0);
        std.debug.assert(@sizeOf(QueryAnswer) % @alignOf(figure.PoseChannels) == 0);
        std.debug.assert(@alignOf(QueryAnswer) <= Table.bytes_alignment.toByteUnits());
    }

    /// The head of `message`'s payload; `error.MessageShape` when the payload is not an answer:
    /// shorter than a head, not aligned as an inbox aligns a payload, or with a `kind` or a
    /// `failure` byte out of range. It points into the inbox's arena.
    pub fn of(message: sequencer.Message) error{MessageShape}!*const QueryAnswer {
        const payload = message.payload;
        if (payload.len < @sizeOf(QueryAnswer)) return error.MessageShape;
        const payload_alignment = Table.bytes_alignment.toByteUnits();
        const address = @intFromPtr(payload.ptr);
        if (!std.mem.isAligned(address, payload_alignment)) return error.MessageShape;
        // Read as bytes first: an enum holding a byte that names none of its values is not one.
        const kind_byte = payload[@offsetOf(QueryAnswer, "kind")];
        if (std.enums.fromInt(QueryKind, kind_byte) == null) return error.MessageShape;
        const failure_byte = payload[@offsetOf(QueryAnswer, "failure")];
        if (std.enums.fromInt(figure.Failure, failure_byte) == null) return error.MessageShape;
        return @ptrCast(@alignCast(payload.ptr));
    }

    /// The hits a `hit_test` answer carries, frontmost first; empty for any other answer, a
    /// failed one, or a payload that is not one.
    pub fn hits(message: sequencer.Message) []const figure.Hit {
        return carried(figure.Hit, message, .hit_test);
    }

    /// The channels a `solve_transient_pose` answer carries, one per bone of the chain in its
    /// order, only its rotation set; empty for any other answer, a failed one, or a payload that
    /// is not one.
    pub fn channels(message: sequencer.Message) []const figure.PoseChannels {
        return carried(figure.PoseChannels, message, .solve_transient_pose);
    }

    /// The figure file an `encode_shape_clipboard` answer carries; empty for any other answer, a
    /// failed one, or a payload that is not one.
    pub fn bytes(message: sequencer.Message) []const u8 {
        return carried(u8, message, .encode_shape_clipboard);
    }

    /// What follows the head of `message` as `T`s, when it is an answer of `kind`.
    fn carried(comptime T: type, message: sequencer.Message, kind: QueryKind) []const T {
        const head = of(message) catch return &.{};
        if (head.kind != kind or head.failure != .none) return &.{};
        const rest = message.payload[@sizeOf(QueryAnswer)..];
        if (rest.len % @sizeOf(T) != 0) return &.{};
        const items: [*]const T = @ptrCast(@alignCast(rest.ptr));
        return items[0 .. rest.len / @sizeOf(T)];
    }
};

/// Validates a query and appends it to `commands.figure_queries`, copying its slices. Refused
/// with `InvalidInput` for a number that is not finite anywhere in it, a negative hit tolerance
/// or an empty chain; with `NotInitialized` without the table.
/// The host answers what it cannot answer with a failure. A kernel may call it when its system
/// declares `commands.figure_queries` written.
pub fn appendQuery(context: figure.Context, command: QueryCommand) figure.AppendError!void {
    if (!finite(command.query)) return error.InvalidInput;
    switch (command.query) {
        .hit_test => |asked| if (asked.query.tolerance < 0) return error.InvalidInput,
        .paint_mapping => {},
        .solve_transient_pose => |asked| if (asked.query.chain.len == 0) return error.InvalidInput,
        .encode_shape_clipboard => {},
    }
    const rows = Queries.of(context.memory, context.tables, queries_table_name);
    rows.tryPush(command) catch |err| return switch (err) {
        error.MissingTable => error.NotInitialized,
        else => error.OutOfMemory,
    };
}

/// Whether every float in `value`, through its optionals, slices, structs and unions, is finite.
fn finite(value: anytype) bool {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .float => return std.math.isFinite(value),
        .optional => return if (value) |inner| finite(inner) else true,
        .pointer => |info| {
            if (info.size != .slice) return true;
            for (value) |item| {
                if (!finite(item)) return false;
            }
            return true;
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!finite(@field(value, field.name))) return false;
            }
            return true;
        },
        .@"union" => switch (value) {
            inline else => |inner| return finite(inner),
        },
        else => return true,
    }
}

test "appendQuery refuses what is not finite and what asks for nothing" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 8);
    defer tables.deinit();
    const context: figure.Context = .{ .memory = &memory, .tables = &tables, .atoms = &atoms };
    const blue = Atom.from("blue");
    const reply: sequencer.ReplyTo = .{};
    const hit: Query = .{ .hit_test = .{ .figure = .{ .definition = blue }, .query = .{ .tolerance = 1 } } };

    try std.testing.expectError(error.NotInitialized, appendQuery(context, .{ .query = hit, .reply = reply }));
    try Queries.ensure(try memory.tableScratchAllocator(), &atoms, &tables, queries_table_name);
    try appendQuery(context, .{ .query = hit, .reply = reply });

    const nan = std.math.nan(f32);
    const turned: figure.Pose = .{ .custom_inputs = .{ .channels = &.{.{ .bone = 1, .rotation = nan }} } };
    const refused = [_]Query{
        .{ .hit_test = .{ .figure = .{ .definition = blue }, .query = .{ .tolerance = -1 } } },
        .{ .hit_test = .{ .figure = .{ .definition = blue, .pose = turned }, .query = .{ .tolerance = 1 } } },
        .{ .paint_mapping = .{ .figure = .{ .definition = blue }, .shape = 3, .point = .{ .x = nan, .y = 0 } } },
        .{ .solve_transient_pose = .{ .definition = blue, .query = .{ .inputs = .{}, .chain = &.{}, .target = .{ .x = 0, .y = 0 } } } },
        .{ .solve_transient_pose = .{ .definition = blue, .query = .{ .inputs = .{}, .chain = &.{2}, .target = .{ .x = nan, .y = 0 } } } },
    };
    for (refused) |query| {
        try std.testing.expectError(error.InvalidInput, appendQuery(context, .{ .query = query, .reply = reply }));
    }
    // Only the one admitted query was pushed, and it reads back as given.
    const rows = Queries.of(&memory, &tables, queries_table_name);
    try std.testing.expectEqual(@as(u32, 1), rows.count());
    var held: [1]QueryCommand = undefined;
    const pushed = rows.peek(&held);
    try std.testing.expectEqual(@as(f32, 1), pushed[0].query.hit_test.query.tolerance);
}

test "a query answer's readers find what follows its head" {
    const head: QueryAnswer = .{ .kind = .hit_test, .failure = .none, .revision = 4 };
    const payload_alignment: u29 = comptime @intCast(Table.bytes_alignment.toByteUnits());
    const found = [_]figure.Hit{ .{ .object = .{ .kind = .shape, .id = 3 } }, .{ .object = .{ .kind = .shape, .id = 5 }, .outline = true } };
    var payload: [@sizeOf(QueryAnswer) + @sizeOf(@TypeOf(found))]u8 align(payload_alignment) = undefined;
    @memcpy(payload[0..@sizeOf(QueryAnswer)], std.mem.asBytes(&head));
    @memcpy(payload[@sizeOf(QueryAnswer)..], std.mem.sliceAsBytes(&found));
    const message: sequencer.Message = .{ .tag = Atom.from("answer"), .payload = &payload };

    try std.testing.expectEqual(@as(figure.Revision, 4), (try QueryAnswer.of(message)).revision);
    try std.testing.expectEqualSlices(figure.Hit, &found, QueryAnswer.hits(message));
    // Read as another kind, it carries nothing.
    try std.testing.expectEqual(@as(usize, 0), QueryAnswer.channels(message).len);
    try std.testing.expectEqual(@as(usize, 0), QueryAnswer.bytes(message).len);
    const short: sequencer.Message = .{ .tag = Atom.from("answer"), .payload = payload[0..4] };
    try std.testing.expectError(error.MessageShape, QueryAnswer.of(short));
    try std.testing.expectEqual(@as(usize, 0), QueryAnswer.hits(short).len);
}

test "a payload that is not a query answer is refused, and carries nothing" {
    const head: QueryAnswer = .{ .kind = .hit_test, .failure = .none, .revision = 4 };
    const payload_alignment: u29 = comptime @intCast(Table.bytes_alignment.toByteUnits());
    const found = [_]figure.Hit{.{ .object = .{ .kind = .shape, .id = 3 } }};
    const size = @sizeOf(QueryAnswer) + @sizeOf(@TypeOf(found));
    // Room for the answer one byte along, where no inbox would put it.
    var storage: [size + payload_alignment]u8 align(payload_alignment) = undefined;
    @memcpy(storage[0..@sizeOf(QueryAnswer)], std.mem.asBytes(&head));
    @memcpy(storage[@sizeOf(QueryAnswer)..size], std.mem.sliceAsBytes(&found));
    const tag = Atom.from("answer");

    // Not aligned as an inbox aligns a payload.
    std.mem.copyBackwards(u8, storage[1 .. size + 1], storage[0..size]);
    const misaligned: sequencer.Message = .{ .tag = tag, .payload = storage[1 .. size + 1] };
    try std.testing.expectError(error.MessageShape, QueryAnswer.of(misaligned));
    try std.testing.expectEqual(@as(usize, 0), QueryAnswer.hits(misaligned).len);
    std.mem.copyForwards(u8, storage[0..size], storage[1 .. size + 1]);
    const aligned: sequencer.Message = .{ .tag = tag, .payload = storage[0..size] };
    try std.testing.expectEqualSlices(figure.Hit, &found, QueryAnswer.hits(aligned));

    // A kind no question has.
    const kind_at = @offsetOf(QueryAnswer, "kind");
    storage[kind_at] = 200;
    try std.testing.expectError(error.MessageShape, QueryAnswer.of(aligned));
    try std.testing.expectEqual(@as(usize, 0), QueryAnswer.hits(aligned).len);
    storage[kind_at] = @intFromEnum(QueryKind.hit_test);

    // A failure no answer has.
    const failure_at = @offsetOf(QueryAnswer, "failure");
    storage[failure_at] = 250;
    try std.testing.expectError(error.MessageShape, QueryAnswer.of(aligned));
    try std.testing.expectEqual(@as(usize, 0), QueryAnswer.hits(aligned).len);
    storage[failure_at] = @intFromEnum(figure.Failure.none);

    // What follows the head is not a whole number of hits.
    const ragged: sequencer.Message = .{ .tag = tag, .payload = storage[0 .. size - 1] };
    try std.testing.expectEqual(@as(figure.Revision, 4), (try QueryAnswer.of(ragged)).revision);
    try std.testing.expectEqual(@as(usize, 0), QueryAnswer.hits(ragged).len);
}
