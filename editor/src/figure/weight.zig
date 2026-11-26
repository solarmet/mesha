//! Weight-mode editor state. Only dabs/numeric edits enter the document journal;
//! Test pose channels and stable-ID locks belong to bounded editor tables.

const std = @import("std");
const mesha = @import("mesha");
const modes = @import("../modes.zig");
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const figure = mesha.figure;
const roop = mesha.roop;
const controls = @import("../ui/style.zig").canvas_controls;

const geometry = @import("geometry.zig");
const session = @import("session.zig");
const preview = @import("preview.zig");
const selection = @import("selection.zig");
const prompts = @import("prompts.zig");
const transport = @import("commands.zig");
const workspace = @import("workspace.zig");
const canvas = @import("canvas.zig");
const view = @import("view.zig");
const gesture = @import("gesture.zig");
const asks = @import("asks.zig");
const watches = @import("watches.zig");

const distance = geometry.distance;

const bone_state_capacity = 4096;

const api = plugin.figure_api;

const sequencer = mesha.sequencer;

// ---- the system -----------------------------------------------------------------------------

/// Weight painting: the weight mode and brush, binding artwork to bones, and the test pose
/// that shows the weights at work. Strokes start from the canvas's press and flush through the
/// gesture.
pub fn system() sequencer.System {
    return .{
        .name = "figure_weight",
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claims,
        .active = workspace.shown,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_weight.take_actions", .run = takeActions },
            .{ .name = "figure_weight.follow_document", .run = followDocument },
        },
    };
}

/// The tags of weight painting's actions.
pub const Msg = enum(u64) {
    figure_bind_rigid = Atom.from("figure_bind_rigid").value(),
    figure_bind_skinned = Atom.from("figure_bind_skinned").value(),
    figure_weight_make_skinned = Atom.from("figure_weight_make_skinned").value(),
    figure_unbind = Atom.from("figure_unbind").value(),
    figure_unbind_current = Atom.from("figure_unbind_current").value(),
    figure_mode_weight = Atom.from("figure_mode_weight").value(),
    figure_weight_settings = Atom.from("figure_weight_settings").value(),
    figure_weight_radius = Atom.from("figure_weight_radius").value(),
    figure_weight_strength = Atom.from("figure_weight_strength").value(),
    figure_weight_value = Atom.from("figure_weight_value").value(),
    figure_weight_brush_mode = Atom.from("figure_weight_brush_mode").value(),
    figure_weight_brush_falloff = Atom.from("figure_weight_brush_falloff").value(),
    figure_weight_falloff = Atom.from("figure_weight_falloff").value(),
    figure_weight_mode = Atom.from("figure_weight_mode").value(),
    figure_weight_mode_add = Atom.from("figure_weight_mode_add").value(),
    figure_weight_mode_subtract = Atom.from("figure_weight_mode_subtract").value(),
    figure_weight_mode_replace = Atom.from("figure_weight_mode_replace").value(),
    figure_weight_mode_smooth = Atom.from("figure_weight_mode_smooth").value(),
    figure_weight_lock = Atom.from("figure_weight_lock").value(),
    figure_weight_numeric = Atom.from("figure_weight_numeric").value(),
    figure_subdivide_for_deform = Atom.from("figure_subdivide_for_deform").value(),
    figure_test_pose = Atom.from("figure_test_pose").value(),
    figure_test_rotation = Atom.from("figure_test_rotation").value(),
    _,
};

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// Following the document writes the brush's settings, and the per-bone rows in a frame they
/// go stale. Actions reach weight painting's rows, the selection, the requests they send and
/// the prompts they open.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const groups = workspace.table_groups;
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    result.readAll(&groups.state);
    result.writeAll(&.{ Atom.from(config_name), Atom.from(bones_name) });
    if (frame.messages.len == 0) return result;
    result.writeAll(&groups.state);
    result.writeAll(&groups.selected);
    result.writeAll(&groups.weight_rows);
    result.writeAll(&.{ groups.commands, groups.figure_requests, groups.palette_requests });
    return result;
}

fn takeActions(pass: *sequencer.Pass) !void {
    try workspace.takeToolActions(pass, claims, runAction);
}

fn runAction(frame: *const sequencer.Frame, received: sequencer.Message) !void {
    _ = try handleAction(frame.tables, frame.atoms, received.tag);
}

/// Follows the open document and mode: a new document clears the per-bone rows, leaving
/// weight mode hides the test pose and masks, and bones the document lost are dropped.
fn followDocument(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    syncWithReads(&reads);
}

pub const config_name = "editor_figure_weight";

pub const bones_name = "editor_figure_weight_bones";

// One sample can touch every captured shape/point and must fit one API batch.
// Larger documents remain usable; only the selected brush target snapshot is bounded.
pub const sample_capacity = 256;
pub const shape_capacity = api.max_weight_batch_dabs;
pub const target_capacity = api.max_weight_batch_pairs;
pub const stroke_name = "editor_figure_weight_stroke";
pub const targets_name = "editor_figure_weight_targets";
pub const samples_name = "editor_figure_weight_samples";
pub const shapes_name = "editor_figure_weight_shapes";
pub const locks_name = "editor_figure_weight_locks";

const Sample = struct {
    slot: u32 = 0,
    point: session.Vec2 = session.zero,
    zoom: f32 = 1,
    modifiers: u8 = 0,
    bone: u32 = 0,
    radius: f32 = 0,
    strength: f32 = 0,
    falloff: Atom = session.none,
    mode: Atom = session.none,
    value: f32 = 0,
};
const TargetShape = struct { ordinal: u32 = 0, id: u32 = 0, start: u32 = 0, len: u32 = 0 };
const Target = struct {
    ordinal: u32 = 0,
    index: u32 = 0,
    position: session.Vec2 = session.zero,
    // The anchor's only bone at press, or 0 when it blends several.
    sole_bone: u32 = 0,
};
const StrokeLock = struct { ordinal: u32 = 0, bone: u32 = 0 };
pub const Stroke = struct {
    head: u32 = 0,
    count: u32 = 0,
    shape_count: u32 = 0,
    point_count: u32 = 0,
    lock_count: u32 = 0,
};

pub const Config = struct {
    doc: Atom = session.none,
    bone: u32 = 0,
    radius: f32 = 45,
    strength: f32 = 0.1,
    falloff: Atom = Atom.from("smooth"),
    brush_mode: Atom = Atom.from("add"),
    value: f32 = 1,
    spacing: f32 = 10,
    point_shape: u32 = 0,
    point_index: u32 = 0,
    test_pose: u8 = 0,
    rotation_bone: u32 = 0,
    rotation_mask: u32 = 0,
    rotation_value: f32 = 0,
    rotation_has_reference: u8 = 0,
    rotation_dragging: u8 = 0,
};

const brush_modes = [_][]const u8{ "add", "subtract", "replace", "smooth" };
const brush_falloffs = [_][]const u8{ "smooth", "linear", "constant" };
pub const brush_options = [_]BrushOption{ .radius, .strength, .mode, .falloff, .value };
pub const BrushOption = enum {
    radius,
    strength,
    mode,
    falloff,
    value,

    pub fn details(self: BrushOption) struct { label: []const u8, hint: []const u8, action: Msg } {
        return switch (self) {
            .radius => .{ .label = "Radius px", .hint = "Finite screen pixels greater than 0 and at most 2048", .action = .figure_weight_radius },
            .strength => .{ .label = "Strength", .hint = "Finite strength from 0 to 1", .action = .figure_weight_strength },
            .value => .{ .label = "Replace value", .hint = "Finite target weight from 0 to 1; used by Replace mode", .action = .figure_weight_value },
            .mode => .{ .label = "Mode", .hint = "add / subtract / replace / smooth", .action = .figure_weight_brush_mode },
            .falloff => .{ .label = "Falloff", .hint = "smooth / linear / constant", .action = .figure_weight_brush_falloff },
        };
    }

    pub fn choices(self: BrushOption) []const []const u8 {
        return switch (self) {
            .mode => &brush_modes,
            .falloff => &brush_falloffs,
            else => &.{},
        };
    }

    pub fn valueText(self: BrushOption, allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry) ![]const u8 {
        const settings = config(tables);
        switch (self) {
            .radius => return std.fmt.allocPrint(allocator, "{d}", .{settings.radius.*}),
            .strength => return std.fmt.allocPrint(allocator, "{d}", .{settings.strength.*}),
            .value => return std.fmt.allocPrint(allocator, "{d}", .{settings.value.*}),
            .mode => return atoms.lookup(settings.brush_mode.*) orelse "?",
            .falloff => return atoms.lookup(settings.falloff.*) orelse "?",
        }
    }

    pub fn apply(self: BrushOption, tables: *Table.Registry, atoms: *Atom.Registry, text: []const u8) !void {
        const settings = config(tables);
        switch (self) {
            .radius, .strength, .value => {
                const value = try parseNumber(text);
                if (self == .radius) {
                    if (value <= 0 or value > 2048) return error.InvalidBrushRadius;
                    settings.radius.* = value;
                } else {
                    if (value < 0 or value > 1) return error.InvalidBrushWeight;
                    if (self == .strength) settings.strength.* = value else settings.value.* = value;
                }
            },
            .mode, .falloff => {
                for (self.choices()) |choice| {
                    if (!std.mem.eql(u8, text, choice)) continue;
                    const value = atoms.intern(choice);
                    if (self == .mode) settings.brush_mode.* = value else settings.falloff.* = value;
                    return;
                }
                return error.InvalidBrushOption;
            },
        }
    }
};

