//! Working-pose authoring. Runtime commands remain the only document mutation path.

const std = @import("std");
const mesha = @import("mesha");
const modes = @import("../modes.zig");
const Atom = mesha.Atom;
const names = @import("names.zig");
const drawing = @import("drawing.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const math = mesha.math;
const plugin = mesha.plugin;
const figure = mesha.figure;
const zon = mesha.zon;

const geometry = @import("geometry.zig");
const session = @import("session.zig");
const watches = @import("watches.zig");
const preview = @import("preview.zig");
const selection = @import("selection.zig");
const prompts = @import("prompts.zig");
const transport = @import("commands.zig");
const filmstrip = @import("filmstrip.zig");
const workspace = @import("workspace.zig");
const weight = @import("weight.zig");
const gesture = @import("gesture.zig");
const asks = @import("asks.zig");

const api = plugin.figure_api;

const sequencer = mesha.sequencer;

// ---- the system -----------------------------------------------------------------------------

/// Posing: the pose mode and IK tool, their chain settings, the pose library and the pose
/// clipboard. Pose drags start from the canvas's press and flush through the gesture.
pub fn system() sequencer.System {
    return .{
        .name = "figure_pose",
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claims,
        .active = workspace.shown,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_pose.take_actions", .run = takeActions },
        },
    };
}

/// The tags of posing's actions.
pub const Msg = enum(u64) {
    figure_pose_auto_ik = Atom.from("figure_pose_auto_ik").value(),
    figure_pose_chain_more = Atom.from("figure_pose_chain_more").value(),
    figure_pose_chain_less = Atom.from("figure_pose_chain_less").value(),
    figure_tool_ik = Atom.from("figure_tool_ik").value(),
    figure_ik_more = Atom.from("figure_ik_more").value(),
    figure_ik_less = Atom.from("figure_ik_less").value(),
    figure_ik_values = Atom.from("figure_ik_values").value(),
    figure_ik_pin = Atom.from("figure_ik_pin").value(),
    figure_ik_unpin = Atom.from("figure_ik_unpin").value(),
    figure_ik_target = Atom.from("figure_ik_target").value(),
    figure_pose_reset_bone = Atom.from("figure_pose_reset_bone").value(),
    figure_pose_reset = Atom.from("figure_pose_reset").value(),
    figure_pose_save = Atom.from("figure_pose_save").value(),
    figure_pose_apply = Atom.from("figure_pose_apply").value(),
    figure_pose_delete = Atom.from("figure_pose_delete").value(),
    figure_pose_copy = Atom.from("figure_pose_copy").value(),
    figure_pose_paste = Atom.from("figure_pose_paste").value(),
    figure_pose_mirror = Atom.from("figure_pose_mirror").value(),
    _,
};

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// Only in a frame with actions: they reach the posing rows, the selection, the animation's
/// working pose, the requests they send and the prompts they open, and stop weight painting.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const groups = workspace.table_groups;
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    result.readAll(&groups.state);
    if (frame.messages.len == 0) return result;
    result.writeAll(&groups.state);
    result.writeAll(&groups.selected);
    result.writeAll(&groups.pose_rows);
    result.writeAll(&.{ groups.commands, groups.figure_requests, groups.palette_requests, Atom.from(weight.bones_name) });
    return result;
}

fn takeActions(pass: *sequencer.Pass) !void {
    try workspace.takeToolActions(pass, claims, runAction);
}

fn runAction(frame: *const sequencer.Frame, received: sequencer.Message) !void {
    _ = try handleAction(frame.tables, frame.atoms, received.tag);
}

/// Starting row count; the tables grow with the rig being copied.
const clipboard_capacity = 4096;

pub const config_name = "editor_figure_pose";

pub const clipboard_bones_name = "editor_figure_pose_clipboard_bones";

pub const clipboard_ik_name = "editor_figure_pose_clipboard_ik";

pub const drag_chain_name = "editor_figure_pose_drag_chain";

/// Starting row count; a press grows the table to the chain it captures.
const drag_chain_capacity = 64;

/// Pose settings and drag solve state; the drag lifecycle is owned by gesture.zig.
pub const Config = struct {
    selected_pose: u32 = 0,
    auto_ik: u8 = 1,
    auto_chain_length: u32 = 2,
    bend: api.BendReference = .{},
    achieved: session.Vec2 = session.zero,
    residual: f64 = 0,
    ik_end: u32 = 0,
    ik_chain: u32 = 2,
    drag_bone: u32 = 0,
    drag_ik: u32 = 0,
    inverse: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    reference: f32 = 0,
    has_reference: u8 = 0,
    dragging: u8 = 0,
    /// Captured selected-key destination for the whole gesture.
    key_clip: u32 = 0,
    key_frame: u32 = 0,
    last_target: session.Vec2 = session.zero,
    has_target: u8 = 0,
    clipboard_valid: u8 = 0,
};

// Editor tables store copied public payload values; their lifetime/budget stays local.
pub const ClipboardBone = api.PoseClipboardBone;
pub const ClipboardIK = api.PoseClipboardIK;

/// One bone of the Auto IK chain a press captured, with its authored channels at that press.
/// A freed table does not keep insertion order, so `position` holds root-to-tip order.
pub const DragChainLink = struct { position: u32, bone: u32, seed: api.PoseChannels };

pub const DragChain = struct { bones: []u32, seeds: []api.PoseChannels };

pub const actions = blk: {
    const definitions = .{
        .{ Msg.figure_pose_auto_ik, "Toggle Auto IK / FK joint dragging" },
        .{ Msg.figure_pose_chain_more, "Increase automatic IK chain length" },
        .{ Msg.figure_pose_chain_less, "Decrease automatic IK chain length" },
        .{ Msg.figure_tool_ik, "Rig IK: click end joint, adjust chain, Enter commits" },
        .{ Msg.figure_ik_more, "Increase draft IK chain length" },
        .{ Msg.figure_ik_less, "Decrease draft IK chain length" },
        .{ Msg.figure_ik_values, "IK chain:bend(-1/0/1):stretch(0/1):pinned_default(0/1)" },
        .{ Msg.figure_ik_pin, "Capture and pin selected bone's IK endpoint" },
        .{ Msg.figure_ik_unpin, "Bake solved FK and disable selected bone's IK without a jump" },
        .{ Msg.figure_ik_target, "IK target x,y:outgoing_angle_degrees in row target space" },
        .{ Msg.figure_pose_reset_bone, "Reset selected bone channel and its active chain to rest" },
        .{ Msg.figure_pose_reset, "Reset entire working pose to rest" },
        .{ Msg.figure_pose_save, "Save working pose with a name" },
        .{ Msg.figure_pose_apply, "Apply a named pose (completion list)" },
        .{ Msg.figure_pose_delete, "Delete selected named pose (clip references reject)" },
        .{ Msg.figure_pose_copy, "Copy authored working channels and IK to session clipboard" },
        .{ Msg.figure_pose_paste, "Replace working pose from compatible name-matched clipboard" },
        .{ Msg.figure_pose_mirror, "Mirror working pose on a compatible symmetric rest rig" },
    };
    var result: [definitions.len]plugin.action_api.Def = undefined;
    for (definitions, 0..) |action_definition, i| result[i] = .{ .name = modes.shortName("figure", @tagName(action_definition[0])), .tag = @tagName(action_definition[0]), .doc = action_definition[1] };
    break :blk result;
};

pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try preview.ensure(tables, atoms);
    try session.prepareSingleton(Config, mem, atoms, tables, config_name);
    try session.prepareTable(ClipboardBone, mem, atoms, tables, clipboard_bones_name, clipboard_capacity);
    try session.prepareTable(ClipboardIK, mem, atoms, tables, clipboard_ik_name, clipboard_capacity);
    try session.prepareTable(DragChainLink, mem, atoms, tables, drag_chain_name, drag_chain_capacity);
}

pub const ConfigView = session.Row(Config);
pub fn config(tables: *Table.Registry) ConfigView {
    const config_table = tables.findByName(Atom.from(config_name)).?;
    return config_table.getRow(.{ .row = 0, .generation = config_table.rowGeneration(0) }, session.Row(Config)).?;
}

/// The bones a pose drag moves by IK, root to tip, a row each.
pub const DragChainRows = sequencer.Rows(session.Row(DragChainLink));
pub fn dragChainLinks(tables: *Table.Registry) DragChainRows {
    return .of(tables.findByName(Atom.from(drag_chain_name)).?);
}
/// The pose clipboard, a row per bone and per IK controller.
pub const ClipboardBoneRows = sequencer.Rows(session.Row(ClipboardBone));
pub fn clipboardBones(tables: *Table.Registry) ClipboardBoneRows {
    return .of(tables.findByName(Atom.from(clipboard_bones_name)).?);
}
pub const ClipboardIKRows = sequencer.Rows(session.Row(ClipboardIK));
pub fn clipboardIK(tables: *Table.Registry) ClipboardIKRows {
    return .of(tables.findByName(Atom.from(clipboard_ik_name)).?);
}

pub fn dragChainLength(drag_chain: DragChainRows) u32 {
    return drag_chain.count();
}

/// The captured chain, root to tip, copied into `allocator`.
pub fn dragChain(links: DragChainRows, allocator: std.mem.Allocator) !DragChain {
    const bones = try allocator.alloc(u32, links.count());
    const seeds = try allocator.alloc(api.PoseChannels, links.count());
    var rows = links.query();
    while (rows.next()) |row| {
        const link = session.readRow(DragChainLink, row.view);
        bones[link.position] = link.bone;
        seeds[link.position] = link.seed;
    }
    return .{ .bones = bones, .seeds = seeds };
}

fn frameAllocator(tables: *Table.Registry) !std.mem.Allocator {
    return (try tables.memory.frameScratchAllocator()).allocator;
}

fn requireBone(definition: api.read.Definition, id: u32) !api.read.Bone {
    return session.findById(api.read.Bone, definition.bones, id) orelse error.MissingBone;
}

fn evaluatedBone(evaluation: api.Evaluation, id: u32) !api.EvaluatedBone {
    return session.findById(api.EvaluatedBone, evaluation.bones, id) orelse error.MissingBone;
}

const SolvedChannels = struct { rotation: f32, local: session.Vec2, scale: session.Vec2, length: f32 };

pub fn readSolvedChannels(evaluation: api.Evaluation, id: u32) !SolvedChannels {
    for (evaluation.channels) |row| if (row.bone == id) return .{
        .rotation = row.rotation orelse return error.InvalidPose,
        .local = row.local orelse return error.InvalidPose,
        .scale = row.scale orelse return error.InvalidPose,
        .length = row.length orelse return error.InvalidPose,
    };
    return error.MissingBone;
}

pub fn readAuthoredChannels(tables: *Table.Registry, atoms: *Atom.Registry, id: u32) !api.PoseChannels {
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    return authoredChannelsFromDefinition(definition, id);
}

fn authoredChannelsFromDefinition(definition: api.read.Definition, id: u32) api.PoseChannels {
    for (definition.pose_channels) |row| if (row.pose == 0 and row.bone == id) return .{
        .bone = row.bone,
        .rotation = if (row.mask & 1 != 0) row.rotation else null,
        .local = if (row.mask & 2 != 0) row.local else null,
        .scale = if (row.mask & 4 != 0) row.scale else null,
        .length = if (row.mask & 8 != 0) row.length else null,
    };
    return .{ .bone = id };
}

fn submitChannels(tables: *Table.Registry, atoms: *Atom.Registry, channels: api.PoseChannels) !void {
    const unchanged = std.meta.eql(channels, try readAuthoredChannels(tables, atoms, channels.bone));
    const updated_channels = try (try frameAllocator(tables)).alloc(api.PoseChannels, if (unchanged) 0 else 1);
    if (!unchanged) updated_channels[0] = channels;
    const payload = api.Payload{ .set_pose_channels = .{ .doc = session.get(tables).doc.*, .channels = updated_channels } };
    try filmstrip.editPose(tables, atoms, payload);
}

fn controller(definition: api.read.Definition, id: u32) ?usize {
    for (definition.ik, 0..) |ik, i| if (ik.end_bone == id) return i;
    return null;
}

pub fn enabledEndpointController(definition: api.read.Definition, id: u32) ?usize {
    const i = controller(definition, id) orelse return null;
    for (definition.pose_ik) |row| {
        if (row.pose == 0 and row.ik == definition.ik[i].id and row.enabled != 0) return i;
    }
    return null;
}

/// Space for any chain `automaticChain` can return: it never crosses more bones than exist.
pub fn automaticChainCapacity(definition: api.read.Definition, limit: u32) usize {
    return @min(limit, definition.bones.len);
}

pub fn automaticHoverChain(definition: api.read.Definition, endpoint: u32, limit: u32, out: []u32) u32 {
    if (enabledEndpointController(definition, endpoint) != null) return 0;
    return automaticChain(definition, endpoint, limit, out);
}

