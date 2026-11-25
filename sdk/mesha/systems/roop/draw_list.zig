//! What a recording writes for the runtime's backend to draw: draw calls and the geometry, paint
//! and instance lists they index, with the frame limits that keep those indices valid.
//!
//! A `Context` holds the lists. `Context.fill`, `stroke` and `text` and the quad batch append to
//! them through the functions here, in drawing order; the backend uploads the lists as they are,
//! has a compute shader tessellate the shapes (`ShapeArgs`) into vertices, and issues one draw for
//! each `DrawCall`. Everything here is the recording's and the runtime's: code that draws calls the
//! `Context`.
const std = @import("std");
const transform = @import("transform.zig");
const color_mod = @import("../../core/color.zig");
const paint_mod = @import("paint.zig");
const geometry = @import("geometry.zig");
const context_mod = @import("context.zig");
const contract = @import("../../core/contract.zig");

/// Which of the backend's pipelines draws a call. The value indexes the backend's pipeline table.
pub const PipelineKind = enum {
    /// A fill that is not one convex subpath: its fans write the stencil, counting windings, and
    /// its cover quad is then drawn with `fill_cover` where the count is not zero.
    fill_stencil,
    /// The cover pass of a `fill_stencil` call. The backend's: no call is recorded with it.
    fill_cover,
    /// A fill of one convex subpath, drawn as a fan with no stencil. Also the pipeline of every
    /// fill's antialiasing fringe.
    fill_convex,
    /// A pipeline the backend makes; no call is recorded with it.
    stroke_stencil,
    /// A pipeline the backend makes; no call is recorded with it.
    stroke_cover,
    /// Triangles drawn as they are: a stroke's tessellated ribbon, or text's glyph quads.
    triangles,
    /// A batch of instanced rectangles and circles (`QuadInstance`).
    quad_instanced,
};

/// A vertex recorded on the CPU (`geometry.Vertex`).
pub const Vertex = geometry.Vertex;

// The shader generator (`shaders/*.slang`, through `runtime/build.zig`'s codegen) is the source of
// the types below, as `gpu.Roop`, `gpu.RoopTessellate` and `gpu.RoopQuadInstanced`. These are
// copies the API owns, so recording needs no shader module; the runtime's backend checks at
// compile time that each lays out field for field as its original, which keeps them in step
// and lets the recorded lists upload as they are.

/// How the fragment shader colors a draw.
pub const PaintType = enum(i32) {
    /// A paint of colors: `innerCol` turning to `outerCol` across the paint's box. A solid color is
    /// one whose two colors are equal.
    fill_grad = 0,
    /// An image pattern, sampled through `paintMat` and tinted by `innerCol`.
    fill_img = 1,
    /// Opaque white. Nothing is recorded with it.
    simple = 2,
    /// An image sampled at each vertex's own texture coordinates and tinted by `innerCol`: text.
    img = 3,
};

/// What one draw's fragment shader reads: its paint and its scissor. Laid out as the shader's
/// `PaintUniforms`.
pub const PaintUniforms = extern struct {
    /// Maps target pixels to the scissor's frame, centered on its rectangle (`transform.toRows`).
    scissorMat: [3][4]f32,
    /// Maps target pixels to the paint's frame.
    paintMat: [3][4]f32,
    /// The paint's inner color with the global alpha in it. `makePaintUniforms` premultiplies it;
    /// `Context.text` writes its color straight.
    innerCol: [4]f32,
    /// The paint's outer color, likewise.
    outerCol: [4]f32,
    /// The scissor rectangle's half size; `1e5` each way when there is no scissor.
    scissorExt: [2]f32,
    /// The scissor transform's scale over the fringe width, by which the scissor's edge is
    /// antialiased; 1 when there is no scissor.
    scissorScale: [2]f32,
    /// The scissor's corner radius; 0 for square corners or no scissor.
    scissorRadius: f32,
    /// How a texel of the draw's image is read (`renderer.ImageEntry.tex_type`).
    texType: i32,
    /// A `PaintType`, as its integer.
    type: i32,
};

/// What the tessellation shader writes per vertex: only its size is recorded against.
pub const RoopVertex = extern struct {
    /// Position in target pixels.
    pos: [2]f32,
    /// Texture coordinate; for a stroke's ribbon, where across and along it the vertex lies.
    tcoord: [2]f32,
};

