//! The pose the canvas shows for the open definition, decided from editor state each time it is
//! asked: rest while designing, a weight test pose, the selected clip at the filmstrip's time, or
//! the authored working pose. The Figure system holds no instance for it. Only the filmstrip's
//! playback clock, kept in its settings, advances, and only through `advance`. What the pose
//! evaluates to the editor reads from its watches (`watches.zig`), a frame behind a change of pose.
const std = @import("std");
const mesha = @import("mesha");
const watches = @import("watches.zig");
const Atom = mesha.Atom;
const names = @import("names.zig");
const Table = mesha.Table;
const figure = mesha.figure;
const weight = @import("weight.zig");
const session = @import("session.zig");
const filmstrip = @import("filmstrip.zig");
const api = figure;
pub const name = "editor_figure_preview";
pub const Data = struct {
    /// Changes whenever what the preview shows may have changed, so a hover pick made against
    /// the old pose can be dropped.
    version: u64 = 0,
    /// The fingerprint `version` last changed for.
    pose_key: u64 = 0,
    /// The filmstrip clip the preview plays, by name, or none. `sync` reads it from the
    /// definition once per update, so queries in between need not.
    clip: Atom = api.none,
    /// Set while the open definition is being closed: the canvas shows nothing until the close
    /// has either succeeded or failed.
    closing: u8 = 0,
};
pub const View = session.Row(Data);
pub fn state(tables: *Table.Registry) View {
    const state_table = tables.findByName(Atom.from(name)).?;
    return state_table.getRow(.{ .row = 0, .generation = state_table.rowGeneration(0) }, View).?;
}

pub fn ensure(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try session.prepareSingleton(Data, tables.memory, atoms, tables, name);
}

pub fn reopen(preview_state: View) void {
    preview_state.closing.* = 0;
}

/// Shows nothing until the asynchronous close has either succeeded or failed.
pub fn closing(preview_state: View) void {
    preview_state.closing.* = 1;
}

pub const ui_reserve = api.Reserve{ .draws = 256, .uniforms = 256, .gpu_points = 4096, .shapes = 256, .gpu_vertices = 16384, .cpu_vertices = 8192, .indirect_draws = 256 };

/// Whether the canvas has a definition to show: not while it closes, nor before its first
/// generation compiles.
pub fn ready(tables: *Table.Registry, atoms: *Atom.Registry) error{ NotReady, Busy }!void {
    if (state(tables).closing.* != 0) return error.Busy;
    const doc = session.get(tables).doc.*;
    if (doc == session.none) return error.NotReady;
    const info = session.definitionInfo(tables, atoms, doc) orelse return error.NotReady;
    if (!info.editor_open or info.effective_revision == null) return error.NotReady;
}

/// The definition and pose the canvas shows now. Custom inputs live in frame scratch.
pub fn current(tables: *Table.Registry, atoms: *Atom.Registry) !api.PosedFigure {
    try ready(tables, atoms);
    const editor = session.get(tables);
    return .{ .definition = editor.doc.*, .pose = try currentPose(tables) };
}

fn currentPose(tables: *Table.Registry) !api.Pose {
    const editor = session.get(tables);
    const settings = filmstrip.config(tables);
    const clip = state(tables).clip.*;
    if (clip != api.none and filmstrip.enabled(session.get(tables)) and settings.preview.* != 0) {
        return .{ .clip = .{ .clip = clip, .time = settings.seconds.* } };
    }
    // The weight brush paints on the working pose, so weights are judged on a bent figure.
    const brushing = editor.tool.* == names.weight;
    if (session.atRest(editor) and !brushing) return .rest;
    if (brushing and weight.config(tables).test_pose.* != 0) {
        const allocator = (try tables.memory.frameScratchAllocator()).allocator;
        return .{ .custom_inputs = try weight.previewInputs(weight.boneStates(tables), allocator) };
    }
    return .working;
}

/// The open definition's working pose, or its rest pose, evaluated: the host's until it next
/// publishes, `error.NotReady` while no watch has it answered.
pub fn workingEvaluation(tables: *Table.Registry, rest: bool) !api.Evaluation {
    const doc = session.get(tables).doc.*;
    const posed: api.PosedFigure = .{ .definition = doc, .pose = if (rest) .rest else .working };
    return watches.evaluation(tables, posed);
}

pub fn workingInputs(tables: *Table.Registry, atoms: *Atom.Registry) !api.CustomInputs {
    return poseInputs(tables, atoms, 0);
}

pub fn poseInputs(tables: *Table.Registry, atoms: *Atom.Registry, pose: u32) !api.CustomInputs {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return poseInputsWithReads(&reads, pose);
}

