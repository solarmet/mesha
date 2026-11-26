//! A figure prepared for drawing, as a plain value, and `draw`, the one function that emits it into
//! a roop context. The host prepares a `Drawing` from a definition and a pose: it flattens each
//! visible shape's curves into vertices, skins them, tints its colours and paints and orders the
//! layer scopes it is drawn in. Nothing here reads the host's compiled definition: a `Drawing`
//! holds all that emission reads, so whoever holds one can draw it.
//!
//! `draw` admits the whole drawing against what the context's budget has left before it makes
//! any context call, so a drawing is drawn whole or not at all.
const std = @import("std");
const math = @import("../../core/math.zig");
const roop = @import("../roop.zig");
const layer_admission = @import("../roop/layer_admission.zig");
const figure = @import("../figure.zig");
const Vec2 = figure.Vec2;

/// What a drawing is prepared for, as a context it will be drawn into would report it
/// (`Context.currentTransform` and `Context.pathBudget`). The defaults are a fresh context's at a
/// pixel ratio of 1.
pub const DrawParams = struct {
    /// The transform the drawing will be drawn under, from the space its shapes are placed in to
    /// target pixels: the context's current transform. It chooses how finely curves are
    /// flattened, and its target space is the one the drawing's bounds lie in.
    transform: math.Affine2f = .identity,
    /// How far, in target pixels, a flattened curve may stray from the true one. More than 0.
    tess_tol: f32 = 0.25,
    /// The antialiasing fringe's width in target pixels, which pads the bounds. 0 or more.
    fringe_width: f32 = 1,
    /// The miter limit strokes are drawn with. 0 or more.
    miter_limit: f32 = 10,
};

/// A figure prepared for drawing. Whoever prepares it (the runtime's `render.prepare`) allocates
/// every slice in one allocator, whose owner frees them with `deinit`; nothing else points into
/// them. A drawing borrows nothing, so it
/// outlives the definition and the evaluation it was made from.
pub const Drawing = struct {
    /// The revision of the compiled generation the drawing was made from.
    revision: figure.Revision,
    /// The shapes that draw, each once, in the order the definition lists them. `ops` says when
    /// each is drawn.
    shapes: []const Shape,
    /// The layer scopes and the shapes drawn in them, in drawing order, balanced: every `begin`
    /// has its `end`.
    ops: []const Op,
    /// Every shape's flattened outline, one run of vertices per shape (`Shape.points`), each in
    /// its shape's own space, which the shape's `transform` places.
    vertices: []const Vec2,
    /// The union of the shapes' `bounds`, in `transform`'s target space; null when no shape is
    /// filled or stroked. Every scope but a single shape's isolation takes it as its layer bounds.
    bounds: ?Bounds,
    /// `DrawParams.transform` as the drawing was prepared: the space `bounds` lie in.
    transform: math.Affine2f,
    /// The opacity the whole figure is composited with, 0 to 1: the render's opacity times its
    /// tint's alpha. `draw` multiplies in the context's alpha.
    outer_alpha: f32,

    /// A box by its least and greatest x and y, in f64 so its padding does not round away.
    pub const Bounds = struct { min_x: f64, min_y: f64, max_x: f64, max_y: f64 };

    /// One shape as emission draws it.
    pub const Shape = struct {
        /// Its outline's run in `Drawing.vertices`: at least 2 vertices.
        points: Range,
        /// From the shape's vertices to the space the figure is placed in: the shape's bone when
        /// it is bound rigidly, the figure's flip and the render's placement. `draw` puts the
        /// context's current transform before it.
        transform: math.Affine2f,
        /// Filled: with `fill_color`, or `fill_paint` when there is one.
        fill: bool,
        /// Stroked: with `stroke_color`, or `stroke_paint` when there is one.
        stroke: bool,
        /// The outline closes back to its first vertex.
        closed: bool,
        /// The fill's colour, tinted.
        fill_color: roop.Color,
        /// The stroke's colour, tinted.
        stroke_color: roop.Color,
        /// A gradient that replaces `fill_color`, tinted and in the space of the shape's vertices.
        fill_paint: ?roop.Paint = null,
        /// A gradient that replaces `stroke_color`, tinted and in the space of the shape's vertices.
        stroke_paint: ?roop.Paint = null,
        /// The stroke's width in the space of the shape's vertices.
        width: f32,
        /// How the stroke ends.
        cap: roop.LineCap,
        /// How the stroke turns corners.
        join: roop.LineJoin,
        /// The glow beneath the stroke, a second stroke of its own, tinted.
        glow_color: roop.Color,
        /// The glow's radius in the space of the shape's vertices; 0 draws no glow.
        glow_radius: f32,
        /// Where the shape draws, its stroke, glow and fringe included, in `Drawing.transform`'s
        /// target space; null when it is neither filled nor stroked. The layer bounds of its
        /// isolation.
        bounds: ?Bounds,
    };

    /// A run of vertices: `len` of them from index `start`.
    pub const Range = struct { start: usize, len: usize };

    /// One step of drawing.
    pub const Op = union(enum) {
        /// Opens a layer scope, composited onto what is beneath when its `end` comes.
        begin: Begin,
        /// Closes the innermost open scope.
        end,
        /// Draws a shape in the innermost scope.
        draw: Draw,
    };

    /// How a layer scope is composited.
    pub const Begin = struct {
        /// 0 to 1.
        opacity: f32,
        /// How its colours mix with what is beneath.
        blend: roop.BlendMode,
        /// The Porter-Duff operation it is composited with.
        composite: roop.CompositeOperation,
    };

    /// A shape drawn: `shape` indexes `Drawing.shapes`. An `opacity` other than 1 isolates the
    /// shape in a scope of its own at that opacity, so its fill and stroke share it.
    pub const Draw = struct { shape: usize, opacity: f32 };

    /// Frees every slice, in the allocator that made them.
    pub fn deinit(self: *Drawing, allocator: std.mem.Allocator) void {
        allocator.free(self.shapes);
        allocator.free(self.ops);
        allocator.free(self.vertices);
        self.* = undefined;
    }
};