/// One job for the tessellation shader: a run of `PointGpu` and what to make of it. Laid out as the
/// shader's `ShapeArgs`.
pub const ShapeArgs = extern struct {
    /// What to make: 0 a fill's fan, 1 a fill's antialiasing fringe, 2 a stroke's ribbon, 3 a
    /// glow's ribbon, which on a closed subpath keeps only its outer half.
    kind: u32,
    /// The index of the subpath's first point in the frame's `gpu_points`.
    pointFirst: u32,
    /// How many points the subpath has.
    pointCount: u32,
    /// 1 when the subpath's inside is on the left (`path.SubPath.ccw`); a stroke that is not a glow
    /// writes 0.
    ccw: u32,
    /// The antialiasing fringe's width in target pixels; 0 for none.
    fringeWidth: f32,
    /// Where in the frame's GPU vertex buffer the job writes its vertices.
    outVertexOffset: u32,
    /// 1 for a closed subpath; fills write 0.
    closed: u32,
    /// A stroke's cap: 0 butt, 1 round, 2 square.
    lineCap: u32,
    /// 1 when a stroke's joins are round.
    roundJoin: u32,
    /// Half a stroke's width in target pixels, without the fringe.
    strokeHalfWidth: f32,
    /// How many segments a stroke's round cap or join is divided into at most.
    ncap: u32,
    /// The indirect draw whose vertex count a stroke's job writes (`DrawCall.indirect_slot`).
    drawIndex: u32,
};

/// A flattened point as the tessellation shader reads it: a `path.Point` with its flags as an
/// integer.
pub const PointGpu = extern struct {
    /// Position along x, in target pixels.
    x: f32,
    /// Position along y.
    y: f32,
    /// Unit direction to the next point, along x.
    dx: f32,
    /// Unit direction to the next point, along y.
    dy: f32,
    /// Distance to the next point.
    len: f32,
    /// Miter direction, along x.
    dmx: f32,
    /// Miter direction, along y.
    dmy: f32,
    /// The bits of `path.PointFlag`.
    flags: u32,
};

/// One rectangle or circle of a quad batch, in target pixels. Laid out as the quad shader's
/// instance.
pub const QuadInstance = extern struct {
    /// The center.
    pos: [2]f32,
    /// The half width and half height.
    extent: [2]f32,
    /// The corner radius: 0 for a rectangle, the half size for a circle.
    radius: f32,
    /// The color, straight, with the global alpha in its alpha.
    color: [4]f32,
    /// The texture coordinate at the top left corner.
    uvMin: [2]f32,
    /// The texture coordinate at the bottom right corner.
    uvMax: [2]f32,
    /// The texture's bindless slot on the device, not an image handle.
    image: u32,
    /// The sampler's bindless slot.
    sampler: u32,
};

/// One draw, in the order recorded. Which fields mean anything depends on `kind`.
pub const DrawCall = struct {
    /// The pipeline that draws it.
    kind: PipelineKind,
    /// The image handle it samples; 0 for the renderer's dummy image.
    image: u32,
    /// The index of its `PaintUniforms` in the frame's uniforms.
    uniform_offset: u32,
    /// Its first vertex: in the GPU vertex buffer for a fill or a stroke, in the CPU vertices for
    /// text.
    vertex_offset: u32,
    /// How many vertices it draws; 0 for a stroke, whose count the tessellation writes.
    vertex_count: u32,

    /// A `fill_stencil` call's cover quad: its first vertex in the CPU vertices.
    cover_offset: u32,
    /// The cover quad's vertex count, 6; 0 for any other call.
    cover_count: u32,

    /// Recorded as 0. The backend does not read it.
    path_first: u32,
    /// How many subpaths the call was made from. The backend does not read it.
    path_count: u32,
    /// True for a stroke's ribbon. The backend does not read it.
    triangle_type: bool,

    /// A fill's antialiasing fringe: its first vertex in the GPU vertex buffer.
    fringe_offset: u32 = 0,
    /// The fringe's vertex count; 0 for none. The backend draws it after the call, with
    /// `fill_convex`.
    fringe_count: u32 = 0,

    /// How sharply a stroke's coverage rises from its ribbon's edge; 1 for calls that are not
    /// strokes.
    stroke_mult: f32 = 1.0,
    /// The coverage under which a fragment is discarded; -1, as every call records, discards none.
    stroke_thr: f32 = -1.0,
    /// The paint's `extent`.
    extent: [2]f32 = .{ 0, 0 },
    /// The paint's `radius`.
    radius: f32 = 0,
    /// The paint's `feather`.
    feather: f32 = 1,

    /// Whether the vertex count comes from the indirect buffer, as a stroke's does.
    gpu_indirect: bool = false,
    /// Which indirect draw, when `gpu_indirect`.
    indirect_slot: u32 = 0,

    /// A `quad_instanced` call's first instance in the frame's quad instances.
    instance_offset: u32 = 0,
    /// How many instances it draws.
    instance_count: u32 = 0,
};

// Frame geometry is recorded into growing CPU lists and uploaded through the frame's upload
// arena (`layer_upload_arena`), sized to what was actually drawn. These are not budgets: they
// keep u32 offsets valid and keep any one class within what the arena can hold.
const kFrameUploadBytes: usize = 1024 * 1024 * 1024;

