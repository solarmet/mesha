//! Line, bar and scatter charts of a table's numeric columns, drawn through a `roop.Context`:
//! `mesha.ui.chart`.
//!
//! There are two ways in. `line`, `bar` and `scatter` draw at once into bounds the caller gives,
//! and return an error when they cannot. `drawable` wraps the same call as a leaf for
//! `ui.Tree.custom`, which draws over the leaf's whole rect each time the tree is committed and
//! keeps its error in `last_error`.
//!
//! A chart reads `fields`, atoms naming columns of the table: the first is X and each one after it
//! a Y series, drawn in `Options.colors` in turn. A column must be `f32` or `i32`. A row that lacks
//! a value, or holds one that is not finite, has no sample for that series. X and Y are each scaled
//! so that the least and greatest samples of all series span the plot, which is the bounds less
//! `Options.padding`, with Y upward; a single value sits in the middle.
//!
//! A chart draws everything or nothing: it resolves the fields, checks the bounds and options, and
//! counts its geometry against the context's remaining path budget before it draws or touches the
//! caller's path. A chart with no samples draws nothing and succeeds.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const Table = @import("../core/table.zig");
const roop = @import("../systems/roop.zig");
const math = @import("../core/math.zig");
const memory = @import("../core/memory.zig");

/// The rectangle a chart draws in, in the context's current coordinates: `x` and `y` its top-left
/// corner, `width` and `height` positive, all finite.
pub const Bounds = struct { x: f32, y: f32, width: f32, height: f32 };
const default_colors = [_]roop.Color{
    .{ .r = 0.485, .g = 0.798, .b = 1, .a = 1 },
    .{ .r = 1, .g = 0.701, .b = 0.485, .a = 1 },
    .{ .r = 0.584, .g = 0.906, .b = 0.665, .a = 1 },
    .{ .r = 0.906, .g = 0.665, .b = 0.955, .a = 1 },
};

/// How a chart is drawn. Every option is checked for every kind of chart, whether that kind uses it
/// or not.
pub const Options = struct {
    /// One color per series, in order, repeating when there are more series than colors. Not empty,
    /// and every channel finite. Borrowed: a direct call reads it during the call, a `Drawable` at
    /// every draw.
    colors: []const roop.Color = &default_colors,
    /// Stroke width of `line`'s series, in the context's coordinates. Greater than 0.
    line_width: f32 = 2,
    /// Inset of the plot from each edge of the bounds. 0 or more, and small enough to leave a plot.
    padding: f32 = 4,
    /// Fraction of the minimum distinct-X spacing occupied by a bar group (0, 1].
    /// A singleton group occupies this fraction of the plot width.
    bar_group_width: f32 = 0.8,
    /// Diameter of `scatter`'s markers, in the context's coordinates. Greater than 0.
    marker_size: f32 = 6,
};
/// Why a chart draws nothing.
///
/// `UnknownField`: an atom of the fields names no column of the table. `NonnumericField`: a named
/// column is neither `f32` nor `i32`. `InvalidFieldCount`: a field slice has fewer than 2 or more
/// than 64 atoms. `InvalidBounds`: the bounds are not finite, not positive, or leave no plot once
/// the padding (and, for `scatter`, the marker) is taken off. `InvalidOptions`: an option is
/// outside the range its field states. `CapacityExceeded`: the context's remaining path budget
/// cannot hold the whole chart. `OutOfMemory`: `bar` could not allocate its frame scratch.
pub const Error = error{ InvalidBounds, InvalidOptions, InvalidFieldCount, UnknownField, NonnumericField, CapacityExceeded, OutOfMemory };

/// Which chart a `Drawable` draws: `line`, `bar` or `scatter`, as the functions of those names do.
pub const Kind = enum { line, bar, scatter };