/// A pick is not a rotation. Near the origin the first threshold-crossing move
/// establishes an angle reference; elsewhere retain the press-angle offset.
pub const TestRotationDrag = struct {
    start: session.Vec2,
    origin: session.Vec2,
    zoom: f32,
    rotation: f32,
    reference: ?f32,
    dragging: bool = false,
    pub const threshold_px: f32 = 3;
    pub fn init(start: session.Vec2, origin: session.Vec2, zoom: f32, rotation: f32) TestRotationDrag {
        const delta = session.Vec2.sub(start, origin);
        return .{
            .start = start,
            .origin = origin,
            .zoom = zoom,
            .rotation = rotation,
            .reference = if (distance(start, origin) * zoom >= threshold_px) std.math.atan2(delta.y, delta.x) else null,
        };
    }
    pub fn move(self: *TestRotationDrag, point: session.Vec2) ?f32 {
        if (!self.dragging and distance(point, self.start) * self.zoom < threshold_px) return null;
        self.dragging = true;
        const delta = session.Vec2.sub(point, self.origin);
        if (distance(point, self.origin) * self.zoom < threshold_px) return null;
        const angle = std.math.atan2(delta.y, delta.x);
        const reference = self.reference orelse {
            self.reference = angle;
            return null;
        };
        const offset = angle - reference;
        return self.rotation + std.math.atan2(@sin(offset), @cos(offset));
    }
};

pub const BoneState = struct {
    doc: Atom = session.none,
    bone: u32 = 0,
    locked: u8 = 0,
    mask: u32 = 0,
    rotation: f32 = 0,
    local: session.Vec2 = session.zero,
    scale: session.Vec2 = session.one,
    length: f32 = 0,
};

pub const actions = blk: {
    const definitions = .{
        .{ Msg.figure_bind_rigid, "Bind selected artwork to selected/active bone at rest" },
        .{ Msg.figure_bind_skinned, "Auto skin selected artwork to selected bones (none: all deform bones)" },
        .{ Msg.figure_weight_make_skinned, "Make unskinned weight targets skinned; preserve existing skinned weights" },
        .{ Msg.figure_unbind, "Unbind selected artwork at rest" },
        .{ Msg.figure_unbind_current, "Bake selected artwork at working pose 0 (NOT Test pose)" },
        .{ Msg.figure_mode_weight, "Rig weight brush; Alt-pick bone, Ctrl-pick anchor, drag paints" },
        .{ Msg.figure_weight_settings, "Brush radius_px:strength:replace_value" },
        .{ Msg.figure_weight_radius, "Edit brush radius in screen pixels" },
        .{ Msg.figure_weight_strength, "Edit brush strength from 0 to 1" },
        .{ Msg.figure_weight_value, "Edit Replace mode target weight from 0 to 1" },
        .{ Msg.figure_weight_brush_mode, "Choose add/subtract/replace/smooth brush mode" },
        .{ Msg.figure_weight_brush_falloff, "Choose smooth/linear/constant brush falloff" },
        .{ Msg.figure_weight_falloff, "Cycle smooth/linear/constant brush falloff" },
        .{ Msg.figure_weight_mode, "Cycle add/subtract/replace/smooth" },
        .{ Msg.figure_weight_mode_add, "Brush adds influence for the brush bone" },
        .{ Msg.figure_weight_mode_subtract, "Brush removes influence for the brush bone" },
        .{ Msg.figure_weight_mode_replace, "Brush moves influence toward Replace value" },
        .{ Msg.figure_weight_mode_smooth, "Brush averages influence with neighbouring anchors" },
        .{ Msg.figure_weight_lock, "Toggle active deform bone weight lock" },
        .{ Msg.figure_weight_numeric, "Edit selected anchor influences as bone=weight,... (locks preserved)" },
        .{ Msg.figure_subdivide_for_deform, "Subdivide selected paths at maximum document-unit spacing" },
        .{ Msg.figure_test_pose, "Toggle non-journaled Test pose (discarded on leaving Weight)" },
        .{ Msg.figure_test_rotation, "Test pose active-bone absolute angle in degrees" },
    };
    var result: [definitions.len]plugin.action_api.Def = undefined;
    for (definitions, 0..) |action_definition, i| result[i] = .{ .name = modes.shortName("figure", @tagName(action_definition[0])), .tag = @tagName(action_definition[0]), .doc = action_definition[1] };
    break :blk result;
};

pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&brush_modes);
    try atoms.tryInternAll(&brush_falloffs);
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    _ = try session.ensureSingleton(Config, mem, atoms, tables, config_name);
    _ = try session.ensureTable(BoneState, mem, atoms, tables, bones_name, bone_state_capacity);
    _ = try session.ensureSingleton(Stroke, mem, atoms, tables, stroke_name);
    _ = try session.ensureTable(Target, mem, atoms, tables, targets_name, target_capacity);
    _ = try session.ensureTable(Sample, mem, atoms, tables, samples_name, sample_capacity);
    _ = try session.ensureTable(TargetShape, mem, atoms, tables, shapes_name, shape_capacity);
    _ = try session.ensureTable(StrokeLock, mem, atoms, tables, locks_name, api.max_weight_batch_locks);
}

pub const ConfigView = session.Row(Config);
pub fn config(tables: *Table.Registry) ConfigView {
    const config_table = tables.findByName(Atom.from(config_name)).?;
    return config_table.getRow(.{ .row = 0, .generation = config_table.rowGeneration(0) }, session.Row(Config)).?;
}

/// Per-bone brush state (lock, test pose mask and rotation), a row per bone touched.
pub const BoneStateRows = sequencer.Rows(session.Row(BoneState));
pub fn boneStates(tables: *Table.Registry) BoneStateRows {
    return .of(tables.findByName(Atom.from(bones_name)).?);
}
/// A stroke's press-time snapshot, a row per target anchor, shape and locked bone, and its
/// queue of samples.
pub const TargetRows = sequencer.Rows(session.Row(Target));
pub fn strokeTargets(tables: *Table.Registry) TargetRows {
    return .of(tables.findByName(Atom.from(targets_name)).?);
}
pub const TargetShapeRows = sequencer.Rows(session.Row(TargetShape));
pub fn strokeShapes(tables: *Table.Registry) TargetShapeRows {
    return .of(tables.findByName(Atom.from(shapes_name)).?);
}
pub const StrokeLockRows = sequencer.Rows(session.Row(StrokeLock));
pub fn strokeLocks(tables: *Table.Registry) StrokeLockRows {
    return .of(tables.findByName(Atom.from(locks_name)).?);
}
pub const SampleRows = sequencer.Rows(session.Row(Sample));
pub fn strokeSamples(tables: *Table.Registry) SampleRows {
    return .of(tables.findByName(Atom.from(samples_name)).?);
}

fn frameAllocator(tables: *Table.Registry) !std.mem.Allocator {
    return (try tables.memory.frameScratchAllocator()).allocator;
}

fn boneState(editor: session.View, bone_table: BoneStateRows, bone: u32) !session.Row(BoneState) {
    const doc = editor.doc.*;
    var bone_rows = bone_table.query();
    while (bone_rows.next()) |bone_row| if (bone_row.view.doc.* == doc and bone_row.view.bone.* == bone) return bone_row.view;
    const handle = try bone_table.insert(BoneState{ .doc = doc, .bone = bone });
    return bone_table.get(handle).?;
}

pub fn locked(bone_states: BoneStateRows, bone: u32) bool {
    var bone_rows = bone_states.query();
    while (bone_rows.next()) |bone_row| if (bone_row.view.bone.* == bone and bone_row.view.locked.* != 0) return true;
    return false;
}