/// The most draw calls one frame's recording may hold.
pub const kMaxDrawCallsPerFrame: usize = kFrameUploadBytes / @sizeOf(PaintUniforms);
/// The most tessellation jobs (`ShapeArgs`) one frame may hold.
pub const kMaxGpuShapesPerFrame: usize = 2 * kMaxDrawCallsPerFrame;
/// The most points (`PointGpu`) one frame may hold.
pub const kMaxGpuPointsPerFrame: usize = kFrameUploadBytes / @sizeOf(PointGpu);
/// The most vertices one frame's tessellation may write.
pub const kMaxGpuVerticesPerFrame: usize = kFrameUploadBytes / @sizeOf(RoopVertex);
/// The most indirect draws, one for each stroked subpath, one frame may hold.
pub const kMaxGpuIndirectDrawsPerFrame: usize = kMaxDrawCallsPerFrame;
/// The most quad instances one frame may hold.
pub const kMaxQuadInstancesPerFrame: usize = kFrameUploadBytes / @sizeOf(QuadInstance);
/// The most CPU vertices (`Vertex`) one frame may hold.
pub const kMaxCpuVerticesPerFrame: usize = kFrameUploadBytes / @sizeOf(Vertex);
/// The most `PaintUniforms` one frame may hold.
pub const kMaxUniformsPerFrame: usize = kMaxDrawCallsPerFrame;

/// Which of a recording's counts is over its frame limit.
pub const FrameLimitError = error{
    /// More than `kMaxDrawCallsPerFrame` calls.
    TooManyDrawCalls,
    /// More than `kMaxCpuVerticesPerFrame` CPU vertices.
    TooManyCpuVertices,
    /// More than `kMaxUniformsPerFrame` uniforms.
    TooManyUniforms,
    /// More than `kMaxGpuPointsPerFrame` points.
    TooManyGpuPoints,
    /// More than `kMaxGpuShapesPerFrame` tessellation jobs.
    TooManyGpuShapes,
    /// More than `kMaxGpuVerticesPerFrame` tessellated vertices.
    TooManyGpuVertices,
    /// More than `kMaxGpuIndirectDrawsPerFrame` indirect draws.
    TooManyIndirectDraws,
    /// More than `kMaxQuadInstancesPerFrame` quad instances.
    TooManyQuadInstances,
};

/// Checks a recording's counts against the frame limits and names the first over, in the order of
/// the parameters. The backend calls it before it uploads a recording.
pub fn validateFrameLimits(calls: usize, cpu_vertices: usize, uniforms: usize, gpu_points: usize, shapes: usize, gpu_vertices: usize, indirect_draws: usize, quad_instances: usize) FrameLimitError!void {
    if (calls > kMaxDrawCallsPerFrame) return error.TooManyDrawCalls;
    if (cpu_vertices > kMaxCpuVerticesPerFrame) return error.TooManyCpuVertices;
    if (uniforms > kMaxUniformsPerFrame) return error.TooManyUniforms;
    if (gpu_points > kMaxGpuPointsPerFrame) return error.TooManyGpuPoints;
    if (shapes > kMaxGpuShapesPerFrame) return error.TooManyGpuShapes;
    if (gpu_vertices > kMaxGpuVerticesPerFrame) return error.TooManyGpuVertices;
    if (indirect_draws > kMaxGpuIndirectDrawsPerFrame) return error.TooManyIndirectDraws;
    if (quad_instances > kMaxQuadInstancesPerFrame) return error.TooManyQuadInstances;
}

