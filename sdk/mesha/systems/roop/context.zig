//! The recording surface of the 2D renderer. A `Context` holds a stack of drawing state (`State`),
//! a path under construction and a frame's draw lists. Its methods change the state, build the
//! path, and record fills, strokes, text, batched quads and layers into the lists (`draw_list`),
//! which the runtime's `render` draws later, on the render thread. Recording reads no device and
//! draws nothing itself.
//!
//! The order of calls: the host begins a recording (`beginFrame`) and hands the Context to the code
//! that draws. That code sets state (`fillColor`, `strokeWidth`, `translate`, `scissor` and the
//! rest) and, for each shape, calls `beginPath`, then path commands (`moveTo`, `lineTo`,
//! `bezierTo`, `rect` and the rest), then `fill` or `stroke`, either of which leaves the path as it
//! is. `save` and `restore` bracket changes of state. The host ends the recording (`endFrame`) and
//! the runtime renders it.
//!
//! Coordinates: a point given to a path command or to `text` is in current coordinates, which the
//! current transform maps to target pixels as the command is appended. The target's origin is its
//! top left, x to the right and y down. A later change of transform does not move what the path
//! already holds. Angles are radians. Colors are sRGB-encoded with straight alpha (`Color`).
//!
//! Failure: only the layer calls return errors. A fill, a stroke or text that finds no memory, and
//! a path that cannot be flattened (a coordinate not finite, too many subpaths or points), record
//! nothing, or part of themselves that nothing draws. Passing a frame limit (`pathBudget`) or the
//! path's command limit breaks a contract invariant, and a path command that finds no memory
//! panics.
//!
//! The host makes every Context (the runtime's `initContext`, over `initLists`) and it never moves.
//! One thread records into it at a time; while a recording is being rendered the Context is the
//! render thread's.
const std = @import("std");
const transform = @import("transform.zig");
const color_mod = @import("../../core/color.zig");
const paint_mod = @import("paint.zig");
const path_mod = @import("path.zig");
const geometry = @import("geometry.zig");
const draw_list = @import("draw_list.zig");
const renderer_mod = @import("renderer.zig");
const resources_api = @import("../resources.zig");
const font_mod = @import("../font.zig");
const gfx_types = @import("../gfx/types.zig");
const contract = @import("../../core/contract.zig");
const memory_mod = @import("../../core/memory.zig");

/// A 2D affine transform as six floats (`transform.Transform2D`).
pub const Transform2D = transform.Transform2D;
/// A color in sRGB-encoded channels with straight alpha, each 0 to 1.
pub const Color = color_mod.Color;
/// How a fill or a stroke is colored (`paint.Paint`).
pub const Paint = paint_mod.Paint;
const kMaxStrokeWidth: f32 = 200;
/// An image handle: 0 for none (`paint.Image`).
pub const Image = paint_mod.Image;
/// Options for an image, which nothing reads (`paint.ImageFlags`).
pub const ImageFlags = paint_mod.ImageFlags;
/// Whether a subpath is a solid shape or a hole (`path.Winding`).
pub const Winding = path_mod.Winding;
/// An interned name: here, a font's.
pub const Atom = resources_api.Atom;
/// What recording reads of the host's renderer (`renderer.Renderer`).
pub const Renderer = renderer_mod.Renderer;

fn nextCodepointLossy(str: []const u8, i: *usize) ?u21 {
    if (i.* >= str.len) return null;
    const first = str[i.*];
    const len = std.unicode.utf8ByteSequenceLength(first) catch {
        i.* += 1;
        return std.unicode.replacement_character;
    };
    if (i.* + len > str.len) {
        i.* += 1;
        return std.unicode.replacement_character;
    }
    const cp = std.unicode.utf8Decode(str[i.* .. i.* + len]) catch {
        i.* += 1;
        return std.unicode.replacement_character;
    };
    i.* += len;
    return cp;
}

/// How a stroke ends on an open subpath: `butt` stops square at the end point, `round` adds a half
/// circle of the stroke's half width, `square` runs half the stroke's width past the end point.
pub const LineCap = enum { butt, round, square };
/// How a stroke turns a corner: `miter` runs the two edges on until they meet, unless that passes
/// the miter limit, when the corner is beveled; `round` rounds it; `bevel` cuts it straight across.
pub const LineJoin = enum { miter, round, bevel };

/// A Porter-Duff operation (`paint.composite.Operation`).
pub const CompositeOperation = @import("paint.zig").composite.Operation;

/// Where text sits against the x that `text` is given. `text` reads `center` and `right`: with
/// neither set the text starts at x. The vertical flags are not read: y is always the baseline.
pub const Align = packed struct(u32) {
    /// The text starts at x: what `text` does when neither `center` nor `right` is set.
    left: bool = false,
    /// The text is centered on x.
    center: bool = false,
    /// The text ends at x.
    right: bool = false,

    /// Not read.
    top: bool = false,
    /// Not read.
    middle: bool = false,
    /// Not read.
    bottom: bool = false,
    /// Not read: `text` always sets the baseline at y.
    baseline: bool = false,
    /// Unused bits, zero.
    _pad: u25 = 0,
};

const kInitDistTol: f32 = 0.01;
const kInitTessTol: f32 = 0.25;
const kInitFringeWidth: f32 = 1.0;

/// One level of the save stack: everything `save` keeps and `restore` brings back. A frame starts
/// from the defaults: a white fill, an opaque black stroke one unit wide, no glow, miter limit 10,
/// butt caps, miter joins, alpha 1, the identity transform, no scissor, antialiasing on, and text
/// in the `default` font starting at x.
pub const State = struct {
    /// The paint `fill` and `text` draw with; `text` takes its inner color alone.
    fill: Paint,
    /// The paint `stroke` draws with.
    stroke: Paint,
    /// The stroke's width, in current coordinates when `stroke` is called.
    stroke_width: f32,
    /// A soft edge bleeding outward from a stroke, drawn beneath it. Zero radius draws none.
    stroke_glow_radius: f32,
    /// The glow's color; one with zero alpha draws no glow.
    stroke_glow_color: Color,
    /// How far a miter join may reach: a corner whose miter tip would lie more than this many half
    /// widths from the path is beveled.
    miter_limit: f32,
    /// How strokes end on open subpaths.
    line_cap: LineCap,
    /// How strokes turn corners.
    line_join: LineJoin,
    /// Multiplies the alpha of everything drawn. Not clamped.
    alpha: f32,
    /// The current transform: current coordinates to target pixels.
    xform: Transform2D,

    /// Maps target pixels to the scissor rectangle's frame, centered on it.
    scissor_xform: Transform2D,
    /// The scissor rectangle's half size; negative when there is no scissor.
    scissor_extent: [2]f32,
    /// The scissor's corner radius.
    scissor_radius: f32,
    /// Whether fills and strokes get an antialiasing fringe, `Context.fringe_width` wide.
    shape_antialias: bool,

    /// Added to each glyph's advance by `text`.
    letter_spacing: f32,
    /// Set by `textLineHeight`. Nothing reads it.
    line_height: f32,
    /// Set by `fontBlur`. Nothing reads it.
    font_blur: f32,
    /// Where text sits against the x `text` is given.
    text_align: Align,
    /// The font `text` draws in, by the name it was loaded under.
    font_name: Atom,
};

fn defaultState() State {
    return .{
        .fill = paint_mod.solidColor(.{ .r = 1, .g = 1, .b = 1, .a = 1 }),
        .stroke = paint_mod.solidColor(.{ .r = 0, .g = 0, .b = 0, .a = 1 }),
        .stroke_width = 1.0,
        .stroke_glow_radius = 0,
        .stroke_glow_color = .transparent,
        .miter_limit = 10.0,
        .line_cap = .butt,
        .line_join = .miter,
        .alpha = 1.0,
        .xform = transform.identity(),
        .scissor_xform = transform.identity(),
        .scissor_extent = .{ -1, -1 },
        .scissor_radius = 0,
        .shape_antialias = true,
        .letter_spacing = 0,
        .line_height = 1,
        .font_blur = 0,
        .text_align = .{ .left = true, .baseline = true },
        .font_name = resources_api.kDefaultFontName,
    };
}

/// The textures a Context renders into. The runtime makes and resizes them on the thread that
/// renders; recording never reads them.
pub const RenderTarget = struct {
    /// The color texture; `.null_handle` until the first resize.
    color_texture: gfx_types.GfxResource,
    /// The color texture's width in pixels.
    width: u32,
    /// The color texture's height in pixels.
    height: u32,

    /// The depth-stencil texture, whose stencil fills are drawn with.
    ds_texture: gfx_types.GfxResource,
    /// The depth-stencil texture's width in pixels.
    ds_width: u32,
    /// The depth-stencil texture's height in pixels.
    ds_height: u32,

    /// No target yet: the first resize makes one.
    pub const none: RenderTarget = .{
        .color_texture = .null_handle,
        .width = 0,
        .height = 0,
        .ds_texture = .null_handle,
        .ds_width = 0,
        .ds_height = 0,
    };
};