/// A chart as a drawable for `ui.Tree.custom`: it draws itself over the whole leaf at each commit,
/// reading the table as it is then.
///
/// It holds a copy of the options and of the field tuple or slice, and borrows the table,
/// `options.colors` and, for a slice, the atoms the slice points to. Keep the drawable and all of
/// these alive and address-stable through every commit; what they hold is read at each one. Change
/// data between commits, not during a draw. A `Fields` that is neither a tuple of at least two
/// atoms nor a `[]const Atom` is a compile error.
pub fn Drawable(comptime Fields: type) type {
    _ = fieldCapacity(Fields);
    return struct {
        /// Which chart to draw.
        kind: Kind,
        /// The table read at every draw. Borrowed.
        table: *const Table,
        /// The columns: X first, then each Y series. A tuple is held by value; a slice's atoms are
        /// borrowed.
        fields: Fields,
        /// Held by value, except `colors`, which is borrowed. May be changed between commits.
        options: Options,
        /// Why the last draw drew nothing; null when it drew, or when the leaf had no size. Every
        /// `draw` sets it.
        last_error: ?Error = null,

        /// Draws the chart from `(0, 0)` to `size` in `ctx`'s coordinates, keeping any error in
        /// `last_error`. A zero width or height draws nothing. `ui.Tree.commit` calls this when
        /// the tree is committed.
        pub fn draw(self: *@This(), size: math.Vec2f, ctx: *roop.Context) void {
            self.last_error = null;
            if (size.x == 0 or size.y == 0) return;
            const bounds = Bounds{ .x = 0, .y = 0, .width = size.x, .height = size.y };
            const result = switch (self.kind) {
                .line => line(ctx, bounds, self.table, self.fields, self.options),
                .bar => bar(ctx, bounds, self.table, self.fields, self.options),
                .scatter => scatter(ctx, bounds, self.table, self.fields, self.options),
            };
            result catch |err| {
                self.last_error = err;
            };
        }
    };
}

/// A `Drawable` of `kind` over the columns `fields` of `table`: a tuple of atoms, or a `[]const
/// Atom` of 2 to 64. Keep it where it outlives the commit, as in frame scratch, and give its
/// address to `ui.Tree.custom`.
pub fn drawable(kind: Kind, table: *const Table, fields: anytype, options: Options) Drawable(@TypeOf(fields)) {
    return .{ .kind = kind, .table = table, .fields = fields, .options = options };
}

const Range = struct {
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),
    fn add(self: *Range, value: f64) void {
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
    }
    fn fraction(self: Range, value: f64) f64 {
        if (self.min == self.max) return 0.5;
        return (value - self.min) / (self.max - self.min);
    }
};

fn sample(table: *const Table, row: Table.RowHandle, index: u32) ?f64 {
    const field = table.getSchema().fields[index];
    if (!table.rowHas(row.row, field.bit)) return null;
    const value: f64 = switch (field.field_type.?) {
        .f32 => blk: {
            const cell = table.getFieldByIndexConst(f32, row, index).?;
            break :blk cell.*;
        },
        .i32 => blk: {
            const cell = table.getFieldByIndexConst(i32, row, index).?;
            break :blk @floatFromInt(cell.*);
        },
        else => unreachable,
    };
    if (!std.math.isFinite(value)) return null;
    return value;
}

const GeometryCost = struct {
    draws: usize = 0,
    uniforms: usize = 0,
    points: usize = 0,
    vertices: usize = 0,

    fn addRun(self: *GeometryCost, count: usize, divisions: usize) void {
        if (count < 2) return;
        self.draws +|= 1;
        self.points +|= count;
        // Upper bound for roop.draw_list.strokeVertexBudget on an open subpath.
        const corners = (count - 1) *| (divisions +| 3);
        const caps = 2 *| (divisions +| 2);
        const pushes = corners +| caps;
        self.vertices +|= 6 *| (pushes -| 1);
    }
};

fn checkGeometry(table: *const Table, indices: []const u32, budget: anytype, x_range: *Range, y_range: *Range) Error!void {
    var total = GeometryCost{};
    for (indices[1..]) |index| {
        var commands: usize = 0;
        var paths: usize = 0;
        var run: usize = 0;
        const initial_draws = total.draws;
        var rows = table.rows();
        while (rows.next()) |row| {
            const x = sample(table, row, indices[0]);
            const y = sample(table, row, index);
            if (x == null or y == null) {
                total.addRun(run, budget.stroke_divisions);
                run = 0;
                continue;
            }
            x_range.add(x.?);
            y_range.add(y.?);
            commands +|= 1;
            if (run == 0) paths +|= 1;
            run +|= 1;
            if (commands > budget.commands or commands > budget.points or paths > budget.paths) {
                return error.CapacityExceeded;
            }
        }
        total.addRun(run, budget.stroke_divisions);
        if (total.draws > initial_draws) total.uniforms +|= 1;
    }
    if (total.draws > budget.draws or total.draws > budget.shapes or
        total.draws > budget.indirect_draws or total.uniforms > budget.uniforms or
        total.points > budget.gpu_points or total.vertices > budget.gpu_vertices)
    {
        return error.CapacityExceeded;
    }
}