test "frame limits accept exact capacity and identify each max-plus-one" {
    const max_calls = kMaxDrawCallsPerFrame;
    const max_vertices = kMaxCpuVerticesPerFrame;
    const max_uniforms = kMaxUniformsPerFrame;
    const max_points = kMaxGpuPointsPerFrame;
    const max_shapes = kMaxGpuShapesPerFrame;
    const max_gpu_vertices = kMaxGpuVerticesPerFrame;
    const max_indirect = kMaxGpuIndirectDrawsPerFrame;
    const max_instances = kMaxQuadInstancesPerFrame;
    try validateFrameLimits(max_calls, max_vertices, max_uniforms, max_points, max_shapes, max_gpu_vertices, max_indirect, max_instances);
    try std.testing.expectError(error.TooManyDrawCalls, validateFrameLimits(max_calls + 1, max_vertices, max_uniforms, max_points, max_shapes, max_gpu_vertices, max_indirect, max_instances));
    try std.testing.expectError(error.TooManyCpuVertices, validateFrameLimits(max_calls, max_vertices + 1, max_uniforms, max_points, max_shapes, max_gpu_vertices, max_indirect, max_instances));
    try std.testing.expectError(error.TooManyUniforms, validateFrameLimits(max_calls, max_vertices, max_uniforms + 1, max_points, max_shapes, max_gpu_vertices, max_indirect, max_instances));
    try std.testing.expectError(error.TooManyGpuPoints, validateFrameLimits(max_calls, max_vertices, max_uniforms, max_points + 1, max_shapes, max_gpu_vertices, max_indirect, max_instances));
    try std.testing.expectError(error.TooManyGpuShapes, validateFrameLimits(max_calls, max_vertices, max_uniforms, max_points, max_shapes + 1, max_gpu_vertices, max_indirect, max_instances));
    try std.testing.expectError(error.TooManyGpuVertices, validateFrameLimits(max_calls, max_vertices, max_uniforms, max_points, max_shapes, max_gpu_vertices + 1, max_indirect, max_instances));
    try std.testing.expectError(error.TooManyIndirectDraws, validateFrameLimits(max_calls, max_vertices, max_uniforms, max_points, max_shapes, max_gpu_vertices, max_indirect + 1, max_instances));
    try std.testing.expectError(error.TooManyQuadInstances, validateFrameLimits(max_calls, max_vertices, max_uniforms, max_points, max_shapes, max_gpu_vertices, max_indirect, max_instances + 1));
}

/// Whether `additional` more fit a list holding `current` under `limit`, without the sum
/// overflowing; `CapacityExceeded` when not.
pub fn validateAppendCapacity(current: usize, additional: usize, limit: usize) error{CapacityExceeded}!void {
    if (current > limit or additional > limit - current) return error.CapacityExceeded;
}

/// As `validateAppendCapacity`, breaking the contract invariant `label` when they do not fit: how
/// recording meets a frame limit.
pub fn requireAppendCapacity(comptime label: []const u8, current: usize, additional: usize, limit: usize) void {
    validateAppendCapacity(current, additional, limit) catch contract.invariant(false, label);
}

test "producer append capacity accepts max and rejects overflow without addition wrap" {
    try validateAppendCapacity(4, 6, 10);
    try std.testing.expectError(error.CapacityExceeded, validateAppendCapacity(10, 1, 10));
    try std.testing.expectError(error.CapacityExceeded, validateAppendCapacity(std.math.maxInt(usize), 1, std.math.maxInt(usize)));
}

/// The uniforms for a draw with `paint` under the state `s`, a `Context`'s `State` or anything with
/// its `alpha` and scissor fields: both colors take `s.alpha` and are premultiplied, and the
/// scissor is written, or the open one when `s` has none. `fringe` is the antialiasing width in
/// target pixels; `tex_type` is the paint's image's (`Renderer.imageTexType`).
pub fn makePaintUniforms(
    paint: *const paint_mod.Paint,
    s: anytype,
    fringe: f32,
    tex_type: i32,
) PaintUniforms {
    const alpha = s.alpha;

    const scissor_rows = transform.toRows(s.scissor_xform);
    const scissor_ext = s.scissor_extent;
    var scissor_scale: [2]f32 = .{
        @sqrt(s.scissor_xform[0] * s.scissor_xform[0] + s.scissor_xform[2] * s.scissor_xform[2]) / fringe,
        @sqrt(s.scissor_xform[1] * s.scissor_xform[1] + s.scissor_xform[3] * s.scissor_xform[3]) / fringe,
    };

    const has_scissor = scissor_ext[0] > -0.5;
    if (!has_scissor) {
        scissor_scale = .{ 1, 1 };
    }

    const paint_rows = transform.toRows(paint.xform);
    const paint_type: PaintType = if (paint.image != 0) .fill_img else .fill_grad;

    var inner = paint.inner_color;
    var outer = paint.outer_color;
    inner.a *= alpha;
    outer.a *= alpha;
    // The render pipelines use premultiplied source-over blending. RGB must
    // carry both paint opacity and global/layer alpha, not just coverage.
    inner.r *= inner.a;
    inner.g *= inner.a;
    inner.b *= inner.a;
    outer.r *= outer.a;
    outer.g *= outer.a;
    outer.b *= outer.a;

    return .{
        .scissorMat = scissor_rows,
        .paintMat = paint_rows,
        .innerCol = color_mod.toArray(inner),
        .outerCol = color_mod.toArray(outer),
        .scissorExt = if (has_scissor) scissor_ext else .{ 1e5, 1e5 },
        .scissorScale = scissor_scale,
        .scissorRadius = if (has_scissor) s.scissor_radius else 0,
        .texType = tex_type,
        .type = @intFromEnum(paint_type),
    };
}