pub fn activeController(tables: *Table.Registry, atoms: *Atom.Registry) !api.read.IK {
    const editor = session.get(tables);
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const index = controller(definition, editor.active_bone.*) orelse return error.SelectIKEndJoint;
    return definition.ik[index];
}

/// Fixed press-frame inverse and angle offset: moves never integrate a prior move.
pub const FKDrag = struct {
    inverse: math.Affine2f,
    origin: session.Vec2,
    start: session.Vec2,
    rotation: f32,
    length: f32,
    zoom: f32,
    reference: ?f32,
    dragging: bool = false,
    pub fn init(inverse: math.Affine2f, origin: session.Vec2, start: session.Vec2, rotation: f32, length: f32, zoom: f32) FKDrag {
        const local_delta = inverse.applyVector(session.Vec2.sub(start, origin));
        return .{
            .inverse = inverse,
            .origin = origin,
            .start = start,
            .rotation = rotation,
            .length = length,
            .zoom = zoom,
            .reference = if (geometry.segmentDistance(start, origin, origin) * zoom >= 3) std.math.atan2(local_delta.y, local_delta.x) else null,
        };
    }
    pub fn move(self: *FKDrag, point: session.Vec2, stretch: bool) ?struct { rotation: f32, length: ?f32 } {
        if (!self.dragging and geometry.segmentDistance(point, self.start, self.start) * self.zoom < 3) return null;
        self.dragging = true;
        if (geometry.segmentDistance(point, self.origin, self.origin) * self.zoom < 3) return null;
        const local_delta = self.inverse.applyVector(session.Vec2.sub(point, self.origin));
        const angle = std.math.atan2(local_delta.y, local_delta.x);
        const reference = self.reference orelse {
            self.reference = angle;
            return null;
        };
        const delta = angle - reference;
        const start = self.inverse.applyVector(session.Vec2.sub(self.start, self.origin));
        const radius = @sqrt(start.x * start.x + start.y * start.y);
        return .{
            .rotation = self.rotation + std.math.atan2(@sin(delta), @cos(delta)),
            .length = if (stretch and radius > 1e-6) self.length * @sqrt(local_delta.x * local_delta.x + local_delta.y * local_delta.y) / radius else null,
        };
    }
};

/// Shared by press interpretation and hover feedback; never crosses rig boundaries.
pub fn automaticChain(definition: api.read.Definition, endpoint: u32, limit: u32, out: []u32) u32 {
    var current = requireBone(definition, endpoint) catch return 0;
    var count: usize = 0;
    while (count < @min(limit, out.len) and current.flags & session.BoneFlags.static == 0) {
        out[count] = current.id;
        count += 1;
        if (current.parent == 0 or current.flags & session.BoneFlags.connected == 0) break;
        current = requireBone(definition, current.parent) catch break;
    }
    std.mem.reverse(u32, out[0..count]);
    return @intCast(count);
}

pub fn hoverIntent(definition: api.read.Definition, id: u32, sub: u32, automatic: bool, chain: []const u32) []const u8 {
    const authored_bone = requireBone(definition, id) catch return "";
    if (authored_bone.flags & session.BoneFlags.static != 0) return "Unavailable: static bone (selection only)";
    if (sub != 1) return if (authored_bone.parent == 0) "Rotate bone; Alt: move root; Ctrl: stretch if enabled" else "Rotate bone; Ctrl: stretch if enabled";
    if (enabledEndpointController(definition, id) != null) return "Move authored IK target (pins preserved)";
    for (definition.pose_ik) |state| if (state.pose == 0 and state.enabled != 0) {
        const controller_definition = session.findById(api.read.IK, definition.ik, state.ik) orelse continue;
        if (!automatic) continue;
        var member = requireBone(definition, controller_definition.end_bone) catch continue;
        for (0..controller_definition.chain) |_| {
            if (std.mem.indexOfScalar(u32, chain, member.id) != null) return "Unavailable: automatic chain overlaps authored IK; use FK";
            if (member.parent == 0) break;
            member = requireBone(definition, member.parent) catch break;
        }
    };
    return if (automatic) "Move limb (Auto IK); chain root fixed; Ctrl: FK stretch if enabled" else "Rotate bone (FK); Alt: move root";
}