/// The recording surface: a save stack of `State`, a path under construction and one frame's draw
/// lists. The host makes it and it never moves; see the file's overview for the order of calls. The
/// fields are the runtime's and this file's to read and write: code that draws calls the methods.
pub const Context = struct {
    /// Allocates every list below: the host's, since a plugin records into a host's Context
    /// (`allocator` adapts it where it is used). A Context's lists live from `initLists` to the
    /// `compactStorage` that replaces them or to the runtime's `deinitContext`. The runtime's
    /// `render` copies what the GPU reads into upload memory and records commands by value, so
    /// no submission holds a pointer into them and they need not outlive a fence.
    lists: memory_mod.SharedAllocator,
    /// One generation of the lists: growth abandons old buffers here until `compactStorage`
    /// drops them. Null only under `initWithoutTarget`, whose caller owns the allocator.
    storage: ?memory_mod.Arena,
    /// `storage` capacity when last judged, so a steady frame does no work and takes no pages.
    judged_capacity: usize,
    /// The frame's scratch, borrowed until the host resets it, after rendering completes. The
    /// host's, shared: a plugin's recording allocates from it (`frameAllocator`).
    frame: memory_mod.SharedAllocator = undefined,
    /// The host's: what recording reads of the renderer (fonts, images, the dummy slots).
    renderer: *Renderer,
    /// What `render` draws into. The runtime's, made and resized on the render thread.
    target: RenderTarget,

    /// Save stack; the top is the current state and it is never empty once initialized.
    states: std.ArrayList(State) = .empty,
    /// Saves since the allocator refused a copy, all on top of the stack: the current state
    /// stands in for them, and `restore` consumes these first so the two stay balanced.
    unbacked_saves: u32 = 0,

    /// The path under construction, its points already in target pixels. Kept, across frames too,
    /// until `beginPath`.
    commands: std.ArrayList(path_mod.Command),
    /// The path's flattened form, made again by each `fill` and `stroke`.
    cache: path_mod.PathCache,

    /// The frame's draw calls, in drawing order.
    calls: std.ArrayList(draw_list.DrawCall),
    /// The frame's CPU vertices: text's glyph quads and fills' cover quads.
    verts: std.ArrayList(draw_list.Vertex),
    /// The frame's paint uniforms: one for each fill, stroke, glow and run of text.
    uniforms: std.ArrayList(draw_list.PaintUniforms),

    /// The frame's flattened points, for the tessellation shader.
    gpu_points: std.ArrayList(draw_list.PointGpu),
    /// The frame's tessellation jobs.
    shape_args: std.ArrayList(draw_list.ShapeArgs),
    /// How many vertices the frame's tessellation jobs write: where the next job's begin.
    gpu_vert_used: u32,
    /// How many indirect draws the frame's strokes have taken.
    gpu_indirect_used: u32,

    /// The frame's batched rectangles and circles.
    quad_instances: std.ArrayList(draw_list.QuadInstance),
    /// The first instance of the open quad batch; null when none is open.
    quad_batch_start: ?u32,

    /// The frame's width as `beginFrame` gave it, which the runtime fits the target to.
    width: f32,
    /// The frame's height as `beginFrame` gave it.
    height: f32,
    /// The pixel ratio `beginFrame` gave: it sets the three tolerances below and nothing else.
    pixel_ratio: f32,
    /// The antialiasing fringe's width: `1 / pixel_ratio`.
    fringe_width: f32,
    /// How far a flattened curve may stray from the true one: `0.25 / pixel_ratio`.
    tess_tol: f32,
    /// Points of a path nearer than this are one point: `0.01 / pixel_ratio`.
    dist_tol: f32,

    /// Where the last `moveTo`, `lineTo` or `bezierTo` ended, along x, in target pixels.
    cmd_x: f32,
    /// Where the last `moveTo`, `lineTo` or `bezierTo` ended, along y, in target pixels.
    cmd_y: f32,

    /// The frame's layer stream: layer markers and the spans of draw calls between them. Empty in a
    /// frame that opens no layer.
    layer_ops: std.ArrayList(@import("layer_stream.zig").Op) = .empty,
    /// How many layers are open.
    layer_depth: usize = 0,
    /// The first draw call that no span has taken.
    layer_draw_cursor: usize = 0,

    /// Set by `compositeOperation`. Nothing reads it.
    composite_op: CompositeOperation = .source_over,

    /// Makes the lists in place, with no target: the runtime's `initContext` and
    /// `initContextTargetLater` call this. `lists` points into this struct, and the layer target
    /// pool keys its reservations on this address, so a Context never moves. The host makes
    /// every Context: `lists` is its functions, which a plugin recording into the Context calls.
    /// The runtime's, which this file's tests use too; not part of what a plugin relies on.
    pub fn initLists(self: *Context, renderer: *Renderer, width: u32, height: u32, backing: *memory_mod.PageBacking) !void {
        self.* = Context{
            .lists = undefined,
            .storage = .{ .pages = backing },
            .judged_capacity = 0,
            .renderer = renderer,
            .target = undefined,
            .commands = .empty,
            .cache = undefined,
            .calls = .empty,
            .verts = .empty,
            .uniforms = .empty,
            .gpu_points = .empty,
            .shape_args = .empty,
            .gpu_vert_used = 0,
            .gpu_indirect_used = 0,
            .quad_instances = .empty,
            .quad_batch_start = null,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
            .pixel_ratio = 1.0,
            .fringe_width = kInitFringeWidth,
            .tess_tol = kInitTessTol,
            .dist_tol = kInitDistTol,
            .cmd_x = 0,
            .cmd_y = 0,
            .composite_op = .source_over,
        };
        self.lists = .ofArena(&self.storage.?);
        self.cache = .empty;
        errdefer self.storage.?.deinit();
        try self.states.append(self.allocator(), defaultState());
    }

    /// The lists' allocator, for use there and then in the calling image.
    pub fn allocator(self: *const Context) std.mem.Allocator {
        return self.lists.allocator();
    }

    /// The frame's scratch, for use there and then in the calling image.
    pub fn frameAllocator(self: *const Context) std.mem.Allocator {
        return self.frame.allocator();
    }

    /// A Context for tests of recording and budgets: no render target exists, `lists`
    /// holds every list and must outlive the Context, and nothing here may render. A default
    /// `Renderer` serves one that draws no image.
    pub fn initWithoutTarget(renderer: *Renderer, lists: *const std.mem.Allocator) !Context {
        var ctx: Context = undefined;
        ctx.lists = .wrap(lists);
        ctx.storage = null;
        ctx.judged_capacity = 0;
        ctx.renderer = renderer;
        ctx.states = .empty;
        ctx.unbacked_saves = 0;
        ctx.commands = .empty;
        ctx.cache = .empty;
        ctx.quad_batch_start = null;
        ctx.layer_ops = .empty;
        ctx.layer_depth = 0;
        ctx.layer_draw_cursor = 0;
        ctx.gpu_vert_used = 0;
        ctx.gpu_indirect_used = 0;
        ctx.calls = .empty;
        ctx.verts = .empty;
        ctx.uniforms = .empty;
        ctx.gpu_points = .empty;
        ctx.shape_args = .empty;
        ctx.quad_instances = .empty;
        ctx.composite_op = .source_over;
        try ctx.states.append(lists.*, defaultState());
        return ctx;
    }

    /// For tests of paint state alone: no target, allocator or renderer stands behind this.
    pub fn bindPaintState(self: *Context, slot: *State) void {
        slot.* = defaultState();
        self.states = .{ .items = @as(*[1]State, slot), .capacity = 1 };
    }

    /// Sets `composite_op`, which nothing reads: every draw is composited source-over, and a layer
    /// takes its operation from `layer_stream.Begin.composite`.
    pub fn compositeOperation(self: *Context, op: CompositeOperation) void {
        self.composite_op = op;
    }

    /// The target this Context renders into: the Context's own field, valid while the Context lives
    /// and written by the render thread.
    pub fn renderTarget(self: *const Context) *const RenderTarget {
        return &self.target;
    }

    /// Begins a recording `width` by `height`: empties the draw lists and the layer stream, resets
    /// the save stack to one default `State`, and sets the tolerances from `pixel_ratio`. `frame`
    /// is the scratch allocator recording borrows until the host resets it, after rendering. The
    /// path under construction is kept. `width` and `height` must be finite and not negative,
    /// `pixel_ratio` finite and above zero, and no quad batch open: each a contract invariant. The
    /// host's to call, once for each recording.
    pub fn beginFrame(self: *Context, width: f32, height: f32, pixel_ratio: f32, frame: memory_mod.SharedAllocator) void {
        self.frame = frame;
        contract.invariant(std.math.isFinite(width) and width >= 0 and std.math.isFinite(height) and height >= 0, "roop.context.frame_dimensions");
        contract.invariant(std.math.isFinite(pixel_ratio) and pixel_ratio > 0 and std.math.isFinite(1.0 / pixel_ratio), "roop.context.pixel_ratio");
        contract.invariant(self.quad_batch_start == null, "roop.context.unclosed_quad_batch");
        self.width = width;
        self.height = height;
        self.pixel_ratio = pixel_ratio;
        self.fringe_width = 1.0 / pixel_ratio;
        self.tess_tol = 0.25 / pixel_ratio;
        self.dist_tol = 0.01 / pixel_ratio;

        self.states.items.len = 1;
        self.states.items[0] = defaultState();
        self.unbacked_saves = 0;

        self.layer_ops.clearRetainingCapacity();
        self.layer_depth = 0;
        self.layer_draw_cursor = 0;
        self.calls.clearRetainingCapacity();
        self.verts.clearRetainingCapacity();
        self.uniforms.clearRetainingCapacity();
        self.gpu_points.clearRetainingCapacity();
        self.shape_args.clearRetainingCapacity();
        self.gpu_vert_used = 0;
        self.gpu_indirect_used = 0;
        self.quad_instances.clearRetainingCapacity();
        self.quad_batch_start = null;
        self.compactStorage();
    }

    /// The rebuild boundary: frame lists are empty and last frame's commands have been
    /// recorded. Only growth changes the capacity, and lists only grow to a new peak, so this
    /// rebuilds at most about once per doubling and never in a steady frame. Refused pages keep
    /// the current generation, which stays valid, and the next frame tries again.
    fn compactStorage(self: *Context) void {
        const storage = if (self.storage) |*owned| owned else return;
        const capacity = storage.reserved();
        if (capacity == self.judged_capacity) return;
        const list_bytes = self.listCapacityBytes();
        if (capacity / 2 <= list_bytes) {
            self.judged_capacity = capacity;
            return;
        }
        var next_storage: memory_mod.Arena = .{ .pages = storage.pages };
        self.rebuildLists(&next_storage, list_bytes) catch {
            next_storage.deinit();
            return;
        };
        storage.deinit();
        storage.* = next_storage;
        self.judged_capacity = storage.reserved();
    }

    fn listCapacityBytes(self: *const Context) usize {
        return listBytes(self.states) + listBytes(self.commands) + listBytes(self.cache.points) +
            listBytes(self.cache.paths) + listBytes(self.calls) + listBytes(self.verts) +
            listBytes(self.uniforms) + listBytes(self.gpu_points) + listBytes(self.shape_args) +
            listBytes(self.quad_instances) + listBytes(self.layer_ops);
    }

    /// All or nothing: every list keeps its capacity, and its contents, because the current
    /// state and the path under construction outlive the frame. `lists` is unchanged since
    /// it points at the `storage` field, which the caller overwrites with this generation.
    fn rebuildLists(self: *Context, next_storage: *memory_mod.Arena, list_bytes: usize) std.mem.Allocator.Error!void {
        const next = next_storage.allocator();
        // One block up front, so the lists share a node rather than each take a larger one.
        const alignment_slack = 16 * 11;
        const block = try next.alloc(u8, list_bytes + alignment_slack);
        next.free(block);
        const states = try rebuiltList(State, next, self.states);
        const commands = try rebuiltList(path_mod.Command, next, self.commands);
        const points = try rebuiltList(@TypeOf(self.cache.points.items[0]), next, self.cache.points);
        const paths = try rebuiltList(@TypeOf(self.cache.paths.items[0]), next, self.cache.paths);
        const calls = try rebuiltList(draw_list.DrawCall, next, self.calls);
        const verts = try rebuiltList(draw_list.Vertex, next, self.verts);
        const uniforms = try rebuiltList(draw_list.PaintUniforms, next, self.uniforms);
        const gpu_points = try rebuiltList(draw_list.PointGpu, next, self.gpu_points);
        const shape_args = try rebuiltList(draw_list.ShapeArgs, next, self.shape_args);
        const quad_instances = try rebuiltList(draw_list.QuadInstance, next, self.quad_instances);
        const layer_ops = try rebuiltList(@import("layer_stream.zig").Op, next, self.layer_ops);
        self.states = states;
        self.commands = commands;
        self.cache.points = points;
        self.cache.paths = paths;
        self.calls = calls;
        self.verts = verts;
        self.uniforms = uniforms;
        self.gpu_points = gpu_points;
        self.shape_args = shape_args;
        self.quad_instances = quad_instances;
        self.layer_ops = layer_ops;
    }

    /// Empties the draw lists and the layer stream and closes any quad batch, leaving the save
    /// stack, the path and the frame's size: drops what was recorded.
    pub fn cancelFrame(self: *Context) void {
        self.layer_ops.clearRetainingCapacity();
        self.layer_depth = 0;
        self.layer_draw_cursor = 0;
        self.calls.clearRetainingCapacity();
        self.verts.clearRetainingCapacity();
        self.uniforms.clearRetainingCapacity();
        self.gpu_points.clearRetainingCapacity();
        self.shape_args.clearRetainingCapacity();
        self.gpu_vert_used = 0;
        self.gpu_indirect_used = 0;
        self.quad_instances.clearRetainingCapacity();
        self.quad_batch_start = null;
    }

    /// Ends a recording. It checks only that no quad batch is open, a contract invariant. The
    /// host's to call.
    pub fn endFrame(self: *Context) void {
        contract.invariant(self.quad_batch_start == null, "roop.context.unclosed_quad_batch");
    }

    /// How many layers are open: `beginLayer`s not yet matched by an `endLayer`.
    pub fn layerDepth(self: *const Context) usize {
        return self.layer_depth;
    }

    /// Reserves room for `markers` layer markers, a `beginLayer` or an `endLayer` each, and the
    /// draw spans they close. Reserve before recording a whole figure, so that no marker fails for
    /// memory midway through its geometry. Errors: `OpenQuadBatch` with a quad batch open,
    /// `Overflow` when the count cannot be computed, `OutOfMemory`.
    pub fn reserveLayers(self: *Context, markers: usize) !void {
        if (self.quad_batch_start != null) return error.OpenQuadBatch;
        try self.layer_ops.ensureUnusedCapacity(self.allocator(), try std.math.add(usize, try std.math.mul(usize, markers, 2), 1));
    }

    /// Closes the draws since the last layer marker into a span: the runtime's `render` calls
    /// this before it schedules the layers, and this file too. Not part of what a plugin
    /// relies on.
    pub fn flushLayerDraws(self: *Context) !void {
        const count = self.calls.items.len - self.layer_draw_cursor;
        if (count != 0) {
            try self.layer_ops.append(self.allocator(), .{ .draw = .{ .first = self.layer_draw_cursor, .count = count } });
            self.layer_draw_cursor = self.calls.items.len;
        }
    }

    /// Opens a layer: what is drawn until the matching `endLayer` is isolated and composited as one
    /// onto what is beneath it, with `begin`'s opacity, blend and operation. `begin.bounds` are in
    /// target pixels, whatever the current transform, and should be padded to hold all the layer
    /// draws; null takes the enclosing layer's. State, the transform and scissor with it, is
    /// unchanged. Errors, each leaving the recording as it was: `OpenQuadBatch`; `InvalidOpacity`
    /// for one not finite or outside 0 to 1; `UnsupportedComposite` for the blend `.unsupported`,
    /// for a blend other than `.normal` with an operation other than `.source_over`, and for a
    /// mask; `InvalidBounds` for a bound not finite or past 2^52, or a rectangle whose corners are
    /// out of order; `OutOfMemory`.
    pub fn beginLayer(self: *Context, begin: @import("layer_stream.zig").Begin) !void {
        if (self.quad_batch_start != null) return error.OpenQuadBatch;
        if (!std.math.isFinite(begin.opacity) or begin.opacity < 0 or begin.opacity > 1) return error.InvalidOpacity;
        if (begin.blend == .unsupported or (begin.blend != .normal and begin.composite != .source_over) or begin.mask) return error.UnsupportedComposite;
        if (begin.bounds) |b| {
            inline for (.{ b.x0, b.y0, b.x1, b.y1 }) |v| if (!std.math.isFinite(v) or @abs(v) > 4503599627370496.0) return error.InvalidBounds;
            if (b.x1 < b.x0 or b.y1 < b.y0) return error.InvalidBounds;
        }
        try self.layer_ops.ensureUnusedCapacity(self.allocator(), 2);
        try self.flushLayerDraws();
        self.layer_ops.appendAssumeCapacity(.{ .begin = begin });
        self.layer_depth += 1;
    }

    /// Closes the innermost open layer. Errors, each leaving the recording as it was:
    /// `UnbalancedStream` when no layer is open, `OpenQuadBatch`, `OutOfMemory`.
    pub fn endLayer(self: *Context) !void {
        if (self.layer_depth == 0) return error.UnbalancedStream;
        if (self.quad_batch_start != null) return error.OpenQuadBatch;
        try self.layer_ops.ensureUnusedCapacity(self.allocator(), 2);
        try self.flushLayerDraws();
        self.layer_ops.appendAssumeCapacity(.end);
        self.layer_depth -= 1;
    }

    /// Pushes a copy of the current state, which `restore` pops. It cannot fail: when no memory is
    /// found for the copy the save is counted instead, and its `restore` then leaves the state as
    /// it is, keeping the changes made since.
    pub fn save(self: *Context) void {
        // Once a save is unbacked, deeper ones must be too: a backed save above it would be
        // popped out of order by the restores, which consume the unbacked count first.
        if (self.unbacked_saves != 0) {
            self.unbacked_saves += 1;
            return;
        }
        const current = self.state().*;
        self.states.append(self.allocator(), current) catch {
            self.unbacked_saves += 1;
        };
    }

    /// Returns to the state the matching `save` kept. With no save to match, does nothing.
    pub fn restore(self: *Context) void {
        if (self.unbacked_saves != 0) {
            self.unbacked_saves -= 1;
            return;
        }
        if (self.states.items.len <= 1) return;
        self.states.items.len -= 1;
    }

    /// Sets the current state to the defaults (see `State`), leaving the saved ones.
    pub fn reset(self: *Context) void {
        self.state().* = defaultState();
    }

    fn state(self: *Context) *State {
        return &self.states.items[self.states.items.len - 1];
    }

    /// Sets the current transform to the identity.
    pub fn resetTransform(self: *Context) void {
        self.state().xform = transform.identity();
    }

    /// Replaces the current transform with `t`, which maps current coordinates to target pixels.
    pub fn setTransform(self: *Context, t: Transform2D) void {
        self.state().xform = t;
    }

    /// The current transform: current coordinates to target pixels.
    pub fn currentTransform(self: *Context) Transform2D {
        return self.state().xform;
    }

    /// Moves by `x, y` after the current transform: `xform = translation * xform`, so the offset is
    /// in target pixels, not scaled or turned by what is already set. So do `rotate`, `scale`,
    /// `skewX` and `skewY`: each acts on coordinates the current transform has already mapped,
    /// which is the reverse of a canvas, whose newest transform reaches a point first. To transform
    /// in current coordinates, compose with `transform.multiply` and `setTransform`.
    pub fn translate(self: *Context, x: f32, y: f32) void {
        const s = self.state();
        s.xform = transform.multiply(transform.translation(x, y), s.xform);
    }

    /// Turns by `angle` radians about the target's origin, after the current transform (see
    /// `translate`); a positive angle is clockwise on screen.
    pub fn rotate(self: *Context, angle: f32) void {
        const s = self.state();
        s.xform = transform.multiply(transform.rotation(angle), s.xform);
    }

    /// Scales x by `x` and y by `y` about the target's origin, after the current transform (see
    /// `translate`).
    pub fn scale(self: *Context, x: f32, y: f32) void {
        const s = self.state();
        s.xform = transform.multiply(transform.scaling(x, y), s.xform);
    }

    /// Shears along x by `angle` radians, after the current transform (see `translate`).
    pub fn skewX(self: *Context, angle: f32) void {
        const s = self.state();
        s.xform = transform.multiply(transform.skewX(angle), s.xform);
    }

    /// Shears along y by `angle` radians, after the current transform (see `translate`).
    pub fn skewY(self: *Context, angle: f32) void {
        const s = self.state();
        s.xform = transform.multiply(transform.skewY(angle), s.xform);
    }

    /// Sets the alpha that multiplies everything drawn from now on, 0 to 1; not clamped.
    pub fn globalAlpha(self: *Context, alpha: f32) void {
        self.state().alpha = alpha;
    }

    /// Clips what fills, strokes and text draw from now on to the rectangle `x, y, w, h` with
    /// corners of `radius`, given in current coordinates and placed by the transform as it is at
    /// this call. It replaces any scissor set. Batched quads are not clipped.
    pub fn scissor(self: *Context, x: f32, y: f32, w: f32, h: f32, radius: f32) void {
        const s = self.state();
        const hw = w * 0.5;
        const hh = h * 0.5;
        var t = s.xform;
        const center = transform.point(s.xform, x + hw, y + hh);
        t[4] = center[0];
        t[5] = center[1];
        s.scissor_xform = transform.inverse(t) orelse transform.identity();
        s.scissor_extent = .{ hw, hh };
        s.scissor_radius = radius;
    }

    /// Removes the scissor.
    pub fn resetScissor(self: *Context) void {
        const s = self.state();
        s.scissor_xform = transform.identity();
        s.scissor_extent = .{ -1, -1 };
        s.scissor_radius = 0;
    }

    /// Narrows the scissor to where it and the rectangle `x, y, w, h`, in current coordinates,
    /// overlap; with none set, sets it as `scissor` does. The scissor already set is taken by its
    /// bounding box in current coordinates, so the result is exact only when the two are aligned.
    /// The radius becomes the smaller of the two. Rectangles that do not overlap clip everything.
    pub fn intersectScissor(self: *Context, x: f32, y: f32, w: f32, h: f32, radius: f32) void {
        const s = self.state();
        if (s.scissor_extent[0] < 0) {
            self.scissor(x, y, w, h, radius);
            return;
        }

        const result_radius = @min(s.scissor_radius, radius);

        const pxform = transform.inverse(s.scissor_xform) orelse {
            self.scissor(x, y, w, h, 0);
            return;
        };
        const ex = s.scissor_extent[0];
        const ey = s.scissor_extent[1];

        // The new rectangle is in current coordinates, which need not be the old scissor's.
        const to_current = transform.inverse(s.xform) orelse transform.identity();
        const device_corners = [4][2]f32{
            transform.point(pxform, -ex, -ey),
            transform.point(pxform, ex, -ey),
            transform.point(pxform, ex, ey),
            transform.point(pxform, -ex, ey),
        };
        var corners: [4][2]f32 = undefined;
        for (device_corners, &corners) |corner, *current| current.* = transform.point(to_current, corner[0], corner[1]);
        var minx = corners[0][0];
        var miny = corners[0][1];
        var maxx = corners[0][0];
        var maxy = corners[0][1];
        for (corners[1..]) |c| {
            minx = @min(minx, c[0]);
            miny = @min(miny, c[1]);
            maxx = @max(maxx, c[0]);
            maxy = @max(maxy, c[1]);
        }
        const ix = @max(minx, x);
        const iy = @max(miny, y);
        const iw = @min(maxx, x + w) - ix;
        const ih = @min(maxy, y + h) - iy;
        if (iw < 0 or ih < 0) {
            self.scissor(ix, iy, 0, 0, 0);
        } else {
            self.scissor(ix, iy, iw, ih, result_radius);
        }
    }

    /// Sets the stroke paint to the solid color `c`.
    pub fn strokeColor(self: *Context, c: Color) void {
        self.state().stroke = paint_mod.solidColor(c);
    }

    /// Sets the stroke paint to `p`, whose coordinates are current coordinates: the paint is bound
    /// to the transform as it is at this call.
    pub fn strokePaint(self: *Context, p: Paint) void {
        var pp = p;

        const inv = transform.inverse(self.state().xform) orelse transform.identity();
        pp.xform = transform.multiply(pp.xform, inv);
        self.state().stroke = pp;
    }

    /// Sets the fill paint, which text is drawn with too, to the solid color `c`.
    pub fn fillColor(self: *Context, c: Color) void {
        self.state().fill = paint_mod.solidColor(c);
    }

    /// Sets the fill paint to `p`, whose coordinates are current coordinates: the paint is bound to
    /// the transform as it is at this call.
    pub fn fillPaint(self: *Context, p: Paint) void {
        var pp = p;

        const inv = transform.inverse(self.state().xform) orelse transform.identity();
        pp.xform = transform.multiply(pp.xform, inv);
        self.state().fill = pp;
    }

    /// Sets the miter limit (`State.miter_limit`).
    pub fn miterLimit(self: *Context, limit: f32) void {
        self.state().miter_limit = limit;
    }

    /// Sets the glow drawn beneath each stroke: `color` fading outward over `radius`, which is in
    /// the units of the stroke's width. On a closed path the glow leaves only the outside; on an
    /// open one, both sides and the ends, which are all outside. A radius of zero, or one not
    /// finite or negative, and a color with zero alpha draw none.
    pub fn strokeGlow(self: *Context, color: Color, radius: f32) void {
        const s = self.state();
        s.stroke_glow_color = color;
        s.stroke_glow_radius = if (std.math.isFinite(radius)) @max(radius, 0) else 0;
    }

    /// Sets the stroke's width in current coordinates. `stroke` scales it by the transform's mean
    /// scale and limits it to 200 target pixels.
    pub fn strokeWidth(self: *Context, width: f32) void {
        self.state().stroke_width = width;
    }

    /// Sets how strokes end on open subpaths.
    pub fn lineCap(self: *Context, cap: LineCap) void {
        self.state().line_cap = cap;
    }

    /// Sets how strokes turn corners.
    pub fn lineJoin(self: *Context, join: LineJoin) void {
        self.state().line_join = join;
    }

    /// Sets whether fills and strokes get an antialiasing fringe.
    pub fn shapeAntiAlias(self: *Context, enabled: bool) void {
        self.state().shape_antialias = enabled;
    }

    /// What a path and the frame can still take, with the state a caller sizing a figure needs. The
    /// first three limits hold for each path and are fresh after `beginPath`; the frame's are
    /// shared by everything recorded and shrink as it grows.
    pub fn pathBudget(self: *const Context) struct {
        /// The most subpaths one path may hold.
        paths: usize,
        /// The most commands one path may hold.
        commands: usize,
        /// The most points one path may flatten to.
        points: usize,
        /// Draw calls the frame can still take.
        draws: usize,
        /// Paint uniforms the frame can still take.
        uniforms: usize,
        /// Flattened points the frame can still take.
        gpu_points: usize,
        /// Tessellation jobs the frame can still take.
        shapes: usize,
        /// Tessellated vertices the frame can still take.
        gpu_vertices: usize,
        /// CPU vertices the frame can still take.
        cpu_vertices: usize,
        /// Indirect draws, one for each stroked subpath, the frame can still take.
        indirect_draws: usize,
        /// Batched quads the frame can still take.
        quad_instances: usize,
        /// Layer scopes one Context can hold live: each takes a color and a depth target.
        layer_targets: usize,
        /// How many segments the round cap of the widest stroke, 200 target pixels, is divided
        /// into: the most a cap or a round join costs.
        stroke_divisions: usize,
        /// The current state's miter limit.
        miter_limit: f32,
        /// The antialiasing fringe's width.
        fringe_width: f32,
        /// The tessellation tolerance.
        tess_tol: f32,
        /// The current state's alpha.
        alpha: f32,
    } {
        return .{
            .paths = path_mod.kMaxPaths,
            .commands = path_mod.kMaxPathCommands,
            .points = path_mod.kMaxFlattenedPoints,
            .draws = draw_list.kMaxDrawCallsPerFrame -| self.calls.items.len,
            .uniforms = draw_list.kMaxUniformsPerFrame -| self.uniforms.items.len,
            .gpu_points = draw_list.kMaxGpuPointsPerFrame -| self.gpu_points.items.len,
            .shapes = draw_list.kMaxGpuShapesPerFrame -| self.shape_args.items.len,
            .gpu_vertices = draw_list.kMaxGpuVerticesPerFrame -| self.gpu_vert_used,
            .cpu_vertices = draw_list.kMaxCpuVerticesPerFrame -| self.verts.items.len,
            .indirect_draws = draw_list.kMaxGpuIndirectDrawsPerFrame -| self.gpu_indirect_used,
            .quad_instances = draw_list.kMaxQuadInstancesPerFrame -| self.quad_instances.items.len,
            .layer_targets = self.renderer.document_live_attachments / 2,
            .stroke_divisions = geometry.curveDivs(100, std.math.pi, self.fringe_width * 0.25),
            .miter_limit = self.states.items[self.states.items.len - 1].miter_limit,
            .fringe_width = self.fringe_width,
            .tess_tol = self.tess_tol,
            .alpha = self.states.items[self.states.items.len - 1].alpha,
        };
    }

    /// Starts a new path, dropping the one under construction.
    pub fn beginPath(self: *Context) void {
        self.commands.clearRetainingCapacity();
        self.cache.reset();
    }

    /// Starts a subpath at `x, y`.
    pub fn moveTo(self: *Context, x: f32, y: f32) void {
        const p = self.transformPoint(x, y);
        self.appendPathCommand(.{ .move_to = p });
        self.cmd_x = p[0];
        self.cmd_y = p[1];
    }

    /// Adds a line from the current point to `x, y`. Before any `moveTo` it adds nothing.
    pub fn lineTo(self: *Context, x: f32, y: f32) void {
        const p = self.transformPoint(x, y);
        self.appendPathCommand(.{ .line_to = p });
        self.cmd_x = p[0];
        self.cmd_y = p[1];
    }

    /// Adds a cubic Bezier curve from the current point to `x, y`, with control points `c1x, c1y`
    /// and `c2x, c2y`.
    pub fn bezierTo(self: *Context, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        const cp1 = self.transformPoint(c1x, c1y);
        const cp2 = self.transformPoint(c2x, c2y);
        const ep = self.transformPoint(x, y);
        self.appendPathCommand(.{ .bezier_to = .{ cp1[0], cp1[1], cp2[0], cp2[1], ep[0], ep[1] } });
        self.cmd_x = ep[0];
        self.cmd_y = ep[1];
    }

    /// Adds a quadratic Bezier curve from the current point to `x, y`, with control point `cx, cy`,
    /// as the cubic that equals it. The current point is read as kept, in target pixels, and mixed
    /// with the arguments in current coordinates: the curve is right only while the transform is
    /// the identity.
    pub fn quadTo(self: *Context, cx: f32, cy: f32, x: f32, y: f32) void {
        const x0 = self.cmd_x;
        const y0 = self.cmd_y;
        self.bezierTo(
            x0 + 2.0 / 3.0 * (cx - x0),
            y0 + 2.0 / 3.0 * (cy - y0),
            x + 2.0 / 3.0 * (cx - x),
            y + 2.0 / 3.0 * (cy - y),
            x,
            y,
        );
    }

    /// Closes the current subpath: a line joins its last point to its first.
    pub fn closePath(self: *Context) void {
        self.appendPathCommand(.close);
    }

    /// Marks the current subpath solid (`.ccw`) or a hole (`.cw`).
    pub fn pathWinding(self: *Context, dir: Winding) void {
        self.appendPathCommand(.{ .winding = dir });
    }

    /// Adds a circular arc about `cx, cy` of radius `r`, from angle `a0` to `a1`, as lines of at
    /// most a twentieth of a turn each. `.ccw` sweeps through rising angles, which with y down is
    /// clockwise on screen; `.cw` through falling ones. A sweep of a full turn or more is one full
    /// turn. In an empty path the arc starts a subpath; otherwise a line joins the current point to
    /// the arc's start.
    pub fn arc(self: *Context, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, dir: Winding) void {
        const kNcap = 5;
        var a = a0;
        var da = a1 - a0;
        if (dir == .cw) {
            if (@abs(da) >= std.math.pi * 2.0) {
                da = -std.math.pi * 2.0;
            } else {
                while (da > 0) da -= std.math.pi * 2.0;
            }
        } else {
            if (@abs(da) >= std.math.pi * 2.0) {
                da = std.math.pi * 2.0;
            } else {
                while (da < 0) da += std.math.pi * 2.0;
            }
        }
        const n: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@abs(da) / (std.math.pi * 0.5 / @as(f32, kNcap))))));
        da /= @as(f32, @floatFromInt(n));

        var first = true;
        for (0..n + 1) |_| {
            const x = cx + @cos(a) * r;
            const y = cy + @sin(a) * r;
            if (first and self.commands.items.len == 0) {
                self.moveTo(x, y);
            } else {
                self.lineTo(x, y);
            }
            first = false;
            a += da;
        }
    }

    /// Adds an arc of `radius` that rounds the corner at `x1, y1` between the current point and
    /// `x2, y2`, with a line to where it starts. In an empty path it only moves to `x1, y1`; a
    /// corner too flat, too sharp or too small to round gets a line to `x1, y1`. Like `quadTo`, it
    /// reads the current point in target pixels and is right only while the transform is the
    /// identity.
    pub fn arcTo(self: *Context, x1: f32, y1: f32, x2: f32, y2: f32, radius: f32) void {
        if (self.commands.items.len == 0) {
            self.moveTo(x1, y1);
            return;
        }
        const x0 = self.cmd_x;
        const y0 = self.cmd_y;
        const tol = self.dist_tol;

        if (ptEquals(x0, y0, x1, y1, tol) or
            ptEquals(x1, y1, x2, y2, tol) or
            distPtSeg(x1, y1, x0, y0, x2, y2) < tol * tol or
            radius < tol)
        {
            self.lineTo(x1, y1);
            return;
        }

        var dx0 = x0 - x1;
        var dy0 = y0 - y1;
        var dx1 = x2 - x1;
        var dy1 = y2 - y1;
        normalize(&dx0, &dy0);
        normalize(&dx1, &dy1);

        const a = std.math.acos(std.math.clamp(dx0 * dx1 + dy0 * dy1, -1.0, 1.0));
        const half_tan = @tan(a * 0.5);
        if (@abs(half_tan) < 1e-6) {
            self.lineTo(x1, y1);
            return;
        }
        const d = radius / half_tan;
        if (d > 10000.0) {
            self.lineTo(x1, y1);
            return;
        }

        const cross = dx0 * dy1 - dy0 * dx1;
        var cx: f32 = undefined;
        var cy: f32 = undefined;
        var a0: f32 = undefined;
        var a1: f32 = undefined;
        var dir: Winding = undefined;
        if (cross > 0.0) {
            cx = x1 + dx0 * d + dy0 * radius;
            cy = y1 + dy0 * d - dx0 * radius;
            a0 = std.math.atan2(dx0, -dy0);
            a1 = std.math.atan2(-dx1, dy1);
            dir = .cw;
        } else {
            cx = x1 + dx0 * d - dy0 * radius;
            cy = y1 + dy0 * d + dx0 * radius;
            a0 = std.math.atan2(-dx0, dy0);
            a1 = std.math.atan2(dx1, -dy1);
            dir = .ccw;
        }
        self.arc(cx, cy, radius, a0, a1, dir);
    }

    /// Adds the rectangle with its top left at `x, y`, `w` wide and `h` high, as a closed subpath.
    pub fn rect(self: *Context, x: f32, y: f32, w: f32, h: f32) void {
        self.moveTo(x, y);
        self.lineTo(x, y + h);
        self.lineTo(x + w, y + h);
        self.lineTo(x + w, y);
        self.closePath();
    }

    /// Adds a rectangle with every corner rounded by `r`.
    pub fn roundedRect(self: *Context, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        self.roundedRectVarying(x, y, w, h, r, r, r, r);
    }

    /// Adds a rectangle with the corner radii `rtl`, `rtr`, `rbr` and `rbl`: top left, top right,
    /// bottom right, bottom left. Each corner is drawn with the smallest of its own radius and its
    /// two neighbours', and no radius is limited by the rectangle's size. Radii that sum to less
    /// than 0.001 give a plain `rect`.
    pub fn roundedRectVarying(
        self: *Context,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        rtl: f32,
        rtr: f32,
        rbr: f32,
        rbl: f32,
    ) void {
        if (rtl + rtr + rbr + rbl < 0.001) {
            self.rect(x, y, w, h);
            return;
        }
        const hl = @min(rtl, rbl);
        const hr = @min(rtr, rbr);
        const ht = @min(rtl, rtr);
        const hb = @min(rbl, rbr);
        const tl = @min(hl, ht);
        const tr = @min(hr, ht);
        const br = @min(hr, hb);
        const bl = @min(hl, hb);
        self.moveTo(x, y + tl);
        self.lineTo(x, y + h - bl);
        self.bezierTo(x, y + h - bl * (1 - 0.5523), x + bl * (1 - 0.5523), y + h, x + bl, y + h);
        self.lineTo(x + w - br, y + h);
        self.bezierTo(x + w - br * (1 - 0.5523), y + h, x + w, y + h - br * (1 - 0.5523), x + w, y + h - br);
        self.lineTo(x + w, y + tr);
        self.bezierTo(x + w, y + tr * (1 - 0.5523), x + w - tr * (1 - 0.5523), y, x + w - tr, y);
        self.lineTo(x + tl, y);
        self.bezierTo(x + tl * (1 - 0.5523), y, x, y + tl * (1 - 0.5523), x, y + tl);
        self.closePath();
    }

    /// Adds the ellipse about `cx, cy` with radii `rx` and `ry`, as a closed subpath of four
    /// curves.
    pub fn ellipse(self: *Context, cx: f32, cy: f32, rx: f32, ry: f32) void {
        const kappa = 0.5523;
        self.moveTo(cx - rx, cy);
        self.bezierTo(cx - rx, cy + ry * kappa, cx - rx * kappa, cy + ry, cx, cy + ry);
        self.bezierTo(cx + rx * kappa, cy + ry, cx + rx, cy + ry * kappa, cx + rx, cy);
        self.bezierTo(cx + rx, cy - ry * kappa, cx + rx * kappa, cy - ry, cx, cy - ry);
        self.bezierTo(cx - rx * kappa, cy - ry, cx - rx, cy - ry * kappa, cx - rx, cy);
        self.closePath();
    }

    /// Adds the circle about `cx, cy` of radius `r`.
    pub fn circle(self: *Context, cx: f32, cy: f32, r: f32) void {
        self.ellipse(cx, cy, r, r);
    }

    /// Fills the path with the fill paint, by the nonzero rule over its subpaths' windings, and
    /// leaves the path as it is. A path that cannot be flattened, or no memory for the draw,
    /// records nothing that draws.
    pub fn fill(self: *Context) void {
        const s = self.state();
        const paint = s.fill; // Global alpha is applied once in makePaintUniforms.

        geometry.flattenPaths(
            self.allocator(),
            &self.cache,
            self.commands.items,
            self.tess_tol,
            self.dist_tol,
        ) catch return;

        const fringe = if (s.shape_antialias) self.fringe_width else 0.0;

        for (self.cache.paths.items) |*sp| {
            geometry.expandFill(&self.cache, sp, fringe, s.miter_limit) catch return;
        }

        draw_list.appendFill(
            self,
            &paint,
            s.*,
            fringe,
        ) catch return;
    }

    /// Strokes the path with the stroke paint, its glow beneath when one is set, and leaves the
    /// path as it is. The width is `State.stroke_width` scaled by the transform's mean scale and
    /// limited to 200 target pixels; a stroke thinner than the antialiasing fringe is drawn that
    /// wide and fainter. A subpath of one point draws nothing. A path that cannot be flattened, or
    /// no memory for the draw, records nothing that draws.
    pub fn stroke(self: *Context) void {
        const s = self.state();
        const scale_factor = getAverageScale(s.xform);
        const stroke_width = std.math.clamp(s.stroke_width * scale_factor, 0, kMaxStrokeWidth);
        var paint = s.stroke; // Keep only thin-stroke coverage here, not global alpha.

        const fringe = if (s.shape_antialias) self.fringe_width else 0.0;
        const aa = fringe;
        const width = if (stroke_width < aa) blk: {
            const alpha = std.math.clamp(stroke_width / aa, 0, 1);
            paint.inner_color.a *= alpha * alpha;
            paint.outer_color.a *= alpha * alpha;
            break :blk aa;
        } else stroke_width;

        geometry.flattenPaths(
            self.allocator(),
            &self.cache,
            self.commands.items,
            self.tess_tol,
            self.dist_tol,
        ) catch return;

        // Beneath the stroke, whose own edge then covers where the glow begins.
        const glow_radius = s.stroke_glow_radius * scale_factor;
        if (glow_radius > 0 and s.stroke_glow_color.a > 0) {
            const half_extent = @min(width * 0.5 + glow_radius, kMaxStrokeWidth * 0.5);
            const glow_paint = paint_mod.solidColor(s.stroke_glow_color);
            var glow_state = s.*;
            glow_state.line_join = .round;
            glow_state.line_cap = .round;
            for (self.cache.paths.items) |*sp| {
                geometry.expandStroke(&self.cache, sp, fringe, half_extent, .round, .round, s.miter_limit) catch return;
            }
            draw_list.appendStroke(self, &glow_paint, glow_state, half_extent * 2, fringe, half_extent - width * 0.5) catch return;
        }

        for (self.cache.paths.items) |*sp| {
            geometry.expandStroke(
                &self.cache,
                sp,
                fringe,
                width * 0.5,
                s.line_cap,
                s.line_join,
                s.miter_limit,
            ) catch return;
        }

        draw_list.appendStroke(self, &paint, s.*, width, fringe, 0) catch return;
    }

    /// Opens a batch of rectangles and circles drawn in one call. Batches do not nest, a contract
    /// invariant; a batch must be closed before a layer begins or ends and before the frame ends.
    pub fn beginQuadBatch(self: *Context) void {
        draw_list.beginQuadBatch(self);
    }

    /// Adds a rectangle of `color` to the open batch; without one open, a contract invariant
    /// breaks. `x, y, w, h` are target pixels: neither the current transform nor the scissor
    /// applies. The current alpha does.
    pub fn fillRectBatched(self: *Context, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        const a = self.state().alpha;
        const dummy = self.renderer.dummy_slots;
        draw_list.appendQuadInstance(self, .{
            .pos = .{ x + w * 0.5, y + h * 0.5 },
            .extent = .{ w * 0.5, h * 0.5 },
            .radius = 0,
            .color = .{ color.r, color.g, color.b, color.a * a },
            .uvMin = .{ 0, 0 },
            .uvMax = .{ 1, 1 },
            .image = dummy.image,
            .sampler = dummy.sampler,
        });
    }

    /// Adds a circle of `color` about `cx, cy` of radius `r` to the open batch, in target pixels as
    /// `fillRectBatched`.
    pub fn fillCircleBatched(self: *Context, cx: f32, cy: f32, r: f32, color: Color) void {
        const a = self.state().alpha;
        const dummy = self.renderer.dummy_slots;
        draw_list.appendQuadInstance(self, .{
            .pos = .{ cx, cy },
            .extent = .{ r, r },
            .radius = r,
            .color = .{ color.r, color.g, color.b, color.a * a },
            .uvMin = .{ 0, 0 },
            .uvMax = .{ 1, 1 },
            .image = dummy.image,
            .sampler = dummy.sampler,
        });
    }

    /// Closes the batch and records its one draw call, which so draws after anything else recorded
    /// while the batch was open. Without a batch open, or with an empty one, records nothing.
    pub fn endQuadBatch(self: *Context) void {
        draw_list.endQuadBatch(self);
    }

    /// Sets `State.font_blur`, which nothing reads: text is drawn as baked.
    pub fn fontBlur(self: *Context, blur: f32) void {
        self.state().font_blur = blur;
    }

    /// Sets the space `text` adds after each glyph, in current coordinates. `measureText` does not
    /// count it.
    pub fn textLetterSpacing(self: *Context, spacing: f32) void {
        self.state().letter_spacing = spacing;
    }

    /// Sets `State.line_height`, which nothing reads: `text` draws one line.
    pub fn textLineHeight(self: *Context, height: f32) void {
        self.state().line_height = height;
    }

    /// Sets where text sits against the x that `text` is given (see `Align`).
    pub fn textAlign(self: *Context, a: Align) void {
        self.state().text_align = a;
    }

    /// Sets the font `text` draws in, by the name it was loaded under.
    pub fn fontFace(self: *Context, name: Atom) void {
        self.state().font_name = name;
    }

    /// The size of `str` in the font `name`: `w` the sum of its glyphs' advances, `h` the font's
    /// pixel height, in the units the font was baked in. Letter spacing and the transform are not
    /// counted. Codepoints the font lacks, and bytes that are not UTF-8, add nothing. Zero both
    /// ways when the font is not loaded.
    pub fn measureText(self: *const Context, name: Atom, str: []const u8) struct { w: f32, h: f32 } {
        const provider = self.renderer.font_provider orelse return .{ .w = 0, .h = 0 };
        const font = provider.get(name) orelse return .{ .w = 0, .h = 0 };
        var w: f32 = 0;
        var i: usize = 0;
        while (nextCodepointLossy(str, &i)) |cp| {
            const glyph = font.glyph(cp) orelse continue;
            w += glyph.xadvance;
        }
        return .{ .w = w, .h = font.pixel_height };
    }

    /// How far the font `name` reaches above the baseline: the highest of its glyphs with ink. Zero
    /// when the font is not loaded. It looks at every glyph of the font on each call.
    pub fn fontAscender(self: *const Context, name: Atom) f32 {
        const provider = self.renderer.font_provider orelse return 0;
        const font = provider.get(name) orelse return 0;
        return font.metrics().ascender;
    }

    /// The height of the font's capital letters above the baseline: its `H`'s. A font
    /// without one, as an icon font, gives its ascender.
    pub fn fontCapHeight(self: *const Context, name: Atom) f32 {
        const provider = self.renderer.font_provider orelse return 0;
        const font = provider.get(name) orelse return 0;
        return font.metrics().cap_height;
    }

    /// Where the baseline of a line of `name` goes, from the top of a box `box_height` tall,
    /// so its capital letters sit in the box's middle, as the eye centers text: a box laid
    /// out around a line is taller than its capitals by the room for descenders, and text set
    /// at its ascender sits high. A font without capitals,
    /// as an icon font, is set at its ascender, its glyphs already filling the box.
    pub fn fontBaseline(self: *const Context, name: Atom, box_height: f32) f32 {
        const provider = self.renderer.font_provider orelse return 0;
        const font = provider.get(name) orelse return 0;
        const capital = font.glyph('H') orelse return self.fontAscender(name);
        if (capital.x0 == capital.x1) return self.fontAscender(name);
        const cap_height = -capital.yoff;
        // Down to a whole pixel: of the two nearest, the higher reads as centered.
        return @floor((box_height + cap_height) / 2);
    }

    /// How far `str`'s glyphs reach above the baseline (`top`, negative) and below it
    /// (`bottom`): what a label centered by its ink, as a badge's, is centered by. Zero for
    /// text with no ink.
    pub fn textInk(self: *const Context, name: Atom, str: []const u8) struct { top: f32, bottom: f32 } {
        const provider = self.renderer.font_provider orelse return .{ .top = 0, .bottom = 0 };
        const font = provider.get(name) orelse return .{ .top = 0, .bottom = 0 };
        var top: f32 = std.math.inf(f32);
        var bottom: f32 = -std.math.inf(f32);
        var i: usize = 0;
        while (nextCodepointLossy(str, &i)) |cp| {
            const glyph = font.glyph(cp) orelse continue;
            if (glyph.x0 == glyph.x1) continue;
            const height: f32 = @floatFromInt(glyph.y1 - glyph.y0);
            top = @min(top, glyph.yoff);
            bottom = @max(bottom, glyph.yoff + height);
        }
        if (top > bottom) return .{ .top = 0, .bottom = 0 };
        return .{ .top = top, .bottom = bottom };
    }

    /// Draws `str` in the current font with the fill paint's inner color, its baseline at `y` and
    /// its start, center or end at `x` by the current alignment, and returns the x where the next
    /// glyph would start. Each glyph is a quad from the font's atlas at the size it was baked,
    /// placed by the current transform; under a transform that only translates, glyphs are set on
    /// whole pixels while advances stay fractional. The scissor applies. Codepoints the font lacks
    /// are skipped, as are bytes that are not UTF-8. With the font not loaded it draws nothing and
    /// returns `x`; with no memory it returns where it stopped.
    pub fn text(self: *Context, x: f32, y: f32, str: []const u8) f32 {
        const s = self.state();
        const provider = self.renderer.font_provider orelse return x;
        const font = provider.get(s.font_name) orelse return x;
        const atlas_size: f32 = @floatFromInt(font_mod.kAtlasSize);

        var total_advance: f32 = 0;
        if (s.text_align.center or s.text_align.right) {
            var align_i: usize = 0;
            while (nextCodepointLossy(str, &align_i)) |cp| {
                const bc = font.glyph(cp) orelse continue;
                total_advance += bc.xadvance + s.letter_spacing;
            }
        }

        var cx: f32 = x;
        if (s.text_align.center) cx -= total_advance * 0.5;
        if (s.text_align.right) cx -= total_advance;

        var fill_color = s.fill.inner_color;
        fill_color.a *= s.alpha;

        const vert_base: u32 = @intCast(self.verts.items.len);

        // The atlas holds one texel per pixel, and a bilinear sample between pixels smears
        // each stem across two. Text drawn at atlas scale lands on whole pixels; advances
        // stay fractional so `measureText` still describes where the next glyph falls.
        const pixel_aligned = s.xform[0] == 1 and s.xform[1] == 0 and s.xform[2] == 0 and s.xform[3] == 1;

        var glyph_i: usize = 0;
        while (nextCodepointLossy(str, &glyph_i)) |cp| {
            const bc = font.glyph(cp) orelse continue;

            const s0 = @as(f32, @floatFromInt(bc.x0)) / atlas_size;
            const t0 = @as(f32, @floatFromInt(bc.y0)) / atlas_size;
            const s1 = @as(f32, @floatFromInt(bc.x1)) / atlas_size;
            const t1 = @as(f32, @floatFromInt(bc.y1)) / atlas_size;

            const px = cx + bc.xoff;
            const py = y + bc.yoff;
            const pw: f32 = @floatFromInt(bc.x1 - bc.x0);
            const ph: f32 = @floatFromInt(bc.y1 - bc.y0);

            var tl = transform.point(s.xform, px, py);
            var tr = transform.point(s.xform, px + pw, py);
            var bl = transform.point(s.xform, px, py + ph);
            var br = transform.point(s.xform, px + pw, py + ph);
            if (pixel_aligned) {
                tl = .{ @round(tl[0]), @round(tl[1]) };
                tr = .{ tl[0] + pw, tl[1] };
                bl = .{ tl[0], tl[1] + ph };
                br = .{ tl[0] + pw, tl[1] + ph };
            }

            draw_list.requireAppendCapacity("roop.producer.cpu_vertex_limit", self.verts.items.len, 6, draw_list.kMaxCpuVerticesPerFrame);

            self.verts.append(self.allocator(), .{ .x = tl[0], .y = tl[1], .u = s0, .v = t0 }) catch return cx;
            self.verts.append(self.allocator(), .{ .x = tr[0], .y = tr[1], .u = s1, .v = t0 }) catch return cx;
            self.verts.append(self.allocator(), .{ .x = bl[0], .y = bl[1], .u = s0, .v = t1 }) catch return cx;

            self.verts.append(self.allocator(), .{ .x = tr[0], .y = tr[1], .u = s1, .v = t0 }) catch return cx;
            self.verts.append(self.allocator(), .{ .x = br[0], .y = br[1], .u = s1, .v = t1 }) catch return cx;
            self.verts.append(self.allocator(), .{ .x = bl[0], .y = bl[1], .u = s0, .v = t1 }) catch return cx;

            cx += bc.xadvance + s.letter_spacing;
        }

        const vert_count: u32 = @intCast(self.verts.items.len - vert_base);
        if (vert_count == 0) return cx;

        const scissor_rows = transform.toRows(s.scissor_xform);
        const scissor_ext = s.scissor_extent;
        const has_scissor = scissor_ext[0] > -0.5;
        const fringe = self.fringe_width;
        const scissor_scale: [2]f32 = if (has_scissor) .{
            @sqrt(s.scissor_xform[0] * s.scissor_xform[0] + s.scissor_xform[2] * s.scissor_xform[2]) / fringe,
            @sqrt(s.scissor_xform[1] * s.scissor_xform[1] + s.scissor_xform[3] * s.scissor_xform[3]) / fringe,
        } else .{ 1, 1 };

        draw_list.requireAppendCapacity("roop.producer.uniform_limit", self.uniforms.items.len, 1, draw_list.kMaxUniformsPerFrame);
        draw_list.requireAppendCapacity("roop.producer.call_limit", self.calls.items.len, 1, draw_list.kMaxDrawCallsPerFrame);
        const uniform_offset: u32 = @intCast(self.uniforms.items.len);
        self.uniforms.append(self.allocator(), draw_list.PaintUniforms{
            .scissorMat = scissor_rows,
            .paintMat = transform.toRows(transform.identity()),
            .innerCol = color_mod.toArray(fill_color),
            .outerCol = color_mod.toArray(fill_color),
            .scissorExt = if (has_scissor) scissor_ext else .{ 1e5, 1e5 },
            .scissorScale = scissor_scale,
            .scissorRadius = if (has_scissor) s.scissor_radius else 0,
            .texType = 2,
            .type = 3,
        }) catch return cx;

        self.calls.append(self.allocator(), draw_list.DrawCall{
            .kind = .triangles,
            .image = font.image,
            .uniform_offset = uniform_offset,
            .vertex_offset = vert_base,
            .vertex_count = vert_count,
            .cover_offset = 0,
            .cover_count = 0,
            .path_first = 0,
            .path_count = 0,
            .triangle_type = false,
            .stroke_mult = 1.0,
            .stroke_thr = -1.0,
            .extent = .{ 0, 0 },
            .radius = 0,
            .feather = 1,
        }) catch return cx;

        return cx;
    }

    fn appendPathCommand(self: *Context, command: path_mod.Command) void {
        path_mod.validateCommandCapacity(self.commands.items.len, 1) catch contract.invariant(false, "roop.path.command_limit");
        self.commands.append(self.allocator(), command) catch @panic("OOM");
    }

    fn transformPoint(self: *Context, x: f32, y: f32) [2]f32 {
        return transform.point(self.state().xform, x, y);
    }
};