/// Records the fill of `ctx`'s flattened path (`ctx.cache`) with `paint`: one `fill_convex` call
/// for a single convex subpath, else one `fill_stencil` call, with the tessellation jobs, points
/// and cover quad it needs. Records nothing for a path with no subpath. `Context.fill` calls it,
/// after flattening and `geometry.expandFill`. A frame limit met breaks a contract invariant; an
/// error is the lists' allocator's, and may leave part of the draw's data appended with no call
/// naming it.
pub fn appendFill(
    ctx: *context_mod.Context,
    paint: *const paint_mod.Paint,
    s: context_mod.State,
    fringe: f32,
) !void {
    const paths = ctx.cache.paths.items;
    if (paths.len == 0) return;
    requireAppendCapacity("roop.producer.call_limit", ctx.calls.items.len, 1, kMaxDrawCallsPerFrame);
    requireAppendCapacity("roop.producer.uniform_limit", ctx.uniforms.items.len, 1, kMaxDrawCallsPerFrame);
    requireAppendCapacity("roop.producer.gpu_point_limit", ctx.gpu_points.items.len, ctx.cache.points.items.len, kMaxGpuPointsPerFrame);
    contract.invariant(paths.len <= kMaxGpuShapesPerFrame / 2, "roop.producer.shape_limit");
    requireAppendCapacity("roop.producer.shape_limit", ctx.shape_args.items.len, paths.len * 2, kMaxGpuShapesPerFrame);

    var all_convex = paths.len == 1;
    if (paths.len == 1) {
        all_convex = paths[0].convex;
    }

    const uniform_offset: u32 = @intCast(ctx.uniforms.items.len);
    const uni = makePaintUniforms(paint, s, fringe, ctx.renderer.imageTexType(paint.image));
    try ctx.uniforms.append(ctx.allocator(), uni);

    if (all_convex) {
        const sp = &paths[0];
        const n = sp.count;

        const point_first: u32 = @intCast(ctx.gpu_points.items.len);
        const pts = ctx.cache.points.items[sp.first .. sp.first + sp.count];
        for (pts) |p| {
            try ctx.gpu_points.append(ctx.allocator(), .{
                .x = p.x,
                .y = p.y,
                .dx = p.dx,
                .dy = p.dy,
                .len = p.len,
                .dmx = p.dmx,
                .dmy = p.dmy,
                .flags = @intCast(@as(u8, @bitCast(p.flags))),
            });
        }

        const fan_vertex_count: u32 = if (n < 3) 0 else 3 * (n - 2);
        requireAppendCapacity("roop.producer.gpu_vertex_limit", @intCast(ctx.gpu_vert_used), @intCast(fan_vertex_count), kMaxGpuVerticesPerFrame);
        const fan_offset: u32 = ctx.gpu_vert_used;
        if (fan_vertex_count > 0) {
            try ctx.shape_args.append(ctx.allocator(), .{
                .kind = 0,
                .pointFirst = point_first,
                .pointCount = n,
                .ccw = @intCast(@intFromBool(sp.ccw)),
                .fringeWidth = fringe,
                .outVertexOffset = fan_offset,
                .closed = 0,
                .lineCap = 0,
                .roundJoin = 0,
                .strokeHalfWidth = 0,
                .ncap = 0,
                .drawIndex = 0,
            });
            ctx.gpu_vert_used += fan_vertex_count;
        }

        var fringe_count: u32 = 0;
        const fringe_offset: u32 = ctx.gpu_vert_used;
        if (fringe > 0 and n >= 3) {
            fringe_count = 6 * n;
            requireAppendCapacity("roop.producer.gpu_vertex_limit", @intCast(ctx.gpu_vert_used), @intCast(fringe_count), kMaxGpuVerticesPerFrame);
            try ctx.shape_args.append(ctx.allocator(), .{
                .kind = 1,
                .pointFirst = point_first,
                .pointCount = n,
                .ccw = @intCast(@intFromBool(sp.ccw)),
                .fringeWidth = fringe,
                .outVertexOffset = fringe_offset,
                .closed = 0,
                .lineCap = 0,
                .roundJoin = 0,
                .strokeHalfWidth = 0,
                .ncap = 0,
                .drawIndex = 0,
            });
            ctx.gpu_vert_used += fringe_count;
        }

        try ctx.calls.append(ctx.allocator(), .{
            .kind = .fill_convex,
            .image = paint.image,
            .uniform_offset = uniform_offset,
            .vertex_offset = fan_offset,
            .vertex_count = fan_vertex_count,
            .cover_offset = 0,
            .cover_count = 0,
            .path_first = 0,
            .path_count = @intCast(paths.len),
            .triangle_type = false,
            .fringe_offset = fringe_offset,
            .fringe_count = fringe_count,
            .stroke_mult = 1.0,
            .stroke_thr = -1.0,
            .extent = paint.extent,
            .radius = paint.radius,
            .feather = paint.feather,
        });
    } else {
        const SubPathPoints = struct { point_first: u32, n: u32, ccw: bool };
        var subpath_pts: std.ArrayList(SubPathPoints) = .empty;
        defer subpath_pts.deinit(ctx.frameAllocator());

        for (paths) |*sp| {
            const point_first: u32 = @intCast(ctx.gpu_points.items.len);
            const pts = ctx.cache.points.items[sp.first .. sp.first + sp.count];
            for (pts) |p| {
                try ctx.gpu_points.append(ctx.allocator(), .{
                    .x = p.x,
                    .y = p.y,
                    .dx = p.dx,
                    .dy = p.dy,
                    .len = p.len,
                    .dmx = p.dmx,
                    .dmy = p.dmy,
                    .flags = @intCast(@as(u8, @bitCast(p.flags))),
                });
            }
            try subpath_pts.append(ctx.frameAllocator(), .{ .point_first = point_first, .n = sp.count, .ccw = sp.ccw });
        }

        const shape_offset: u32 = ctx.gpu_vert_used;
        for (subpath_pts.items) |sub| {
            const fan_vertex_count: u32 = if (sub.n < 3) 0 else 3 * (sub.n - 2);
            if (fan_vertex_count == 0) continue;
            requireAppendCapacity("roop.producer.gpu_vertex_limit", @intCast(ctx.gpu_vert_used), @intCast(fan_vertex_count), kMaxGpuVerticesPerFrame);
            try ctx.shape_args.append(ctx.allocator(), .{
                .kind = 0,
                .pointFirst = sub.point_first,
                .pointCount = sub.n,
                .ccw = @intCast(@intFromBool(sub.ccw)),
                .fringeWidth = fringe,
                .outVertexOffset = ctx.gpu_vert_used,
                .closed = 0,
                .lineCap = 0,
                .roundJoin = 0,
                .strokeHalfWidth = 0,
                .ncap = 0,
                .drawIndex = 0,
            });
            ctx.gpu_vert_used += fan_vertex_count;
        }
        const shape_vertex_count: u32 = ctx.gpu_vert_used - shape_offset;

        requireAppendCapacity("roop.producer.cpu_vertex_limit", ctx.verts.items.len, 6, kMaxCpuVerticesPerFrame);
        const b = ctx.cache.bounds;
        const cover_base: u32 = @intCast(ctx.verts.items.len);

        try ctx.verts.append(ctx.allocator(), geometry.Vertex{ .x = b[0], .y = b[1], .u = 0.5, .v = 1.0 });
        try ctx.verts.append(ctx.allocator(), geometry.Vertex{ .x = b[2], .y = b[1], .u = 0.5, .v = 1.0 });
        try ctx.verts.append(ctx.allocator(), geometry.Vertex{ .x = b[0], .y = b[3], .u = 0.5, .v = 1.0 });

        try ctx.verts.append(ctx.allocator(), geometry.Vertex{ .x = b[2], .y = b[1], .u = 0.5, .v = 1.0 });
        try ctx.verts.append(ctx.allocator(), geometry.Vertex{ .x = b[2], .y = b[3], .u = 0.5, .v = 1.0 });
        try ctx.verts.append(ctx.allocator(), geometry.Vertex{ .x = b[0], .y = b[3], .u = 0.5, .v = 1.0 });

        var fringe_count: u32 = 0;
        const fringe_offset: u32 = ctx.gpu_vert_used;
        if (fringe > 0) {
            for (subpath_pts.items) |sub| {
                if (sub.n < 3) continue;
                requireAppendCapacity("roop.producer.gpu_vertex_limit", @intCast(ctx.gpu_vert_used), @intCast(6 * sub.n), kMaxGpuVerticesPerFrame);
                try ctx.shape_args.append(ctx.allocator(), .{
                    .kind = 1,
                    .pointFirst = sub.point_first,
                    .pointCount = sub.n,
                    .ccw = @intCast(@intFromBool(sub.ccw)),
                    .fringeWidth = fringe,
                    .outVertexOffset = ctx.gpu_vert_used,
                    .closed = 0,
                    .lineCap = 0,
                    .roundJoin = 0,
                    .strokeHalfWidth = 0,
                    .ncap = 0,
                    .drawIndex = 0,
                });
                ctx.gpu_vert_used += 6 * sub.n;
            }
            fringe_count = ctx.gpu_vert_used - fringe_offset;
        }

        try ctx.calls.append(ctx.allocator(), .{
            .kind = .fill_stencil,
            .image = paint.image,
            .uniform_offset = uniform_offset,
            .vertex_offset = shape_offset,
            .vertex_count = shape_vertex_count,
            .cover_offset = cover_base,
            .cover_count = 6,
            .path_first = 0,
            .path_count = @intCast(paths.len),
            .triangle_type = false,
            .fringe_offset = fringe_offset,
            .fringe_count = fringe_count,
            .stroke_mult = 1.0,
            .stroke_thr = -1.0,
            .extent = paint.extent,
            .radius = paint.radius,
            .feather = paint.feather,
        });
    }
}