pub fn locks(tables: *Table.Registry) ![]const u32 {
    var result: std.ArrayListUnmanaged(u32) = .empty;
    var bone_rows = boneStates(tables).query();
    while (bone_rows.next()) |bone_row| {
        if (bone_row.view.locked.* != 0) {
            const frame_allocator = try frameAllocator(tables);
            try result.append(frame_allocator, bone_row.view.bone.*);
        }
    }
    const frame_allocator = try frameAllocator(tables);
    return result.toOwnedSlice(frame_allocator);
}

pub fn discard(weight_settings: ConfigView, bone_states: BoneStateRows) void {
    weight_settings.test_pose.* = 0;
    var bone_rows = bone_states.query();
    while (bone_rows.next()) |bone_row| bone_row.view.mask.* = 0;
}

pub fn sync(tables: *Table.Registry, atoms: *Atom.Registry) void {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    syncWithReads(&reads);
}

pub fn syncWithReads(reads: *session.ReadContext) void {
    const tables = reads.tables;
    const editor = session.get(tables);
    const settings = config(tables);
    if (settings.doc.* != editor.doc.*) {
        while (true) {
            var bone_rows = boneStates(tables).query();
            const bone_row = bone_rows.next() orelse break;
            const handle = bone_row.handle;
            boneStates(tables).free(handle);
        }
        settings.doc.* = editor.doc.*;
        settings.bone.* = 0;
        settings.point_shape.* = 0;
        discard(config(tables), boneStates(tables));
    }
    if (editor.tool.* != names.weight) discard(config(tables), boneStates(tables));
    const definition = reads.definition(editor.doc.*) catch return;
    while (true) {
        var bone_rows = boneStates(tables).query();
        var remove: ?Table.RowHandle = null;
        while (bone_rows.next()) |bone_row| if (session.findById(api.read.Bone, definition.bones, bone_row.view.bone.*) == null) {
            remove = bone_row.handle;
            break;
        };
        boneStates(tables).free(remove orelse break);
    }
    if (settings.bone.* != 0 and session.findById(api.read.Bone, definition.bones, settings.bone.*) == null) settings.bone.* = 0;
    if (settings.bone.* == 0 and editor.tool.* == names.weight) settings.bone.* = defaultBrushBone(definition, editor.active_bone.*);
    if (settings.point_shape.* != 0) {
        const found = for (definition.points) |authored_point| {
            if (authored_point.shape == settings.point_shape.* and authored_point.index == settings.point_index.*) break true;
        } else false;
        if (!found) settings.point_shape.* = 0;
    }
}

// Weights are only meaningful relative to a bone, so the heat view always has one:
// the bone the user was last working with, otherwise the first deform bone.
fn defaultBrushBone(definition: anytype, active_bone: u32) u32 {
    var first_deform: u32 = 0;
    for (definition.bones) |bone| {
        if (bone.flags & session.BoneFlags.deform == 0) continue;
        if (bone.id == active_bone) return bone.id;
        if (first_deform == 0) first_deform = bone.id;
    }
    return first_deform;
}

/// Copies the non-journaled test-pose UX draft into caller-owned instance inputs.
pub fn previewInputs(bone_states: BoneStateRows, allocator: std.mem.Allocator) !figure.CustomInputs {
    var channels: std.ArrayListUnmanaged(figure.PoseChannels) = .empty;
    errdefer channels.deinit(allocator);
    var bone_rows = bone_states.query();
    while (bone_rows.next()) |bone_row| if (bone_row.view.mask.* != 0) {
        try channels.append(allocator, .{
            .bone = bone_row.view.bone.*,
            .rotation = if (bone_row.view.mask.* & api.read.Channels.rotation != 0) bone_row.view.rotation.* else null,
            .local = if (bone_row.view.mask.* & api.read.Channels.local != 0) bone_row.view.local.* else null,
            .scale = if (bone_row.view.mask.* & api.read.Channels.scale != 0) bone_row.view.scale.* else null,
            .length = if (bone_row.view.mask.* & api.read.Channels.length != 0) bone_row.view.length.* else null,
        });
    };
    const owned_channels = try channels.toOwnedSlice(allocator);
    return .{ .channels = owned_channels };
}

/// The skinned shapes' points and contour samples in the shown pose, sampled at the canvas's
/// tolerance: the host's until it next publishes a change, `error.NotReady` until the editor's
/// watch of the pose is answered with them, as when the brush was just picked up.
fn weightGeometry(tables: *Table.Registry, atoms: *Atom.Registry) !api.WeightGeometry {
    const shown = try preview.current(tables, atoms);
    return watches.weights(tables, shown);
}

/// Makes `bone` the one the brush paints. Layers marks it as its chosen bone while the brush
/// is in hand: the selection itself holds the artwork being painted.
pub fn pickBone(weight_settings: ConfigView, editor: session.View, bone: u32) void {
    weight_settings.bone.* = bone;
    editor.active_bone.* = bone;
}

/// The brush bone's name, or "" while there is none.
pub fn brushBoneName(tables: *Table.Registry, atoms: *Atom.Registry) ![]const u8 {
    const editor = session.get(tables);
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const bone = session.findById(api.read.Bone, definition.bones, config(tables).bone.*) orelse return "";
    return atoms.lookup(bone.name) orelse "";
}

pub fn falloffFactor(falloff: Atom, distance_px: f32, radius: f32) f32 {
    if (!std.math.isFinite(radius) or radius <= 0 or !std.math.isFinite(distance_px)) return 0;
    const x = std.math.clamp(1 - distance_px / radius, 0, 1);
    if (x == 0) return 0;
    if (falloff == Atom.from("constant")) return 1;
    return if (falloff == Atom.from("linear")) x else x * x * (3 - 2 * x);
}

pub const StrokeView = session.Row(Stroke);
pub fn stroke(tables: *Table.Registry) StrokeView {
    const table_name = Atom.from(stroke_name);
    const stroke_table = tables.findByName(table_name).?;
    const handle = Table.RowHandle{ .row = 0, .generation = stroke_table.rowGeneration(0) };
    return stroke_table.getRow(handle, session.Row(Stroke)).?;
}

/// Rows own sample and snapshot values; counters/slots describe their ordering.
/// The snapshot is retired only after the shared gesture owner settles its terminal.
pub fn clearStroke(state: StrokeView, stroke_targets: TargetRows, stroke_samples: SampleRows, stroke_shapes: TargetShapeRows, stroke_locks: StrokeLockRows) void {
    state.head.* = 0;
    state.count.* = 0;
    state.shape_count.* = 0;
    state.point_count.* = 0;
    state.lock_count.* = 0;
    stroke_targets.clear();
    stroke_samples.clear();
    stroke_shapes.clear();
    stroke_locks.clear();
}

const BrushTargets = struct {
    paintable: []const u32,
    needs_skin: []const u32,
    blocked: usize = 0,
    first_name: Atom = session.none,
    first_binding: Atom = session.none,
    bone: ?api.read.Bone = null,
};

// Target IDs borrow the current frame. The brush and conversion action use the
// same selection and editability policy as the eligibility feedback.
fn brushTargets(tables: *Table.Registry, atoms: *Atom.Registry) !BrushTargets {
    const editor = session.get(tables);
    const settings = config(tables);
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const allocator = try frameAllocator(tables);
    var paintable: std.ArrayListUnmanaged(u32) = .empty;
    var needs_skin: std.ArrayListUnmanaged(u32) = .empty;
    var result = BrushTargets{ .paintable = &.{}, .needs_skin = &.{}, .bone = session.findById(api.read.Bone, definition.bones, settings.bone.*) };
    const shape_kind = names.shape;
    for (definition.shapes) |shape| {
        if (!selection.contains(session.get(tables), session.selections(tables), shape_kind, shape.id) and settings.point_shape.* != shape.id) continue;
        if (result.first_name == session.none) {
            result.first_name = shape.name;
            result.first_binding = shape.binding;
        }
        if (shape.visible == 0 or !session.editableLayer(definition, shape.layer)) {
            result.blocked += 1;
        } else if (shape.binding == names.skinned and shape.kind == names.path) {
            try paintable.append(allocator, shape.id);
        } else {
            try needs_skin.append(allocator, shape.id);
        }
    }
    result.paintable = paintable.items;
    result.needs_skin = needs_skin.items;
    return result;
}