pub fn pointerDown(tables: *Table.Registry, atoms: *Atom.Registry, point: session.Vec2, alt: bool, control: bool) !bool {
    const editor = session.get(tables);
    const settings = config(tables);
    if (editor.tool.* == names.ik and editor.mode.* == names.rig) {
        if (!session.bonesShown(editor)) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Show bones to choose an IK chain");
            return true;
        }
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const evaluation = try preview.workingEvaluation(tables, true);
        const picked = geometry.pickJoint(evaluation.bones, point, editor.view_zoom.*) orelse return true;
        if (picked.sub != 1) return error.SelectIKEndJoint;
        selection.select(tables, atoms, names.bone, picked.id, false, false);
        settings.ik_end.* = picked.id;
        settings.ik_chain.* = if (controller(definition, picked.id)) |i| definition.ik[i].chain else 2;
        prompts.inform(session.feedbackTable(tables), session.feedback(tables), "IK draft: Up/Down chain length; Enter commits; Esc cancels");
        return true;
    }
    if (!filmstrip.enabled(editor)) return false;
    try filmstrip.canEditPose(tables, atoms);
    if (gesture.busy(gesture.get(tables))) return error.PoseGestureSettling;
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const evaluation = try preview.workingEvaluation(tables, false);
    const picked = geometry.pickBone(evaluation.bones, point, editor.view_zoom.*) orelse return true;
    const authored_bone = try requireBone(definition, picked.id);
    const evaluated_bone = try evaluatedBone(evaluation, picked.id);
    selection.select(tables, atoms, names.bone, picked.id, false, false);
    if (authored_bone.flags & session.BoneFlags.static != 0) return error.StaticBone;
    settings.has_target.* = 0;
    settings.key_clip.* = 0;
    if (filmstrip.enabled(session.get(tables))) if (filmstrip.reconcileSelectedKey(tables, atoms)) |key| {
        settings.key_clip.* = filmstrip.config(tables).clip.*;
        settings.key_frame.* = key.frame;
    };
    settings.drag_bone.* = picked.id;
    settings.drag_ik.* = 0;
    settings.dragging.* = 0;
    editor.gesture_origin.* = evaluated_bone.origin;
    const channels = try readAuthoredChannels(tables, atoms, picked.id);
    editor.gesture_rotation.* = channels.rotation orelse authored_bone.rotation;
    editor.gesture_length.* = channels.length orelse authored_bone.length;
    editor.gesture_local.* = channels.local orelse authored_bone.local;
    editor.gesture_modifiers.* = @as(u8, if (alt) 2 else 0) | @as(u8, if (control) 4 else 0);
    var inverse = if (authored_bone.parent == 0) math.Affine2f.identity else (try evaluatedBone(evaluation, authored_bone.parent)).world.inverse() orelse return error.InvalidTransform;
    editor.gesture_kind.* = if (alt and authored_bone.parent == 0) names.pose_root else names.pose_fk;
    const endpoint_controller = enabledEndpointController(definition, picked.id);
    if (picked.sub == 1 and !(alt and authored_bone.parent == 0)) if (endpoint_controller) |i| {
        const ik = definition.ik[i];
        settings.drag_ik.* = ik.id;
        editor.gesture_kind.* = names.pose_ik;
        editor.gesture_local.* = evaluated_bone.tip;
        inverse = math.Affine2f.identity;
        for (definition.pose_ik) |row| if (row.pose == 0 and row.ik == ik.id and row.enabled != 0 and row.pinned == 0) {
            // Authoring target space follows authored ancestry, not compiler indices.
            var root = try requireBone(definition, ik.end_bone);
            if (ik.chain == 0 or ik.chain > definition.bones.len) return error.InvalidIK;
            for (1..ik.chain) |_| root = try requireBone(definition, root.parent);
            const parent = root.parent;
            inverse = if (parent == 0) math.Affine2f.identity else (try evaluatedBone(evaluation, parent)).world.inverse() orelse return error.InvalidTransform;
        };
    };
    const drag_links = dragChainLinks(tables);
    drag_links.clear();
    if (picked.sub == 1 and endpoint_controller == null and settings.auto_ik.* != 0 and !(alt and authored_bone.parent == 0) and !(control and authored_bone.flags & session.BoneFlags.stretchy != 0)) {
        const frame_allocator = try frameAllocator(tables);
        const chain_capacity = automaticChainCapacity(definition, settings.auto_chain_length.*);
        const chain_storage = try frame_allocator.alloc(u32, chain_capacity);
        const chain_length = automaticChain(definition, authored_bone.id, settings.auto_chain_length.*, chain_storage);
        const chain = chain_storage[0..chain_length];
        for (chain, 0..) |id, i| {
            const seed = authoredChannelsFromDefinition(definition, id);
            _ = try drag_links.insert(DragChainLink{ .position = @intCast(i), .bone = id, .seed = seed });
        }
        for (definition.pose_ik) |ik_state| if (ik_state.pose == 0 and ik_state.enabled != 0) {
            const index = for (definition.ik, 0..) |ik, i| {
                if (ik.id == ik_state.ik) break i;
            } else continue;
            const ik = definition.ik[index];
            var member = try requireBone(definition, ik.end_bone);
            for (0..ik.chain) |_| {
                if (std.mem.indexOfScalar(u32, chain, member.id) != null) return error.AutoIKAuthoredControllerBoundary;
                if (member.parent == 0) break;
                member = try requireBone(definition, member.parent);
            }
        };
        // The host solves the chain where it is, which checks its constraints before any
        // transaction opens and gives the bend the drag keeps (`pressAnswered`); the drag
        // previews nothing until then.
        const inputs = try preview.workingInputs(tables, atoms);
        const query: figure.Query = .{ .solve_transient_pose = .{
            .definition = editor.doc.*,
            .query = .{ .inputs = inputs, .chain = chain, .target = evaluated_bone.tip },
        } };
        const context = session.figureContext(tables, atoms);
        const asked = asks.rows(tables);
        const asker = gesture.system();
        try asks.ask(context, asked, editor, asker, query, .{ .purpose = .pose_press, .point = evaluated_bone.tip });
        settings.bend.* = .{};
        settings.achieved.* = evaluated_bone.tip;
        settings.residual.* = 0;
        editor.gesture_local.* = evaluated_bone.tip;
        editor.gesture_kind.* = names.pose_auto_ik;
        prompts.inform(session.feedbackTable(tables), session.feedback(tables), if (chain_length < settings.auto_chain_length.*) "Auto IK: chain stopped at rig boundary" else "Auto IK: move limb");
    }
    settings.inverse.* = @bitCast(inverse);
    const drag = FKDrag.init(inverse, editor.gesture_origin.*, point, editor.gesture_rotation.*, editor.gesture_length.*, editor.view_zoom.*);
    settings.reference.* = drag.reference orelse 0;
    settings.has_reference.* = @intFromBool(drag.reference != null);
    const press = gesture.Pointer{ .point = point, .screen = editor.gesture_start_screen.*, .modifiers = editor.gesture_modifiers.* };
    try gesture.begin(gesture.get(tables), .{ .kind = .pose, .doc = editor.doc.*, .pointer = press });
    editor.gesture_active.* = 1;
    return true;
}

