//! The figure editor's watches (`mesha.figure.Watch`): what it reads of the open definition
//! every frame, which the figure host answers in `figure_published` once it has applied the
//! frame's commands. One kernel, in the last of the figure editor's systems, declares them from
//! the frame's final state, so the frame's drawing reads what it declared and the next frame's
//! kernels read it as of their start, exactly as fresh as the document tables.
//!
//! A reader finds an answer by its key and checks it answers what it wants now: the open
//! definition, in the pose it would ask for. A kernel that changed what is watched (the tool, the
//! mode, the filmstrip's time, the selection) reads `error.NotReady` until the host has answered
//! the change, the next frame.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const sequencer = mesha.sequencer;
const figure = mesha.figure;
const panels_mod = mesha.panels;
const names = @import("names.zig");
const session = @import("session.zig");
const preview = @import("preview.zig");
const filmstrip = @import("filmstrip.zig");
const geometry = @import("geometry.zig");
const workspace = @import("workspace.zig");
const weight = @import("weight.zig");
const gesture = @import("gesture.zig");

/// The system that declares the watches, and so the subscriber the host's answers name.
pub const system_name = "figure_watches";
/// The subscriber `figure_published` names for the editor's answers.
pub const subscriber = Atom.from(system_name);

/// The editor's watches, each a `Watch.key`.
pub const Key = enum(u32) {
    /// The pose the canvas shows (`preview.current`): its evaluation, its drawing while the
    /// workspace is shown, its weights while the weight brush is in hand, and the contours of
    /// the shape under the pointer and of the selected shapes.
    shown,
    /// The working pose's evaluation, while posing needs it and the canvas shows another pose.
    working,
    /// The authored content and the figure's extent, while a definition is open, and the rest
    /// pose's evaluation while an IK chain is chosen on a canvas showing another pose. The host
    /// publishes the content whatever the compile or the pose come to.
    rest,
    /// The onion skin of the clip's key before the filmstrip's frame, drawing only.
    ghost_before,
    /// The onion skin of the clip's key after the filmstrip's frame, drawing only.
    ghost_after,
};

const watches_table = Atom.from(figure.watches_table_name);

/// Declares the watches: last among the figure editor's systems, so it sees the frame's state.
pub fn system() sequencer.System {
    return .{
        .name = system_name,
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claimsNothing,
        .active = active,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_watches.declare", .run = declare },
        },
    };
}

fn claimsNothing(tag: Atom) bool {
    _ = tag;
    return false;
}

/// While the figure workspace is hidden nothing of the figure editor shows, so it watches nothing
/// and the host evaluates nothing for it: switched off, its rows go (`sequencer.Subscribed`). It
/// runs on while a figure system does for work it left unfinished and may read the answers for:
/// a drag settling (`gesture`) and an animation edit's transaction (`filmstrip`). The canvas,
/// which runs hidden for its requests, and the document system, which runs hidden when the
/// catalog moves, read the content only when it is there, and follow it again once the
/// workspace shows. Shown again, the watches are declared at the end of that frame's run and
/// answered before its drawing; that frame's earlier kernels read `error.NotReady`, as after any
/// change of what is watched.
fn active(frame: *const sequencer.Frame) bool {
    if (workspace.shown(frame)) return true;
    const tables = frame.tables;
    if (gesture.busy(gesture.get(tables))) return true;
    return filmstrip.config(tables).transaction.* != filmstrip.Transaction.none;
}

/// Its watches, and every editor row they follow from. Without `subscriptions.figure`, as in a
/// test with no figure host, it does not run.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    _ = frame;
    var result: sequencer.Access = .{};
    result.write(watches_table);
    declareReads(&result);
    result.readAll(&workspace.table_groups.state);
    result.readAll(&workspace.table_groups.selected);
    // The weight brush's test pose is the canvas's while it is on.
    result.read(Atom.from(weight.bones_name));
    result.read(Atom.from(panels_mod.nodes_table_name));
    result.read(Atom.from(panels_mod.state_table_name));
    return result;
}