/// What it takes of a context's budget to fill and stroke one path of `n` flattened points, with
/// round caps and joins divided into `divisions` (`pathBudget().stroke_divisions`). Nothing for a
/// path neither filled nor stroked. `InvalidGeometry` for a drawn path of fewer than 2 points,
/// `GeometryOverflow` when a count does not fit in a u64.
pub fn geometryCost(n: u64, closed: bool, fill: bool, stroke: bool, divisions: u64) error{ InvalidGeometry, GeometryOverflow }!layer_admission.Geometry {
    var cost: layer_admission.Geometry = .{};
    if (!fill and !stroke) return cost;
    if (n < 2) return error.InvalidGeometry;
    if (fill) cost = .{ .draws = 1, .uniforms = 1, .points = n, .shapes = 2, .gpu_vertices = try mul(9, n), .cpu_vertices = 6 };
    if (stroke) {
        cost.draws = try add(cost.draws, 1);
        cost.uniforms = cost.draws;
        cost.points = try add(cost.points, n);
        cost.shapes = try add(cost.shapes, 1);
        cost.indirect_draws = 1;
        const corners = if (closed) n else n - 1;
        const caps = if (closed) 2 else try mul(2, try add(divisions, 2));
        const pushes = try add(try mul(corners, try add(divisions, 3)), caps);
        cost.gpu_vertices = try add(cost.gpu_vertices, try mul(6, pushes - 1));
    }
    return cost;
}

fn add(a: u64, b: u64) error{GeometryOverflow}!u64 {
    return std.math.add(u64, a, b) catch error.GeometryOverflow;
}

fn mul(a: u64, b: u64) error{GeometryOverflow}!u64 {
    return std.math.mul(u64, a, b) catch error.GeometryOverflow;
}