fn fieldCapacity(comptime Fields: type) usize {
    const info = @typeInfo(Fields);
    if (info == .@"struct" and info.@"struct".is_tuple) {
        if (info.@"struct".fields.len < 2) @compileError("chart fields must contain at least two Atom values");
        for (info.@"struct".fields) |field| {
            if (field.type != Atom) @compileError("chart fields must contain Atom values");
        }
        return info.@"struct".fields.len;
    }
    if (info == .pointer and info.pointer.size == .slice and info.pointer.child == Atom) return 64;
    @compileError("chart fields must be an Atom tuple or slice");
}

fn resolveField(table: *const Table, id: Atom) Error!u32 {
    for (table.getSchema().fields, 0..) |field, index| {
        const field_id = if (@intFromEnum(field.name_id) == 0) Atom.from(field.name) else field.name_id;
        if (field_id == id) {
            const kind = field.field_type;
            if (kind == null or (kind.? != .f32 and kind.? != .i32)) return error.NonnumericField;
            return @intCast(index);
        }
    }
    return error.UnknownField;
}

fn resolveFields(table: *const Table, fields: anytype, indices: []u32) Error![]const u32 {
    const info = @typeInfo(@TypeOf(fields));
    if (comptime info == .@"struct") {
        inline for (fields, 0..) |id, i| indices[i] = try resolveField(table, id);
        return indices;
    } else {
        if (fields.len < 2 or fields.len > 64) return error.InvalidFieldCount;
        for (fields, 0..) |id, i| indices[i] = try resolveField(table, id);
        return indices[0..fields.len];
    }
}

const Plot = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,

    fn x(self: Plot, range: Range, value: f64) f64 {
        return self.left + range.fraction(value) * (self.right - self.left);
    }
    fn y(self: Plot, range: Range, value: f64) f64 {
        return self.bottom - range.fraction(value) * (self.bottom - self.top);
    }
};

fn validate(bounds: Bounds, options: Options) Error!Plot {
    if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or
        !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or
        bounds.width <= 0 or bounds.height <= 0)
    {
        return error.InvalidBounds;
    }
    if (!std.math.isFinite(options.padding) or options.padding < 0 or
        !std.math.isFinite(options.line_width) or options.line_width <= 0 or
        options.colors.len == 0)
    {
        return error.InvalidOptions;
    }
    for (options.colors) |color| {
        if (!std.math.isFinite(color.r) or !std.math.isFinite(color.g) or
            !std.math.isFinite(color.b) or !std.math.isFinite(color.a))
        {
            return error.InvalidOptions;
        }
    }
    const left: f64 = @as(f64, bounds.x) + options.padding;
    const top: f64 = @as(f64, bounds.y) + options.padding;
    const right: f64 = @as(f64, bounds.x) + bounds.width - options.padding;
    const bottom: f64 = @as(f64, bounds.y) + bounds.height - options.padding;
    const max_float = std.math.floatMax(f32);
    if (left >= right or top >= bottom or left < -max_float or right > max_float or
        top < -max_float or bottom > max_float)
    {
        return error.InvalidBounds;
    }
    if (!std.math.isFinite(options.bar_group_width) or options.bar_group_width <= 0 or
        options.bar_group_width > 1 or !std.math.isFinite(options.marker_size) or
        options.marker_size <= 0)
    {
        return error.InvalidOptions;
    }
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