/// Declares what a figure system reads of the figure host's publications: the catalog's
/// `figure_definitions`, the answers in `figure_published`, and the watches they answer.
pub fn declareReads(result: *sequencer.Access) void {
    result.read(Atom.from(figure.definitions_table_name));
    result.read(Atom.from(figure.published_table_name));
    result.read(watches_table);
}

/// Appends the watches of the open definition: none when there is none, and `shown` only once
/// the canvas has a pose to show.
fn declare(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const atoms = frame.atoms;
    // Through the run, so the sequencer names this system the rows' subscriber.
    _ = try pass.writeTable(watches_table);
    const watch_rows = figure.Watches.of(frame.memory, tables, figure.watches_table_name);
    const editor = session.get(tables);
    const doc = editor.doc.*;
    if (doc == session.none) return;
    const shown: ?figure.PosedFigure = preview.current(tables, atoms) catch |err| switch (err) {
        error.NotReady, error.Busy => null,
        else => return err,
    };
    const shown_pose: ?PoseKind = if (shown) |posed| std.meta.activeTag(posed.pose) else null;

    const zoom = editor.view_zoom.*;
    const zoom_usable = std.math.isFinite(zoom) and zoom > 0;
    const view_zoom = if (zoom_usable) zoom else 1;
    const camera = canvasCamera(tables, atoms, editor.view_center.*, view_zoom);

    const rest_evaluated = choosingChain(editor) and !shows(shown_pose, .rest);
    try watch_rows.tryPush(.{ .key = @intFromEnum(Key.rest), .definition = doc, .pose = .rest, .wants = .{ .definition = true, .bounds = true, .evaluation = rest_evaluated } });
    if (shown) |posed| {
        const shown_watch = try shownWatch(frame, editor, posed, camera);
        try watch_rows.tryPush(shown_watch);
    }
    const posing = filmstrip.enabled(editor) or choosingChain(editor);
    if (posing and !shows(shown_pose, .working)) {
        try watch_rows.tryPush(.{ .key = @intFromEnum(Key.working), .definition = doc, .pose = .working, .wants = .{ .evaluation = true } });
    }
    if (workspace.shown(frame)) try declareGhosts(tables, atoms, watch_rows, doc, camera);
}

/// The transform the canvas draws the figure under (`workspace.canvasDrawTransform`), which the
/// drawings are prepared for and the weights sampled under. Without the stage panel laid out, as
/// in a test of the figure editor alone, the camera over an empty canvas, whose scale is the
/// view's: a drawing prepared for it is drawn under whatever transform the drawing context has.
fn canvasCamera(tables: *Table.Registry, atoms: *Atom.Registry, center: session.Vec2, zoom: f32) mesha.math.Affine2f {
    if (workspace.canvasDrawTransform(tables, atoms, center, zoom)) |drawn_under| return drawn_under;
    return geometry.affine(.{}, center, zoom);
}

const PoseKind = std.meta.Tag(figure.Pose);

/// Whether the canvas shows a pose of `kind`, whose evaluation `shown` carries.
fn shows(shown_pose: ?PoseKind, kind: PoseKind) bool {
    const found = shown_pose orelse return false;
    return found == kind;
}

/// The canvas's pose, `posed`: its evaluation, its drawing for `camera` (`canvasCamera`) while the
/// workspace is shown, the weights while the brush is in hand, and the contours the canvas
/// outlines. Its slices are in frame scratch, copied when the row is appended.
fn shownWatch(frame: *const sequencer.Frame, editor: session.View, posed: figure.PosedFigure, camera: mesha.math.Affine2f) !figure.Watch {
    const allocator = (try frame.memory.frameScratchAllocator()).allocator;
    const contours = try contourShapes(allocator, editor, session.selections(frame.tables));
    const zoom = editor.view_zoom.*;
    const zoom_usable = std.math.isFinite(zoom) and zoom > 0;
    return .{
        .key = @intFromEnum(Key.shown),
        .definition = posed.definition,
        .pose = posed.pose,
        .wants = .{
            .evaluation = true,
            .drawing = workspace.shown(frame),
            .weights = editor.tool.* == names.weight,
            .contours = contours.len != 0,
        },
        // Flattened, and the weight overlay sampled, at the canvas's tolerance.
        .draw = .{ .transform = camera },
        .weight = .{ .sample_transform = camera },
        .contours = contours,
        // The tolerance the canvas's hit tests use: 4 pixels at the view's zoom.
        .contour_tolerance = if (zoom_usable) 4 / zoom else 4,
    };
}