/// The geometry of a run of paths, summed path by path and checked against a context's budget
/// (`pathBudget()`, less any reserve) once all are in: what `draw` admits a drawing by, and what
/// the host's preparation measures its cost by. Every limit `add` and `check` read is a field of
/// that budget.
pub const GeometryAdmission = struct {
    /// The paths' geometry so far, each sum saturating where it would overflow (which refuses).
    total: layer_admission.Geometry = .{},
    /// Paths added.
    paths: usize = 0,
    /// A path alone overran a per-path limit, or a sum overflowed: `check` refuses.
    refused: bool = false,

    /// One path as admission counts it.
    pub const Path = struct {
        /// Its flattened points.
        points: u64,
        /// It closes back to its first point.
        closed: bool,
        /// It is filled.
        fill: bool,
        /// It is stroked.
        stroke: bool,
        /// A glow, a second stroke of its own, is drawn beneath the stroke.
        glow: bool,
    };

    /// Counts `path`; a path drawn twice is added twice. A path over the budget's per-path
    /// `points` or `commands` marks the run refused rather than failing, so a caller walking a
    /// drawing can finish its walk. `InvalidGeometry` for a drawn path of fewer than 2 points.
    pub fn add(self: *GeometryAdmission, path: Path, budget: anytype) error{InvalidGeometry}!void {
        self.paths += 1;
        const closing: u64 = @intFromBool(path.closed);
        const commands = std.math.add(u64, path.points, closing + 1) catch std.math.maxInt(u64);
        if (path.points > budget.points or commands > budget.commands) self.refused = true;
        try self.sum(path.points, path.closed, path.fill, path.stroke, budget.stroke_divisions);
        if (path.stroke and path.glow) {
            // Round joins and caps, unlike the stroke's own, are covered by the same divisions.
            try self.sum(path.points, path.closed, false, true, budget.stroke_divisions);
        }
    }

    fn sum(self: *GeometryAdmission, n: u64, closed: bool, fill: bool, stroke: bool, divisions: u64) error{InvalidGeometry}!void {
        const cost = geometryCost(n, closed, fill, stroke, divisions) catch |err| switch (err) {
            error.InvalidGeometry => return error.InvalidGeometry,
            error.GeometryOverflow => {
                self.refused = true;
                return;
            },
        };
        inline for (std.meta.fields(layer_admission.Geometry)) |field| {
            const total = std.math.add(u64, @field(self.total, field.name), @field(cost, field.name)) catch blk: {
                self.refused = true;
                break :blk std.math.maxInt(u64);
            };
            @field(self.total, field.name) = total;
        }
    }

    /// The run's geometry when the budget takes it all, else `BudgetExceeded`: a path was refused,
    /// paths were added to a budget with no `paths` left, or a total passes the budget's frame
    /// limit.
    pub fn check(self: *const GeometryAdmission, budget: anytype) error{BudgetExceeded}!layer_admission.Geometry {
        if (self.refused) return error.BudgetExceeded;
        if (self.paths != 0 and budget.paths == 0) return error.BudgetExceeded;
        const total = self.total;
        const over = total.draws > budget.draws or
            total.uniforms > budget.uniforms or
            total.points > budget.gpu_points or
            total.shapes > budget.shapes or
            total.gpu_vertices > budget.gpu_vertices or
            total.cpu_vertices > budget.cpu_vertices or
            total.indirect_draws > budget.indirect_draws;
        if (over) return error.BudgetExceeded;
        return total;
    }
};

/// Layer scopes a drawing opens, as the context counts them.
const Layers = struct {
    /// Begin and end markers.
    markers: usize = 0,
    /// The most targets held at once, a blended scope's backdrop copy included.
    peak: usize = 0,
};