/// One coalesced pose preview, recomputed from the press frame and the latest
/// sample. The working pose and selected key publish in one envelope.
pub fn previewDrag(tables: *Table.Registry, atoms: *Atom.Registry, drag: gesture.Drag) !void {
    const editor = session.get(tables);
    const settings = config(tables);
    const kind = editor.gesture_kind.*;
    const point = drag.latest.point;
    const start = drag.origin;
    const pointer_distance = geometry.segmentDistance(point, start, start);
    if (settings.dragging.* == 0 and pointer_distance * editor.view_zoom.* < 3) return;
    const inverse: math.Affine2f = @bitCast(settings.inverse.*);
    const pointer_delta = session.Vec2.sub(point, start);
    if (kind == names.pose_auto_ik) {
        const target = session.Vec2.add(editor.gesture_local.*, pointer_delta);
        if (settings.has_target.* != 0 and std.meta.eql(target, settings.last_target.*)) return;
        try askDragSolve(tables, atoms, drag.doc, target);
        // The sample stays pending until `dragAnswered` has previewed its solve.
        return error.Busy;
    } else if (kind == names.pose_ik) {
        const document_target = session.Vec2.add(editor.gesture_local.*, pointer_delta);
        const target = inverse.apply(document_target);
        if (settings.has_target.* != 0 and std.meta.eql(target, settings.last_target.*)) return;
        try submitDragPreview(tables, atoms, .{ .set_ik_target = .{ .doc = drag.doc, .id = settings.drag_ik.*, .target = target } });
        settings.last_target.* = target;
        settings.has_target.* = 1;
    } else {
        var channels = try readAuthoredChannels(tables, atoms, settings.drag_bone.*);
        if (kind == names.pose_root) {
            const local_delta = inverse.applyVector(pointer_delta);
            channels.local = session.Vec2.add(editor.gesture_local.*, local_delta);
        } else {
            const definition = try session.readDefinition(tables, atoms, editor.doc.*);
            const authored_bone = try requireBone(definition, settings.drag_bone.*);
            var fk_drag = FKDrag{
                .inverse = inverse,
                .origin = editor.gesture_origin.*,
                .start = start,
                .rotation = editor.gesture_rotation.*,
                .length = editor.gesture_length.*,
                .zoom = editor.view_zoom.*,
                .reference = if (settings.has_reference.* != 0) settings.reference.* else null,
                .dragging = settings.dragging.* != 0,
            };
            // Pose modifiers are press-time: Ctrl at the press requests stretch.
            const stretch_requested = editor.gesture_modifiers.* & gesture.Modifiers.control != 0;
            const stretchy = authored_bone.flags & session.BoneFlags.stretchy != 0;
            const result = fk_drag.move(point, stretch_requested and stretchy);
            settings.reference.* = fk_drag.reference orelse 0;
            settings.has_reference.* = @intFromBool(fk_drag.reference != null);
            settings.dragging.* = @intFromBool(fk_drag.dragging);
            const updated_channels = result orelse return;
            channels.rotation = updated_channels.rotation;
            if (updated_channels.length) |length| channels.length = length;
        }
        const authored_channels = try readAuthoredChannels(tables, atoms, channels.bone);
        if (std.meta.eql(channels, authored_channels)) return;
        const frame_allocator = try frameAllocator(tables);
        const updated_channels = try frame_allocator.alloc(api.PoseChannels, 1);
        updated_channels[0] = channels;
        try submitDragPreview(tables, atoms, .{ .set_pose_channels = .{ .doc = drag.doc, .channels = updated_channels } });
    }
    settings.dragging.* = 1;
}

/// Asks the host how the Auto IK drag's chain reaches `target` from the seeds its press
/// captured, keeping the bend it has, answered in the gesture system's inbox
/// (`dragAnswered`). The drag waits for the answer before it previews again or ends.
fn askDragSolve(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom, target: session.Vec2) !void {
    const settings = config(tables);
    const frame_allocator = try frameAllocator(tables);
    const inputs = try preview.workingInputs(tables, atoms);
    const drag_chain = try dragChain(dragChainLinks(tables), frame_allocator);
    const chain = drag_chain.bones;
    var channels: std.ArrayListUnmanaged(api.PoseChannels) = .empty;
    for (inputs.channels) |row| if (std.mem.indexOfScalar(u32, chain, row.bone) == null) {
        try channels.append(frame_allocator, row);
    };
    try channels.appendSlice(frame_allocator, drag_chain.seeds);
    const query: figure.Query = .{ .solve_transient_pose = .{
        .definition = doc,
        .query = .{
            .inputs = .{ .channels = channels.items, .ik = inputs.ik },
            .chain = chain,
            .target = target,
            .reference = settings.bend.*,
        },
    } };
    const context = session.figureContext(tables, atoms);
    const asked = asks.rows(tables);
    const editor = session.get(tables);
    const asker = gesture.system();
    try asks.ask(context, asked, editor, asker, query, .{ .purpose = .pose_drag, .point = target });
}

/// Whether the drag a pose answer was asked for still goes on: an Auto IK drag that has not been
/// cancelled or failed.
fn autoDragGoesOn(drag_state: gesture.View, editor: session.View) bool {
    if (gesture.kindOf(drag_state) != .pose or editor.gesture_kind.* != names.pose_auto_ik) return false;
    return switch (gesture.phaseOf(drag_state)) {
        .sampling => true,
        .draining => gesture.intentOf(drag_state) == .commit,
        .idle, .awaiting_terminal => false,
    };
}

/// The Auto IK press's solve: a chain that cannot be solved where it is ends the drag with the
/// reason; otherwise the drag keeps the bend it has.
pub fn pressAnswered(tables: *Table.Registry, answer: asks.Answer) void {
    const drag_state = gesture.get(tables);
    const editor = session.get(tables);
    if (!autoDragGoesOn(drag_state, editor)) return;
    answer.failure.check() catch |err| {
        const session_table = session.table(tables);
        const feedback = session.feedback(tables);
        gesture.reject(session_table, drag_state, editor, feedback, err);
        return;
    };
    const settings = config(tables);
    const solution = answer.solution();
    settings.bend.* = solution.reference;
    settings.achieved.* = solution.endpoint;
    settings.residual.* = solution.error_distance;
}

/// An Auto IK drag's solve: previews the chain's new rotations when any changed, and keeps the
/// solve's bend, endpoint and residual once its edit was admitted or found unnecessary, when the
/// sample it solved is no longer pending unless a later one came. An edit not admitted yet
/// (`error.Busy`) leaves the sample pending, to be asked again.
pub fn dragAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const drag_state = gesture.get(tables);
    const editor = session.get(tables);
    if (!autoDragGoesOn(drag_state, editor)) return;
    try answer.failure.check();
    const settings = config(tables);
    const solved = answer.channels();
    var changed = false;
    for (solved) |row| {
        const authored_channels = try readAuthoredChannels(tables, atoms, row.bone);
        if (!std.meta.eql(row.rotation, authored_channels.rotation)) {
            changed = true;
        }
    }
    if (changed) {
        // The answer's channels lie in the inbox's arena; the edit takes a copy of its own.
        const frame_allocator = try frameAllocator(tables);
        const updated_channels = try frame_allocator.alloc(api.PoseChannels, solved.len);
        for (updated_channels, solved) |*destination, row| {
            destination.* = try readAuthoredChannels(tables, atoms, row.bone);
            destination.rotation = row.rotation;
        }
        try submitDragPreview(tables, atoms, .{ .set_pose_channels = .{ .doc = drag_state.doc.*, .channels = updated_channels } });
    }
    const solution = answer.solution();
    settings.bend.* = solution.reference;
    settings.achieved.* = solution.endpoint;
    settings.residual.* = solution.error_distance;
    settings.last_target.* = answer.point;
    settings.has_target.* = 1;
    if (changed) settings.dragging.* = 1;
    // A sample that came while the solve was asked is still to be solved.
    const pointer_delta = session.Vec2.sub(drag_state.latest.*, drag_state.origin.*);
    const latest_target = session.Vec2.add(editor.gesture_local.*, pointer_delta);
    if (std.meta.eql(latest_target, answer.point)) drag_state.sample_pending.* = 0;
}