/// Rig's IK tool picks a chain's end joint on the rest pose.
fn choosingChain(editor: session.View) bool {
    return editor.mode.* == names.rig and editor.tool.* == names.ik;
}

/// The shapes whose contours the canvas outlines: the one under the pointer, then the selected
/// ones, each once. In `allocator`.
fn contourShapes(allocator: std.mem.Allocator, editor: session.View, selected: session.SelectionRows) ![]const u32 {
    var shapes: std.ArrayList(u32) = .empty;
    const hovered: ?u32 = if (editor.hover_kind.* == names.shape) editor.hover_id.* else null;
    if (hovered) |id| try shapes.append(allocator, id);
    // A selection row is one per item: only the hovered shape can come twice.
    var rows = selected.read();
    while (rows.next()) |row| {
        if (row.view.doc.* != editor.doc.* or row.view.kind.* != names.shape) continue;
        const id = row.view.id.*;
        const is_hovered = if (hovered) |hovered_id| hovered_id == id else false;
        if (is_hovered) continue;
        try shapes.append(allocator, id);
    }
    return shapes.items;
}

/// The onion skins' drawings for `camera`, while the filmstrip shows them: the keys either side
/// of its frame, tinted red before and green after.
fn declareGhosts(tables: *Table.Registry, atoms: *Atom.Registry, watch_rows: figure.Watches, doc: Atom, camera: mesha.math.Affine2f) !void {
    const editor = session.get(tables);
    const settings = filmstrip.config(tables);
    if (!filmstrip.enabled(editor) or settings.onion.* == 0) return;
    const clip = filmstrip.clipRow(tables, atoms) orelse return;
    // A definition not published yet has no keys to show.
    const clip_keys = filmstrip.keys(tables, atoms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const poses = filmstrip.ghostPoses(clip_keys, settings.frame.*, clip.loop != 0);
    const ghosts = [_]struct { key: Key, color: [3]u8 }{
        .{ .key = .ghost_before, .color = .{ 255, 0, 0 } },
        .{ .key = .ghost_after, .color = .{ 0, 255, 0 } },
    };
    for (poses, ghosts) |found, ghost| {
        const pose_id = found orelse continue;
        const inputs = try preview.poseInputs(tables, atoms, pose_id);
        try watch_rows.tryPush(.{
            .key = @intFromEnum(ghost.key),
            .definition = doc,
            .pose = .{ .custom_inputs = inputs },
            .wants = .{ .drawing = true },
            .draw = .{ .transform = camera },
            .options = .{ .opacity = 0.3, .color_override = ghost.color },
        });
    }
}

// ---- reading the answers ------------------------------------------------------------------

/// One of the editor's watches as `subscriptions.figure` holds it, and what the host published
/// for it. The watch's slices last while its row does, until the editor's watches are declared
/// again; what the answer points at is the host's, until it next publishes a change.
pub const Answer = struct { watch: figure.Watch, published: figure.Published };

/// The answer to the editor's watch `key`, null before the host has answered it or once the
/// editor stopped declaring it. It needs the editor's own row in `subscriptions.figure`: after
/// the subscriptions are reset, as when a plugin loads, the host still answers the watches it
/// kept, but until `figure_watches` has run again at the end of that frame there is no row,
/// so the editor's kernels read `error.NotReady` that frame.
pub fn answer(tables: *Table.Registry, key: Key) ?Answer {
    const watch = ownWatch(tables, key) orelse return null;
    const published = figure.published(tables, subscriber, @intFromEnum(key)) orelse return null;
    return .{ .watch = watch, .published = published };
}

fn ownWatch(tables: *Table.Registry, key: Key) ?figure.Watch {
    const watch_rows = figure.Watches.of(tables.memory, tables, figure.watches_table_name);
    var rows = watch_rows.iterate();
    while (rows.next()) |watch| {
        if (rows.subscriber() != subscriber) continue;
        if (watch.key == @intFromEnum(key)) return watch;
    }
    return null;
}

/// Whether `watch` is of `posed`'s definition in `posed`'s pose.
fn watches(watch: figure.Watch, posed: figure.PosedFigure) bool {
    if (watch.definition != posed.definition) return false;
    return preview.samePose(watch.pose, posed.pose);
}

/// `doc`'s authored content as the host last published it, which is the host's until it next
/// publishes; `error.NotReady` when it has published none of `doc`.
pub fn content(tables: *Table.Registry, doc: Atom) error{NotReady}!*const figure.read.Definition {
    const published = figure.published(tables, subscriber, @intFromEnum(Key.rest)) orelse return error.NotReady;
    if (published.definition != doc) return error.NotReady;
    return published.content orelse error.NotReady;
}

/// The evaluation of `posed` a watch carries, the host's until it next publishes a change: the
/// pose's failure when it could not be evaluated, `error.NotReady` when no watch has it answered.
pub fn evaluation(tables: *Table.Registry, posed: figure.PosedFigure) figure.Error!figure.Evaluation {
    const keys = [_]Key{ .shown, .working, .rest };
    for (keys) |key| {
        const found = answer(tables, key) orelse continue;
        if (!watches(found.watch, posed)) continue;
        try found.published.failure.check();
        const evaluated = found.published.evaluation orelse continue;
        return evaluated.*;
    }
    return error.NotReady;
}

/// The weights of the canvas's pose `posed`, sampled at the canvas's tolerance; the host's until
/// it next publishes a change.
pub fn weights(tables: *Table.Registry, posed: figure.PosedFigure) figure.Error!figure.WeightGeometry {
    const found = try shownAnswer(tables, posed);
    const published = found.published.weights orelse return error.NotReady;
    return published.*;
}

/// The contour of `shape` in the canvas's pose `posed`, at the canvas's hit tolerance, the
/// host's until it next publishes a change: no points for a shape the definition does not
/// have, `error.NotReady` for one the canvas does not outline.
pub fn contour(tables: *Table.Registry, posed: figure.PosedFigure, shape: u32) figure.Error!figure.ShapeGeometry {
    const found = try shownAnswer(tables, posed);
    const index = std.mem.indexOfScalar(u32, found.watch.contours, shape) orelse return error.NotReady;
    if (index >= found.published.contours.len) return error.NotReady;
    return found.published.contours[index];
}

/// The answer to the watch of the canvas's pose `posed`, what the host published for it until it
/// next publishes a change: the pose's failure when it could not be evaluated, `error.NotReady`
/// while no watch of `posed` has been answered. Its drawing may still have failed
/// (`drawing_failure`).
pub fn shownAnswer(tables: *Table.Registry, posed: figure.PosedFigure) figure.Error!Answer {
    const found = answer(tables, .shown) orelse return error.NotReady;
    if (!watches(found.watch, posed)) return error.NotReady;
    try found.published.failure.check();
    return found;
}

/// The host's answer measuring `doc`'s extent over its rest pose and saved poses, as of the
/// compiled generation it last published (`Published.revision`): its `bounds`, null for a figure
/// that draws nothing, or its `failure`. Null before the editor's watch of `doc` is answered.
pub fn extent(tables: *Table.Registry, doc: Atom) ?figure.Published {
    const found = answer(tables, .rest) orelse return null;
    if (found.watch.definition != doc or !found.watch.wants.bounds) return null;
    return found.published;
}