/// Draws each Y series as a polyline through its samples in the table's iteration order, without
/// sorting by X. A row with no sample for X or for the series breaks the line there.
///
/// `fields` is a tuple of at least two atoms or a `[]const Atom` of 2 to 64: the X column, then the
/// Y columns. On error nothing is drawn and the caller's path is untouched. When it draws, it
/// leaves the current path empty; the context's state, transform and inherited clip are preserved.
pub fn line(ctx: *roop.Context, bounds: Bounds, table: *const Table, fields: anytype, options: Options) Error!void {
    var index_storage: [fieldCapacity(@TypeOf(fields))]u32 = undefined;
    const indices = try resolveFields(table, fields, &index_storage);
    const plot = try validate(bounds, options);
    const budget = ctx.pathBudget();
    var x_range = Range{};
    var y_range = Range{};
    try checkGeometry(table, indices, budget, &x_range, &y_range);
    if (x_range.min == std.math.inf(f64)) return;
    ctx.save();
    defer ctx.restore();
    ctx.strokeWidth(options.line_width);
    for (indices[1..], 0..) |index, series_index| {
        const color = options.colors[series_index % options.colors.len];
        ctx.strokeColor(color);
        ctx.beginPath();
        var connected = false;
        var rows = table.rows();
        while (rows.next()) |row| {
            const x = sample(table, row, indices[0]) orelse {
                connected = false;
                continue;
            };
            const y = sample(table, row, index) orelse {
                connected = false;
                continue;
            };
            const plot_x: f32 = @floatCast(plot.x(x_range, x));
            const plot_y: f32 = @floatCast(plot.y(y_range, y));
            if (connected) {
                ctx.lineTo(plot_x, plot_y);
            } else {
                ctx.moveTo(plot_x, plot_y);
            }
            connected = true;
        }
        ctx.stroke();
    }
    ctx.beginPath();
}

const Primitive = enum { bar, scatter };

// Each primitive uses a separate closed fill path. roop.draw_list.appendFill can use either convex
// or stencil rendering: reserve its worst case, including a CPU cover quad, two shapes and 9
// vertices per point, for every primitive.
fn checkFills(table: *const Table, indices: []const u32, budget: anytype, primitive: Primitive, x_range: *Range, y_range: *Range) Error!void {
    const point_count: usize = switch (primitive) {
        .bar => 4,
        .scatter => 8,
    };
    if (budget.paths < 1 or budget.commands < point_count + 1 or budget.points < point_count) {
        return error.CapacityExceeded;
    }
    var shapes: usize = 0;
    for (indices[1..]) |index| {
        var rows = table.rows();
        while (rows.next()) |row| {
            const x = sample(table, row, indices[0]) orelse continue;
            const y = sample(table, row, index) orelse continue;
            x_range.add(x);
            y_range.add(y);
            shapes +|= 1;
        }
    }
    if (shapes > budget.draws or shapes > budget.uniforms or
        shapes *| 2 > budget.shapes or shapes *| point_count > budget.gpu_points or
        shapes *| (9 * point_count) > budget.gpu_vertices or shapes *| 6 > budget.cpu_vertices)
    {
        return error.CapacityExceeded;
    }
}

fn filledPolygon(ctx: *roop.Context, xs: []const f64, ys: []const f64) void {
    ctx.beginPath();
    for (xs, ys, 0..) |x, y, i| {
        const point_x: f32 = @floatCast(x);
        const point_y: f32 = @floatCast(y);
        if (i == 0) {
            ctx.moveTo(point_x, point_y);
        } else {
            ctx.lineTo(point_x, point_y);
        }
    }
    ctx.closePath();
    ctx.fill();
}