/// Working-pose edits and the selected key are admitted and published together.
fn submitDragPreview(tables: *Table.Registry, atoms: *Atom.Registry, edit: api.PreviewEdit) !void {
    const settings = config(tables);
    var edits: [2]api.PreviewEdit = undefined;
    edits[0] = edit;
    var count: usize = 1;
    if (settings.key_clip.* != 0) {
        const doc = session.get(tables).doc.*;
        edits[1] = .{ .sync_clip_key = .{ .doc = doc, .clip = settings.key_clip.*, .frame = settings.key_frame.* } };
        count += 1;
    }
    try gesture.openTransaction(tables, atoms, names.pose_drag);
    try gesture.submitPreview(tables, atoms, .incremental, edits[0..count]);
}

pub fn commitIK(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const settings = config(tables);
    if (settings.ik_end.* == 0) return;
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    const doc = session.get(tables).doc.*;
    if (controller(definition, settings.ik_end.*)) |i| try transport.send(tables, atoms, .{
        .set_ik = .{
            .doc = doc,
            .id = definition.ik[i].id,
            .chain = settings.ik_chain.*,
        },
    }) else try transport.send(tables, atoms, .{
        .add_ik = .{
            .doc = doc,
            .end_bone = settings.ik_end.*,
            .chain = settings.ik_chain.*,
        },
    });
    // Retain the draft on rejection; result callback clears it only on success.
}

pub fn copy(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    const captured = try figure.capturePoseClipboard(definition, try frameAllocator(tables));
    const clipboard_bones = clipboardBones(tables);
    const clipboard_ik = clipboardIK(tables);
    config(tables).clipboard_valid.* = 0;
    clipboard_bones.clear();
    clipboard_ik.clear();
    for (captured.bones) |clipboard_bone| _ = try clipboard_bones.insert(clipboard_bone);
    for (captured.ik) |clipboard_controller| _ = try clipboard_ik.insert(clipboard_controller);
    config(tables).clipboard_valid.* = 1;
}

pub fn paste(tables: *Table.Registry, atoms: *Atom.Registry) !api.Payload {
    if (config(tables).clipboard_valid.* == 0) return error.EmptyPoseClipboard;
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    const frame_allocator = try frameAllocator(tables);
    const clipboard_bones = clipboardBones(tables);
    const clipboard_ik = clipboardIK(tables);
    const bones = try frame_allocator.alloc(api.PoseClipboardBone, clipboard_bones.count());
    const controllers = try frame_allocator.alloc(api.PoseClipboardIK, clipboard_ik.count());
    var bone_rows = clipboard_bones.query();
    for (bones) |*clipboard_bone| clipboard_bone.* = session.readRow(ClipboardBone, bone_rows.next().?.view);
    var ik_rows = clipboard_ik.query();
    for (controllers) |*clipboard_controller| clipboard_controller.* = session.readRow(ClipboardIK, ik_rows.next().?.view);
    const remapped = try figure.remapPoseClipboard(definition, .{ .bones = bones, .ik = controllers }, frame_allocator);
    return .{ .set_pose = .{ .doc = session.get(tables).doc.*, .channels = remapped.channels, .ik = remapped.ik } };
}

pub fn handleAction(tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) !bool {
    const editor = session.get(tables);
    const settings = config(tables);
    const frame_allocator = try frameAllocator(tables);
    // The IK tool's draft chain also follows drawing's polygon keys.
    if (editor.tool.* == names.ik) {
        switch (tag.to(drawing.Msg)) {
            .figure_polygon_more => {
                stepIkChain(settings, .longer);
                return true;
            },
            .figure_polygon_less => {
                stepIkChain(settings, .shorter);
                return true;
            },
            else => {},
        }
    }
    const message = tag.to(Msg);
    switch (message) {
        .figure_pose_auto_ik, .figure_pose_chain_more, .figure_pose_chain_less => {
            if (gesture.busy(gesture.get(tables))) return error.PoseGestureSettling;
            switch (message) {
                .figure_pose_auto_ik => settings.auto_ik.* ^= 1,
                .figure_pose_chain_more => settings.auto_chain_length.* +|= 1,
                else => settings.auto_chain_length.* = @max(1, settings.auto_chain_length.* -| 1),
            }
        },
        .figure_tool_ik => {
            workspace.showAtRest(tables, atoms, names.rig, names.ik);
            settings.ik_end.* = 0;
        },
        .figure_ik_more => {
            if (editor.tool.* != names.ik) return false;
            stepIkChain(settings, .longer);
        },
        .figure_ik_less => {
            if (editor.tool.* != names.ik) return false;
            stepIkChain(settings, .shorter);
        },
        .figure_pose_save, .figure_pose_apply, .figure_ik_target, .figure_ik_values => try promptForPose(tables, atoms, editor, message, frame_allocator),
        .figure_pose_copy => {
            try copy(tables, atoms);
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Copied authored working pose (session clipboard)");
        },
        .figure_pose_paste => try filmstrip.editPose(tables, atoms, try paste(tables, atoms)),
        .figure_pose_reset, .figure_pose_reset_bone => {
            const whole_pose = message == .figure_pose_reset;
            if (!whole_pose and editor.active_bone.* == 0) return error.MissingBone;
            try filmstrip.editPose(tables, atoms, .{
                .reset_pose = .{
                    .doc = editor.doc.*,
                    .bone = if (whole_pose) 0 else editor.active_bone.*,
                },
            });
        },
        .figure_pose_mirror => try filmstrip.editPose(tables, atoms, .{ .mirror_pose = .{ .doc = editor.doc.* } }),
        .figure_pose_delete => {
            const id = if (editor.active_kind.* == names.pose) editor.active_id.* else settings.selected_pose.*;
            if (id == 0) return error.SelectSavedPose;
            try transport.send(tables, atoms, .{ .delete_pose = .{ .doc = editor.doc.*, .id = id } });
        },
        .figure_ik_pin, .figure_ik_unpin => {
            const controller_definition = try activeController(tables, atoms);
            try filmstrip.editPose(tables, atoms, if (message == .figure_ik_pin) .{
                .pin_ik = .{
                    .doc = editor.doc.*,
                    .id = controller_definition.id,
                },
            } else .{
                .unpin_ik = .{
                    .doc = editor.doc.*,
                    .id = controller_definition.id,
                },
            });
        },
        _ => return false,
    }
    return true;
}

