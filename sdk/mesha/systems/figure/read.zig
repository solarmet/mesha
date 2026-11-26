//! A figure document's authored content as plain values, for an inspector, a canvas or a
//! timeline to read: what the figure host publishes for a watch that wants it
//! (`figure.Published.content`), and what `mesha_runtime.figure`'s `readDefinition` copies out of a
//! document's tables. Nothing here points into a table: a `Definition`'s rows hold only values, in
//! slices whoever made it owns. A copy a reader made it keeps for as long as it likes while the
//! document goes on changing; a published one lasts until the host next publishes.
//!
//! A document is rows of a few families. A rig is `Bone`s, each in its parent's space, with `IK`
//! controllers over chains of them. Artwork is `Shape`s in `Layer`s; a shape is a path of `Point`s
//! or a primitive, coloured solid or by a `Paint`, and may be bound to bones. A `Pose` gives bones,
//! controllers and properties values (`PoseChannel`, `PoseIK`, `PoseProperty`); pose 0 is the
//! working pose, the one being edited, and has no `Pose` row. A `Clip` is `ClipKey`s, each putting
//! a pose at a frame.
//!
//! Every row of a document has an id from one counter, so no two rows of any family share one; 0
//! means none. Ids stay with their rows for the document's life and are what commands
//! (`figure.Payload`) name. Lengths and positions are in the document's units and angles in
//! radians. Names are atoms, snake_case and unique within their family: bones, layers, shapes,
//! paints, controllers, poses and clips each have a name.
//!
//! `projectOutliner` arranges a `Definition`'s rows as the tree an outliner shows, and
//! `layer_order` is the order layers draw in; both are pure functions of the rows they are given.
const std = @import("std");
const Atom = @import("../../core/atom.zig").Atom;
const Vec2 = @import("../../core/math.zig").Vec2f;
const figure = @import("../figure.zig");
const Color = [4]u8;
const none: Atom = @enumFromInt(0);
const zero = Vec2{ .x = 0, .y = 0 };
const one = Vec2{ .x = 1, .y = 1 };
/// The bits of `Bone.flags`.
pub const BoneFlags = struct {
    /// The bone starts at its parent's tip: its `local` is zero and stays so. A bone without a
    /// parent cannot be connected.
    pub const connected: u32 = 1;
    /// The bone may carry skin weights: only such a bone is an influence of a skinned shape's
    /// points.
    pub const deform: u32 = 2;
    /// Poses do not move the bone: its pose channels are ignored, and it cannot be in an IK chain.
    pub const static: u32 = 4;
    /// A pose may change the bone's length; without it a pose's length channel is ignored. A
    /// stretching IK controller needs it on every bone of its chain.
    pub const stretchy: u32 = 8;
    /// The outliner lists the bone and its descendants as not visible.
    pub const hidden: u32 = 16;
};
/// The bits of `PoseChannel.mask`: which of the channel's values the pose sets.
pub const Channels = struct {
    /// `PoseChannel.rotation` is set.
    pub const rotation: u32 = 1;
    /// `PoseChannel.local` is set.
    pub const local: u32 = 2;
    /// `PoseChannel.scale` is set.
    pub const scale: u32 = 4;
    /// `PoseChannel.length` is set.
    pub const length: u32 = 8;
};
/// Where a document or a sketch is in its life, as its catalog row's `state` cell holds it:
/// `absent` (no document), `loading` (its file is being read), `ready`, or `failed` (the load
/// failed; the row's error text says why).
pub const State = enum(u32) { absent, loading, ready, failed };
/// A bone of the rig: a transform in its parent's space and a length along its own x axis.
pub const Bone = struct {
    /// The bone's id.
    id: u32 = 0,
    /// The bone's name.
    name: Atom = none,
    /// The parent bone's id; 0 for a root, whose space is the document's.
    parent: u32 = 0,
    /// Where the bone starts, in its parent's space. Zero for a connected bone, which starts at its
    /// parent's tip.
    local: Vec2 = zero,
    /// Its rotation in its parent's space, in radians.
    rotation: f32 = 0,
    /// Its length, from its origin to its tip along its x axis; never negative.
    length: f32 = 0,
    /// Its scale in its parent's space; neither component may be zero.
    scale: Vec2 = one,
    /// `BoneFlags` bits.
    flags: u32 = BoneFlags.deform,
    /// The colour an editor draws the bone in, RGBA.
    display_color: Color = .{ 230, 70, 65, 255 },
    /// Its place among the bones of its parent, lowest first, in the outliner; ties go by id.
    sibling_order: u32 = 0,
};
/// A layer of artwork, or a folder of layers.
pub const Layer = struct {
    /// The layer's id.
    id: u32 = 0,
    /// The layer's name.
    name: Atom = none,
    /// `vector`, a layer of shapes, or `folder`, a group of layers.
    kind: Atom = Atom.from("vector"),
    /// The folder it is in; 0 for a layer at the root. Folders do not nest.
    parent: u32 = 0,
    /// Its place among the layers of its parent: lower draws first, beneath the rest.
    order: u32 = 0,
    /// 0 hides the layer and what is in it.
    visible: u8 = 1,
    /// Nonzero refuses edits to the layer's shapes, and to those of the layers in it.
    locked: u8 = 0,
    /// 0 to 1, applied to the layer as a whole.
    opacity: f32 = 1,
    /// How the layer is composited over what is beneath it, by name; `normal` by default.
    blend: Atom = Atom.from("normal"),
    /// Nonzero clips the layer to the layer beneath it.
    clip_to_below: u8 = 0,
};
/// A piece of artwork: a path of points or a primitive, its colours, and how it follows the rig.
pub const Shape = struct {
    /// The shape's id.
    id: u32 = 0,
    /// The shape's name.
    name: Atom = none,
    /// The layer it is in.
    layer: u32 = 0,
    /// Its place among its layer's shapes: lower draws first.
    order: u32 = 0,
    /// What the shape is. `path`: its points, joined by cubic segments. `line`: a primitive from
    /// `start` to `end`, drawn as `stroke_kind` says. `bone_stroke`: a primitive along the bone
    /// `bone`, from its origin to its tip. `joint_fill`: a filled polygon whose points each sit at
    /// an end of a bone.
    kind: Atom = Atom.from("path"),
    /// Nonzero joins the path's last point to its first.
    closed: u8 = 0,
    /// How the shape follows the rig: `none`, `rigid` (it moves as the bone `bone` does) or
    /// `skinned` (each point moves by its weighted bones).
    binding: Atom = Atom.from("none"),
    /// The bone a rigid shape or a bone stroke follows; 0 otherwise.
    bone: u32 = 0,
    /// How a `line` or `bone_stroke` is drawn between its two ends: `line`, `square_line` (a line
    /// with square caps), `circle` (the circle whose diameter they are) or `circle_fill` (that
    /// circle, filled).
    stroke_kind: Atom = Atom.from("line"),
    /// The fill's colour, RGBA; alpha 0 with no `fill_paint` fills nothing.
    fill_color: Color = .{ 0, 0, 0, 0 },
    /// The stroke's colour, RGBA; alpha 0 with no `stroke_paint` strokes nothing.
    stroke_color: Color = .{ 148, 82, 210, 255 },
    /// The stroke's width in document units; 0 strokes nothing.
    stroke_width: f32 = 12,
    /// A soft edge bleeding outward from the stroke, in the stroke's units. Zero draws none.
    stroke_glow_radius: f32 = 0,
    /// The glow's colour, RGBA.
    stroke_glow_color: Color = .{ 255, 255, 255, 160 },
    /// How an open stroke ends: `butt`, `round` or `square`.
    cap: Atom = Atom.from("round"),
    /// How a stroke turns a corner: `miter`, `round` or `bevel`.
    join: Atom = Atom.from("round"),
    /// 0 to 1, applied to the whole shape.
    opacity: f32 = 1,
    /// 0 hides the shape.
    visible: u8 = 1,
    /// The `Paint` that fills the shape in place of `fill_color`; 0 for none.
    fill_paint: u32 = 0,
    /// The `Paint` that strokes the shape in place of `stroke_color`; 0 for none.
    stroke_paint: u32 = 0,
    /// The first end of a `line` primitive, in bind space: the document's space while the rig is at
    /// rest.
    start: Vec2 = zero,
    /// The other end of a `line` primitive, in bind space.
    end: Vec2 = zero,
};
/// A point of a shape's path, in bind space: the document's space while the rig is at rest. For a
/// `joint_fill` it is a corner of the polygon instead, placed from a bone.
pub const Point = struct {
    /// The shape the point is in.
    shape: u32 = 0,
    /// Its place in the path, from 0 with no gaps.
    index: u32 = 0,
    /// The point's position; for a `joint_fill`, its offset from the joint in the joint bone's
    /// space.
    p: Vec2 = zero,
    /// The handle of the segment arriving at the point, as an offset from `p`; zero for a corner.
    in: Vec2 = zero,
    /// The handle of the segment leaving the point, as an offset from `p`.
    out: Vec2 = zero,
    /// Bits kept with the point as authored.
    flags: u32 = 0,
    /// A width at the point, never negative, interpolated along the path between points.
    width: f32 = 1,
    /// For a `joint_fill`, the bone whose end the point sits at; 0 otherwise.
    joint_bone: u32 = 0,
    /// For a `joint_fill`, which end of `joint_bone`: 0 its origin, 1 its tip.
    joint_end: u8 = 1,
    /// For a skinned shape, the bones that move the point, up to four; a slot with weight 0 holds
    /// 0.
    bones: [4]u32 = @splat(0),
    /// The weight of each of `bones`, each 0 to 1.
    weights: [4]f32 = @splat(0),
};
/// A gradient a shape is filled or stroked with.
pub const Paint = struct {
    /// The paint's id.
    id: u32 = 0,
    /// The paint's name.
    name: Atom = none,
    /// `linear`, along the line from `start` to `end`, or `radial`, outward from `start` to the
    /// distance of `end`.
    kind: Atom = Atom.from("linear"),
    /// Where the gradient begins, in the paint's own space.
    start: Vec2 = zero,
    /// Where the gradient ends, in the paint's own space.
    end: Vec2 = one,
    /// The affine from the paint's own space to the shape's bind space, as `[a, b, c, d, tx, ty]`.
    /// The endpoints stay in the paint's space.
    transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    /// How many of the stops are used, up to 8.
    stop_count: u32 = 0,
    /// Each stop's place along the gradient, 0 to 1 and never decreasing.
    stop_offsets: [8]f32 = @splat(0),
    /// Each stop's colour, RGBA.
    stop_colors: [8]Color = @splat(.{ 0, 0, 0, 0 }),
};
/// The bits of `IK.flags`.
pub const IKFlags = struct {
    /// The controller may lengthen its chain to reach a target beyond it. Every bone of the chain
    /// must be `BoneFlags.stretchy`.
    pub const stretch: u32 = 1;
    /// A hint for whoever creates the controller's first pose row: start it pinned. Evaluation
    /// never reads it.
    pub const pinned_default: u32 = 2;
};
/// An inverse kinematics controller: it turns a chain of bones so the last one's tip reaches a
/// target a pose gives (`PoseIK`).
pub const IK = struct {
    /// The controller's id.
    id: u32 = 0,
    /// The controller's name.
    name: Atom = none,
    /// The last bone of the chain, whose tip reaches for the target.
    end_bone: u32 = 0,
    /// How many bones the chain has, counted from `end_bone` up through its ancestors; at least 1.
    chain: u32 = 2,
    /// Which way the chain may bend: 1 or -1 for one side only, 0 for either.
    bend: i32 = 0,
    /// `IKFlags` bits.
    flags: u32 = 0,
};
/// A saved pose's row: `id` is the pose's id, never 0, since 0 is the working pose; `name` its
/// name; `flags` bits kept with it as authored.
pub const Pose = struct { id: u32 = 0, name: Atom = none, flags: u32 = 0 };
/// What a pose gives one bone, in place of the bone's own values, for the channels `mask` names.
pub const PoseChannel = struct {
    /// The pose; 0 is the working pose.
    pose: u32 = 0,
    /// The bone.
    bone: u32 = 0,
    /// `Channels` bits: which of the values below the pose sets. The others are ignored.
    mask: u32 = 0,
    /// The bone's rotation in its parent's space, in radians.
    rotation: f32 = 0,
    /// Where the bone starts, in its parent's space; ignored for a connected bone.
    local: Vec2 = zero,
    /// The bone's scale; neither component may be zero.
    scale: Vec2 = one,
    /// The bone's length, never negative; applied only to a stretchy bone.
    length: f32 = 0,
};
/// What a pose gives one IK controller: whether it solves, and the target it reaches for. A
/// controller with no row in a pose does not solve in it.
pub const PoseIK = struct {
    /// The pose; 0 is the working pose.
    pose: u32 = 0,
    /// The controller.
    ik: u32 = 0,
    /// Where the chain's end reaches. Pinned: in the document's space. Not pinned: in the space of
    /// the chain's first bone's parent, the document's when that bone is a root.
    target: Vec2 = zero,
    /// The direction, in radians and in `target`'s space, the bones after the chain's end take as
    /// their parent's x axis.
    target_rotation: f32 = 0,
    /// 1 when the controller solves in this pose, 0 when it is kept but does not.
    enabled: u8 = 1,
    /// 1 when `target` is in the document's space, so the end stays put as the chain's parent
    /// moves; 0 when it moves with that parent.
    pinned: u8 = 0,
    /// The side the chain bent to when the pose was last solved: 1, -1, or 0 to infer it from the
    /// bones' own rotations. A side in the chain's solving space, not left or right on screen.
    bend_side: i32 = 0,
    /// The direction, in radians in the chain's solving space, the bend is measured against.
    pole_angle: f32 = std.math.pi / 2.0,
};
/// A value a pose gives one property of one definition row; see `figure.PoseProperty`.
pub const PoseProperty = struct {
    /// The pose; 0 is the working pose.
    pose: u32 = 0,
    /// A `figure.PropertyFamily`.
    family: u32 = 0,
    /// The row's id; a point's shape.
    target: u32 = 0,
    /// A point's index in its shape; 0 for other families.
    index: u32 = 0,
    /// The property, by its field's name.
    field: Atom = none,
    /// The value's bytes, read with `figure.propertyAs`.
    value: [32]u8 = @splat(0),
};
/// A clip: `id` its id, `name` its name, `fps` its frames a second, `frames` its length in frames
/// (at least 1) and `loop` nonzero when it wraps at its end, where another holds its last frame.
pub const Clip = struct { id: u32 = 0, name: Atom = none, fps: f32 = 12, frames: u32 = 1, loop: u8 = 1 };
/// A key of a clip: at `frame` of `clip` the figure is in `pose`. A clip has at most one key at a
/// frame. `easing` shapes the way from this key to the next: `constant` (hold), `linear`, `smooth`,
/// `ease_in` or `ease_out`.
pub const ClipKey = struct { clip: u32 = 0, frame: u32 = 0, pose: u32 = 0, easing: Atom = Atom.from("linear") };