fn poseInputsWithReads(reads: *session.ReadContext, pose: u32) !api.CustomInputs {
    const editor = session.get(reads.tables);
    const data = try reads.definition(editor.doc.*);
    const frame_allocator = try reads.readAllocator();
    var channels: std.ArrayListUnmanaged(api.PoseChannels) = .empty;
    errdefer channels.deinit(frame_allocator);
    var ik: std.ArrayListUnmanaged(api.PoseIK) = .empty;
    errdefer ik.deinit(frame_allocator);
    for (data.pose_channels) |row| if (row.pose == pose) {
        try channels.append(frame_allocator, .{
            .bone = row.bone,
            .rotation = if (row.mask & api.read.Channels.rotation != 0) row.rotation else null,
            .local = if (row.mask & api.read.Channels.local != 0) row.local else null,
            .scale = if (row.mask & api.read.Channels.scale != 0) row.scale else null,
            .length = if (row.mask & api.read.Channels.length != 0) row.length else null,
        });
    };
    for (data.pose_ik) |row| if (row.pose == pose) {
        try ik.append(frame_allocator, .{
            .ik = row.ik,
            .target = row.target,
            .target_rotation = row.target_rotation,
            .enabled = row.enabled,
            .pinned = row.pinned,
            .bend_side = row.bend_side,
            .pole_angle = row.pole_angle,
        });
    };
    const owned_channels = try channels.toOwnedSlice(frame_allocator);
    errdefer frame_allocator.free(owned_channels);
    const owned_ik = try ik.toOwnedSlice(frame_allocator);
    errdefer frame_allocator.free(owned_ik);
    // The values the pose gives the definition's other properties, so a ghost looks as the
    // key does and not only its bones.
    var values: std.ArrayListUnmanaged(api.PoseProperty) = .empty;
    errdefer values.deinit(frame_allocator);
    for (data.pose_properties) |row| if (row.pose == pose) {
        const family = std.enums.fromInt(api.PropertyFamily, row.family) orelse continue;
        try values.append(frame_allocator, .{ .family = family, .target = row.target, .index = row.index, .field = row.field, .value = row.value });
    };
    return .{ .channels = owned_channels, .ik = owned_ik, .properties = try values.toOwnedSlice(frame_allocator) };
}

/// Picks up the filmstrip's clip and bumps `version` when the shown pose may differ from the
/// last sync's. Runs from editor update.
pub fn sync(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const preview_state = state(tables);
    const settings = filmstrip.config(tables);
    const plays_clip = filmstrip.enabled(session.get(tables)) and settings.preview.* != 0;
    const selected = if (plays_clip) filmstrip.clipRow(tables, atoms) else null;
    preview_state.clip.* = if (selected) |clip| clip.name else api.none;
    const shown = current(tables, atoms) catch |err| switch (err) {
        error.NotReady, error.Busy => return,
        else => return err,
    };
    const info = session.definitionInfo(tables, atoms, shown.definition) orelse return;
    var hash = std.hash.Wyhash.init(0);
    hashValue(&hash, shown.definition);
    hashValue(&hash, info.authored_revision);
    hashValue(&hash, info.effective_revision);
    hashPose(&hash, shown.pose);
    const pose_key = hash.final();
    if (pose_key == preview_state.pose_key.*) return;
    preview_state.pose_key.* = pose_key;
    preview_state.version.* +%= 1;
}

/// Whether `a` and `b` are the same pose: the same values, wherever their slices are.
pub fn samePose(a: api.Pose, b: api.Pose) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .rest, .working => true,
        .saved_pose => |id| id == b.saved_pose,
        .clip => |clip| std.meta.eql(clip, b.clip),
        .custom_inputs => |inputs| sameInputs(inputs, b.custom_inputs),
    };
}

fn sameInputs(a: api.CustomInputs, b: api.CustomInputs) bool {
    return sameRows(api.PoseChannels, a.channels, b.channels) and
        sameRows(api.PoseIK, a.ik, b.ik) and
        sameRows(api.PoseProperty, a.properties, b.properties);
}

fn sameRows(comptime Row: type, a: []const Row, b: []const Row) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_row, b_row| {
        if (!std.meta.eql(a_row, b_row)) return false;
    }
    return true;
}