/// Plain wording for document rejections in Weight mode; other errors keep their names.
pub fn describeRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.LockedInfluence => "Weights unchanged: this would change a locked bone's weight",
        error.NoInfluences => "Weights unchanged: this would leave an anchor with no bone",
        else => null,
    };
}

pub const BrushFeedback = struct {
    title: []const u8,
    detail: []const u8,
    action: enum { none, make_skinned, unlock_bone } = .none,
};

pub fn brushFeedback(tables: *Table.Registry, atoms: *Atom.Registry) !BrushFeedback {
    const targets = try brushTargets(tables, atoms);
    const allocator = try frameAllocator(tables);
    if (targets.needs_skin.len != 0) {
        const total = targets.needs_skin.len + targets.paintable.len + targets.blocked;
        const title = if (total == 1) blk: {
            const name = atoms.lookup(targets.first_name) orelse "Artwork";
            const binding = if (targets.first_binding == names.rigid) "rigid binding" else "unskinned";
            break :blk try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, binding });
        } else try std.fmt.allocPrint(allocator, "{d} ready; {d} need skinning", .{ targets.paintable.len, targets.needs_skin.len });
        return .{ .title = title, .detail = "Weights require a skinned path.", .action = .make_skinned };
    }
    if (targets.paintable.len == 0) {
        if (targets.blocked != 0) return .{ .title = "Artwork is hidden or locked.", .detail = "Show/unlock it and its layers." };
        return .{ .title = "Click artwork to paint it.", .detail = "Select the bone to paint in Layers." };
    }
    const bone = targets.bone orelse return .{ .title = "No bone to paint.", .detail = "Select a deform bone in Layers, or Alt-click one on the canvas." };
    if (bone.flags & session.BoneFlags.deform == 0) return .{ .title = "This bone does not deform artwork.", .detail = "Select a deform bone in Layers to paint." };
    if (locked(boneStates(tables), bone.id)) return .{ .title = "The brush bone is locked.", .detail = "Unlock it to change its weights.", .action = .unlock_bone };
    const title = try std.fmt.allocPrint(allocator, "{d} skinned paths ready to paint", .{targets.paintable.len});
    return .{ .title = title, .detail = if (targets.blocked == 0) "Drag to paint; Esc cancels the stroke." else "Hidden/locked targets are skipped." };
}

fn bindSkinned(tables: *Table.Registry, atoms: *Atom.Registry, ids: []const u32) !void {
    const editor = session.get(tables);
    const allocator = try frameAllocator(tables);
    var bones: std.ArrayListUnmanaged(u32) = .empty;
    var rows = session.selections(tables).read();
    while (rows.next()) |row| {
        if (row.view.doc.* == editor.doc.* and row.view.kind.* == names.bone) try bones.append(allocator, row.view.id.*);
    }
    try transport.send(tables, atoms, .{ .bind_skinned = .{ .doc = editor.doc.*, .ids = ids, .bones = bones.items } });
}

fn captureTargets(tables: *Table.Registry, atoms: *Atom.Registry, ids: []const u32) !void {
    clearStroke(stroke(tables), strokeTargets(tables), strokeSamples(tables), strokeShapes(tables), strokeLocks(tables));
    errdefer clearStroke(stroke(tables), strokeTargets(tables), strokeSamples(tables), strokeShapes(tables), strokeLocks(tables));
    const state = stroke(tables);
    const projected = try weightGeometry(tables, atoms);
    const lock_ids = try locks(tables);
    if (lock_ids.len > api.max_weight_batch_locks) return error.WeightStrokeSnapshotTooLarge;
    const lock_table = strokeLocks(tables);
    for (lock_ids) |bone| {
        _ = try lock_table.insert(StrokeLock{ .ordinal = state.lock_count.*, .bone = bone });
        state.lock_count.* += 1;
    }
    const target_table = strokeTargets(tables);
    const shape_table = strokeShapes(tables);
    for (projected.shapes) |shape| {
        if (!shape.brush_eligible or shape.points.len == 0) continue;
        if (std.mem.indexOfScalar(u32, ids, shape.id) == null) continue;
        if (state.shape_count.* == shape_capacity) return error.WeightStrokeSnapshotTooLarge;
        if (shape.points.len > target_capacity - state.point_count.*) return error.WeightStrokeSnapshotTooLarge;
        const point_count: u32 = @intCast(shape.points.len);
        _ = try shape_table.insert(TargetShape{
            .ordinal = state.shape_count.*,
            .id = shape.id,
            .start = state.point_count.*,
            .len = point_count,
        });
        state.shape_count.* += 1;
        for (projected.points[shape.points.start..][0..shape.points.len]) |point| {
            _ = try target_table.insert(Target{
                .ordinal = state.point_count.*,
                .index = point.index,
                .position = point.position,
                .sole_bone = soleBone(point.influences),
            });
            state.point_count.* += 1;
        }
    }
}

fn soleBone(influences: api.WeightInfluences) u32 {
    var sole: u32 = 0;
    for (influences.bones, influences.weights) |bone, influence| {
        if (influence <= 0) continue;
        if (sole != 0) return 0;
        sole = bone;
    }
    return sole;
}

// Every anchor must keep some influence, and the document rejects a whole stroke that
// would strip one. An anchor's only bone therefore cannot lose weight; passing over one
// leaves it alone, like any other anchor the brush has no effect on.
fn dabWouldStripAnchor(sample: Sample, target: Target) bool {
    if (target.sole_bone != sample.bone) return false;
    if (sample.mode == Atom.from("subtract")) return true;
    return sample.mode == Atom.from("replace") and sample.value < 1;
}

fn sampleFactor(sample: Sample, target: Target) f32 {
    if (dabWouldStripAnchor(sample, target)) return 0;
    const document_distance = distance(sample.point, target.position);
    const screen_distance = document_distance * sample.zoom;
    return falloffFactor(sample.falloff, screen_distance, sample.radius);
}

/// Consumes a complete FIFO prefix only after the transport owns a recursive copy.
/// Each sample visits its press-time shapes in order; a shape-dab is never split.
pub fn flushStroke(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const state = stroke(tables);
    if (state.count.* == 0) return;
    const owner = gesture.get(tables);
    const allocator = try frameAllocator(tables);
    const targets = try allocator.alloc(Target, state.point_count.*);
    const target_table = strokeTargets(tables);
    var target_rows = target_table.query();
    while (target_rows.next()) |row| targets[row.view.ordinal.*] = session.readRow(Target, row.view);
    const shapes = try allocator.alloc(TargetShape, state.shape_count.*);
    const shape_table = strokeShapes(tables);
    var shape_rows = shape_table.query();
    while (shape_rows.next()) |row| shapes[row.view.ordinal.*] = session.readRow(TargetShape, row.view);
    const lock_ids = try allocator.alloc(u32, state.lock_count.*);
    const lock_table = strokeLocks(tables);
    var lock_rows = lock_table.read();
    while (lock_rows.next()) |row| lock_ids[row.view.ordinal.*] = row.view.bone.*;
    const samples = try allocator.alloc(Sample, state.count.*);
    const sample_handles = try allocator.alloc(Table.RowHandle, state.count.*);
    const sample_table = strokeSamples(tables);
    var sample_rows = sample_table.query();
    while (sample_rows.next()) |row| {
        const queue_index = (row.view.slot.* + sample_capacity - state.head.*) % sample_capacity;
        samples[queue_index] = session.readRow(Sample, row.view);
        sample_handles[queue_index] = row.handle;
    }
    const queued_pairs = @as(usize, state.count.*) * state.point_count.*;
    const pair_capacity = @min(api.max_weight_batch_pairs, queued_pairs);
    const indices = try allocator.alloc(u32, pair_capacity);
    const factors = try allocator.alloc(f32, pair_capacity);
    const dabs = try allocator.alloc(api.WeightDab, api.max_weight_batch_dabs);
    var consumed: u32 = 0;
    var pair_count: usize = 0;
    var dab_count: usize = 0;
    var stripped_anchor = false;
    while (consumed < state.count.*) {
        const sample = samples[consumed];
        for (targets) |target| {
            if (!dabWouldStripAnchor(sample, target)) continue;
            const screen_distance = distance(sample.point, target.position) * sample.zoom;
            if (falloffFactor(sample.falloff, screen_distance, sample.radius) > 0) stripped_anchor = true;
        }
        var sample_pairs: usize = 0;
        var sample_dabs: usize = 0;
        for (shapes) |shape| {
            var shape_pairs: usize = 0;
            for (targets[shape.start..][0..shape.len]) |target| {
                if (sampleFactor(sample, target) > 0) shape_pairs += 1;
            }
            sample_pairs += shape_pairs;
            if (shape_pairs != 0) sample_dabs += 1;
        }
        if (sample_pairs > pair_capacity - pair_count or sample_dabs > dabs.len - dab_count) break;
        for (shapes) |shape| {
            const start = pair_count;
            for (targets[shape.start..][0..shape.len]) |target| {
                const factor = sampleFactor(sample, target);
                if (factor <= 0) continue;
                indices[pair_count] = target.index;
                factors[pair_count] = factor;
                pair_count += 1;
            }
            if (start == pair_count) continue;
            dabs[dab_count] = .{
                .shape = shape.id,
                .bone = sample.bone,
                .indices = indices[start..pair_count],
                .factors = factors[start..pair_count],
                .strength = sample.strength,
                .mode = sample.mode,
                .value = sample.value,
            };
            dab_count += 1;
        }
        consumed += 1;
    }
    // Snapshot bounds guarantee that the first complete sample fits the API.
    if (consumed == 0) return error.WeightStrokeSnapshotTooLarge;
    if (stripped_anchor) prompts.inform(session.feedbackTable(tables), session.feedback(tables), "An anchor bound only to this bone can't lose weight; paint another bone onto it first");
    if (dab_count != 0) {
        try gesture.openTransaction(tables, atoms, names.weight_stroke);
        try gesture.submitPreview(tables, atoms, .incremental, &.{.{ .paint_weights_batch = .{
            .doc = owner.doc.*,
            .dabs = dabs[0..dab_count],
            .locked_bones = lock_ids,
        } }});
    }
    // Logical row handles survive physical compaction while the prefix is freed.
    for (sample_handles[0..consumed]) |handle| sample_table.free(handle);
    state.head.* = (state.head.* + consumed) % sample_capacity;
    state.count.* -= consumed;
    owner.sample_pending.* = @intFromBool(state.count.* != 0);
}