/// Checks that `drawing` is well formed: every shape's vertex run inside `vertices` and at least 2
/// long, every draw naming a shape, every `end` closing an open scope and all closed at the end
/// (`InvalidGeometry`). In the same walk admits every draw's geometry against `budget`, a shape
/// drawn twice counted twice (`BudgetExceeded`). Returns the layer scopes it opens.
fn admit(drawing: *const Drawing, budget: anytype) figure.Error!Layers {
    for (drawing.shapes) |shape| {
        const inside = shape.points.start <= drawing.vertices.len and shape.points.len <= drawing.vertices.len - shape.points.start;
        if (!inside or shape.points.len < 2) return error.InvalidGeometry;
    }
    var geometry: GeometryAdmission = .{};
    var layers: Layers = .{};
    var depth: usize = 0;
    for (drawing.ops) |op| switch (op) {
        .begin => |begin| {
            depth += 1;
            layers.markers += 2;
            // A blended scope holds a backdrop copy as well while it composites.
            const backdrop: usize = if (begin.blend == .normal) 0 else 1;
            layers.peak = @max(layers.peak, depth + backdrop);
        },
        .end => {
            if (depth == 0) return error.InvalidGeometry;
            depth -= 1;
        },
        .draw => |shape_draw| {
            if (shape_draw.shape >= drawing.shapes.len) return error.InvalidGeometry;
            const shape = drawing.shapes[shape_draw.shape];
            const path: GeometryAdmission.Path = .{
                .points = shape.points.len,
                .closed = shape.closed,
                .fill = shape.fill,
                .stroke = shape.stroke,
                .glow = shape.glow_radius > 0,
            };
            try geometry.add(path, budget);
            if (shape_draw.opacity != 1) {
                layers.markers += 2;
                layers.peak = @max(layers.peak, depth + 1);
            }
        },
    };
    if (depth != 0) return error.InvalidGeometry;
    _ = try geometry.check(budget);
    return layers;
}

/// The largest coordinate a layer's bounds may reach: past it, f64 no longer holds whole pixels.
const max_bounds_coordinate: f64 = 4503599627370496.0;

/// `bounds` taken from `Drawing.transform`'s target space to the live one, as the box around its
/// corners. `relative` is null when the two transforms are the same, and the bounds stay as they
/// are.
fn liveBounds(bounds: ?Drawing.Bounds, relative: ?math.Affine2f) figure.Error!?roop.layer_stream.Rect {
    const box = bounds orelse return null;
    var result: roop.layer_stream.Rect = .{ .x0 = box.min_x, .y0 = box.min_y, .x1 = box.max_x, .y1 = box.max_y };
    if (relative) |t| {
        const xs = [2]f64{ @as(f64, t.a) * box.min_x, @as(f64, t.a) * box.max_x };
        const ys = [2]f64{ @as(f64, t.c) * box.min_y, @as(f64, t.c) * box.max_y };
        const xs_y = [2]f64{ @as(f64, t.b) * box.min_x, @as(f64, t.b) * box.max_x };
        const ys_y = [2]f64{ @as(f64, t.d) * box.min_y, @as(f64, t.d) * box.max_y };
        result = .{
            .x0 = @min(xs[0], xs[1]) + @min(ys[0], ys[1]) + t.tx,
            .x1 = @max(xs[0], xs[1]) + @max(ys[0], ys[1]) + t.tx,
            .y0 = @min(xs_y[0], xs_y[1]) + @min(ys_y[0], ys_y[1]) + t.ty,
            .y1 = @max(xs_y[0], xs_y[1]) + @max(ys_y[0], ys_y[1]) + t.ty,
        };
    }
    for ([_]f64{ result.x0, result.y0, result.x1, result.y1 }) |value| {
        if (!std.math.isFinite(value) or @abs(value) > max_bounds_coordinate) return error.InvalidGeometry;
    }
    return result;
}

fn finiteAffine(t: math.Affine2f) bool {
    for ([_]f32{ t.a, t.b, t.c, t.d, t.tx, t.ty }) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}

/// A context call's failure as a render's.
fn contextError(err: anyerror) figure.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StackTooDeep, error.CapacityExceeded, error.PathBudgetExceeded => error.BudgetExceeded,
        error.InvalidOpacity => error.InvalidOptions,
        else => error.InvalidGeometry,
    };
}