fn hashPose(hash: *std.hash.Wyhash, pose: api.Pose) void {
    hashValue(hash, std.meta.activeTag(pose));
    switch (pose) {
        .rest, .working => {},
        .saved_pose => |id| hashValue(hash, id),
        .clip => |clip| hashValue(hash, clip),
        .custom_inputs => |inputs| {
            hashValue(hash, inputs.channels.len);
            for (inputs.channels) |channel| hashValue(hash, channel);
            hashValue(hash, inputs.ik.len);
            for (inputs.ik) |ik| hashValue(hash, ik);
            hashValue(hash, inputs.properties.len);
            for (inputs.properties) |property| hashValue(hash, property);
        },
    }
}

// Hash values rather than optional/struct padding.
fn hashValue(hash: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => inline for (std.meta.fields(@TypeOf(value))) |field| hashValue(hash, @field(value, field.name)),
        .optional => {
            const present = [_]u8{@intFromBool(value != null)};
            hash.update(&present);
            if (value) |item| hashValue(hash, item);
        },
        else => hash.update(std.mem.asBytes(&value)),
    }
}

/// The shown pose's bones: the host's until it next publishes a change, `error.NotReady` while
/// the pose the canvas shows now has not been answered.
pub fn evaluation(tables: *Table.Registry, atoms: *Atom.Registry) !api.Evaluation {
    const shown = try current(tables, atoms);
    return watches.evaluation(tables, shown);
}

pub const RenderResult = struct {
    /// The shown pose's bones, for the overlays: the host's until it next publishes a change.
    /// Null when the pose has none, as `fallback_error` says, or with no error while the pose the
    /// canvas shows now has not been answered yet, as in the frame after it changed.
    evaluation: ?api.Evaluation = null,
    /// Why the figure was not drawn: its pose's or its drawing's failure, or the context's refusal.
    render_error: ?anyerror = null,
    /// Why there is no evaluation for the overlays.
    fallback_error: ?anyerror = null,
};

/// Draws the canvas's pose into `render_context` from the drawing its watch published
/// (`watches.Key.shown`), leaving `ui_reserve` of the context's budget for the overlays, and
/// returns the pose's evaluation, which a drawing that failed or was refused leaves for the
/// overlays without changing the editor's status. A pose not answered yet draws nothing and is
/// no failure: its watch is answered at the end of the frame. Writes no table.
pub fn renderEvaluated(tables: *Table.Registry, atoms: *Atom.Registry, render_context: anytype) !RenderResult {
    const shown = try current(tables, atoms);
    const found = watches.shownAnswer(tables, shown) catch |err| switch (err) {
        error.NotReady => return .{},
        else => return .{ .render_error = err, .fallback_error = err },
    };
    const evaluated = found.published.evaluation orelse return .{};
    var result = RenderResult{ .evaluation = evaluated.* };
    found.published.drawing_failure.check() catch |err| {
        result.render_error = err;
        return result;
    };
    // None while the workspace is hidden, when none was asked for.
    const drawing = found.published.drawing orelse return result;
    _ = api.draw(drawing, ui_reserve, render_context) catch |err| {
        result.render_error = err;
    };
    return result;
}

/// The filmstrip's playback clock: the time subscription is its only advance. A looping clip
/// wraps; another stops on its last frame.
pub fn advance(tables: *Table.Registry, atoms: *Atom.Registry, dt: f64) !void {
    if (!std.math.isFinite(dt) or dt < 0 or dt > std.math.floatMax(f32)) return;
    const settings = filmstrip.config(tables);
    if (!filmstrip.enabled(session.get(tables)) or settings.playing.* == 0) return;
    const clip = filmstrip.clipRow(tables, atoms) orelse return error.SelectClip;
    try filmstrip.validDuration(clip);
    settings.preview.* = 1;
    settings.key_selected.* = 0;
    const fps: f64 = clip.fps;
    const frames: f64 = @floatFromInt(clip.frames);
    const last_frame_seconds = (frames - 1) / fps;
    var seconds = @as(f64, settings.seconds.*) + dt;
    if (clip.loop != 0) {
        seconds = @mod(seconds, frames / fps);
    } else if (seconds >= last_frame_seconds) {
        seconds = last_frame_seconds;
        settings.playing.* = 0;
    }
    settings.seconds.* = @floatCast(seconds);
    settings.frame.* = @intFromFloat(@min(frames - 1, @floor(seconds * fps)));
}

/// The contour of `shape` in the shown pose, at the hit tests' tolerance: the host's until it next
/// publishes. Only the shape under the pointer and the selected shapes are watched.
pub fn geometry(tables: *Table.Registry, atoms: *Atom.Registry, shape: u32) !api.ShapeGeometry {
    const shown = try current(tables, atoms);
    return watches.contour(tables, shown, shape);
}