/// Draws a bar from zero to each sample, the series of one X side by side in a group centered on
/// it. The Y scale always includes zero.
///
/// A group's width is `Options.bar_group_width` of the smallest positive spacing between distinct
/// Xs that have a sample, whatever the row order. Rows with the same X draw over each other. A
/// series with no sample at an X keeps its slot in the group empty. Fields, errors, the path and
/// the context's state are as for `line`; it also allocates one `f64` per row from the context's
/// frame allocator, freed before it returns, and fails with `OutOfMemory` when it cannot.
pub fn bar(ctx: *roop.Context, bounds: Bounds, table: *const Table, fields: anytype, options: Options) Error!void {
    var index_storage: [fieldCapacity(@TypeOf(fields))]u32 = undefined;
    const indices = try resolveFields(table, fields, &index_storage);
    const plot = try validate(bounds, options);
    const budget = ctx.pathBudget();
    var x_range = Range{};
    var y_range = Range{};
    try checkFills(table, indices, budget, .bar, &x_range, &y_range);
    if (x_range.min == std.math.inf(f64)) return;
    y_range.add(0);

    // Frame scratch: the Context's arena holds only its lists, and capacity changes there are
    // what trigger a rebuild.
    const frame = ctx.frameAllocator();
    const x_values = frame.alloc(f64, table.count()) catch return error.OutOfMemory;
    defer frame.free(x_values);
    var x_count: usize = 0;
    var rows = table.rows();
    while (rows.next()) |row| {
        const x = sample(table, row, indices[0]) orelse continue;
        for (indices[1..]) |index| {
            if (sample(table, row, index) != null) {
                x_values[x_count] = x;
                x_count += 1;
                break;
            }
        }
    }
    std.mem.sort(f64, x_values[0..x_count], {}, std.sort.asc(f64));
    var min_spacing = std.math.inf(f64);
    for (x_values[1..x_count], x_values[0 .. x_count - 1]) |current, previous| {
        const spacing = current - previous;
        if (spacing > 0) min_spacing = @min(min_spacing, spacing);
    }
    const width = plot.right - plot.left;
    const span = x_range.max - x_range.min;
    const group_width = if (span == 0)
        width * options.bar_group_width
    else
        width * (@as(f64, options.bar_group_width) * min_spacing) / (span + @as(f64, options.bar_group_width) * min_spacing);
    const series_count: f64 = @floatFromInt(indices.len - 1);
    const slot_width = group_width / series_count;
    const baseline = plot.y(y_range, 0);

    ctx.save();
    defer ctx.restore();
    for (indices[1..], 0..) |index, series_index| {
        const color = options.colors[series_index % options.colors.len];
        ctx.fillColor(color);
        var series_rows = table.rows();
        while (series_rows.next()) |row| {
            const x = sample(table, row, indices[0]) orelse continue;
            const y = sample(table, row, index) orelse continue;
            const center = plot.left + group_width * 0.5 + x_range.fraction(x) * (width - group_width);
            const slot: f64 = @floatFromInt(series_index);
            const left = center - group_width * 0.5 + slot * slot_width;
            const right = left + slot_width;
            const value_y = plot.y(y_range, y);
            const xs = [_]f64{ left, left, right, right };
            const ys = [_]f64{ baseline, value_y, value_y, baseline };
            filledPolygon(ctx, &xs, &ys);
        }
    }
    ctx.beginPath();
}

/// Draws a filled eight-sided marker, `Options.marker_size` across, for every sample. The plot is
/// inset by the marker's radius so markers stay within the padded bounds; `InvalidBounds` when that
/// leaves no plot. Fields, the other errors, the path and the context's state are as for `line`.
pub fn scatter(ctx: *roop.Context, bounds: Bounds, table: *const Table, fields: anytype, options: Options) Error!void {
    var index_storage: [fieldCapacity(@TypeOf(fields))]u32 = undefined;
    const indices = try resolveFields(table, fields, &index_storage);
    var plot = try validate(bounds, options);
    const radius: f64 = @as(f64, options.marker_size) * 0.5;
    plot.left += radius;
    plot.right -= radius;
    plot.top += radius;
    plot.bottom -= radius;
    if (plot.left > plot.right or plot.top > plot.bottom) return error.InvalidBounds;
    const budget = ctx.pathBudget();
    var x_range = Range{};
    var y_range = Range{};
    try checkFills(table, indices, budget, .scatter, &x_range, &y_range);
    if (x_range.min == std.math.inf(f64)) return;
    ctx.save();
    defer ctx.restore();
    for (indices[1..], 0..) |index, series_index| {
        const color = options.colors[series_index % options.colors.len];
        ctx.fillColor(color);
        var rows = table.rows();
        while (rows.next()) |row| {
            const x = sample(table, row, indices[0]) orelse continue;
            const y = sample(table, row, index) orelse continue;
            const center_x = plot.x(x_range, x);
            const center_y = plot.y(y_range, y);
            var xs: [8]f64 = undefined;
            var ys: [8]f64 = undefined;
            for (0..8) |i| {
                const angle = @as(f64, @floatFromInt(i)) * (std.math.pi / 4.0);
                xs[i] = center_x + radius * @cos(angle);
                ys[i] = center_y + radius * @sin(angle);
            }
            filledPolygon(ctx, &xs, &ys);
        }
    }
    ctx.beginPath();
}