fn listBytes(list: anytype) usize {
    return list.capacity * @sizeOf(@TypeOf(list.items[0]));
}

fn rebuiltList(comptime T: type, allocator: std.mem.Allocator, list: std.ArrayList(T)) std.mem.Allocator.Error!std.ArrayList(T) {
    var rebuilt: std.ArrayList(T) = .empty;
    try rebuilt.ensureTotalCapacityPrecise(allocator, list.capacity);
    rebuilt.appendSliceAssumeCapacity(list.items);
    return rebuilt;
}

fn getAverageScale(t: Transform2D) f32 {
    const sx = @sqrt(t[0] * t[0] + t[2] * t[2]);
    const sy = @sqrt(t[1] * t[1] + t[3] * t[3]);
    return (sx + sy) * 0.5;
}

fn ptEquals(ax: f32, ay: f32, bx: f32, by: f32, tol: f32) bool {
    const dx = bx - ax;
    const dy = by - ay;
    return dx * dx + dy * dy < tol * tol;
}

fn distPtSeg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const ex = px - ax;
    const ey = py - ay;
    const d = dx * dx + dy * dy;
    var t = dx * ex + dy * ey;
    if (d > 0) t /= d;
    t = std.math.clamp(t, 0.0, 1.0);
    const fx = ax + t * dx - px;
    const fy = ay + t * dy - py;
    return fx * fx + fy * fy;
}