/// Draws `drawing` into `ctx`, under the context's current transform and at its alpha, leaving
/// `reserve` of its budget unused and its state as it found it. `ctx` is a `roop.Context` or a
/// value with its methods.
///
/// Before any context call it admits the whole drawing: every draw's geometry against
/// `ctx.pathBudget()` less `reserve`, and its layer scopes on top of those the context holds
/// open, `BudgetExceeded` when either does not fit. `InvalidGeometry` when the drawing is not well
/// formed (a vertex run outside `vertices` or shorter than 2, a draw naming no shape, unbalanced
/// scopes) or its bounds do not fit the target's coordinates; `InvalidOptions` when the context's
/// alpha or transform is not finite. A context alpha of 0 or less draws nothing. When the current transform is not the
/// one the drawing was prepared under (`Drawing.transform`), its bounds are carried to the current
/// one as the box around their corners. Emission allocates nothing.
pub fn draw(drawing: *const Drawing, reserve: figure.Reserve, ctx: anytype) figure.Error!figure.RenderStats {
    const nothing: figure.RenderStats = .{ .consumed = .{}, .effective_revision = drawing.revision };
    if (drawing.shapes.len == 0) return nothing;
    const before = ctx.pathBudget();
    if (!std.math.isFinite(before.alpha)) return error.InvalidOptions;
    if (before.alpha <= 0) return nothing;
    const live = roop.transform.toAffine(ctx.currentTransform());
    if (!finiteAffine(live)) return error.InvalidOptions;
    const same_transform = std.meta.eql(live, drawing.transform);
    const relative: ?math.Affine2f = if (same_transform) null else blk: {
        const prepared_inverse = drawing.transform.inverse() orelse return error.InvalidOptions;
        break :blk math.Affine2f.mul(live, prepared_inverse);
    };

    var budget = before;
    inline for (std.meta.fields(figure.Reserve)) |field| @field(budget, field.name) -|= @field(reserve, field.name);
    const layers = try admit(drawing, budget);
    const outer_alpha = drawing.outer_alpha * before.alpha;
    const outer = outer_alpha != 1;
    const nested = layers.peak + @intFromBool(outer) + ctx.layerDepth();
    // Refuse a whole figure rather than lose the frame at submission. This counts targets for
    // scopes an empty parent would skip, so it errs towards refusing.
    if (nested > before.layer_targets) return error.BudgetExceeded;
    const scope_bounds = try liveBounds(drawing.bounds, relative);
    for (drawing.shapes) |shape| _ = try liveBounds(shape.bounds, relative);

    const outer_markers: usize = if (outer) 2 else 0;
    ctx.reserveLayers(layers.markers + outer_markers) catch |err| return contextError(err);
    ctx.save();
    defer ctx.restore();
    if (outer) ctx.beginLayer(.{ .opacity = outer_alpha, .bounds = scope_bounds, .kind = .instance }) catch |err| return contextError(err);
    for (drawing.ops) |op| switch (op) {
        .begin => |begin| ctx.beginLayer(.{ .opacity = begin.opacity, .blend = begin.blend, .composite = begin.composite, .bounds = scope_bounds }) catch |err| return contextError(err),
        .end => ctx.endLayer() catch |err| return contextError(err),
        .draw => |shape_draw| {
            const shape = drawing.shapes[shape_draw.shape];
            const isolated = shape_draw.opacity != 1;
            if (isolated) {
                const shape_bounds = try liveBounds(shape.bounds, relative);
                ctx.beginLayer(.{ .opacity = shape_draw.opacity, .bounds = shape_bounds }) catch |err| return contextError(err);
            }
            emitShape(drawing, shape, live, ctx);
            if (isolated) ctx.endLayer() catch |err| return contextError(err);
        },
    };
    if (outer) ctx.endLayer() catch |err| return contextError(err);

    const after = ctx.pathBudget();
    var consumed: figure.Reserve = .{};
    inline for (std.meta.fields(figure.Reserve)) |field| @field(consumed, field.name) = @field(before, field.name) -| @field(after, field.name);
    return .{ .consumed = consumed, .effective_revision = drawing.revision };
}