fn testContext(allocator: *const std.mem.Allocator, renderer: *roop.Renderer) roop.Context {
    var ctx = roop.Context.initWithoutTarget(renderer, allocator) catch @panic("OOM");
    ctx.beginFrame(200, 200, 1, .wrap(allocator));
    return ctx;
}

test "line bar and scatter render runtime mixed series and validate before drawing" {
    var mem: memory.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(std.testing.allocator, &atoms, 4);
    defer schema.deinit();
    schema.addField("x", f32, .text_field);
    schema.addField("y", i32, .text_field);
    schema.addField("z", f32, .text_field);
    schema.addField("label", Atom, .text_field);
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 2);
    defer tables.deinit();
    const handle = try tables.create(&schema, 8, atoms.intern("chart.test"), .durable);
    const table = tables.get(handle).?;
    _ = table.insert(.{ .x = @as(f32, 0), .y = @as(i32, 0), .z = @as(f32, 10) });
    _ = table.insert(.{ .x = @as(f32, 1), .y = @as(i32, 5), .z = @as(f32, 5) });
    _ = table.insert(.{ .x = @as(f32, 2), .y = @as(i32, 10), .z = @as(f32, 0) });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var renderer: roop.Renderer = .{};
    const ctx_allocator = arena.allocator();
    var ctx = testContext(&ctx_allocator, &renderer);
    ctx.translate(3, 7);
    const state = ctx.states.items[0];
    const fields = .{ atoms.intern("x"), atoms.intern("y"), atoms.intern("z") };
    try line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, fields, .{});
    try std.testing.expectEqual(@as(usize, 2), ctx.calls.items.len);
    const first_color = ctx.uniforms.items[ctx.calls.items[0].uniform_offset].innerCol;
    const second_color = ctx.uniforms.items[ctx.calls.items[1].uniform_offset].innerCol;
    try std.testing.expect(!std.mem.eql(f32, &first_color, &second_color));
    try std.testing.expectApproxEqAbs(@as(f32, 7), ctx.gpu_points.items[0].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 103), ctx.gpu_points.items[0].y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 99), ctx.gpu_points.items[2].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 11), ctx.gpu_points.items[2].y, 0.01);
    try std.testing.expectEqualDeep(state, ctx.states.items[0]);
    try std.testing.expectEqual(@as(usize, 0), ctx.commands.items.len);
    var runtime_storage = [_]Atom{ fields[0], fields[1], fields[2] };
    const runtime_fields: []const Atom = &runtime_storage;
    const runtime_ctx_allocator = arena.allocator();
    var runtime_ctx = testContext(&runtime_ctx_allocator, &renderer);
    runtime_ctx.translate(3, 7);
    const bounds = Bounds{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try line(&runtime_ctx, bounds, table, runtime_fields, .{});
    try std.testing.expectEqualDeep(ctx.gpu_points.items, runtime_ctx.gpu_points.items);
    try std.testing.expectEqual(@as(usize, 2), runtime_ctx.calls.items.len);
    try std.testing.expectError(error.InvalidFieldCount, line(&runtime_ctx, bounds, table, @as([]const Atom, runtime_fields[0..1]), .{}));
    var too_many = [_]Atom{fields[0]} ** 65;
    const oversized: []const Atom = &too_many;
    try std.testing.expectError(error.InvalidFieldCount, line(&runtime_ctx, bounds, table, oversized, .{}));
    runtime_storage[1] = atoms.intern("missing");
    try std.testing.expectError(error.UnknownField, line(&runtime_ctx, bounds, table, runtime_fields, .{}));
    runtime_storage[1] = atoms.intern("label");
    try std.testing.expectError(error.NonnumericField, line(&runtime_ctx, bounds, table, runtime_fields, .{}));
    try std.testing.expectEqual(@as(usize, 2), runtime_ctx.calls.items.len);
    runtime_storage[1] = fields[1];

    const calls = ctx.calls.items.len;
    try std.testing.expectError(error.UnknownField, line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, .{ fields[0], atoms.intern("missing") }, .{}));
    try std.testing.expectError(error.NonnumericField, line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, .{ fields[0], atoms.intern("label") }, .{}));
    try std.testing.expectError(error.InvalidBounds, line(&ctx, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, table, fields, .{}));
    try std.testing.expectError(error.InvalidOptions, line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, fields, .{ .colors = &.{} }));
    const invalid_colors = [_]roop.Color{.{ .r = 1, .g = std.math.nan(f32), .b = 0, .a = 1 }};
    try std.testing.expectError(error.InvalidOptions, line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, fields, .{ .colors = &invalid_colors }));
    try std.testing.expectEqual(calls, ctx.calls.items.len);

    // Both fill APIs use normal paths, so translation and paint reach roop.
    table.clear();
    _ = table.insert(.{ .x = @as(f32, 10), .y = @as(i32, 10), .z = @as(f32, -10) });
    _ = table.insert(.{ .x = @as(f32, 0), .y = @as(i32, -10), .z = @as(f32, 10) });
    _ = table.insert(.{ .x = @as(f32, 2), .y = @as(i32, 5) });
    _ = table.insert(.{ .x = std.math.nan(f32), .y = @as(i32, 8), .z = @as(f32, 1) });
    const bar_ctx_allocator = arena.allocator();
    var bar_ctx = testContext(&bar_ctx_allocator, &renderer);
    bar_ctx.translate(3, 7);
    bar_ctx.scissor(0, 0, 100, 100, 0);
    const bar_state = bar_ctx.states.items[0];
    const chart_bounds = Bounds{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try bar(&bar_ctx, chart_bounds, table, runtime_fields, .{ .padding = 0 });
    try std.testing.expectEqual(@as(usize, 5), bar_ctx.calls.items.len);
    const bar_color_1 = bar_ctx.uniforms.items[bar_ctx.calls.items[0].uniform_offset].innerCol;
    const bar_color_2 = bar_ctx.uniforms.items[bar_ctx.calls.items[3].uniform_offset].innerCol;
    try std.testing.expect(!std.mem.eql(f32, &bar_color_1, &bar_color_2));
    try std.testing.expectApproxEqAbs(@as(f32, 96.10345), bar_ctx.gpu_points.items[0].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 57), bar_ctx.gpu_points.items[0].y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 7), bar_ctx.gpu_points.items[1].y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3), bar_ctx.gpu_points.items[4].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 107), bar_ctx.gpu_points.items[5].y, 0.01);
    // The missing second series at X=2 does not shift its first-series slot.
    try std.testing.expectApproxEqAbs(@as(f32, 20.24138), bar_ctx.gpu_points.items[10].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 96.10345), bar_ctx.gpu_points.items[12].x, 0.01);
    try std.testing.expectEqualDeep(bar_state, bar_ctx.states.items[0]);

    const scatter_ctx_allocator = arena.allocator();

    var scatter_ctx = testContext(&scatter_ctx_allocator, &renderer);
    scatter_ctx.translate(3, 7);
    scatter_ctx.scissor(0, 0, 100, 100, 0);
    const scatter_state = scatter_ctx.states.items[0];
    try scatter(&scatter_ctx, chart_bounds, table, runtime_fields, .{ .padding = 0, .marker_size = 10 });
    try std.testing.expectEqual(@as(usize, 5), scatter_ctx.calls.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 103), scatter_ctx.gpu_points.items[7].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12), scatter_ctx.gpu_points.items[7].y, 0.01);
    const scatter_color_1 = scatter_ctx.uniforms.items[scatter_ctx.calls.items[0].uniform_offset].innerCol;
    const scatter_color_2 = scatter_ctx.uniforms.items[scatter_ctx.calls.items[3].uniform_offset].innerCol;
    try std.testing.expect(!std.mem.eql(f32, &scatter_color_1, &scatter_color_2));
    try std.testing.expectEqualDeep(scatter_state, scatter_ctx.states.items[0]);
    table.clear();
    _ = table.insert(.{ .x = @as(f32, 2), .y = @as(i32, 5) });
    const scatter_calls = scatter_ctx.calls.items.len;
    try scatter(&scatter_ctx, chart_bounds, table, .{ fields[0], fields[1] }, .{ .padding = 0 });
    try std.testing.expectEqual(scatter_calls + 1, scatter_ctx.calls.items.len);
    const singleton_point = scatter_ctx.gpu_points.items[scatter_ctx.gpu_points.items.len - 1];
    try std.testing.expectApproxEqAbs(@as(f32, 56), singleton_point.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 57), singleton_point.y, 0.01);

    // Insufficient aggregate fill budget cannot emit even the first marker.
    const existing_fill = scatter_ctx.calls.items[0];
    while (scatter_ctx.pathBudget().draws > 0) try scatter_ctx.calls.append(scatter_ctx.allocator(), existing_fill);
    scatter_ctx.beginPath();
    scatter_ctx.moveTo(2, 3);
    const rejected_calls = scatter_ctx.calls.items.len;
    const rejected_points = scatter_ctx.gpu_points.items.len;
    try std.testing.expectError(error.CapacityExceeded, scatter(&scatter_ctx, chart_bounds, table, .{ fields[0], fields[1] }, .{}));
    try std.testing.expectEqual(rejected_calls, scatter_ctx.calls.items.len);
    try std.testing.expectEqual(rejected_points, scatter_ctx.gpu_points.items.len);
    try std.testing.expectEqual(@as(usize, 1), scatter_ctx.commands.items.len);

    // The first series is drawable, but the second exceeds the path budget.
    // Rejection must precede any drawing or replacement of the caller's path.
    table.clear();
    for (0..2050) |i| {
        const x: f32 = @floatFromInt(i);
        if (i % 2 == 0) {
            _ = table.insert(.{ .x = x, .y = @as(i32, 1), .z = x });
        } else {
            _ = table.insert(.{ .x = x, .z = x });
        }
    }
    ctx.beginPath();
    ctx.moveTo(2, 3);
    const commands_before = ctx.commands.items.len;
    const points_before = ctx.gpu_points.items.len;
    const uniforms_before = ctx.uniforms.items.len;
    try std.testing.expectError(error.CapacityExceeded, line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, .{ fields[0], fields[2], fields[1] }, .{}));
    try std.testing.expectEqual(calls, ctx.calls.items.len);
    try std.testing.expectEqual(points_before, ctx.gpu_points.items.len);
    try std.testing.expectEqual(uniforms_before, ctx.uniforms.items.len);
    try std.testing.expectEqual(commands_before, ctx.commands.items.len);
    try std.testing.expectEqualDeep(state, ctx.states.items[0]);

    table.clear();
    _ = table.insert(.{ .x = @as(f32, 0), .y = @as(i32, 0) });
    _ = table.insert(.{ .x = @as(f32, 1), .y = @as(i32, 1) });
    _ = table.insert(.{ .x = @as(f32, 2) });
    _ = table.insert(.{ .x = @as(f32, 3), .y = @as(i32, 3) });
    _ = table.insert(.{ .x = @as(f32, 4), .y = @as(i32, 4) });
    _ = table.insert(.{ .x = std.math.nan(f32), .y = @as(i32, 5) });
    _ = table.insert(.{ .x = @as(f32, 6), .y = @as(i32, 6) });
    try line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, @as([]const Atom, runtime_fields[0..2]), .{});
    try std.testing.expectEqual(calls + 2, ctx.calls.items.len);
    // A deep save stack is storage: the chart still draws and restores what it saved.
    for (0..64) |_| ctx.save();
    const deep_saves = ctx.states.items.len;
    const deep_calls = ctx.calls.items.len;
    try line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, fields, .{});
    try std.testing.expect(ctx.calls.items.len > deep_calls);
    try std.testing.expectEqual(deep_saves, ctx.states.items.len);
    for (0..64) |_| ctx.restore();

    // Two valid runs cannot fit in the one remaining frame draw slot.
    const existing_call = ctx.calls.items[0];
    while (ctx.pathBudget().draws > 1) try ctx.calls.append(ctx.allocator(), existing_call);
    const saturated_calls = ctx.calls.items.len;
    const saturated_points = ctx.gpu_points.items.len;
    try std.testing.expectError(error.CapacityExceeded, line(&ctx, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, table, .{ fields[0], fields[1] }, .{}));
    try std.testing.expectEqual(saturated_calls, ctx.calls.items.len);
    try std.testing.expectEqual(saturated_points, ctx.gpu_points.items.len);
}