fn strokeVertexBudget(n: u32, ncap: u32, closed: bool) u32 {
    if (n < 2) return 0;
    const corner_count: u32 = if (closed) n else n - 1;
    var pushes: u32 = corner_count * (ncap + 3);
    if (closed) {
        pushes += 2;
    } else {
        pushes += 2 * (ncap + 2);
    }
    return 6 * (pushes - 1);
}

/// Records the stroke of `ctx`'s flattened path with `paint`: for each subpath of two points or
/// more, a tessellation job and a `triangles` call drawn indirectly, all sharing one
/// `PaintUniforms`. `width` is the stroke's in target pixels; a `glow_radius` above zero makes the
/// ribbon a glow fading over that distance. `Context.stroke` calls it, after flattening and
/// `geometry.expandStroke`. Every frame limit is checked before anything is appended, and one met
/// breaks a contract invariant; an error is the lists' allocator's.
pub fn appendStroke(
    ctx: *context_mod.Context,
    paint: *const paint_mod.Paint,
    s: context_mod.State,
    width: f32,
    fringe: f32,
    glow_radius: f32,
) !void {
    const paths = ctx.cache.paths.items;
    if (paths.len == 0) return;

    const half_width = width * 0.5;
    const is_glow = glow_radius > 0;
    const ncap: u32 = geometry.curveDivs(half_width, std.math.pi, fringe * 0.25);
    var projected_calls = ctx.calls.items.len;
    var projected_points: usize = ctx.gpu_points.items.len;
    var projected_shapes = ctx.shape_args.items.len;
    var projected_vertices: usize = @intCast(ctx.gpu_vert_used);
    var projected_indirect: usize = @intCast(ctx.gpu_indirect_used);
    var valid_subpaths: usize = 0;
    for (paths) |sp| {
        if (sp.count < 2) continue;
        requireAppendCapacity("roop.producer.call_limit", projected_calls, 1, kMaxDrawCallsPerFrame);
        projected_calls += 1;
        requireAppendCapacity("roop.producer.gpu_point_limit", projected_points, @intCast(sp.count), kMaxGpuPointsPerFrame);
        projected_points += @intCast(sp.count);
        requireAppendCapacity("roop.producer.shape_limit", projected_shapes, 1, kMaxGpuShapesPerFrame);
        projected_shapes += 1;
        const vertex_budget: usize = @intCast(strokeVertexBudget(sp.count, ncap, sp.closed));
        requireAppendCapacity("roop.producer.gpu_vertex_limit", projected_vertices, vertex_budget, kMaxGpuVerticesPerFrame);
        projected_vertices += vertex_budget;
        requireAppendCapacity("roop.producer.indirect_limit", projected_indirect, 1, kMaxGpuIndirectDrawsPerFrame);
        projected_indirect += 1;
        valid_subpaths += 1;
    }
    if (valid_subpaths == 0) return;
    requireAppendCapacity("roop.producer.uniform_limit", ctx.uniforms.items.len, 1, kMaxDrawCallsPerFrame);
    const uniform_offset: u32 = @intCast(ctx.uniforms.items.len);
    const uni = makePaintUniforms(paint, s, fringe, ctx.renderer.imageTexType(paint.image));
    try ctx.uniforms.append(ctx.allocator(), uni);

    const round_join = s.line_join == .round;
    const line_cap: u32 = switch (s.line_cap) {
        .butt => 0,
        .round => 1,
        .square => 2,
    };

    for (paths) |*sp| {
        const n = sp.count;
        if (n < 2) continue;

        const point_first: u32 = @intCast(ctx.gpu_points.items.len);
        const pts = ctx.cache.points.items[sp.first .. sp.first + sp.count];
        for (pts) |p| {
            try ctx.gpu_points.append(ctx.allocator(), .{
                .x = p.x,
                .y = p.y,
                .dx = p.dx,
                .dy = p.dy,
                .len = p.len,
                .dmx = p.dmx,
                .dmy = p.dmy,
                .flags = @intCast(@as(u8, @bitCast(p.flags))),
            });
        }

        const budget = strokeVertexBudget(n, ncap, sp.closed);
        const out_offset: u32 = ctx.gpu_vert_used;
        const draw_index: u32 = ctx.gpu_indirect_used;
        ctx.gpu_vert_used += budget;
        ctx.gpu_indirect_used += 1;

        try ctx.shape_args.append(ctx.allocator(), .{
            .kind = if (is_glow) 3 else 2,
            .pointFirst = point_first,
            .pointCount = n,
            .ccw = @intCast(@intFromBool(is_glow and sp.ccw)),
            .fringeWidth = fringe,
            .outVertexOffset = out_offset,
            .closed = @intCast(@intFromBool(sp.closed)),
            .lineCap = line_cap,
            .roundJoin = @intCast(@intFromBool(round_join)),
            .strokeHalfWidth = half_width,
            .ncap = ncap,
            .drawIndex = draw_index,
        });

        try ctx.calls.append(ctx.allocator(), .{
            .kind = .triangles,
            .image = paint.image,
            .uniform_offset = uniform_offset,
            .vertex_offset = out_offset,
            .vertex_count = 0,
            .cover_offset = 0,
            .cover_count = 0,
            .path_first = 0,
            .path_count = 1,
            .triangle_type = true,
            .stroke_mult = strokeMult(is_glow, half_width, glow_radius, fringe),
            .stroke_thr = -1.0,
            .extent = paint.extent,
            .radius = paint.radius,
            .feather = paint.feather,
            .gpu_indirect = true,
            .indirect_slot = draw_index,
        });
    }
}