fn normalize(x: *f32, y: *f32) void {
    const d = @sqrt(x.* * x.* + y.* * y.*);
    if (d > 1e-6) {
        x.* /= d;
        y.* /= d;
    }
}

test "pathBudget reports frame headroom independently of resettable path capacity" {
    // Only CPU accounting fields are read; no render target or GPU is created.
    var ctx: Context = undefined;
    var calls: [1]draw_list.DrawCall = undefined;
    var uniforms: [1]draw_list.PaintUniforms = undefined;
    var points: [3]draw_list.PointGpu = undefined;
    var shapes: [2]draw_list.ShapeArgs = undefined;
    var vertices: [6]draw_list.Vertex = undefined;
    var states: [4]State = undefined;
    var renderer: Renderer = .{};
    ctx.renderer = &renderer;
    ctx.calls = .{ .items = &calls, .capacity = calls.len };
    ctx.uniforms = .{ .items = &uniforms, .capacity = uniforms.len };
    ctx.gpu_points = .{ .items = &points, .capacity = points.len };
    ctx.shape_args = .{ .items = &shapes, .capacity = shapes.len };
    ctx.verts = .{ .items = &vertices, .capacity = vertices.len };
    ctx.gpu_vert_used = 12;
    ctx.gpu_indirect_used = 1;
    ctx.states = .{ .items = &states, .capacity = states.len };
    states[3].alpha = 0.5;
    ctx.tess_tol = 0.125;
    ctx.fringe_width = 0.5;
    const budget = ctx.pathBudget();
    try std.testing.expectEqual(path_mod.kMaxPaths, budget.paths);
    try std.testing.expectEqual(path_mod.kMaxPathCommands, budget.commands);
    try std.testing.expectEqual(path_mod.kMaxFlattenedPoints, budget.points);
    try std.testing.expectEqual(draw_list.kMaxDrawCallsPerFrame - 1, budget.draws);
    try std.testing.expectEqual(draw_list.kMaxUniformsPerFrame - 1, budget.uniforms);
    try std.testing.expectEqual(draw_list.kMaxGpuPointsPerFrame - 3, budget.gpu_points);
    try std.testing.expectEqual(draw_list.kMaxGpuShapesPerFrame - 2, budget.shapes);
    try std.testing.expectEqual(draw_list.kMaxGpuVerticesPerFrame - 12, budget.gpu_vertices);
    try std.testing.expectEqual(draw_list.kMaxCpuVerticesPerFrame - 6, budget.cpu_vertices);
    try std.testing.expectEqual(draw_list.kMaxGpuIndirectDrawsPerFrame - 1, budget.indirect_draws);
    try std.testing.expectEqual(@as(usize, 12), budget.layer_targets);
    try std.testing.expectEqual(@as(f32, 0.5), budget.alpha);
    try std.testing.expectEqual(@as(f32, 0.125), budget.tess_tol);
    ctx.gpu_vert_used = draw_list.kMaxGpuVerticesPerFrame + 1;
    try std.testing.expectEqual(@as(usize, 0), ctx.pathBudget().gpu_vertices);
}