fn recordSample(tables: *Table.Registry, atoms: *Atom.Registry, pointer: gesture.Pointer) !void {
    const owner = gesture.get(tables);
    if (gesture.phaseOf(owner) != .sampling) return;
    const state = stroke(tables);
    if (state.count.* == sample_capacity) {
        if (owner.transaction_owned.* == 0 or owner.in_flight.* != 0) return error.WeightStrokeQueueFull;
        flushStroke(tables, atoms) catch |err| {
            if (err == error.Busy or err == error.CapacityExceeded) return error.WeightStrokeQueueFull;
            return err;
        };
        if (state.count.* == sample_capacity) return error.WeightStrokeQueueFull;
    }
    const settings = config(tables);
    const editor = session.get(tables);
    const tail = (state.head.* + state.count.*) % sample_capacity;
    const sample_table = strokeSamples(tables);
    _ = try sample_table.insert(Sample{
        .slot = tail,
        .point = pointer.point,
        .zoom = editor.view_zoom.*,
        .modifiers = pointer.modifiers,
        .bone = settings.bone.*,
        .radius = settings.radius.*,
        .strength = settings.strength.*,
        .falloff = settings.falloff.*,
        .mode = settings.brush_mode.*,
        .value = settings.value.*,
    });
    state.count.* += 1;
    owner.sample_pending.* = 1;
}

/// Whether a press at `point` only chooses what to paint, of the shapes `found` under it: other
/// artwork than the brush's targets, or with no targets a bone.
fn pressRetargets(tables: *Table.Registry, atoms: *Atom.Registry, point: session.Vec2, targets: BrushTargets, found: []const api.Hit) !bool {
    const editor = session.get(tables);
    const has_targets = targets.first_name != session.none;
    for (found) |hit| {
        const shape_is_target = std.mem.indexOfScalar(u32, targets.paintable, hit.object.id) != null or
            std.mem.indexOfScalar(u32, targets.needs_skin, hit.object.id) != null;
        if (shape_is_target) return false;
    }
    if (found.len != 0) {
        selection.select(tables, atoms, names.shape, found[0].object.id, false, false);
        config(tables).point_shape.* = 0;
        return true;
    }
    if (has_targets) return false;
    // Bones run through artwork, so only empty canvas gives a plain click to a bone.
    const evaluation = try preview.evaluation(tables, atoms);
    if (geometry.pickBone(evaluation.bones, point, editor.view_zoom.*)) |bone| {
        pickBone(config(tables), session.get(tables), bone.id);
        return true;
    }
    prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Click artwork to paint it, or a bone to choose the brush bone");
    return true;
}

pub fn pointerDown(tables: *Table.Registry, atoms: *Atom.Registry, pointer: gesture.Pointer) !bool {
    const point = pointer.point;
    const alt = pointer.modifiers & gesture.Modifiers.alt != 0;
    const control = pointer.modifiers & gesture.Modifiers.control != 0;
    const editor = session.get(tables);
    if (editor.tool.* != names.weight) return false;
    const settings = config(tables);
    if (gesture.busy(gesture.get(tables))) return true;
    if (alt) {
        const evaluation = try preview.evaluation(tables, atoms);
        if (geometry.pickBone(evaluation.bones, point, editor.view_zoom.*)) |bone| {
            pickBone(config(tables), session.get(tables), bone.id);
            if (settings.test_pose.* != 0) {
                editor.gesture_kind.* = names.test_rotation;
                editor.gesture_active.* = 1;
                for (evaluation.bones) |evaluated_bone| if (evaluated_bone.id == bone.id) {
                    editor.gesture_origin.* = evaluated_bone.origin;
                    break;
                };
                const definition = try session.readDefinition(tables, atoms, editor.doc.*);
                const authored_bone = session.findById(api.read.Bone, definition.bones, bone.id) orelse return error.MissingBone;
                const bone_row = try boneState(session.get(tables), boneStates(tables), bone.id);
                // Test rotation uses the shared length field for the press angle and
                // the shared rotation field for the pointer reference angle.
                const press_angle = if (bone_row.mask.* & api.read.Channels.rotation != 0) bone_row.rotation.* else authored_bone.rotation;
                editor.gesture_length.* = press_angle;
                settings.rotation_bone.* = bone.id;
                settings.rotation_mask.* = bone_row.mask.*;
                settings.rotation_value.* = bone_row.rotation.*;
                editor.gesture_start.* = point;
                const drag = TestRotationDrag.init(point, editor.gesture_origin.*, editor.view_zoom.*, editor.gesture_length.*);
                const reference_angle = drag.reference;
                editor.gesture_rotation.* = reference_angle orelse 0;
                settings.rotation_has_reference.* = @intFromBool(drag.reference != null);
                settings.rotation_dragging.* = 0;
            }
        }
        return true;
    }
    if (control) {
        var best: f32 = 9 / editor.view_zoom.*;
        const projected = try weightGeometry(tables, atoms);
        for (projected.points) |projected_point| {
            const point_distance = distance(point, projected_point.position);
            if (point_distance < best) {
                best = point_distance;
                settings.point_shape.* = projected_point.shape;
                settings.point_index.* = projected_point.index;
            }
        }
        return true;
    }
    if (!std.math.isFinite(settings.radius.*) or settings.radius.* <= 0) return error.InvalidRadius;
    // What lies under the press decides whether it paints; `pressAnswered` goes on with the
    // press as the canvas took it.
    editor.gesture_start_screen.* = pointer.screen;
    try asks.hitTest(tables, atoms, workspace.system(), .{ .purpose = .weight_press, .point = point, .value = pointer.modifiers });
    return true;
}

/// A brush press goes on with the artwork the host found under it: choosing what to paint, or
/// starting a stroke. Nothing when the brush was put down or a stroke began meanwhile.
pub fn pressAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const editor = session.get(tables);
    if (editor.tool.* != names.weight or gesture.busy(gesture.get(tables))) return;
    try answer.failure.check();
    const pointer: gesture.Pointer = .{ .point = answer.point, .screen = editor.gesture_start_screen.*, .modifiers = @truncate(answer.value) };
    const targets = try brushTargets(tables, atoms);
    // A press that only chooses what to paint never edits weights; painting starts
    // on the next press so that a first click cannot leave an unintended dab.
    if (try pressRetargets(tables, atoms, pointer.point, targets, answer.hits())) return;
    const bone = targets.bone orelse {
        prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Add a deform bone in Design to paint weights");
        return;
    };
    if (bone.flags & session.BoneFlags.deform == 0 or locked(boneStates(tables), bone.id)) {
        prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Choose an unlocked deform bone to paint");
        return;
    }
    try captureTargets(tables, atoms, targets.paintable);
    errdefer clearStroke(stroke(tables), strokeTargets(tables), strokeSamples(tables), strokeShapes(tables), strokeLocks(tables));
    if (stroke(tables).point_count.* == 0) {
        clearStroke(stroke(tables), strokeTargets(tables), strokeSamples(tables), strokeShapes(tables), strokeLocks(tables));
        prompts.inform(session.feedbackTable(tables), session.feedback(tables), if (targets.needs_skin.len != 0) "Use Make skinned before painting" else "Select an editable skinned path to paint");
        return;
    }
    try gesture.begin(gesture.get(tables), .{ .kind = .weight, .doc = editor.doc.*, .pointer = pointer });
    editor.gesture_kind.* = names.weight_stroke;
    editor.gesture_active.* = 1;
    recordSample(tables, atoms, pointer) catch |err| {
        gesture.reject(session.table(tables), gesture.get(tables), session.get(tables), session.feedback(tables), err);
        return err;
    };
}