/// How sharply a stroke's coverage rises from its ribbon's edge, which lies half a fringe
/// outside the stroke: the fragment shader scales the distance from that edge, measured as
/// a share of the ribbon's half width, by this and clamps it to one.
///
/// A plain stroke rises over one whole fringe, so coverage is half at the stroke's own edge
/// and full half a fringe inside it: a pixel-wide box filter, as fills get. Rising over only
/// half a fringe leaves a slanted line's pixels nearly all or nothing, and it shows as steps.
/// A glow fades over its whole radius instead.
fn strokeMult(is_glow: bool, half_width: f32, glow_radius: f32, fringe: f32) f32 {
    if (fringe <= 0 and !is_glow) return 1.0;
    const ribbon_half_width = half_width + fringe * 0.5;
    if (is_glow) return ribbon_half_width / (glow_radius + fringe * 0.5);
    return ribbon_half_width / fringe;
}

test "a plain stroke's coverage rises over a whole fringe, a glow's over its radius" {
    // A 3 px stroke with a 1 px fringe: its ribbon reaches 2 px from the center line, and
    // coverage is full from 1 px of the ribbon's edge.
    const plain = strokeMult(false, 1.5, 0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 2), plain, 1e-6);
    const at_stroke_edge = std.math.clamp((0.5 / 2.0) * plain, 0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), at_stroke_edge, 1e-6);
    // A glow 4 px beyond a 1 px half width fades over the 4.5 px past where it is solid.
    try std.testing.expectApproxEqAbs(@as(f32, 5.5 / 4.5), strokeMult(true, 5, 4, 1), 1e-6);
    try std.testing.expectEqual(@as(f32, 1), strokeMult(false, 1.5, 0, 0));
}