test "layer and save stacks grow past their former limits and a refused save stays balanced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var renderer: Renderer = .{};
    const ctx_allocator = arena.allocator();
    var ctx = try Context.initWithoutTarget(&renderer, &ctx_allocator);

    for (0..40) |_| try ctx.beginLayer(.{});
    try std.testing.expectEqual(@as(usize, 40), ctx.layerDepth());
    for (0..40) |_| try ctx.endLayer();
    try std.testing.expectEqual(@as(usize, 0), ctx.layerDepth());

    // Each level holds its own state.
    for (0..40) |level| {
        ctx.globalAlpha(@floatFromInt(level));
        ctx.save();
    }
    for (0..40) |level| {
        ctx.restore();
        try std.testing.expectEqual(@as(f32, @floatFromInt(39 - level)), ctx.states.items[ctx.states.items.len - 1].alpha);
    }

    // With no page for the copy, the state stands in and the restore matches its save.
    // A page returning before the restores must not put a backed save above the unbacked one.
    var backing: CountingBacking = .{ .child = arena.allocator() };
    const counting = backing.allocator();
    ctx.lists = .wrap(&counting);
    ctx.states = .{ .items = ctx.states.items, .capacity = ctx.states.items.len };
    const depth = ctx.states.items.len;
    ctx.globalAlpha(0.25);
    backing.refuse = true;
    ctx.save();
    backing.refuse = false;
    ctx.save();
    try std.testing.expectEqual(depth, ctx.states.items.len);
    ctx.restore();
    ctx.restore();
    try std.testing.expectEqual(depth, ctx.states.items.len);
    try std.testing.expectEqual(@as(f32, 0.25), ctx.states.items[depth - 1].alpha);
    // Balanced again, so an ordinary save and restore work on the same stack.
    ctx.save();
    try std.testing.expectEqual(depth + 1, ctx.states.items.len);
    ctx.globalAlpha(0.5);
    ctx.restore();
    try std.testing.expectEqual(@as(f32, 0.25), ctx.states.items[depth - 1].alpha);
}