/// One shape's paths at full alpha within its scope: scopes carry every opacity.
fn emitShape(drawing: *const Drawing, shape: Drawing.Shape, live: math.Affine2f, ctx: anytype) void {
    const placed = math.Affine2f.mul(live, shape.transform);
    ctx.setTransform(.{ placed.a, placed.b, placed.c, placed.d, placed.tx, placed.ty });
    ctx.globalAlpha(1);
    switch (shape.cap) {
        .butt => ctx.lineCap(.butt),
        .round => ctx.lineCap(.round),
        .square => ctx.lineCap(.square),
    }
    switch (shape.join) {
        .miter => ctx.lineJoin(.miter),
        .round => ctx.lineJoin(.round),
        .bevel => ctx.lineJoin(.bevel),
    }
    ctx.beginPath();
    const vertices = drawing.vertices[shape.points.start..][0..shape.points.len];
    ctx.moveTo(vertices[0].x, vertices[0].y);
    for (vertices[1..]) |vertex| ctx.lineTo(vertex.x, vertex.y);
    if (shape.closed) ctx.closePath();
    // roop normalizes winding after transforming vertices; always request solid winding, even
    // under reflection (cw would mark the mirrored fill as a hole).
    ctx.pathWinding(.ccw);
    if (shape.fill) {
        ctx.fillColor(shape.fill_color);
        if (shape.fill_paint) |paint| ctx.fillPaint(paint);
        ctx.fill();
    }
    if (shape.stroke) {
        ctx.strokeColor(shape.stroke_color);
        if (shape.stroke_paint) |paint| ctx.strokePaint(paint);
        ctx.strokeWidth(shape.width);
        // Always set: the context's state otherwise keeps the previous shape's glow.
        ctx.strokeGlow(shape.glow_color, shape.glow_radius);
        ctx.stroke();
    }
}

fn testContext(renderer: *roop.Renderer, lists: *const std.mem.Allocator) !roop.Context {
    var ctx = try roop.Context.initWithoutTarget(renderer, lists);
    ctx.beginFrame(64, 64, 1, .wrap(lists));
    return ctx;
}

/// A closed triangle, filled and stroked, in a layer at full opacity.
fn triangle(shapes: *[1]Drawing.Shape, ops: *[3]Drawing.Op, vertices: *const [3]Vec2) Drawing {
    shapes.* = .{.{
        .points = .{ .start = 0, .len = vertices.len },
        .transform = .identity,
        .fill = true,
        .stroke = true,
        .closed = true,
        .fill_color = roop.rgb(255, 0, 0),
        .stroke_color = roop.rgb(0, 0, 255),
        .width = 2,
        .cap = .butt,
        .join = .miter,
        .glow_color = roop.rgb(0, 0, 0),
        .glow_radius = 0,
        .bounds = .{ .min_x = -40, .min_y = -40, .max_x = 60, .max_y = 60 },
    }};
    ops.* = .{
        .{ .begin = .{ .opacity = 1, .blend = .normal, .composite = .source_over } },
        .{ .draw = .{ .shape = 0, .opacity = 1 } },
        .end,
    };
    return .{ .revision = 3, .shapes = shapes, .ops = ops, .vertices = vertices, .bounds = shapes[0].bounds, .transform = .identity, .outer_alpha = 1 };
}

test "draw params default to a fresh context's tolerances" {
    var renderer: roop.Renderer = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = arena.allocator();
    var ctx = try testContext(&renderer, &lists);
    const budget = ctx.pathBudget();
    const params: DrawParams = .{};
    try std.testing.expectEqual(budget.tess_tol, params.tess_tol);
    try std.testing.expectEqual(budget.fringe_width, params.fringe_width);
    try std.testing.expectEqual(budget.miter_limit, params.miter_limit);
    try std.testing.expect(std.meta.eql(roop.transform.toAffine(ctx.currentTransform()), params.transform));
}