/// Opens a quad batch at the end of `ctx`'s quad instances. One must not be open already: a
/// contract invariant.
pub fn beginQuadBatch(ctx: *context_mod.Context) void {
    contract.invariant(ctx.quad_batch_start == null, "roop.producer.quad_batch_not_nested");
    ctx.quad_batch_start = @intCast(ctx.quad_instances.items.len);
}

/// Appends `inst` to the open batch. A batch must be open and the frame's instances under their
/// limit, each a contract invariant; panics when the lists' allocator has no memory.
pub fn appendQuadInstance(ctx: *context_mod.Context, inst: QuadInstance) void {
    contract.invariant(ctx.quad_batch_start != null, "roop.producer.quad_batch_open");
    requireAppendCapacity("roop.producer.quad_instance_limit", ctx.quad_instances.items.len, 1, kMaxQuadInstancesPerFrame);
    ctx.quad_instances.append(ctx.allocator(), inst) catch @panic("OOM");
}

/// Closes the batch and records one `quad_instanced` call for its instances, or none when it is
/// empty or no batch is open. Panics when the lists' allocator has no memory.
pub fn endQuadBatch(ctx: *context_mod.Context) void {
    const start = ctx.quad_batch_start orelse return;
    ctx.quad_batch_start = null;
    const count: u32 = @as(u32, @intCast(ctx.quad_instances.items.len)) - start;
    if (count == 0) return;
    requireAppendCapacity("roop.producer.call_limit", ctx.calls.items.len, 1, kMaxDrawCallsPerFrame);

    ctx.calls.append(ctx.allocator(), .{
        .kind = .quad_instanced,
        .image = 0,
        .uniform_offset = 0,
        .vertex_offset = 0,
        .vertex_count = 0,
        .cover_offset = 0,
        .cover_count = 0,
        .path_first = 0,
        .path_count = 0,
        .triangle_type = false,
        .instance_offset = start,
        .instance_count = count,
    }) catch @panic("OOM");
}