/// Live backing bytes and every call, standing in for the host's page context.
const CountingBacking = struct {
    child: std.mem.Allocator,
    live_bytes: usize = 0,
    operations: usize = 0,
    refuse: bool = false,

    fn allocator(self: *CountingBacking) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingBacking = @ptrCast(@alignCast(context));
        self.operations += 1;
        if (self.refuse) return null;
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.live_bytes += len;
        return result;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingBacking = @ptrCast(@alignCast(context));
        self.operations += 1;
        if (self.refuse or !self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingBacking = @ptrCast(@alignCast(context));
        self.operations += 1;
        self.child.rawFree(memory, alignment, return_address);
        self.live_bytes -= memory.len;
    }
};

/// Every page the source mapped, unmapped or resized.
fn pageOperations(source: *const memory_mod.PageSource) usize {
    const allocations = source.allocations.load(.monotonic);
    const deallocations = source.deallocations.load(.monotonic);
    const resizes = source.resizes.load(.monotonic);
    return allocations + deallocations + resizes;
}

fn appendVertices(ctx: *Context, count: usize) !void {
    for (0..count) |index| {
        const position: f32 = @floatFromInt(index);
        try ctx.verts.append(ctx.allocator(), .{ .x = position, .y = position, .u = 0, .v = 0 });
    }
}