pub fn pointerMove(tables: *Table.Registry, atoms: *Atom.Registry, pointer: gesture.Pointer) !bool {
    const point = pointer.point;
    const editor = session.get(tables);
    if (editor.gesture_kind.* == names.test_rotation and editor.tool.* == names.weight) {
        const settings = config(tables);
        const press_angle = editor.gesture_length.*;
        const reference_angle = if (settings.rotation_has_reference.* != 0) editor.gesture_rotation.* else null;
        var drag = TestRotationDrag{
            .start = editor.gesture_start.*,
            .origin = editor.gesture_origin.*,
            .zoom = editor.view_zoom.*,
            .rotation = press_angle,
            .reference = reference_angle,
            .dragging = settings.rotation_dragging.* != 0,
        };
        const rotation = drag.move(point);
        settings.rotation_dragging.* = @intFromBool(drag.dragging);
        settings.rotation_has_reference.* = @intFromBool(drag.reference != null);
        editor.gesture_rotation.* = drag.reference orelse 0;
        if (rotation) |angle| {
            const bone_row = try boneState(session.get(tables), boneStates(tables), settings.rotation_bone.*);
            bone_row.rotation.* = angle;
            bone_row.mask.* |= api.read.Channels.rotation;
        }
        return true;
    }
    if (gesture.activeKind(gesture.get(tables)) != .weight) return false;
    // Pointer events, not frame time, determine dabs; stationary release never adds a dab.
    const document_distance = distance(point, editor.gesture_current.*);
    if (document_distance * editor.view_zoom.* >= 1) {
        recordSample(tables, atoms, pointer) catch |err| {
            gesture.reject(session.table(tables), gesture.get(tables), session.get(tables), session.feedback(tables), err);
            return err;
        };
    }
    return true;
}

pub fn endTestRotation(editor: session.View, settings: ConfigView, bone_states: BoneStateRows, ending: gesture.End) void {
    if (editor.gesture_kind.* != names.test_rotation or editor.gesture_active.* == 0) return;
    if (ending == .cancel and settings.rotation_bone.* != 0) {
        var bone_rows = bone_states.query();
        while (bone_rows.next()) |row| if (row.view.doc.* == editor.doc.* and row.view.bone.* == settings.rotation_bone.*) {
            row.view.mask.* = settings.rotation_mask.*;
            row.view.rotation.* = settings.rotation_value.*;
            break;
        };
    }
    settings.rotation_bone.* = 0;
    settings.rotation_dragging.* = 0;
}

pub fn reconcileResult(settings: ConfigView, editor: session.View, metadata: session.Metadata, failed: bool) void {
    const doc = metadata.doc;
    if (doc != editor.doc.*) return;
    if (!failed and (metadata.operation == .subdivide_for_deform or
        metadata.operation == .unbind or
        metadata.operation == .bind_skinned or
        metadata.operation == .bind_rigid or
        metadata.operation == .undo or
        metadata.operation == .redo))
    {
        settings.point_shape.* = 0;
    }
}

pub fn numericText(tables: *Table.Registry, atoms: *Atom.Registry) ![]const u8 {
    const settings = config(tables);
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    for (definition.points) |authored_point| {
        if (authored_point.shape != settings.point_shape.* or authored_point.index != settings.point_index.*) continue;
        var text: std.ArrayListUnmanaged(u8) = .empty;
        for (authored_point.bones, authored_point.weights) |bone, weight| if (weight > 0) {
            const part_allocator = try frameAllocator(tables);
            const separator = if (text.items.len == 0) "" else ",";
            const named = session.findById(api.read.Bone, definition.bones, bone);
            const name = if (named) |found| atoms.lookup(found.name) else null;
            // Names that collide with the prompt grammar stay addressable by stable ID.
            const part = if (name != null and name.?.len != 0 and std.mem.indexOfAny(u8, name.?, "=, \t") == null)
                try std.fmt.allocPrint(part_allocator, "{s}{s}={d}", .{ separator, name.?, weight })
            else
                try std.fmt.allocPrint(part_allocator, "{s}{d}={d}", .{ separator, bone, weight });
            const append_allocator = try frameAllocator(tables);
            try text.appendSlice(append_allocator, part);
        };
        const result_allocator = try frameAllocator(tables);
        return text.toOwnedSlice(result_allocator);
    }
    return error.SelectAnchorWithControl;
}

// Names take precedence; a purely numeric token that names no bone is a stable ID.
fn parseBoneReference(definition: anytype, text: []const u8) !u32 {
    const typed = Atom.from(text);
    for (definition.bones) |bone| {
        if (bone.name == typed) return bone.id;
    }
    return std.fmt.parseInt(u32, text, 10) catch error.MissingBone;
}

pub const AnchorInfluence = struct { name: []const u8, weight: f32 };

/// Display rows for the inspected anchor; null when none is inspected.
pub fn inspectedAnchor(reads: *session.ReadContext, allocator: std.mem.Allocator) !?[]const AnchorInfluence {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const settings = config(tables);
    if (settings.point_shape.* == 0) return null;
    const definition = try reads.definition(session.get(tables).doc.*);
    for (definition.points) |point| {
        if (point.shape != settings.point_shape.* or point.index != settings.point_index.*) continue;
        var rows: std.ArrayListUnmanaged(AnchorInfluence) = .empty;
        for (point.bones, point.weights) |bone, influence| {
            if (influence <= 0) continue;
            const named = session.findById(api.read.Bone, definition.bones, bone);
            const name = if (named) |found| atoms.lookup(found.name) else null;
            try rows.append(allocator, .{ .name = name orelse "?", .weight = influence });
        }
        const owned_rows = try rows.toOwnedSlice(allocator);
        return owned_rows;
    }
    return null;
}

fn parseNumber(text: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, std.mem.trim(u8, text, " \t"));
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    return value;
}

fn testAngleDegrees(editor: session.View, bone_table: BoneStateRows, bone: u32) f32 {
    var rows = bone_table.read();
    while (rows.next()) |row| {
        if (row.view.doc.* != editor.doc.* or row.view.bone.* != bone) continue;
        if (row.view.mask.* & api.read.Channels.rotation == 0) return 0;
        return row.view.rotation.* * (180.0 / std.math.pi);
    }
    return 0;
}