const ChainStep = enum { longer, shorter };

/// Lengthens or shortens the IK tool's draft chain, never below one bone.
fn stepIkChain(settings: ConfigView, chain_step: ChainStep) void {
    settings.ik_chain.* = switch (chain_step) {
        .longer => settings.ik_chain.* +| 1,
        .shorter => @max(1, settings.ik_chain.* -| 1),
    };
}

/// Opens the prompt a named pose or IK action asks with: the IK ones about the active bone,
/// the others about the selection.
fn promptForPose(tables: *Table.Registry, atoms: *Atom.Registry, editor: session.View, message: Msg, frame_allocator: std.mem.Allocator) !void {
    const kind = switch (message) {
        .figure_pose_save => names.pose_save,
        .figure_pose_apply => names.pose_apply,
        .figure_ik_target => names.ik_target,
        .figure_ik_values => names.ik_values,
        else => unreachable,
    };
    workspace.finish(tables, atoms);
    var initial: []const u8 = "";
    switch (message) {
        .figure_ik_values => {
            const controller_definition = try activeController(tables, atoms);
            initial = try std.fmt.allocPrint(frame_allocator, "{d}:{d}:{d}:{d}", .{
                controller_definition.chain,
                controller_definition.bend,
                controller_definition.flags & 1,
                (controller_definition.flags >> 1) & 1,
            });
        },
        .figure_ik_target => _ = try activeController(tables, atoms),
        else => {},
    }
    const on_bone = message == .figure_ik_target or message == .figure_ik_values;
    const target_kind = if (on_bone) names.bone else editor.active_kind.*;
    const target_id = if (on_bone) editor.active_bone.* else editor.active_id.*;
    try prompts.showTarget(tables.memory, tables, atoms, kind, initial, target_kind, target_id);
}

fn parseNumber(text: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, std.mem.trim(u8, text, " \t"));
    if (!std.math.isFinite(value)) return error.NonFiniteNumber;
    return value;
}

pub fn submitPrompt(tables: *Table.Registry, atoms: *Atom.Registry, kind: Atom, text: []const u8) !bool {
    const editor = session.get(tables);
    if (kind == names.pose_save) {
        if (!zon.isSnakeCaseAtom(text)) return error.InvalidName;
        try transport.send(tables, atoms, .{ .save_pose = .{ .doc = editor.doc.*, .name = atoms.intern(text) } });
        return true;
    }
    if (kind == names.ik_values) {
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const controller_definition = definition.ik[controller(definition, editor.prompt_id.*) orelse return error.SelectIKEndJoint];
        var parts = std.mem.splitScalar(u8, text, ':');
        const chain = try std.fmt.parseInt(u32, parts.next() orelse return error.ExpectedIKValues, 10);
        const bend = try std.fmt.parseInt(i32, parts.next() orelse return error.ExpectedIKValues, 10);
        const stretch = try std.fmt.parseInt(u32, parts.next() orelse return error.ExpectedIKValues, 10);
        const pin = try std.fmt.parseInt(u32, parts.next() orelse return error.ExpectedIKValues, 10);
        if (parts.next() != null or stretch > 1 or pin > 1) return error.ExpectedIKValues;
        try transport.send(tables, atoms, .{
            .set_ik = .{
                .doc = editor.doc.*,
                .id = controller_definition.id,
                .chain = chain,
                .bend = bend,
                .flags = stretch | (pin << 1),
            },
        });
        return true;
    }
    if (kind == names.ik_target) {
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const controller_definition = definition.ik[controller(definition, editor.prompt_id.*) orelse return error.SelectIKEndJoint];
        var parts = std.mem.splitScalar(u8, text, ':');
        var xy = std.mem.splitScalar(u8, parts.next().?, ',');
        const x = try parseNumber(xy.next() orelse return error.ExpectedIKTarget);
        const y = try parseNumber(xy.next() orelse return error.ExpectedIKTarget);
        const angle = try parseNumber(parts.next() orelse return error.ExpectedIKTarget);
        if (parts.next() != null or xy.next() != null) return error.ExpectedIKTarget;
        try filmstrip.editPose(tables, atoms, .{
            .set_ik_target = .{
                .doc = editor.doc.*,
                .id = controller_definition.id,
                .target = .{
                    .x = x,
                    .y = y,
                },
                .target_rotation = angle * std.math.pi / 180,
            },
        });
        return true;
    }
    if (kind == names.bone_values and editor.prompt_mode.* == names.animate) {
        var parts = std.mem.splitScalar(u8, text, ':');
        const angle = parts.next().?;
        const length = parts.next();
        if (parts.next() != null) return error.ExpectedAngleLength;
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const authored_bone = try requireBone(definition, editor.prompt_id.*);
        if (authored_bone.flags & session.BoneFlags.static != 0) return error.StaticBone;
        var channels = try readAuthoredChannels(tables, atoms, authored_bone.id);
        if (angle.len != 0) channels.rotation = try requestedRotation(tables, atoms, authored_bone.id, try parseNumber(angle) * std.math.pi / 180);
        if (length) |length_text| if (length_text.len != 0) {
            const value = try parseNumber(length_text);
            if (@abs(value - (channels.length orelse authored_bone.length)) > 1e-6) {
                if (authored_bone.flags & session.BoneFlags.stretchy == 0) return error.BoneNotStretchy;
                channels.length = value;
            }
            if (value < 0) return error.InvalidLength;
        };
        try submitChannels(tables, atoms, channels);
        return true;
    }
    return false;
}

pub fn numericText(tables: *Table.Registry, atoms: *Atom.Registry, id: u32) ![]const u8 {
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    const authored_bone = try requireBone(definition, id);
    const working = try preview.workingEvaluation(tables, false);
    const solved_channels = try readSolvedChannels(working, id);
    const channels = try readAuthoredChannels(tables, atoms, id);
    if (authored_bone.flags & session.BoneFlags.stretchy == 0) return std.fmt.allocPrint(try frameAllocator(tables), "{d}:", .{
        solved_channels.rotation * 180 / std.math.pi,
    });
    return std.fmt.allocPrint(try frameAllocator(tables), "{d}:{d}", .{ solved_channels.rotation * 180 / std.math.pi, channels.length orelse authored_bone.length });
}