test "context growth reclaims old generations, keeps the path and is free once steady" {
    var source: memory_mod.PageSource = .{};
    var pages: memory_mod.PageBacking = .{ .upstream = .{ .source = &source } };
    var renderer: Renderer = .{};
    var ctx: Context = undefined;
    try ctx.initLists(&renderer, 64, 64, &pages);
    defer ctx.storage.?.deinit();

    // Each round doubles the peak. A never-reset arena would keep every abandoned buffer.
    var peak: usize = 512;
    for (0..7) |_| {
        ctx.beginFrame(64, 64, 1, undefined);
        try appendVertices(&ctx, peak);
        peak *= 2;
    }
    ctx.beginFrame(64, 64, 1, undefined);
    const list_bytes = ctx.listCapacityBytes();
    try std.testing.expect(list_bytes >= peak / 2 * @sizeOf(draw_list.Vertex));
    try std.testing.expect(pages.stats().current_bytes <= 3 * list_bytes);

    // A steady workload after that touches the backing not at all.
    ctx.beginFrame(64, 64, 1, undefined);
    const operations = pageOperations(&source);
    for (0..100) |_| {
        ctx.beginFrame(64, 64, 1, undefined);
        try appendVertices(&ctx, peak / 2);
        ctx.save();
        ctx.restore();
    }
    try std.testing.expectEqual(operations, pageOperations(&source));

    // The path being built and the current state outlive a compaction.
    ctx.beginPath();
    ctx.moveTo(3, 4);
    try appendVertices(&ctx, 4 * peak);
    ctx.beginFrame(64, 64, 1, undefined);
    try std.testing.expectEqual(@as(usize, 1), ctx.commands.items.len);
    try std.testing.expectEqual(@as(f32, 3), ctx.commands.items[0].move_to[0]);
    try std.testing.expect(pages.stats().current_bytes <= 3 * ctx.listCapacityBytes());
    try std.testing.expectEqual(@as(usize, 0), ctx.verts.items.len);
}