pub fn submitPrompt(tables: *Table.Registry, atoms: *Atom.Registry, kind: Atom, text: []const u8) !bool {
    const editor = session.get(tables);
    const settings = config(tables);
    if (kind == names.weight_option) {
        const option = session.enumFromAtom(BrushOption, editor.prompt_field.*) orelse return error.MissingField;
        try option.apply(tables, atoms, text);
    } else if (kind == names.weight_settings) {
        var parts = std.mem.splitScalar(u8, text, ':');
        const radius = try parseNumber(parts.next() orelse return error.ExpectedRadiusStrengthValue);
        const strength = try parseNumber(parts.next() orelse return error.ExpectedRadiusStrengthValue);
        const value = try parseNumber(parts.next() orelse return error.ExpectedRadiusStrengthValue);
        if (parts.next() != null or radius <= 0 or radius > 2048 or strength < 0 or strength > 1 or value < 0 or value > 1) return error.InvalidBrushSettings;
        settings.radius.* = radius;
        settings.strength.* = strength;
        settings.value.* = value;
    } else if (kind == names.weight_numeric) {
        const capture = session.observed(tables);
        const info = session.definitionInfo(tables, atoms, editor.prompt_doc.*) orelse return error.PromptDocumentChanged;
        // Anchors have positional indices, not stable IDs. Any authored change
        // invalidates the captured index rather than risking a different vertex.
        if (info.authored_revision != capture.prompt_revision.*) return error.PromptTargetChanged;
        const definition = try session.readDefinition(tables, atoms, editor.prompt_doc.*);
        const found = for (definition.points) |point| {
            if (point.shape == editor.prompt_id.* and point.index == capture.prompt_anchor_index.*) break true;
        } else false;
        if (!found) return error.PromptTargetMissing;
        var influences: std.ArrayListUnmanaged(api.Influence) = .empty;
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |part| {
            var pair = std.mem.splitScalar(u8, part, '=');
            const bone_text = std.mem.trim(u8, pair.next().?, " \t");
            const bone = try parseBoneReference(definition, bone_text);
            const weight = try parseNumber(pair.next() orelse return error.ExpectedBoneEqualsWeight);
            if (pair.next() != null or influences.items.len >= 4) return error.ExpectedAtMostFourInfluences;
            try influences.append(try frameAllocator(tables), .{ .bone = bone, .weight = weight });
        }
        try transport.send(tables, atoms, .{
            .set_weights = .{
                .doc = editor.prompt_doc.*,
                .shape = editor.prompt_id.*,
                .index = capture.prompt_anchor_index.*,
                .influences = influences.items,
                .locked_bones = try locks(tables),
            },
        });
    } else if (kind == names.deform_spacing) {
        const spacing = try parseNumber(text);
        if (spacing <= 0) return error.InvalidSpacing;
        try transport.send(tables, atoms, .{
            .subdivide_for_deform = .{
                .doc = editor.doc.*,
                .ids = try selection.selectedShapeIds(tables),
                .spacing = spacing,
            },
        });
        settings.spacing.* = spacing;
    } else if (kind == names.test_rotation) {
        if (editor.tool.* != names.weight or settings.test_pose.* == 0) return error.PromptTargetChanged;
        const exists = session.isValidObject(tables, atoms, editor.prompt_doc.*, editor.prompt_target_kind.*, editor.prompt_id.*);
        if (!exists or editor.prompt_target_kind.* != names.bone) return error.PromptTargetMissing;
        const angle = try parseNumber(text);
        const bone_row = try boneState(session.get(tables), boneStates(tables), editor.prompt_id.*);
        bone_row.rotation.* = angle * (std.math.pi / 180.0);
        bone_row.mask.* |= api.read.Channels.rotation;
    } else return false;
    return true;
}

pub fn handleAction(tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) !bool {
    const editor = session.get(tables);
    const settings = config(tables);
    const frame_allocator = try frameAllocator(tables);
    const message = tag.to(Msg);
    for (brush_options) |option| {
        const detail = option.details();
        if (message != detail.action) continue;
        try prompts.showWeightOption(tables.memory, tables, atoms, option);
        return true;
    }
    switch (message) {
        .figure_weight_make_skinned => {
            if (editor.tool.* != names.weight) return true;
            const targets = try brushTargets(tables, atoms);
            if (targets.needs_skin.len != 0) try bindSkinned(tables, atoms, targets.needs_skin);
        },
        .figure_weight_numeric => try prompts.showWeightNumeric(tables.memory, tables, atoms),
        .figure_test_rotation => {
            if (editor.tool.* != names.weight or settings.test_pose.* == 0 or settings.bone.* == 0) return error.EnableTestPoseAndPickBone;
            const angle = testAngleDegrees(session.get(tables), boneStates(tables), settings.bone.*);
            const initial = try std.fmt.allocPrint(frame_allocator, "{d}", .{angle});
            const kind = names.bone;
            try prompts.showTarget(tables.memory, tables, atoms, names.test_rotation, initial, kind, settings.bone.*);
        },
        .figure_weight_settings => {
            const initial = try std.fmt.allocPrint(frame_allocator, "{d}:{d}:{d}", .{
                settings.radius.*,
                settings.strength.*,
                settings.value.*,
            });
            try prompts.show(tables.memory, tables, atoms, names.weight_settings, initial);
        },
        .figure_subdivide_for_deform => {
            const initial = try std.fmt.allocPrint(frame_allocator, "{d}", .{settings.spacing.*});
            try prompts.show(tables.memory, tables, atoms, names.deform_spacing, initial);
        },
        .figure_mode_weight => {
            workspace.showAtRest(tables, atoms, names.rig, names.weight);
            if (editor.active_bone.* != 0) pickBone(config(tables), session.get(tables), editor.active_bone.*);
        },
        .figure_weight_mode_add => settings.brush_mode.* = names.add,
        .figure_weight_mode_subtract => settings.brush_mode.* = names.subtract,
        .figure_weight_mode_replace => settings.brush_mode.* = names.replace,
        .figure_weight_mode_smooth => settings.brush_mode.* = names.smooth,
        .figure_weight_falloff => {
            settings.falloff.* = if (settings.falloff.* == names.smooth) names.linear else if (settings.falloff.* == names.linear) names.constant else names.smooth;
        },
        .figure_weight_mode => {
            settings.brush_mode.* = if (settings.brush_mode.* == names.add)
                names.subtract
            else if (settings.brush_mode.* == names.subtract)
                names.replace
            else if (settings.brush_mode.* == names.replace)
                names.smooth
            else
                names.add;
        },
        .figure_weight_lock => {
            const definition = try session.readDefinition(tables, atoms, editor.doc.*);
            const bone = session.findById(api.read.Bone, definition.bones, settings.bone.*) orelse return error.MissingBone;
            if (bone.flags & session.BoneFlags.deform == 0) return error.NonDeformBone;
            const bone_row = try boneState(session.get(tables), boneStates(tables), settings.bone.*);
            bone_row.locked.* = 1 - bone_row.locked.*;
        },
        .figure_test_pose => {
            if (editor.tool.* != names.weight) return error.EnterWeightMode;
            if (settings.test_pose.* != 0) {
                discard(config(tables), boneStates(tables));
                return true;
            }
            const definition = try session.readDefinition(tables, atoms, editor.doc.*);
            for (definition.pose_channels) |channels| {
                if (channels.pose != 0) continue;
                const bone_row = try boneState(session.get(tables), boneStates(tables), channels.bone);
                bone_row.mask.* = channels.mask;
                bone_row.rotation.* = channels.rotation;
                bone_row.local.* = channels.local;
                bone_row.scale.* = channels.scale;
                bone_row.length.* = channels.length;
            }
            settings.test_pose.* = 1;
        },
        .figure_bind_rigid, .figure_bind_skinned, .figure_unbind, .figure_unbind_current => {
            const ids = try selection.selectedShapeIds(tables);
            if (ids.len == 0) return error.SelectArtwork;
            switch (message) {
                .figure_bind_rigid => {
                    const bone = if (editor.active_kind.* == names.bone and editor.active_bone.* != 0) editor.active_bone.* else if (settings.bone.* != 0) settings.bone.* else editor.active_bone.*;
                    if (bone == 0) return error.PickActiveBone;
                    try transport.send(tables, atoms, .{ .bind_rigid = .{ .doc = editor.doc.*, .ids = ids, .bone = bone } });
                },
                .figure_bind_skinned => try bindSkinned(tables, atoms, ids),
                else => try transport.send(tables, atoms, .{
                    .unbind = .{
                        .doc = editor.doc.*,
                        .ids = ids,
                        .pose = if (message == .figure_unbind_current) names.current else names.rest,
                    },
                }),
            }
        },
        else => return false,
    }
    return true;
}

pub const OverlayResult = struct {
    limited: bool = false,
    diagnostic: ?anyerror = null,
    // Anchors of target paths under the visible brush; null when no target or brush is shown.
    brush_reach: ?u32 = null,
};

// Value labels stay readable only for a small neighbourhood of anchors.
const max_anchor_labels = 12;
const contour_step_px = 12;
const max_contour_steps = 32;