/// A displayed outgoing-frame correction must never become authored input again.
fn requestedRotation(tables: *Table.Registry, atoms: *Atom.Registry, id: u32, requested: f32) !?f32 {
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    const authored_bone = try requireBone(definition, id);
    const working = try preview.workingEvaluation(tables, false);
    const solved_channels = try readSolvedChannels(working, id);
    const channels = try readAuthoredChannels(tables, atoms, id);
    const delta = requested - solved_channels.rotation;
    const arc = std.math.atan2(@sin(delta), @cos(delta));
    if (@abs(arc) <= 1e-6) return channels.rotation;
    return (channels.rotation orelse authored_bone.rotation) + arc;
}

pub fn constraintText(tables: *Table.Registry, atoms: *Atom.Registry) []const u8 {
    const definition = session.readDefinition(tables, atoms, session.get(tables).doc.*) catch return "";
    const id = session.get(tables).active_bone.*;
    for (definition.pose_ik) |ik_state| if (ik_state.pose == 0 and ik_state.enabled != 0) {
        const controller_definition = session.findById(api.read.IK, definition.ik, ik_state.ik) orelse continue;
        var current = controller_definition.end_bone;
        var remaining = @min(controller_definition.chain, definition.bones.len);
        while (remaining > 0) : (remaining -= 1) {
            if (current == id) return "IK constrained: FK edits seeds; drag end to move target";
            current = (requireBone(definition, current) catch break).parent;
        }
        const authored_bone = requireBone(definition, id) catch continue;
        if (authored_bone.parent == controller_definition.end_bone) return "IK outgoing frame: displayed angle delta is applied once";
    };
    return "Joint: Auto IK / FK toolbar mode; shaft: rotate; Ctrl stretch; Alt root move.";
}

fn parseVector(text: []const u8) !session.Vec2 {
    var parts = std.mem.splitScalar(u8, text, ',');
    const x = try parseNumber(parts.next() orelse return error.ExpectedVector);
    const y = try parseNumber(parts.next() orelse return error.ExpectedVector);
    if (parts.next() != null) return error.ExpectedVector;
    return .{ .x = x, .y = y };
}

pub fn fieldCommand(tables: *Table.Registry, atoms: *Atom.Registry, id: u32, field: []const u8, text: []const u8) !api.Payload {
    const definition = try session.readDefinition(tables, atoms, session.get(tables).doc.*);
    const authored_bone = try requireBone(definition, id);
    if (authored_bone.flags & session.BoneFlags.static != 0) return error.StaticBone;
    var channels = try readAuthoredChannels(tables, atoms, id);
    if (std.mem.eql(u8, field, "angle")) channels.rotation = try requestedRotation(tables, atoms, id, try parseNumber(text) * std.math.pi / 180) else if (std.mem.eql(u8, field, "length")) {
        const value = try parseNumber(text);
        if (value < 0) return error.InvalidLength;
        if (@abs(value - (channels.length orelse authored_bone.length)) > 1e-6) {
            if (authored_bone.flags & session.BoneFlags.stretchy == 0) return error.BoneNotStretchy;
            channels.length = value;
        }
    } else if (std.mem.eql(u8, field, "local")) {
        const value = try parseVector(text);
        if (!std.meta.eql(value, channels.local orelse authored_bone.local)) {
            if (authored_bone.flags & session.BoneFlags.connected != 0) return error.ConnectedBoneOffset;
            channels.local = value;
        }
    } else if (std.mem.eql(u8, field, "scale")) channels.scale = try parseVector(text) else return error.PoseFieldReadOnly;
    const before = try readAuthoredChannels(tables, atoms, id);
    if (channels.length != null and @abs(channels.length.? - (before.length orelse authored_bone.length)) <= 1e-6) channels.length = before.length;
    if (channels.local != null and std.meta.eql(channels.local.?, before.local orelse authored_bone.local)) channels.local = before.local;
    if (channels.scale != null and std.meta.eql(channels.scale.?, before.scale orelse authored_bone.scale)) channels.scale = before.scale;
    const updated_channels = try (try frameAllocator(tables)).alloc(api.PoseChannels, if (std.meta.eql(channels, before)) 0 else 1);
    if (updated_channels.len != 0) updated_channels[0] = channels;
    return .{ .set_pose_channels = .{ .doc = session.get(tables).doc.*, .channels = updated_channels } };
}

pub fn editableText(tables: *Table.Registry, atoms: *Atom.Registry, id: u32, field: []const u8) ![]const u8 {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return editableTextWithReads(&reads, id, field);
}

pub fn editableTextWithReads(reads: *session.ReadContext, id: u32, field: []const u8) ![]const u8 {
    const editor = session.get(reads.tables);
    const definition = try reads.definition(editor.doc.*);
    const evaluation = try preview.workingEvaluation(reads.tables, false);
    const solved_channels = try readSolvedChannels(evaluation, id);
    const allocator = try reads.readAllocator();
    if (std.mem.eql(u8, field, "angle")) return std.fmt.allocPrint(allocator, "{d}", .{solved_channels.rotation * 180 / std.math.pi});
    const channels = authoredChannelsFromDefinition(definition, id);
    const authored_bone = try requireBone(definition, id);
    if (std.mem.eql(u8, field, "length")) return std.fmt.allocPrint(allocator, "{d}", .{channels.length orelse authored_bone.length});
    const value = if (std.mem.eql(u8, field, "local")) channels.local orelse authored_bone.local else channels.scale orelse authored_bone.scale;
    return std.fmt.allocPrint(allocator, "{d},{d}", .{ value.x, value.y });
}

/// Only Rig changes the skeleton's structure. The tab is not a runtime command permission:
/// explicit figure.cmd remains independent of it.
pub fn guardRigAction(editor: session.View, tag: Atom) !void {
    if (editor.mode.* == names.rig) return;
    if (tag.to(Msg) == .figure_ik_values) return error.PoseRigEditRequiresRig;
    switch (tag.to(workspace.Msg)) {
        .figure_delete_branch, .figure_reparent, .figure_mirror_branch => return error.PoseRigEditRequiresRig,
        // Design's Delete removes artwork, so only Animate refuses it.
        .figure_delete_bone => if (filmstrip.enabled(editor)) return error.PoseRigEditRequiresRig,
        .figure_rename => if (editor.active_kind.* == names.bone) return error.PoseRigEditRequiresRig,
        else => {},
    }
}

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try session.prepareSingleton(Config, mem, atoms, tables, config_name);
    try session.prepareTable(ClipboardBone, mem, atoms, tables, clipboard_bones_name, clipboard_capacity);
    try session.prepareTable(ClipboardIK, mem, atoms, tables, clipboard_ik_name, clipboard_capacity);
    try session.prepareTable(DragChainLink, mem, atoms, tables, drag_chain_name, drag_chain_capacity);
}