test "refused compaction keeps the current lists and tries again" {
    var source: memory_mod.PageSource = .{};
    var pages: memory_mod.PageBacking = .{ .upstream = .{ .source = &source } };
    var renderer: Renderer = .{};
    var ctx: Context = undefined;
    try ctx.initLists(&renderer, 64, 64, &pages);
    defer ctx.storage.?.deinit();

    ctx.beginPath();
    ctx.moveTo(5, 6);
    try appendVertices(&ctx, 4096);
    const retained = pages.stats().current_bytes;
    const capacity = ctx.verts.capacity;

    source.refuseAfter(0);
    ctx.beginFrame(64, 64, 1, undefined);
    source.refuseNone();
    try std.testing.expectEqual(retained, pages.stats().current_bytes);
    try std.testing.expectEqual(capacity, ctx.verts.capacity);
    try std.testing.expectEqual(@as(f32, 5), ctx.commands.items[0].move_to[0]);
    try appendVertices(&ctx, 16);
    try std.testing.expectEqual(@as(f32, 0), ctx.verts.items[0].x);

    ctx.beginFrame(64, 64, 1, undefined);
    try std.testing.expect(pages.stats().current_bytes < retained);
    try std.testing.expectEqual(capacity, ctx.verts.capacity);
    try std.testing.expectEqual(@as(f32, 5), ctx.commands.items[0].move_to[0]);
}

test "roop text uses listed and contiguous glyphs for measure alignment and drawing" {
    const Fixture = struct {
        view: resources_api.FontView,
        fn get(raw: *anyopaque, _: *const resources_api.ScopeId, _: Atom, font: *resources_api.FontView) callconv(.c) bool {
            const fixture: *@This() = @ptrCast(@alignCast(raw));
            font.* = fixture.view;
            return true;
        }
    };
    var legacy = std.mem.zeroes(font_mod.BakedChars);
    legacy[0].x1 = 2;
    legacy[0].y1 = 3;
    legacy[0].xadvance = 7;
    var listed = std.mem.zeroes([2]font_mod.Glyph);
    listed[0].x1 = 3;
    listed[0].y1 = 4;
    listed[0].xadvance = 11;
    listed[1].x1 = 4;
    listed[1].y1 = 5;
    listed[1].xadvance = 13;
    const codepoints = [_]u32{ 0xf01c0, 0xf1225 };
    var fixture: Fixture = .{ .view = .{
        .baked_chars = &legacy,
        .pixel_height = 20,
        .image = 1,
        .first_char = 32,
        .listed_codepoints = &codepoints,
        .listed_chars = &listed,
    } };
    var renderer: Renderer = .{ .font_provider = .{ .context = &fixture, .scope = .{ .atom = resources_api.kApplicationScope, .generation = 1 }, .get_fn = Fixture.get } };
    var context: Context = undefined;
    context.lists = .wrap(&std.testing.allocator);
    context.renderer = &renderer;
    var states = [_]State{defaultState()};
    context.states = .{ .items = &states, .capacity = states.len };
    context.fringe_width = 1;
    context.verts = .empty;
    context.calls = .empty;
    context.uniforms = .empty;
    defer context.verts.deinit(context.allocator());
    defer context.calls.deinit(context.allocator());
    defer context.uniforms.deinit(context.allocator());

    const measured = context.measureText(resources_api.kDefaultFontName, "\u{f01c0}?\u{f1225}");
    try std.testing.expectEqual(@as(f32, 24), measured.w);
    context.textAlign(.{ .center = true });
    try std.testing.expectEqual(@as(f32, 112), context.text(100, 20, "\u{f01c0}?\u{f1225}"));
    try std.testing.expectEqual(@as(usize, 12), context.verts.items.len);
    try std.testing.expectEqual(@as(f32, 88), context.verts.items[0].x);
    try std.testing.expectEqual(@as(f32, 99), context.verts.items[6].x);
    const before = context.verts.items.len;
    try std.testing.expectEqual(@as(f32, 100), context.text(100, 20, "?"));
    try std.testing.expectEqual(before, context.verts.items.len);

    fixture.view.listed_codepoints = &.{};
    fixture.view.listed_chars = &.{};
    const legacy_measure = context.measureText(resources_api.kDefaultFontName, " \u{f01c0}");
    try std.testing.expectEqual(@as(f32, 7), legacy_measure.w);
    context.textAlign(.{ .left = true });
    try std.testing.expectEqual(@as(f32, 107), context.text(100, 20, " \u{f01c0}"));
    try std.testing.expectEqual(before + 6, context.verts.items.len);

    // Atlas-scale text lands on whole pixels while its advance stays fractional.
    const aligned = context.verts.items.len;
    try std.testing.expectEqual(@as(f32, 107.4), context.text(100.4, 20.6, " "));
    try std.testing.expectEqual(@as(f32, 100), context.verts.items[aligned].x);
    try std.testing.expectEqual(@as(f32, 21), context.verts.items[aligned].y);
    try std.testing.expectEqual(@as(f32, 102), context.verts.items[aligned + 1].x);

    // Scaled text cannot stay on the pixel grid, so it keeps its exact position.
    const scaled = context.verts.items.len;
    context.state().xform[0] = 2;
    _ = context.text(10.25, 20, " ");
    try std.testing.expectEqual(@as(f32, 20.5), context.verts.items[scaled].x);
}

test "text recorded with a font that has not loaded records nothing" {
    const Unloaded = struct {
        fn get(_: *anyopaque, _: *const resources_api.ScopeId, _: Atom, _: *resources_api.FontView) callconv(.c) bool {
            return false;
        }
    };
    var provider_context: u8 = 0;
    var renderer: Renderer = .{ .font_provider = .{ .context = &provider_context, .scope = .{ .atom = resources_api.kApplicationScope, .generation = 1 }, .get_fn = Unloaded.get } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = arena.allocator();
    var ctx = try Context.initWithoutTarget(&renderer, &lists);
    ctx.beginFrame(64, 64, 1, .wrap(&lists));

    try std.testing.expectEqual(@as(f32, 10), ctx.text(10, 20, "abc"));
    try std.testing.expectEqual(@as(usize, 0), ctx.calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.verts.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.uniforms.items.len);
}

test "text with a codepoint the font lacks skips that glyph" {
    const Ascii = struct {
        view: resources_api.FontView,
        fn get(raw: *anyopaque, _: *const resources_api.ScopeId, _: Atom, font: *resources_api.FontView) callconv(.c) bool {
            const fixture: *@This() = @ptrCast(@alignCast(raw));
            font.* = fixture.view;
            return true;
        }
    };
    var ascii = std.mem.zeroes(font_mod.BakedChars);
    for ("ab") |letter| {
        const glyph = &ascii[letter - font_mod.kFirstChar];
        glyph.x1 = 5;
        glyph.y1 = 7;
        glyph.xadvance = 6;
    }
    var fixture: Ascii = .{ .view = .{ .baked_chars = &ascii, .pixel_height = 12, .image = 1, .first_char = font_mod.kFirstChar } };
    var renderer: Renderer = .{ .font_provider = .{ .context = &fixture, .scope = .{ .atom = resources_api.kApplicationScope, .generation = 1 }, .get_fn = Ascii.get } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = arena.allocator();
    var ctx = try Context.initWithoutTarget(&renderer, &lists);
    ctx.beginFrame(64, 64, 1, .wrap(&lists));

    try std.testing.expectEqual(@as(f32, 12), ctx.text(0, 20, "a\u{2603}b"));
    try std.testing.expectEqual(@as(usize, 2 * 6), ctx.verts.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls.items.len);
    try std.testing.expectEqual(@as(f32, 6), ctx.verts.items[6].x);
}