pub fn renderOverlay(tables: *Table.Registry, atoms: *Atom.Registry, render_context: anytype) OverlayResult {
    var result = OverlayResult{};
    const editor = session.get(tables);
    if (editor.tool.* != names.weight) return result;
    const settings = config(tables);
    const projected = weightGeometry(tables, atoms) catch |err| return .{ .diagnostic = err };
    const zoom = editor.view_zoom.*;
    const shape_kind = names.shape;
    const painting = editor.gesture_active.* != 0 and editor.gesture_kind.* == names.weight_stroke;
    const brush_visible = painting or view.canvasOwnsHover(tables);
    // Hover stops updating while the pointer is captured by a stroke.
    const brush_center = if (painting) editor.gesture_current.* else editor.hover_point.*;
    if (session.bonesShown(editor)) drawBrushBone(tables, atoms, render_context, settings.bone.*, zoom);
    var has_target = false;
    var reach: u32 = 0;
    var labels: u32 = 0;
    for (projected.shapes) |shape| {
        if (!shape.overlay_visible) continue;
        const is_target = selection.contains(session.get(tables), session.selections(tables), shape_kind, shape.id) or settings.point_shape.* == shape.id;
        has_target = has_target or is_target;
        const samples = projected.samples[shape.samples.start..][0..shape.samples.len];
        if (!drawHeatContour(render_context, samples, settings.bone.*, zoom, is_target)) result.limited = true;
        for (projected.points[shape.points.start..][0..shape.points.len]) |point| {
            const remaining = render_context.pathBudget();
            if (!canvas.overlayCapacity(remaining)) {
                result.limited = true;
                break;
            }
            const influence = boneInfluence(point.influences, settings.bone.*);
            const screen_distance = distance(brush_center, point.position) * zoom;
            const factor = falloffFactor(settings.falloff.*, screen_distance, settings.radius.*);
            const reached = is_target and brush_visible and factor > 0;
            if (reached) drawReachedAnchor(render_context, point.position, factor, zoom);
            drawAnchor(render_context, point.position, zoom, influence);
            if (settings.point_shape.* == shape.id and settings.point_index.* == point.index) {
                render_context.beginPath();
                render_context.circle(point.position.x, point.position.y, 9 / zoom);
                render_context.strokeColor(controls.paper);
                render_context.strokeWidth(3.5 / zoom);
                render_context.stroke();
                render_context.strokeColor(controls.ink);
                render_context.strokeWidth(1.5 / zoom);
                render_context.stroke();
            }
            if (!reached) continue;
            reach += 1;
            if (labels == max_anchor_labels) continue;
            labels += 1;
            var label_buffer: [16]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "{d:.2}", .{influence}) catch continue;
            if (canvas.renderBadge(render_context, point.position, label)) result.limited = true;
        }
    }
    if (!brush_visible) return result;
    if (has_target) result.brush_reach = reach;
    const remaining = render_context.pathBudget();
    if (!canvas.overlayCapacity(remaining)) {
        result.limited = true;
        return result;
    }
    const bone_locked = locked(boneStates(tables), settings.bone.*);
    const ready = has_target and settings.bone.* != 0 and !bone_locked;
    drawBrush(render_context, brush_center, settings, zoom, if (ready) controls.ink else controls.caution);
    const allocator = frameAllocator(tables) catch return result;
    const bone_name = brushBoneName(tables, atoms) catch "";
    const mode_name = atoms.lookup(settings.brush_mode.*) orelse "";
    const lock_suffix = if (bone_locked) " (locked)" else "";
    const label = std.fmt.allocPrint(allocator, "{s}: {s}{s}", .{ mode_name, bone_name, lock_suffix }) catch return result;
    const below_brush = session.Vec2{ .x = brush_center.x, .y = brush_center.y + settings.radius.* / zoom };
    if (canvas.renderBadge(render_context, below_brush, label)) result.limited = true;
    return result;
}

fn boneInfluence(influences: api.WeightInfluences, bone: u32) f32 {
    for (influences.bones, influences.weights) |id, weight| if (bone != 0 and id == bone) return weight;
    return 0;
}

pub fn heatColor(weight: f32, alpha: u8) roop.Color {
    const clamped = std.math.clamp(weight, 0, 1);
    const red: u8 = @intFromFloat(255 * clamped);
    const green: u8 = @intFromFloat(219 * (1 - @abs(2 * clamped - 1)));
    const blue: u8 = @intFromFloat(255 * (1 - clamped));
    return roop.rgba(red, green, blue, alpha);
}

// Heat follows the artwork's own outline so the weight field reads between anchors.
// Returns false when the path budget ended the contour early.
fn drawHeatContour(render_context: anytype, samples: []const api.WeightSample, bone: u32, zoom: f32, emphasized: bool) bool {
    if (samples.len < 2) return true;
    const width: f32 = if (emphasized) 5 else 2;
    for (samples[0 .. samples.len - 1], samples[1..]) |from, to| {
        const from_weight = boneInfluence(from.influences, bone);
        const to_weight = boneInfluence(to.influences, bone);
        // Long flat edges would otherwise show one averaged color between differing anchors.
        const screen_length = distance(from.position, to.position) * zoom;
        const steps: u32 = if (from_weight == to_weight) 1 else @intFromFloat(std.math.clamp(screen_length / contour_step_px, 1, max_contour_steps));
        const step_count: f32 = @floatFromInt(steps);
        for (0..steps) |step| {
            const remaining = render_context.pathBudget();
            if (!canvas.overlayCapacity(remaining)) return false;
            const step_index: f32 = @floatFromInt(step);
            const start = step_index / step_count;
            const end = (step_index + 1) / step_count;
            const middle = (start + end) / 2;
            render_context.beginPath();
            render_context.moveTo(std.math.lerp(from.position.x, to.position.x, start), std.math.lerp(from.position.y, to.position.y, start));
            render_context.lineTo(std.math.lerp(from.position.x, to.position.x, end), std.math.lerp(from.position.y, to.position.y, end));
            render_context.strokeColor(heatColor(std.math.lerp(from_weight, to_weight, middle), 255));
            render_context.strokeWidth(width / zoom);
            render_context.stroke();
        }
    }
    return true;
}

fn drawBrushBone(tables: *Table.Registry, atoms: *Atom.Registry, render_context: anytype, bone: u32, zoom: f32) void {
    const remaining = render_context.pathBudget();
    if (!canvas.overlayCapacity(remaining)) return;
    const evaluation = preview.evaluation(tables, atoms) catch return;
    for (evaluation.bones) |evaluated| {
        if (evaluated.id != bone) continue;
        render_context.beginPath();
        render_context.moveTo(evaluated.origin.x, evaluated.origin.y);
        render_context.lineTo(evaluated.tip.x, evaluated.tip.y);
        render_context.strokeColor(controls.paper);
        render_context.strokeWidth(5 / zoom);
        render_context.stroke();
        render_context.strokeColor(controls.joint);
        render_context.strokeWidth(3 / zoom);
        render_context.stroke();
        return;
    }
}

fn drawReachedAnchor(render_context: anytype, point: session.Vec2, factor: f32, zoom: f32) void {
    render_context.beginPath();
    render_context.circle(point.x, point.y, (7 + 5 * factor) / zoom);
    render_context.fillColor(controls.selection_wash);
    render_context.fill();
    render_context.strokeColor(controls.target);
    render_context.strokeWidth(1.5 / zoom);
    render_context.stroke();
}

fn drawAnchor(render_context: anytype, point: session.Vec2, zoom: f32, weight: f32) void {
    render_context.beginPath();
    render_context.circle(point.x, point.y, 5 / zoom);
    render_context.fillColor(heatColor(weight, 255));
    render_context.fill();
    render_context.strokeColor(controls.paper);
    render_context.strokeWidth(1.5 / zoom);
    render_context.stroke();
}

fn drawBrush(render_context: anytype, center: session.Vec2, settings: session.Row(Config), zoom: f32, color: roop.Color) void {
    const radius = settings.radius.* / zoom;
    render_context.beginPath();
    render_context.circle(center.x, center.y, radius);
    render_context.strokeColor(controls.paper);
    render_context.strokeWidth(3.5 / zoom);
    render_context.stroke();
    render_context.strokeColor(color);
    render_context.strokeWidth(1.5 / zoom);
    render_context.stroke();
    // Smooth and linear falloffs both reach half effect at half the radius.
    if (settings.falloff.* == Atom.from("constant")) return;
    render_context.beginPath();
    render_context.circle(center.x, center.y, radius / 2);
    render_context.strokeColor(controls.muted);
    render_context.strokeWidth(controls.line_width / zoom);
    render_context.stroke();
}

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&brush_modes);
    try atoms.tryInternAll(&brush_falloffs);
    try session.prepareSingleton(Config, mem, atoms, tables, config_name);
    try session.prepareTable(BoneState, mem, atoms, tables, bones_name, bone_state_capacity);
    try session.prepareSingleton(Stroke, mem, atoms, tables, stroke_name);
    try session.prepareTable(Target, mem, atoms, tables, targets_name, target_capacity);
    try session.prepareTable(Sample, mem, atoms, tables, samples_name, sample_capacity);
    try session.prepareTable(TargetShape, mem, atoms, tables, shapes_name, shape_capacity);
    try session.prepareTable(StrokeLock, mem, atoms, tables, locks_name, api.max_weight_batch_locks);
}