/// A document's authored content, copied at one revision. Every slice is the caller's, in the
/// allocator the read was given; free them with `deinit`.
pub const Definition = struct {
    /// The document's authored revision when it was read.
    revision: u32,
    /// Current save destination, copied into the caller allocator: the file the document was
    /// read from or last saved to, or the one it was made to be saved to (`NewDoc.path`); null
    /// while it has none.
    path: ?[]const u8 = null,
    /// The document's pixels per unit; above 0.
    pixels_per_unit: f32,
    /// The document's background colour, RGBA.
    background: Color,
    /// The document's colour swatches, up to 32.
    palette: []const Color,
    /// The rig's bones.
    bones: []const Bone,
    /// The layers and folders.
    layers: []const Layer,
    /// The artwork's shapes.
    shapes: []const Shape,
    /// Every shape's points.
    points: []const Point,
    /// The gradients.
    paints: []const Paint,
    /// The IK controllers.
    ik: []const IK,
    /// The saved poses; the working pose has no row.
    poses: []const Pose,
    /// Every pose's bone channels, the working pose's among them.
    pose_channels: []const PoseChannel,
    /// Every pose's controller rows.
    pose_ik: []const PoseIK,
    /// Every pose's property values.
    pose_properties: []const PoseProperty,
    /// The clips.
    clips: []const Clip,
    /// Every clip's keys.
    clip_keys: []const ClipKey,
    /// Whether the document has a row of `object`'s family with its id.
    pub fn has(self: *const Definition, object: figure.ObjectId) bool {
        return switch (object.kind) {
            .bone => hasId(self.bones, object.id),
            .layer => hasId(self.layers, object.id),
            .shape => hasId(self.shapes, object.id),
            .ik => hasId(self.ik, object.id),
            .pose => hasId(self.poses, object.id),
            .clip => hasId(self.clips, object.id),
        };
    }

    fn hasId(rows: anytype, id: u32) bool {
        for (rows) |row| {
            if (row.id == id) return true;
        }
        return false;
    }

    /// Frees every slice and the path with `allocator`, the one the read was given, and leaves the
    /// value undefined. Never for a published definition, which is the host's.
    pub fn deinit(self: *Definition, allocator: std.mem.Allocator) void {
        inline for (.{ "palette", "bones", "layers", "shapes", "points", "paints", "ik", "poses", "pose_channels", "pose_ik", "pose_properties", "clips", "clip_keys" }) |field| allocator.free(@field(self, field));
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

/// The order layers draw in, back to front, for any rows with `id`, `parent` and `order` as
/// `Layer` has them: a top-level layer or folder by its `order` (then `id`), each folder followed
/// by its own layers by theirs. `layers` is every layer `a` and `b` may name as parent.
pub const layer_order = struct {
    fn siblingLess(a: anytype, b: @TypeOf(a)) bool {
        return a.order < b.order or (a.order == b.order and a.id < b.id);
    }
    fn topLevel(layers: anytype, layer: anytype) @TypeOf(layer) {
        if (layer.parent == 0) return layer;
        for (layers) |row| if (row.id == layer.parent) return row;
        return layer;
    }
    /// Whether `a` draws before (beneath) `b`.
    pub fn less(layers: anytype, a: anytype, b: @TypeOf(a)) bool {
        const a_top = topLevel(layers, a);
        const b_top = topLevel(layers, b);
        if (a_top.id != b_top.id) return siblingLess(a_top, b_top);
        if (a.id == a_top.id) return b.id != a_top.id;
        if (b.id == b_top.id) return false;
        return siblingLess(a, b);
    }
};

fn objectParent(kind: figure.ObjectKind, id: u32) ?figure.ObjectId {
    if (id == 0) return null;
    return .{ .kind = kind, .id = id };
}

fn layerById(layers: []const Layer, id: u32) ?Layer {
    for (layers) |layer| if (layer.id == id) return layer;
    return null;
}

const LayerState = struct { visible: bool = true, locked: bool = false };

/// Whether a layer shows and is locked once its ancestors are counted in. A layer whose ancestry
/// breaks off, or loops, does not show.
fn layerState(layers: []const Layer, id: u32) LayerState {
    var state: LayerState = .{};
    var current = id;
    var depth: usize = 0;
    while (current != 0 and depth <= layers.len) : (depth += 1) {
        const layer = layerById(layers, current) orelse return .{ .visible = false, .locked = state.locked };
        state.visible = state.visible and layer.visible != 0 and layer.opacity > 0;
        state.locked = state.locked or layer.locked != 0;
        current = layer.parent;
    }
    if (current != 0) state.visible = false;
    return state;
}

/// Appends the bones in preorder, siblings in row order. Walks parent links rather than the call
/// stack, because hierarchy depth is bounded only by the bone count. A row whose ancestry never
/// reaches a root has no route from one, so it is left out.
fn appendBones(allocator: std.mem.Allocator, bones: []const Bone, items: *std.ArrayListUnmanaged(figure.OutlinerItem)) error{OutOfMemory}!void {
    const no_row = std.math.maxInt(u32);
    const count: u32 = @intCast(bones.len);
    var rows_by_id = std.AutoHashMap(u32, u32).init(allocator);
    defer rows_by_id.deinit();
    try rows_by_id.ensureTotalCapacity(count);
    for (bones, 0..) |bone, row| rows_by_id.putAssumeCapacity(bone.id, @intCast(row));
    const parent_row = try allocator.alloc(u32, count);
    defer allocator.free(parent_row);
    const first_child = try allocator.alloc(u32, count);
    defer allocator.free(first_child);
    const next_sibling = try allocator.alloc(u32, count);
    defer allocator.free(next_sibling);
    const shown = try allocator.alloc(bool, count);
    defer allocator.free(shown);
    @memset(first_child, no_row);
    var first_root: u32 = no_row;
    var reversed_row = count;
    // Prepending in reverse leaves each sibling list in row order.
    while (reversed_row > 0) {
        reversed_row -= 1;
        const bone = bones[reversed_row];
        parent_row[reversed_row] = no_row;
        next_sibling[reversed_row] = no_row;
        if (bone.parent == 0) {
            next_sibling[reversed_row] = first_root;
            first_root = reversed_row;
        } else if (rows_by_id.get(bone.parent)) |parent_of_row| {
            parent_row[reversed_row] = parent_of_row;
            next_sibling[reversed_row] = first_child[parent_of_row];
            first_child[parent_of_row] = reversed_row;
        }
    }
    var current = first_root;
    while (current != no_row) {
        const bone = bones[current];
        const above = parent_row[current];
        const parent_shown = above == no_row or shown[above];
        shown[current] = parent_shown and bone.flags & BoneFlags.hidden == 0;
        try items.append(allocator, .{
            .object = .{ .kind = .bone, .id = bone.id },
            .parent = objectParent(.bone, bone.parent),
            .name = bone.name,
            .visible = shown[current],
            .locked = false,
        });
        if (first_child[current] != no_row) {
            current = first_child[current];
            continue;
        }
        while (current != no_row and next_sibling[current] == no_row) current = parent_row[current];
        if (current != no_row) current = next_sibling[current];
    }
}

fn shapeLess(_: void, left: Shape, right: Shape) bool {
    return left.order < right.order or (left.order == right.order and left.id < right.id);
}

fn boneLess(_: void, left: Bone, right: Bone) bool {
    return left.sibling_order < right.sibling_order or (left.sibling_order == right.sibling_order and left.id < right.id);
}

fn layerLess(layers: []const Layer, left: Layer, right: Layer) bool {
    return layer_order.less(layers, left, right);
}

/// `definition`'s rows as the tree an outliner shows (see `figure.Outliner`), at its revision.
/// Reads `definition` without changing it. Fails with `error.InvalidGeometry` when a layer's
/// ancestry breaks off or loops, a shape is in no layer, or a bone's never reaches a root. The
/// caller frees `items` with `allocator`.
pub fn projectOutliner(definition: Definition, allocator: std.mem.Allocator) figure.Error!figure.Outliner {
    for (definition.layers) |layer| {
        var current = layer.parent;
        var depth: usize = 0;
        while (current != 0) : (depth += 1) {
            if (depth >= definition.layers.len) return error.InvalidGeometry;
            const ancestor = layerById(definition.layers, current) orelse return error.InvalidGeometry;
            current = ancestor.parent;
        }
    }
    // Sorting owns only the three ordered collections; the caller's definition stays as it is.
    const layers = try allocator.dupe(Layer, definition.layers);
    defer allocator.free(layers);
    const shapes = try allocator.dupe(Shape, definition.shapes);
    defer allocator.free(shapes);
    const bones = try allocator.dupe(Bone, definition.bones);
    defer allocator.free(bones);
    std.mem.sort(Layer, layers, definition.layers, layerLess);
    std.mem.sort(Shape, shapes, {}, shapeLess);
    std.mem.sort(Bone, bones, {}, boneLess);

    var items: std.ArrayListUnmanaged(figure.OutlinerItem) = .empty;
    errdefer items.deinit(allocator);
    var shape_count: usize = 0;
    for (layers) |layer| {
        const state = layerState(layers, layer.id);
        try items.append(allocator, .{
            .object = .{ .kind = .layer, .id = layer.id },
            .parent = objectParent(.layer, layer.parent),
            .name = layer.name,
            .visible = state.visible,
            .locked = state.locked,
        });
        for (shapes) |shape| if (shape.layer == layer.id) {
            shape_count += 1;
            try items.append(allocator, .{
                .object = .{ .kind = .shape, .id = shape.id },
                .parent = objectParent(.layer, layer.id),
                .name = shape.name,
                .visible = state.visible and shape.visible != 0 and shape.opacity > 0,
                .locked = state.locked,
            });
        };
    }
    if (shape_count != shapes.len) return error.InvalidGeometry;
    const before_bones = items.items.len;
    try appendBones(allocator, bones, &items);
    if (items.items.len - before_bones != bones.len) return error.InvalidGeometry;
    for (definition.clips) |clip| try items.append(allocator, .{ .object = .{ .kind = .clip, .id = clip.id }, .parent = null, .name = clip.name, .visible = true, .locked = false });
    for (definition.poses) |pose| try items.append(allocator, .{ .object = .{ .kind = .pose, .id = pose.id }, .parent = null, .name = pose.name, .visible = true, .locked = false });
    for (definition.ik) |controller| try items.append(allocator, .{ .object = .{ .kind = .ik, .id = controller.id }, .parent = null, .name = controller.name, .visible = true, .locked = false });
    const owned_items = try items.toOwnedSlice(allocator);
    return .{ .revision = definition.revision, .items = owned_items };
}

test "outliner bones walk a chain too deep for recursion in preorder and inherit hidden" {
    // Deep enough that a recursive walk would overflow the stack.
    const count = 200_000;
    const allocator = std.testing.allocator;
    const rows = try allocator.alloc(Bone, count + 2);
    defer allocator.free(rows);
    for (rows[0..count], 0..) |*bone, i| bone.* = .{ .id = @intCast(i + 1), .parent = @intCast(i) };
    // A second root after the chain, then a child that follows its parent's hidden flag.
    rows[count] = .{ .id = count + 1, .flags = BoneFlags.hidden };
    rows[count + 1] = .{ .id = count + 2, .parent = count + 1 };
    var items: std.ArrayListUnmanaged(figure.OutlinerItem) = .empty;
    defer items.deinit(allocator);
    try appendBones(allocator, rows, &items);
    try std.testing.expectEqual(@as(usize, count + 2), items.items.len);
    for (items.items, rows) |item, row| try std.testing.expectEqual(row.id, item.object.id);
    try std.testing.expect(items.items[count - 1].visible);
    try std.testing.expect(!items.items[count].visible);
    try std.testing.expect(!items.items[count + 1].visible);
}

test "a definition has the rows of each family by id" {
    const bones = [_]Bone{.{ .id = 1 }};
    const shapes = [_]Shape{.{ .id = 3 }};
    const definition: Definition = .{ .revision = 1, .pixels_per_unit = 1, .background = .{ 0, 0, 0, 0 }, .palette = &.{}, .bones = &bones, .layers = &.{}, .shapes = &shapes, .points = &.{}, .paints = &.{}, .ik = &.{}, .poses = &.{}, .pose_channels = &.{}, .pose_ik = &.{}, .pose_properties = &.{}, .clips = &.{}, .clip_keys = &.{} };
    try std.testing.expect(definition.has(.{ .kind = .bone, .id = 1 }));
    try std.testing.expect(definition.has(.{ .kind = .shape, .id = 3 }));
    // An id belongs to one family: the bone's is no shape's.
    try std.testing.expect(!definition.has(.{ .kind = .shape, .id = 1 }));
    try std.testing.expect(!definition.has(.{ .kind = .layer, .id = 3 }));
}