test "draw refuses a drawing over budget before touching the context" {
    var renderer: roop.Renderer = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = arena.allocator();
    var ctx = try testContext(&renderer, &lists);
    var shapes: [1]Drawing.Shape = undefined;
    var ops: [3]Drawing.Op = undefined;
    const vertices = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 0, .y = 20 } };
    const drawing = triangle(&shapes, &ops, &vertices);

    // The frame has one tessellated vertex left: the triangle needs many more.
    ctx.gpu_vert_used = roop.draw_list.kMaxGpuVerticesPerFrame - 1;
    const calls_before = ctx.calls.items.len;
    const states_before = ctx.states.items.len;
    try std.testing.expectError(error.BudgetExceeded, draw(&drawing, .{}, &ctx));
    try std.testing.expectEqual(calls_before, ctx.calls.items.len);
    try std.testing.expectEqual(states_before, ctx.states.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.layer_ops.items.len);

    // A reserve that leaves one draw call refuses it too: the triangle needs two.
    ctx.gpu_vert_used = 0;
    const reserve: figure.Reserve = .{ .draws = ctx.pathBudget().draws - 1 };
    try std.testing.expectError(error.BudgetExceeded, draw(&drawing, reserve, &ctx));
    try std.testing.expectEqual(calls_before, ctx.calls.items.len);

    // With room it draws, and reports what it took.
    const stats = try draw(&drawing, .{}, &ctx);
    try std.testing.expectEqual(@as(figure.Revision, 3), stats.effective_revision);
    try std.testing.expectEqual(@as(usize, 2), stats.consumed.draws);
    try std.testing.expectEqual(calls_before + 2, ctx.calls.items.len);
    try std.testing.expectEqual(states_before, ctx.states.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.layerDepth());
}

test "draw refuses layers deeper than the context can hold" {
    var renderer: roop.Renderer = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = arena.allocator();
    var ctx = try testContext(&renderer, &lists);
    var shapes: [1]Drawing.Shape = undefined;
    var ops: [3]Drawing.Op = undefined;
    const vertices = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 0, .y = 20 } };
    const drawing = triangle(&shapes, &ops, &vertices);
    const limit = ctx.pathBudget().layer_targets;
    for (0..limit) |_| try ctx.beginLayer(.{});
    const calls_before = ctx.calls.items.len;
    try std.testing.expectError(error.BudgetExceeded, draw(&drawing, .{}, &ctx));
    try std.testing.expectEqual(calls_before, ctx.calls.items.len);
    try std.testing.expectEqual(limit, ctx.layerDepth());
}

test "geometry cost follows its formulas and refuses overflow" {
    const cost = try geometryCost(3, true, true, true, 23);
    try std.testing.expectEqual(@as(u64, 501), cost.gpu_vertices);
    try std.testing.expectEqual(@as(u64, 6), cost.points);
    try std.testing.expectError(error.GeometryOverflow, geometryCost(std.math.maxInt(u64), true, true, false, 23));
    try std.testing.expectError(error.GeometryOverflow, geometryCost(2, false, false, true, std.math.maxInt(u64)));
}

test "draw refuses a malformed drawing before touching the context" {
    var renderer: roop.Renderer = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = arena.allocator();
    var ctx = try testContext(&renderer, &lists);
    var shapes: [1]Drawing.Shape = undefined;
    var ops: [3]Drawing.Op = undefined;
    const vertices = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 0, .y = 20 } };
    const valid = triangle(&shapes, &ops, &vertices);
    const calls_before = ctx.calls.items.len;
    const states_before = ctx.states.items.len;

    var bad_index = valid;
    const draws_missing_shape = [_]Drawing.Op{ ops[0], .{ .draw = .{ .shape = 1, .opacity = 1 } }, .end };
    bad_index.ops = &draws_missing_shape;
    try std.testing.expectError(error.InvalidGeometry, draw(&bad_index, .{}, &ctx));

    var unbalanced = valid;
    const ends_first = [_]Drawing.Op{ .end, ops[0], ops[1] };
    unbalanced.ops = &ends_first;
    try std.testing.expectError(error.InvalidGeometry, draw(&unbalanced, .{}, &ctx));

    var left_open = valid;
    left_open.ops = ops[0..2];
    try std.testing.expectError(error.InvalidGeometry, draw(&left_open, .{}, &ctx));

    var outside = valid;
    var long_run = shapes;
    long_run[0].points = .{ .start = 2, .len = 2 };
    outside.shapes = &long_run;
    try std.testing.expectError(error.InvalidGeometry, draw(&outside, .{}, &ctx));

    try std.testing.expectEqual(calls_before, ctx.calls.items.len);
    try std.testing.expectEqual(states_before, ctx.states.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.layer_ops.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.layerDepth());
}
